"""Backfill global_vec on an EXISTING fingerprints.sqlite, in place.

Reverses the 2026 decision to leave global_vec empty (see fpcore/build.py):
the photo-inventory lens has no OCR gate to narrow candidates, so it needs
BoVW nearest-neighbour narrowing over the whole pack. This computes
global_vec from the descriptors ALREADY STORED in each row -- it never
touches descriptors/keypoints/fp_version, so it cannot change the pack's
compatibility fingerprint (fp_version, codebook_hash) that clients gate on.

A card with zero descriptors gets Codebook.global_vec's own zero handling:
a float16 zero vector (see tests/test_codebook.py::test_global_vec_empty_is_zero),
packed to CODEBOOK_K*2 bytes -- not left as b"". That keeps every row's
global_vec at a fixed, predictable width for the client's fixed-size read.

Usage:
  python scripts/backfill_global_vec.py --db path/to/fingerprints.sqlite \
      [--codebook fpcore/codebook.bin] [--commit-every 500]
"""
import argparse
import os
import sqlite3
from fpcore import codebook as cb, packing


def backfill(db_path: str, codebook_path: str, commit_every: int = 500,
             on_progress=None) -> dict:
    book = cb.Codebook.load(codebook_path)
    conn = sqlite3.connect(db_path)

    stored_hash = conn.execute("SELECT codebook_hash FROM meta").fetchone()
    if stored_hash is None:
        conn.close()
        raise ValueError(f"{db_path}: no meta row -- not a fingerprints.sqlite")
    stored_hash = stored_hash[0]
    if stored_hash != book.sha256_hex():
        conn.close()
        raise ValueError(
            "codebook mismatch: DB was built against codebook_hash="
            f"{stored_hash}, but {codebook_path} hashes to {book.sha256_hex()}. "
            "Backfilling with a different codebook would write vectors no "
            "client could compare against. Aborting.")

    rows = conn.execute("SELECT card_id, kp_count, descriptors FROM card_fp").fetchall()
    total = len(rows)
    done = 0
    for card_id, kp_count, desc_blob in rows:
        desc = packing.unpack_descriptors(bytes(desc_blob), kp_count)
        vec = book.global_vec(desc)  # zero vector for kp_count == 0, per Codebook.global_vec
        conn.execute("UPDATE card_fp SET global_vec=? WHERE card_id=?",
                     (sqlite3.Binary(packing.pack_global_vec(vec)), card_id))
        done += 1
        if done % commit_every == 0:
            conn.commit()
        if on_progress and done % 500 == 0:
            on_progress(done, total)
    conn.commit()
    conn.close()
    return {"total": total, "done": done}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="fingerprints.sqlite to backfill IN PLACE")
    ap.add_argument("--codebook", default=os.path.join(
        os.path.dirname(__file__), "..", "fpcore", "codebook.bin"))
    ap.add_argument("--commit-every", type=int, default=500)
    args = ap.parse_args()

    def progress(done, total):
        print(f"  {done}/{total}")

    stats = backfill(args.db, args.codebook, commit_every=args.commit_every, on_progress=progress)
    print(f"done: {stats}")


if __name__ == "__main__":
    main()
