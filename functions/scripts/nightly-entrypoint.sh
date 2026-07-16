#!/usr/bin/env bash
# Nightly catalog rebuild: pull PPT CSV (2/day quota, ONE call/night) -> build -> enrich ->
# publish tiers to the NAS (+ optional Firebase casual backup) -> refresh funding block.
#
# Runs unattended in a container. Required env:
#   PPT_PAID (or PPT_API_KEY / PPT_BUSINESS)   — PPT Business API key
# Optional:
#   FIREBASE_STORAGE_BUCKET         — your Firebase Storage bucket (<project>.firebasestorage.app);
#                                      used for image mirroring and the casual-tier backup
#   GOOGLE_APPLICATION_CREDENTIALS  — path to a scoped Firebase service-account key JSON;
#                                      when set (with the bucket), publish-tiers.ts also pushes
#                                      the casual tier backup to Firebase Storage (--firebase)
#   OC_SLUG, FUNDING_GOAL_CENTS     — passed through to refresh-funding.ts
#   SKIP_EXPORT_PULL=1              — skip the PPT CSV pull, reuse whatever is already in
#                                      .export-cache/ (for testing the rest of the chain without
#                                      spending the day's export quota)
#   EXPORT_WAIT_MINS                — max minutes probe-ppt-export.ts may wait for PPT's daily
#                                      ~06:01 UTC dump regeneration before pulling (default 120)
# Success/failure/degraded-run notifications go through the notify() hook below — a no-op
# by default; edit it to wire up your own alerting.
#
# NAS is expected mounted at /data (same volume catalog-server itself reads from); publish-tiers
# appends /catalog to that root itself, refresh-funding takes /data/catalog directly.
set -euo pipefail
cd "$(dirname "$0")/.."   # functions/

# probe-ppt-export.ts accepts PPT_BUSINESS/PPT_API_KEY/PPT_PAID interchangeably, but
# fill-overnight.ts only reads PPT_API_KEY specifically -- normalize once here so every step
# downstream sees the same var regardless of which name the container was started with.
export PPT_API_KEY="${PPT_API_KEY:-${PPT_BUSINESS:-${PPT_PAID:-}}}"
if [ -z "$PPT_API_KEY" ]; then
  echo "[nightly] FATAL: no PPT key set (PPT_API_KEY / PPT_BUSINESS / PPT_PAID all empty)" >&2
  exit 1
fi

NAS_DIR=/data
CATALOG_DIR="$NAS_DIR/catalog"
NEXT_VERSION=""

notify() {
  # notify <tag> <message> — ops notification hook, intentionally a no-op.
  # The pipeline calls this on success, failure, and degraded runs (stale prices,
  # skipped enrichment). Customize it to plug in your own alerting — e.g. curl to
  # ntfy/Gotify/Slack/webhook of choice using $1 (tag) and $2 (message).
  :
}

on_exit() {
  local code=$?
  if [ "$code" -eq 0 ]; then
    notify "Success" "catalog-pipeline: published v${NEXT_VERSION} at $(date -u +%FT%TZ)"
  else
    notify "Error" "catalog-pipeline: FAILED (exit $code) at $(date -u +%FT%TZ), version was ${NEXT_VERSION:-unknown} — check logs/cron.log"
  fi
}
trap on_exit EXIT

step() { echo "[nightly] $(date -u +%FT%TZ) === $1 ==="; }

echo "[nightly] $(date -u +%FT%TZ) CONTAINER STARTED (pid $$) — this line proves the pipeline actually ran."

