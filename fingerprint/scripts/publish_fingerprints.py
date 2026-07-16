"""Gzip a built fingerprints.sqlite and emit the manifest into .fp-output in the
Firebase Storage object layout (fingerprint/...). Reads codebook_hash from the
pack's meta row. Does NOT upload — see scripts/README.md for the upload command.

Usage:
  python scripts/publish_fingerprints.py --db .fp-output/fingerprints.sqlite \
      --version 1 --out .fp-output
"""
import argparse
import json
import os
from datetime import datetime, timezone
from fpcore import publish, fpdb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--version", type=int, required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", ".fp-output"))
    args = ap.parse_args()

    if not os.path.exists(args.db):
        raise SystemExit(f"no such pack db: {args.db}")
    conn = fpdb.open_db(args.db)
    row = conn.execute("SELECT codebook_hash FROM meta").fetchone()
    if row is None:
        raise SystemExit(f"{args.db} has no meta row — not a built fingerprint pack")
    codebook_hash = row[0]

    with open(args.db, "rb") as f:
        gz = publish.gzip_bytes(f.read())
    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    manifest = publish.make_manifest(gz, args.version, codebook_hash, generated_at)

    fp_dir = os.path.join(args.out, "fingerprint")
    os.makedirs(fp_dir, exist_ok=True)
    gz_path = os.path.join(fp_dir, f"fingerprints-v{args.version}.sqlite.gz")
    with open(gz_path, "wb") as f:
        f.write(gz)
    with open(os.path.join(fp_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f)
    print(f"wrote {gz_path} ({len(gz)} bytes) and manifest.json")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
