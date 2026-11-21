#!/usr/bin/env bash
# Host-cron wrapper for the scanner-pack auto-publish. Mirrors catalog-pipeline/run-nightly.sh:
# logs an invocation marker BEFORE touching docker, waits for the nightly catalog run to finish
# (they share the NAS and ~4 GB of this host's RAM), then runs the container once.
#
#   30 3 * * * /home/tomas/portainer-stacks/fp-pipeline/run-fp.sh >> /home/tomas/portainer-stacks/fp-pipeline/logs/cron.log 2>&1
#
# Extra args pass through to auto_publish.py (e.g. --dry-run, --check-only, --force).
set -uo pipefail
cd "$(dirname "$0")"
DATA=${FP_DATA_ROOT:-/mnt/media/private/app-config/catalog-server}

echo "[fp-wrapper] $(date -u +%FT%TZ) invoked, pid $$"

# Never overlap the nightly catalog run: wait up to 3 h for it to exit.
for _ in $(seq 1 180); do
  docker ps --format '{{.Names}}' | grep -qx catalog-pipeline-run || break
  sleep 60
done
if docker ps --format '{{.Names}}' | grep -qx catalog-pipeline-run; then
  echo "[fp-wrapper] nightly catalog run still going after 3 h; skipping tonight"
  exit 0
fi

# Default args come from the image CMD only when none are given; always pass the paths so
# extra flags (--dry-run, ...) don't replace them.
docker run --rm \
  --name fp-pipeline-run \
  --memory=3g --memory-swap=3g \
  --env-file .env \
  -v "$DATA":/data \
  -v fp-pipeline-work:/work \
  -v fp-pipeline-state:/state \
  -v fp-pipeline-cache:/cache \
  fp-pipeline:latest \
  --data-root /data --work /work --state /state/state.json "$@"
CODE=$?
echo "[fp-wrapper] $(date -u +%FT%TZ) container exited $CODE"
exit "$CODE"