# --- 1. determine next version (current live version + 1; 1 if nothing published yet) ---
step "1/7 version detection"
NEXT_VERSION=$(node -e "
  try {
    const m = require('$CATALOG_DIR/manifest.json');
    console.log((m.version || 0) + 1);
  } catch { console.log(1); }
")
echo "[nightly] live NAS manifest version: $(node -e "try{console.log(require('$CATALOG_DIR/manifest.json').version)}catch{console.log('none')}") -> building v$NEXT_VERSION"

# --- 2. refresh the tcgdex cards-database metadata cache ---
# GitHub being down must not kill the night: with an existing clone, a failed fetch degrades to
# building against yesterday's metadata (prices are the nightly payload; set metadata barely moves).
# Only a missing clone AND a failed fresh clone is fatal (no metadata at all = nothing to build).
step "2/7 cards-database metadata refresh"
if [ -d .cache/cards-database/.git ]; then
  echo "[nightly] pulling existing cards-database clone"
  if ! { git -C .cache/cards-database fetch --depth 1 origin HEAD \
         && git -C .cache/cards-database reset --hard FETCH_HEAD; }; then
    echo "[nightly] WARN: cards-database refresh failed — building with the existing (stale) clone"
    notify "Warning" "catalog-pipeline: cards-database refresh failed, built v${NEXT_VERSION} with stale set metadata"
  fi
else
  echo "[nightly] no cached clone found, cloning fresh (~194MB)"
  rm -rf .cache/cards-database
  git clone --depth 1 https://github.com/tcgdex/cards-database.git .cache/cards-database
fi
bun scripts/flatten-cards-db.ts

# --- 3. pull the PPT bulk CSV export — 2/day quota, exactly once per run ---
# probe-ppt-export.ts owns the freshness/quota logic: PPT regenerates dumps daily ~06:01 UTC; the
# script skips the pull when the cache already has the current dump, waits (<= EXPORT_WAIT_MINS)
# when the next regeneration is imminent, retries network-layer errors, and NEVER retries 429/403.
# Any failure here degrades to building from the cached CSVs (day-old prices beat no publish).
step "3/7 PPT CSV export pull (quota-limited, once/run)"
if [ "${SKIP_EXPORT_PULL:-0}" = "1" ]; then
  echo "[nightly] SKIP_EXPORT_PULL=1 — reusing existing .export-cache/ (NOT spending quota)"
else
  echo "[nightly] pulling today's PPT export (fresh-dump gate + quota guard in probe-ppt-export.ts)"
  EXPORT_OUT=$(mktemp)
  if ! SAVE_DIR=.export-cache EXPORT_WAIT_MINS="${EXPORT_WAIT_MINS:-120}" \
       npx tsx scripts/probe-ppt-export.ts cards,sealed 2>&1 | tee "$EXPORT_OUT"; then
    echo "[nightly] WARN: export pull crashed — reusing existing .export-cache/"
    notify "Warning" "catalog-pipeline: PPT export pull crashed, built v${NEXT_VERSION} from cached CSVs"
  elif grep -q "STALE DUMP" "$EXPORT_OUT"; then
    notify "Warning" "catalog-pipeline: PPT dump regeneration late — v${NEXT_VERSION} built with day-old export prices"
  fi
  rm -f "$EXPORT_OUT"
fi
echo "[nightly] export cache: $(ls -la .export-cache/*.csv 2>/dev/null | awk '{print $NF, $5"b"}' | tr '\n' ' ')"

# --- 4. build (offline compaction from the cached export) ---
step "4/7 build-catalog (offline compaction)"
EXPORT_DIR=.export-cache npx tsx scripts/build-catalog.ts "$NEXT_VERSION" .seed-output

# --- 5. enrich (REST sweep: condition prices, graded, population — separate large credit pool) ---
# Publish gate: a catalog missing enrichment (history/graded/condition) is WORSE for users than
# yesterday's complete one, so any incomplete sweep — rate-limit/credit stop (exit 2), crash,
# OOM — keeps the current live version and skips publish. fill-overnight exits non-zero on every
# early-stop path. A full sweep needs ~95k PPT purchased credits; check the balance before
# expecting a publish.
step "5/7 fill-overnight (REST enrichment sweep)"
if ! PPT_MINUTE_LIMIT="${PPT_MINUTE_LIMIT:-400}" \
     npx tsx scripts/fill-overnight.ts ".seed-output/catalog-v$NEXT_VERSION.sqlite" "$NEXT_VERSION" .seed-output; then
  echo "[nightly] enrichment incomplete — NOT publishing v${NEXT_VERSION}; keeping v$((NEXT_VERSION-1)) live"
  notify "Warning" "catalog-pipeline: enrichment incomplete (credits/rate-limit?) — kept v$((NEXT_VERSION-1)) live, v${NEXT_VERSION} not published; retries next night"
  trap - EXIT
  exit 0
fi

# --- 6. publish tiers to the NAS (+ Firebase casual backup if creds are present) ---
step "6/7 publish-tiers (NAS + optional Firebase)"
FIREBASE_FLAG=""
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -n "${FIREBASE_STORAGE_BUCKET:-}" ]; then
  echo "[nightly] GOOGLE_APPLICATION_CREDENTIALS + FIREBASE_STORAGE_BUCKET set — will also push casual tier to Firebase"
  FIREBASE_FLAG="--firebase"
else
  echo "[nightly] GOOGLE_APPLICATION_CREDENTIALS / FIREBASE_STORAGE_BUCKET not both set — Firebase backup SKIPPED"
fi
npx tsx scripts/publish-tiers.ts ".seed-output/catalog-v$NEXT_VERSION.sqlite" "$NEXT_VERSION" "$NAS_DIR" $FIREBASE_FLAG
echo "[nightly] NAS manifest now: $(cat "$CATALOG_DIR/manifest.json")"

# --- 7. refresh the funding block in the manifest the server just started serving ---
step "7/7 refresh-funding"
npx tsx scripts/refresh-funding.ts "$CATALOG_DIR" "${OC_SLUG:-}" "${FUNDING_GOAL_CENTS:-15000}" || echo "[nightly] WARN: funding refresh failed (non-fatal)"

echo "[nightly] $(date -u +%FT%TZ) === DONE — published v$NEXT_VERSION ==="
