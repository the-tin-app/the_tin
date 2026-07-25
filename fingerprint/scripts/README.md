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

## 4. Upload — self-hosted NAS only

**The pack is NOT mirrored to Firebase Storage** (decision 2026-07-24). The catalog's casual
tier is mirrored because it's ~22 MB; the pack is ~500 MB, and backing up an artifact with
another one 20× its size costs real money — for a fallback that never actually existed (the
bucket has no `fingerprint/` prefix at all). The iOS client has one source and reports a plain
retryable failure instead of a second timeout on the way to the same message. Don't re-add a
Firebase path without redoing that cost trade.

Copy into the served fingerprint dir, **parts before manifests** — a manifest listing parts
that aren't served yet strands every client that reads it. `catalog-server` serves any file
under its fingerprint dir, so no server change is needed:

    NAS=/mnt/media/private/app-config/catalog-server/fingerprint   # host: tomas@192.168.50.20
    rsync -av .fp-output/fingerprint/parts/fingerprints-v<N>.part* tomas@192.168.50.20:$NAS/parts/
    rsync -av .fp-output/fingerprint/parts/manifest.json           tomas@192.168.50.20:$NAS/parts/
    # legacy pair, while still published
    rsync -av .fp-output/fingerprint/fingerprints-v<N>.sqlite.gz   tomas@192.168.50.20:$NAS/
    rsync -av .fp-output/fingerprint/manifest.json                 tomas@192.168.50.20:$NAS/

**Adding the parts format to an already-served pack needs no rebuild and no transfer** — the
served `.sqlite.gz` gunzips to exactly the pack, so split it in place on the NAS, at the SAME
version (a version bump would force every installed client to re-download ~500 MB of identical
bytes):

    gunzip -c $NAS/fingerprints-v<N>.sqlite.gz > /tmp/pack.sqlite
    python3 scripts/publish_fingerprints.py --db /tmp/pack.sqlite --version <N> --skip-legacy --out /tmp/out
    cat /tmp/out/fingerprint/parts/fingerprints-v<N>.part0* | sha256sum   # must equal manifest sha256

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
