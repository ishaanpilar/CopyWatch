#!/bin/zsh
# Build CopyWatch.app from the SwiftPM executable.
#
# Ad-hoc (default):  ./build.sh                → runs on THIS Mac only.
# Distributable:     DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" ./build.sh
#                    …signs with the hardened runtime so it can be notarized.
# Notarize + staple: also set NOTARY_PROFILE=<notarytool keychain profile>
#                    (create once: xcrun notarytool store-credentials).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/CopyWatch"
APP="dist/CopyWatch.app"
ENTITLEMENTS="Resources/CopyWatch.entitlements"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CopyWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_ID="${DEVELOPER_ID_APP:--}"
if [ "$SIGN_ID" = "-" ]; then
  # Ad-hoc: fine for local runs, but Gatekeeper will refuse it on other Macs.
  codesign --force -s - "$APP" >/dev/null 2>&1 || true
  echo "Built $APP (ad-hoc signed — this Mac only)"
else
  # Developer ID + hardened runtime → notarizable, distributable.
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"
  echo "Built and signed $APP ($SIGN_ID)"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ZIP="dist/CopyWatch.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Submitting for notarization…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    echo "Notarized and stapled $APP"
  fi
fi

echo "Run: open $APP"
