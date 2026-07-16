# Fingerprint pack build & publish runbook

Server-side pipeline for the offline card scanner (Plan 2). All commands run from
`fingerprint/` with the venv active: `cd fingerprint && . .venv/bin/activate`.

## Prerequisites
- A built `catalog.sqlite` (from `functions/` `build-catalog.ts` → `.seed-output/`,
  or the published `catalog/catalog-v{N}.sqlite.gz` gunzipped).
- The committed `fpcore/codebook.bin` (retrain only when the vocabulary must change).

## 1. Train the codebook (only when changing the vocabulary)
    python scripts/train_codebook.py --catalog /path/to/catalog.sqlite \
        --per-set 6 --max-cards 1200 --seed 0 --out fpcore/codebook.bin
Commit the regenerated `fpcore/codebook.bin`. Its sha256 becomes `meta.codebook_hash`
in every pack built against it, and (Plan 3) the bundled device codebook must match.

## 2. Build the full pack (resumable)
    python scripts/build_fingerprints.py --catalog /path/to/catalog.sqlite \
        --codebook fpcore/codebook.bin --out .fp-output/fingerprints.sqlite
~21.7k cards; the first run fetches all high.webp art (cached to `.cache/images/`,
polite 120ms throttle). Re-running skips cards already at the current fp_version, so
it is safe to interrupt and resume. Do NOT commit `fingerprints.sqlite` or `.cache/`.

## 3. Publish (gzip + manifest)
    python scripts/publish_fingerprints.py --db .fp-output/fingerprints.sqlite \
        --version <N> --out .fp-output
Produces `.fp-output/fingerprint/fingerprints-v<N>.sqlite.gz` and `manifest.json`
in the Firebase Storage object layout (parallel to `catalog/`).

## 4. Upload to Firebase Storage (manual; needs bucket credentials)
Upload both objects to the `hobby-tcg` default bucket, preserving paths:
    gsutil cp .fp-output/fingerprint/fingerprints-v<N>.sqlite.gz \
        gs://hobby-tcg.firebasestorage.app/fingerprint/fingerprints-v<N>.sqlite.gz
    gsutil cp .fp-output/fingerprint/manifest.json \
        gs://hobby-tcg.firebasestorage.app/fingerprint/manifest.json
The client fetches these via the Firebase Storage REST endpoint (see
`ios/TheTin/Sources/Catalog/CatalogRemote.swift`); Plan 3 adds the iOS
`FingerprintUpdater` that mirrors `CatalogUpdater` (fetch manifest → compare
version/fpVersion/codebookHash → download → sha256-verify → gunzip → probe → swap).

## Versioning
- Bump `--version` on every published pack.
- `fp_version` (in `fpcore/constants.py`) bumps only when canonical size, ORB params,
  or the pack layout change; `codebookHash` changes whenever the codebook is retrained.
  Plan 3's device gate re-downloads on any of version / fpVersion / codebookHash mismatch.
