#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: notarize.sh <path-to-Besties.app>}"
BUNDLE_ID="com.besties.app"
ZIP_PATH="/tmp/Besties-notarize.zip"

echo "==> Zipping app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "notarytool-profile" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

rm -f "$ZIP_PATH"

echo "==> Done! App is signed, notarized, and stapled."
echo "    Zip it up and share: ditto -c -k --keepParent \"$APP_PATH\" Besties.zip"
