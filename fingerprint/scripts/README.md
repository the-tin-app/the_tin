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

## 3. Publish (both distribution formats)
    python scripts/publish_fingerprints.py --db .fp-output/fingerprints.sqlite \
        --version <N> --out .fp-output

Produces **two** formats under `.fp-output/`, because they roll out on different clocks:

| Format | Objects | Read by |
|--------|---------|---------|
| legacy (frozen) | `fingerprint/fingerprints-v<N>.sqlite.gz` + `fingerprint/manifest.json` | builds shipped before the parts format |
| parts (current) | `fingerprint/parts/fingerprints-v<N>.part000…` + `fingerprint/parts/manifest.json` | current builds |

Parts are the sqlite split verbatim at 50 MiB, **uncompressed on purpose**: ORB descriptors
are high-entropy binary and do not compress (measured 41,600 B → 41,613 B — gzip makes them
slightly bigger). Across a whole pack gzip returns ~9%, all from the keypoint floats, and it
costs the client a whole-buffer inflate — which is what forced the entire ~800 MB pack through
device memory. Without it the client streams each part straight to its offset on disk, so peak
memory is one part and an interrupted download resumes part-by-part.

Concatenating the parts in index order reproduces the sqlite byte-for-byte; `manifest.json`
carries a per-part sha256 (refetch one corrupt part, not the whole pack) plus the whole-file
sha256 as the pre-install gate.

Keep publishing both until TestFlight shows no build in the wild still reads the legacy pair,
then add `--skip-legacy` and delete the old objects from both hosts.

## 4. Upload

Both hosts serve both formats. **Upload parts before the manifest** — a manifest that lists
parts which aren't served yet strands every client that reads it.

### Self-hosted NAS (primary)
Copy into the served fingerprint dir, preserving relative paths (see `docs/HANDOFF.md` for
the real path; `catalog-server` serves any file under it, so no server change is needed):

    rsync -av .fp-output/fingerprint/ <nas>/fingerprint/

### Firebase Storage (fallback; needs bucket credentials)
The fallback covers a self-hosted server rejecting the device's App Attest environment, so it
must carry the parts too — otherwise failover lands on a format the current client can't read.

    # parts first, then the manifests
    gsutil -m cp .fp-output/fingerprint/parts/fingerprints-v<N>.part* \
        gs://hobby-tcg.firebasestorage.app/fingerprint/parts/
    gsutil cp .fp-output/fingerprint/parts/manifest.json \
        gs://hobby-tcg.firebasestorage.app/fingerprint/parts/manifest.json
    # legacy pair, while still published
    gsutil cp .fp-output/fingerprint/fingerprints-v<N>.sqlite.gz \
        gs://hobby-tcg.firebasestorage.app/fingerprint/fingerprints-v<N>.sqlite.gz
    gsutil cp .fp-output/fingerprint/manifest.json \
        gs://hobby-tcg.firebasestorage.app/fingerprint/manifest.json

The iOS `FingerprintUpdater` fetches the parts manifest, downloads missing parts, verifies each
against its sha256, writes it at `index * partSize`, then gates the assembled file on the whole
sha256 → probe → atomic swap.

## Versioning
- Bump `--version` on every published pack.
- `fp_version` (in `fpcore/constants.py`) bumps only when canonical size, ORB params,
  or the pack layout change; `codebookHash` changes whenever the codebook is retrained.
  The device gate re-downloads on any of version / fpVersion / codebookHash mismatch.
- Part filenames carry the version, so publishing v<N+1> never collides with the v<N> parts
  still being served. Delete the old version's parts once the new manifest is live.
