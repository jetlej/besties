#!/bin/bash
#
# Build, sign, notarize, and staple Besties for distribution outside the App Store.
# Produces "Time Capsule.zip" at the repo root — send that to friends; it installs with
# no Gatekeeper warning.
#
# Reuses the same notarytool keychain profile as the Speed app (SPEED_NOTARY,
# team 34HCA7L7PV) — no separate credential needed. Override with an argument.
#
# Usage:  ./release.sh [keychain-profile]   (default profile: SPEED_NOTARY)

set -euo pipefail

PROFILE="${1:-SPEED_NOTARY}"
IDENTITY="Developer ID Application: Jordan Lejuwaan (34HCA7L7PV)"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/Besties"

APP="build/Build/Products/Release/Time Capsule.app"
# Use the source entitlements, NOT the build-generated .xcent — the latter injects
# com.apple.security.get-task-allow, which the notary service rejects.
ENTITLEMENTS="Besties/Besties.entitlements"

echo "▶ Building Release…"
rm -rf build
xcodebuild -project Besties.xcodeproj -scheme Besties -configuration Release \
  -derivedDataPath build clean build >/dev/null

echo "▶ Re-signing with a secure timestamp (required for notarization)…"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"

echo "▶ Zipping for notary submission…"
ditto -c -k --keepParent "$APP" "build/Besties-notarize.zip"

echo "▶ Submitting to Apple notary service (a few minutes)…"
xcrun notarytool submit "build/Besties-notarize.zip" \
  --keychain-profile "$PROFILE" --wait

echo "▶ Stapling the notarization ticket to the app…"
xcrun stapler staple "$APP"

echo "▶ Packaging the distributable zip…"
rm -f "$ROOT/Time Capsule.zip"
ditto -c -k --keepParent "$APP" "$ROOT/Time Capsule.zip"

echo "▶ Final verification…"
xcrun stapler validate "$APP"
spctl -a -vvv --type execute "$APP"

echo "✅ Done → $ROOT/Time Capsule.zip  (send this to friends)"
