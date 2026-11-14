# fp-pipeline: automatic scanner-pack publish

Daily job that notices catalog cards the live scanner pack lacks, builds an incremental pack,
validates it, and ships it to the NAS and R2. Replaces scripts/README.md §2-4 for routine
releases. Codebook retrains and `fp_version` bumps stay manual (the job refuses and alerts).

Flow, gates and rollback: `fingerprint/scripts/auto_publish.py` (module docstring) and
`fpcore/packcheck.py`. Decision rules (debounce, versioning, pruning): `fpcore/autopublish.py`.

## Setup (once)
    docker build -f Dockerfile.fp-pipeline -t fp-pipeline:latest .     # from fingerprint/
    mkdir -p logs; cp .env.example .env   # fill in the values

`.env` (never committed):
    CLOUDFLARE_API_TOKEN=...      # scoped to R2 write on the tin-artifacts bucket
    CLOUDFLARE_ACCOUNT_ID=...
    NOTIFY_URL=...                # optional; POST {service,tag,message,recipient}
    NOTIFY_API_KEY=...

## Run
    ./run-fp.sh --dry-run --force     # stages 0-3: build + validate, never touches NAS/R2
    ./run-fp.sh --check-only          # validate the live pack, compare NAS vs R2
    ./run-fp.sh                       # the real thing (cron runs this daily)

## Behavior notes
- A new version does not force anything: the client keeps scanning with the installed pack and offers
  the update, but the update is a full ~550 MB download (no deltas). With the default
  `--min-interval-days 1` a user could be offered that daily; raise it (weeks) to batch releases.
- Cards whose art stays unfetchable for 7 daily attempts stop triggering builds and are reported once.
- State (first-seen ledger, publish history) lives in the `fp-pipeline-state` volume.
