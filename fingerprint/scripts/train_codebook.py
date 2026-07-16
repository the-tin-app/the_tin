# fingerprint/scripts/train_codebook.py
"""Train the shared BoVW codebook over a stratified sample of catalog art and
write fpcore/codebook.bin (committed shared artifact). Deterministic given
--seed and the cached image set.

Usage:
  python scripts/train_codebook.py --catalog PATH/catalog.sqlite \
      --per-set 6 --max-cards 1200 --seed 0 --out fpcore/codebook.bin
"""
import argparse
import os
import sqlite3
import numpy as np
from fpcore import build, codebook as cb, canonicalize, descriptors as d, constants as c
from build_fingerprints import make_cached_loader


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--per-set", type=int, default=6)
    ap.add_argument("--max-cards", type=int, default=1200)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "fpcore", "codebook.bin"))
    args = ap.parse_args()

    cat = sqlite3.connect(args.catalog)
    rows = cat.execute(
        "SELECT id, image_base, set_id FROM card WHERE image_base IS NOT NULL").fetchall()
    cat.close()
    sample = build.stratified_sample(rows, args.per_set, args.max_cards, args.seed)
    print(f"sampled {len(sample)} cards for training")

    loader = make_cached_loader()
    card_descriptors = []
    for i, (card_id, image_base) in enumerate(sample):
        bgr = loader(card_id, image_base)
        if bgr is None:
            continue
        _, desc = d.extract(canonicalize.canonicalize(bgr))
        if len(desc):
            card_descriptors.append(desc)
        if (i + 1) % 100 == 0:
            print(f"  extracted {i + 1}/{len(sample)}")

    book = cb.train(card_descriptors, K=c.CODEBOOK_K, seed=args.seed, iters=10)
    book.save(args.out)
    print(f"wrote {args.out} (K={book.K}) codebook_hash={book.sha256_hex()}")


if __name__ == "__main__":
    main()
