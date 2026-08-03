"""Publish a built fingerprints.sqlite into .fp-output in the served object layout, and push
it to the R2 backup origin. Reads codebook_hash from the pack's meta row.

The NAS is still a manual rsync (see scripts/README.md); R2 is not, because forgetting it is
silent. On 2026-08-03 R2 served v3 for a day after v4 went live on the NAS, and nothing
surfaced the drift — a NAS outage during a first install would have handed that user the older
pack with no way to tell. So the R2 push happens by default and you opt OUT with --no-r2,
rather than opting in to a step whose omission nothing reports.

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
import subprocess
from datetime import datetime, timezone
from fpcore import publish, fpdb

# The backup origin the iOS client falls back to when the NAS is unreachable — the `tin-backup`
# Worker (workers/tin-backup/) at backupthetin.reyes.ai serves this bucket under the same
# `fingerprint/**` keys the NAS uses.
R2_BUCKET = "tin-artifacts"


def _upload(path, key):
    """One object to R2, via wrangler.

    Shelling out rather than signing S3 requests by hand: wrangler is already the authenticated
    path (OAuth on the publishing machine), and `fingerprint/` is deliberately stdlib-only so it
    runs on the NAS's system Python. Hand-rolled SigV4 would cost more code than the entire rest
    of this script and would be the only crypto here.
    """
    proc = subprocess.run(
        ["npx", "wrangler", "r2", "object", "put", f"{R2_BUCKET}/{key}",
         "--file", path, "--remote"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"R2 upload failed for {key}:\n{proc.stderr.strip() or proc.stdout.strip()}\n"
            "Fix it and re-run — a half-uploaded pack is safe as long as the manifest never "
            "went up (it is uploaded last, on purpose). Pass --no-r2 to publish locally only.")


def _publish_order(out_dir, version, wrote_legacy):
    """Every object to upload, in the order it MUST go up: payload before the manifest naming it.

    A manifest listing parts that aren't served yet strands every client that reads it. That is
    the one ordering rule this format has, and it is enforced here rather than left to whoever
    is typing the commands at the time.
    """
    fp_dir = os.path.join(out_dir, "fingerprint")
    parts_dir = os.path.join(out_dir, publish.parts_dir_name())   # same idiom as main()
    parts = sorted(n for n in os.listdir(parts_dir)
                   if n.startswith(f"fingerprints-v{version}.part"))
    if not parts:
        raise SystemExit(f"no v{version} parts found under {parts_dir} — nothing to upload")

    ordered = [os.path.join(parts_dir, n) for n in parts]
    if wrote_legacy:
        ordered.append(os.path.join(fp_dir, f"fingerprints-v{version}.sqlite.gz"))
    ordered.append(os.path.join(parts_dir, "manifest.json"))      # LAST for the parts format
    if wrote_legacy:
        ordered.append(os.path.join(fp_dir, "manifest.json"))
    return ordered


def push_to_r2(out_dir, version, wrote_legacy):
    ordered = _publish_order(out_dir, version, wrote_legacy)
    print(f"r2:     pushing {len(ordered)} objects to {R2_BUCKET} (manifests last)")
    for i, path in enumerate(ordered, 1):
        key = os.path.relpath(path, out_dir).replace(os.sep, "/")
        size = os.path.getsize(path)
        print(f"r2:     [{i}/{len(ordered)}] {key} ({size} B)", flush=True)
        _upload(path, key)

    # Confirm the flip actually took. Cheap (the manifest is ~2 KB) and it is the object that
    # decides what every failing-over client sees, so it is the one worth reading back.
    proc = subprocess.run(
        ["npx", "wrangler", "r2", "object", "get",
         f"{R2_BUCKET}/fingerprint/parts/manifest.json", "--remote", "--pipe"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"uploaded, but could not read the manifest back: {proc.stderr.strip()}")
    served = json.loads(proc.stdout)
    if served.get("version") != version:
        raise SystemExit(
            f"R2 still serves v{served.get('version')} after uploading v{version} — do not "
            "assume this is a caching delay, check the bucket before publishing anything else.")
    print(f"r2:     verified — {R2_BUCKET} now serves v{served['version']} "
          f"({served['sizeBytes']} B, {len(served['parts'])} parts)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--version", type=int, required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", ".fp-output"))
    ap.add_argument("--part-bytes", type=int, default=publish.PART_BYTES,
                    help="parts-format chunk size in bytes (default 50 MiB)")
    ap.add_argument("--skip-legacy", action="store_true",
                    help="stop emitting the gzipped single-file format (only once no shipped build reads it)")
    ap.add_argument("--no-r2", action="store_true",
                    help="write the objects but don't push them to the R2 backup origin. Use when "
                         "re-splitting an already-served pack in place, or on a machine with no "
                         "wrangler auth — never because you'll 'do it after'.")
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

    if args.no_r2:
        print(f"r2:     SKIPPED (--no-r2). The backup origin still serves whatever it served "
              f"before, NOT v{args.version}. Nothing will tell you about that later.")
    else:
        push_to_r2(args.out, args.version, wrote_legacy=not args.skip_legacy)

    print(f"\nStill to do by hand: rsync to the NAS (parts before manifests) — see "
          f"scripts/README.md §4. The NAS is the PRIMARY; until that rsync runs, clients keep "
          f"getting the old pack.")


if __name__ == "__main__":
    main()
