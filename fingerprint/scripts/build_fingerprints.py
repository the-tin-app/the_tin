"""Full-catalog fingerprint build. Fetches each card's high.webp (cached, polite)
and writes fingerprints.sqlite. Resumable: re-running skips cards already at the
current fp_version; cached images make re-runs ~free.

Usage:
  python scripts/build_fingerprints.py --catalog PATH/catalog.sqlite \
      --codebook fpcore/codebook.bin --out .fp-output/fingerprints.sqlite [--force] [--limit N]
"""
import argparse
import os
import ssl
import time
import urllib.request
from datetime import datetime, timezone
import certifi
import cv2
from fpcore import build, codebook as cb

UA = "HobbyTCG/1.0"
CACHE_DIR = os.path.join(os.path.dirname(__file__), "..", ".cache", "images")
# python.org's macOS Python ships without a usable system CA bundle, so verify
# against certifi's bundle explicitly (keep verification ON — never disable it).
_SSL_CTX = ssl.create_default_context(cafile=certifi.where())


class _LimitReached(Exception):
    pass


def make_cached_loader(cache_dir=CACHE_DIR):
    os.makedirs(cache_dir, exist_ok=True)

    def load(card_id, image_base):
        path = os.path.join(cache_dir, f"{card_id}.webp")
        if not os.path.exists(path):
            url = f"{image_base}/high.webp"
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            try:
                with urllib.request.urlopen(req, timeout=30, context=_SSL_CTX) as r:
                    data = r.read()
            except Exception as e:  # noqa: BLE001 — skip unfetchable cards, retried next run
                print(f"  fetch failed {card_id}: {e}")
                return None
            with open(path, "wb") as f:
                f.write(data)
            time.sleep(0.12)  # politeness: only after a real fetch, not cache hits
        img = cv2.imread(path, cv2.IMREAD_COLOR)
        return img

    return load


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--codebook", default=os.path.join(os.path.dirname(__file__), "..", "fpcore", "codebook.bin"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", ".fp-output", "fingerprints.sqlite"))
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--limit", type=int, default=None, help="stop after N newly built cards (smoke)")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    book = cb.Codebook.load(args.codebook)
    built_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    limit = args.limit

    def progress(card_id, built, skipped):
        if built % 200 == 0:
            print(f"  built={built} skipped={skipped} (last {card_id})")
        if limit is not None and built >= limit:
            raise _LimitReached

    loader = make_cached_loader()
    try:
        stats = build.build_fingerprints(args.catalog, args.out, book, loader,
                                         built_at=built_at, force=args.force,
                                         on_progress=progress)
    except _LimitReached:
        print(f"stopped early at limit={limit}")
        return
    print(f"done: {stats}")


if __name__ == "__main__":
    main()
