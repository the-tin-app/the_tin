"""Validate a published parts pack against every gate in fpcore/packcheck.py.

  python scripts/validate_pack.py --base /mnt/.../catalog-server \
      --manifest /mnt/.../catalog-server/fingerprint/parts/manifest.json

`--base` is the directory manifest paths are relative to (they start `fingerprint/parts/`).
Exit 0 when every gate passes, 1 otherwise. Use it on a staging dir before shipping and on the
origin's own files after copying.
"""
import argparse
import os
import sys
import tempfile
from fpcore import codebook as cb, packcheck


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--base", required=True)
    a.add_argument("--manifest", required=True)
    a.add_argument("--codebook", default=os.path.join(os.path.dirname(__file__), "..", "fpcore", "codebook.bin"))
    a.add_argument("--live-db", help="previous pack's sqlite, for the no-card-lost / size gates")
    a.add_argument("--work", default=None, help="scratch dir (needs ~pack size free)")
    args = a.parse_args()
    expected = cb.Codebook.load(args.codebook).sha256_hex()
    work = args.work or tempfile.mkdtemp(prefix="fpvalidate-")
    rep = packcheck.validate(args.base, args.manifest, work, expected_codebook_hash=expected,
                             live_db_path=args.live_db,
                             live_size=os.path.getsize(args.live_db) if args.live_db else None)
    print(rep.info)
    for f in rep.failures:
        print("FAIL", f)
    print("OK" if rep.ok else "INVALID")
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
