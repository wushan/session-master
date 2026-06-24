#!/bin/bash
# Bundle the SessionMaster menu-bar app into a signed .app. Usage: scripts/bundle-app.sh [release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-debug}"
APP="$ROOT/build/SessionMaster.app"

if [ "$CONF" = release ]; then swift build -c release >/dev/null; BIN="$ROOT/.build/release/SessionMaster"
else swift build >/dev/null; BIN="$ROOT/.build/debug/SessionMaster"; fi

VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SessionMaster"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SessionMaster</string>
  <key>CFBundleIdentifier</key><string>com.sessionmaster.app</string>
  <key>CFBundleName</key><string>SessionMaster</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>SessionMaster recalls terminal windows and switches tabs.</string>
</dict>
</plist>
PLIST

source "$ROOT/scripts/sign.sh"
sign_bundle "$APP" com.sessionmaster.app
echo "Built $APP"
