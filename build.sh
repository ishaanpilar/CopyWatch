#!/bin/zsh
# Build CopyWatch.app from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/CopyWatch"
APP="dist/CopyWatch.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CopyWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run: open $APP"
