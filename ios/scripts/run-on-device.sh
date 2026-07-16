#!/usr/bin/env bash
# Build, install, and launch TheTin on a connected physical iPhone (Debug).
#
# Usage:  ios/scripts/run-on-device.sh
# Env overrides (rarely needed): BUILD_UDID (xcodebuild id), CORE_DEVICE_ID (devicectl id).
set -euo pipefail

SCHEME="TheTin"
BUNDLE_ID="ai.reyes.thetin"
DERIVED="/tmp/tcgapp-device-build"
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$IOS_DIR"

# The two tools use different id forms for the same phone, so resolve both.
CORE_DEVICE_ID="${CORE_DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null \
  | grep 'available (paired)' \
  | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}' | head -1)}"
BUILD_UDID="${BUILD_UDID:-$(xcrun xctrace list devices 2>/dev/null \
  | sed -n '/== Devices ==/,/== Devices Offline ==/p' \
  | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1)}"

if [[ -z "$CORE_DEVICE_ID" ]]; then
  echo "✗ No paired device found. Plug in + unlock your iPhone, then run: xcrun devicectl list devices" >&2
  exit 1
fi
echo "▶ device (devicectl): $CORE_DEVICE_ID"

if [[ -n "$BUILD_UDID" ]]; then
  DEST="id=$BUILD_UDID"; echo "▶ device (xcodebuild): $BUILD_UDID"
else
  DEST="generic/platform=iOS"; echo "▶ xcodebuild destination: generic/platform=iOS (UDID not auto-detected)"
fi

echo "▶ xcodegen generate…"
xcodegen generate >/dev/null

echo "▶ building (Debug, automatic signing)…"
xcodebuild -project TheTin.xcodeproj -scheme "$SCHEME" -configuration Debug \
  -destination "$DEST" -allowProvisioningUpdates -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app"
# Brace ${APP}/${BUNDLE_ID}: a bare $VAR immediately followed by the multibyte "…"
# makes bash (set -u) read the ellipsis bytes as part of the variable name.
echo "▶ installing ${APP}…"
xcrun devicectl device install app --device "$CORE_DEVICE_ID" "$APP"

# App Check debug token: the DEBUG build's AppCheckDebugProvider reads it only from the
# FIRAAppCheckDebugToken env var, so it must be injected at launch — a devicectl launch
# WITHOUT it (or an icon tap) gets a fresh random token and Storage/Firestore downloads 403,
# leaving catalog/fingerprint updates silently stuck. Token lives in repo-root .env as
# DEBUG_TOKEN (gitignored, already registered in the hobby-tcg Firebase console). Applies only
# to this launched session; the downloaded pack persists locally after one good launch.
DEBUG_TOKEN="${DEBUG_TOKEN:-$(sed -n 's/^DEBUG_TOKEN=//p' "$IOS_DIR/../.env" 2>/dev/null | tr -d '"'\''')}"
# SELFHOST_URL (optional): point this DEBUG build at a development-environment catalog-server so
# App Attest succeeds — a debug build attests as "development", which the production server rejects.
# Unset ⇒ the app uses the production URL baked into AppConfig.selfHostBaseURL.
SELFHOST_URL="${SELFHOST_URL:-$(sed -n 's/^SELFHOST_URL=//p' "$IOS_DIR/../.env" 2>/dev/null | tr -d '"'\''')}"

# Assemble the launch env from whichever vars are present.
ENV_PAIRS=()
if [[ -n "$DEBUG_TOKEN" ]]; then
  echo "▶ injecting App Check debug token"
  ENV_PAIRS+=("\"FIRAAppCheckDebugToken\":\"$DEBUG_TOKEN\"")
else
  echo "⚠ no DEBUG_TOKEN in .env — App Check will use a random token; Storage downloads will 403" >&2
fi
if [[ -n "$SELFHOST_URL" ]]; then
  echo "▶ pointing self-host at dev server: $SELFHOST_URL"
  ENV_PAIRS+=("\"SELFHOST_URL\":\"$SELFHOST_URL\"")
fi

echo "▶ launching ${BUNDLE_ID}…"
if [[ ${#ENV_PAIRS[@]} -gt 0 ]]; then
  ENV_JSON="{$(IFS=,; echo "${ENV_PAIRS[*]}")}"
  xcrun devicectl device process launch \
    --environment-variables "$ENV_JSON" --device "$CORE_DEVICE_ID" "$BUNDLE_ID"
else
  xcrun devicectl device process launch --device "$CORE_DEVICE_ID" "$BUNDLE_ID"
fi
echo "✅ done — TheTin is running on the device."
