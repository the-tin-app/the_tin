#!/usr/bin/env bash
# Archive, export, and upload The Tin to TestFlight via the App Store Connect API.
#
# Usage:   ios/scripts/deploy-testflight.sh [BUILD_NUMBER]
#   BUILD_NUMBER  optional; overrides CURRENT_PROJECT_VERSION for this upload.
#                 TestFlight requires each build number to be unique and increasing.
#                 If omitted, uses CURRENT_PROJECT_VERSION from project.yml.
#
# Credentials (never committed — read from env, keys live in ~/.appstoreconnect/):
#   ASC_ISSUER    issuer id (UUID)                 [required]
#   ASC_KEY_ID    key id, e.g. ABCDE12345          [required]
#   ASC_KEY_PATH  path to AuthKey_<KEY_ID>.p8      [default ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8]
#
# Signing is automatic: xcodebuild uses the ASC API key + -allowProvisioningUpdates to
# create/download the distribution cert and an "iOS App Store" profile for ai.reyes.thetin
# on first run.
set -euo pipefail

SCHEME="TheTin"
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="/tmp/TheTin.xcarchive"
EXPORT_DIR="/tmp/TheTin-export"
cd "$IOS_DIR"

: "${ASC_ISSUER:?Set ASC_ISSUER (App Store Connect API issuer id)}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "✗ ASC key not found: $ASC_KEY_PATH" >&2; exit 1; }

BUILD_NUMBER="${1:-}"
VERSION_OVERRIDE=()
[[ -n "$BUILD_NUMBER" ]] && VERSION_OVERRIDE=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER")

echo "▶ xcodegen generate…"
xcodegen generate >/dev/null

echo "▶ archiving (Release${BUILD_NUMBER:+, build $BUILD_NUMBER})…"
rm -rf "$ARCHIVE"
xcodebuild -project TheTin.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" "${VERSION_OVERRIDE[@]}" clean archive

echo "▶ exporting + uploading to TestFlight…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates "${AUTH[@]}"

echo "✅ uploaded. Processing takes a few minutes; watch with:"
echo "   ASC_ISSUER=\$ASC_ISSUER ASC_KEY_ID=\$ASC_KEY_ID \\"
echo "     ios/scripts/asc.py GET '/v1/builds?filter[app]=6788516920&sort=-uploadedDate&limit=5'"
