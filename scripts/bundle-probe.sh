#!/bin/bash
# Bundle recall-probe into a stable, ad-hoc-signed .app so the Accessibility grant
# persists and behaves like the real app. Usage: scripts/bundle-probe.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/RecallProbe.app"

swift build >/dev/null
BIN="$ROOT/.build/debug/recall-probe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/recall-probe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>recall-probe</string>
  <key>CFBundleIdentifier</key><string>com.sessionmaster.recallprobe</string>
  <key>CFBundleName</key><string>RecallProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>RecallProbe recalls terminal windows.</string>
</dict>
</plist>
PLIST

source "$ROOT/scripts/sign.sh"
sign_bundle "$APP" com.sessionmaster.recallprobe
echo "Built $APP"
echo "Binary: $APP/Contents/MacOS/recall-probe"
