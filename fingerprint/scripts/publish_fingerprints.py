"""Publish a built fingerprints.sqlite into .fp-output in the served object layout.
Reads codebook_hash from the pack's meta row. Does NOT upload — see scripts/README.md
for the upload commands.

Emits BOTH distribution formats by default, because they roll out on different clocks:

  fingerprint/fingerprints-v{N}.sqlite.gz + fingerprint/manifest.json   (legacy, frozen)
  fingerprint/parts/fingerprints-v{N}.part000... + parts/manifest.json  (current)

Builds shipped before the parts format read only the legacy pair, so keep publishing both
until TestFlight shows nobody on those builds; then pass --skip-legacy.

Usage:
  python scripts/publish_fingerprints.py --db .fp-output/fingerprints.sqlite \
      --version 4 --out .fp-output
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
    ap.add_argument("--part-bytes", type=int, default=publish.PART_BYTES,
                    help="parts-format chunk size in bytes (default 50 MiB)")
    ap.add_argument("--skip-legacy", action="store_true",
                    help="stop emitting the gzipped single-file format (only once no shipped build reads it)")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        raise SystemExit(f"no such pack db: {args.db}")
    conn = fpdb.open_db(args.db)
    row = conn.execute("SELECT codebook_hash FROM meta").fetchone()
    if row is None:
        raise SystemExit(f"{args.db} has no meta row — not a built fingerprint pack")
    codebook_hash = row[0]

    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    if not args.skip_legacy:
        with open(args.db, "rb") as f:
            gz = publish.gzip_bytes(f.read())
        manifest = publish.make_manifest(gz, args.version, codebook_hash, generated_at)
        fp_dir = os.path.join(args.out, "fingerprint")
        os.makedirs(fp_dir, exist_ok=True)
        gz_path = os.path.join(fp_dir, f"fingerprints-v{args.version}.sqlite.gz")
        with open(gz_path, "wb") as f:
            f.write(gz)
        with open(os.path.join(fp_dir, "manifest.json"), "w") as f:
            json.dump(manifest, f)
        print(f"legacy: wrote {gz_path} ({len(gz)} bytes) and fingerprint/manifest.json")
        del gz

    whole_sha, total, parts = publish.split_into_parts(
        args.db, args.out, args.version, part_bytes=args.part_bytes)
    parts_manifest = publish.make_parts_manifest(
        args.version, codebook_hash, generated_at, whole_sha, total, parts,
        part_bytes=args.part_bytes)
    parts_dir = os.path.join(args.out, publish.parts_dir_name())
    os.makedirs(parts_dir, exist_ok=True)
    with open(os.path.join(parts_dir, "manifest.json"), "w") as f:
        json.dump(parts_manifest, f)
    print(f"parts:  wrote {len(parts)} x {args.part_bytes} B under {parts_dir} "
          f"({total} bytes total) and parts/manifest.json")
    print(json.dumps({k: v for k, v in parts_manifest.items() if k != "parts"}, indent=2))


if __name__ == "__main__":
    main()
