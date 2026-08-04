#!/bin/bash
#
# Build, sign, notarize, and staple Besties for distribution outside the App Store.
# Produces Besties.zip at the repo root — send that to friends; it installs with
# no Gatekeeper warning.
#
# It also stages the zip for Sparkle auto-updates and regenerates the appcast.
#
# Reuses the same notarytool keychain profile as the Speed app (SPEED_NOTARY,
# team 34HCA7L7PV) — no separate credential needed. Override with an argument.
#
# Usage:  ./release.sh <major.minor[.patch]> [keychain-profile]
#         e.g. ./release.sh 1.1            (default profile: SPEED_NOTARY)

set -euo pipefail

VERSION="${1:-}"
PROFILE="${2:-SPEED_NOTARY}"

# At least two components — "1" and "1.0" would both compute build 10000.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Usage: ./release.sh <major.minor[.patch]> [keychain-profile]   e.g. ./release.sh 1.1" >&2
  exit 1
fi

# Sparkle compares CFBundleVersion, so the build number must always increase.
# 1.2.3 → 10203 — monotonic as long as no component goes past 99.
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<<"$VERSION"
BUILD=$(( 10#$V_MAJOR * 10000 + 10#${V_MINOR:-0} * 100 + 10#${V_PATCH:-0} ))

IDENTITY="Developer ID Application: Jordan Lejuwaan (34HCA7L7PV)"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Unguessable public dir the app's SUFeedURL points at. generate_appcast keeps
# the most recent releases in the feed (emitting deltas between them) and moves
# superseded zips into old_updates/.
UPDATES="$ROOT/site/u-a0941b9884e8fcb0"
cd "$ROOT/Besties"

APP="build/Build/Products/Release/Besties.app"
# Use the source entitlements, NOT the build-generated .xcent — the latter injects
# com.apple.security.get-task-allow, which the notary service rejects.
ENTITLEMENTS="Besties/Besties.entitlements"

echo "▶ Building Release $VERSION (build $BUILD)…"
rm -rf build
xcodebuild -project Besties.xcodeproj -scheme Besties -configuration Release \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  clean build >/dev/null

# Sparkle ships its tools inside the SPM binary artifact the build just fetched,
# so they always match the Sparkle the app is linked against. Fail here rather
# than after a ten-minute notarization round trip.
SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "generate_appcast not found at $SPARKLE_BIN — is Sparkle still an SPM dependency?" >&2
  exit 1
fi
SPARKLE_BIN="$(cd "$SPARKLE_BIN" && pwd)"

SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "▶ Re-signing Sparkle's nested components (deep-first)…"
  # Sparkle's helpers are separate bundles/executables; the outer --force sign
  # does not reach them, and an invalid inner signature fails notarization.
  for NESTED in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc \
                "$SPARKLE_FW"/Versions/B/Updater.app \
                "$SPARKLE_FW"/Versions/B/Autoupdate; do
    [ -e "$NESTED" ] || continue
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$NESTED"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW"
fi

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
rm -f "$ROOT/Besties.zip"
ditto -c -k --keepParent "$APP" "$ROOT/Besties.zip"

echo "▶ Final verification…"
xcrun stapler validate "$APP"
spctl -a -vvv --type execute "$APP"

echo "▶ Staging the update zip and regenerating the appcast…"
mkdir -p "$UPDATES"
cp "$ROOT/Besties.zip" "$UPDATES/Besties-$VERSION.zip"
# generate_appcast picks up release notes from an .html file named like the zip.
NOTES="$ROOT/docs/release-notes/$VERSION.html"
if [ -f "$NOTES" ]; then
  cp "$NOTES" "$UPDATES/Besties-$VERSION.html"
else
  echo "⚠️  No release notes at $NOTES — this update will ship without any."
fi
# old_updates/ lives inside the deployed static root, so retired zips would be
# re-uploaded and served forever; --auto-prune-update-files clears them out.
"$SPARKLE_BIN/generate_appcast" --auto-prune-update-files "$UPDATES"

echo "✅ Done → $ROOT/Besties.zip  (send this to friends)"
echo "   Update staged → $UPDATES/Besties-$VERSION.zip + appcast.xml"
echo "   Deploy it:  cd site && ./build.sh && vercel deploy --prod --yes"
