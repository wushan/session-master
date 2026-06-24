#!/bin/bash
# Build a release SessionMaster.app and package it into a drag-to-install .dmg.
# Usage: scripts/make-dmg.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}"

"$ROOT/scripts/bundle-app.sh" release
APP="$ROOT/build/SessionMaster.app"
DMG="$ROOT/build/SessionMaster-$VERSION.dmg"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # drag target

rm -f "$DMG"
hdiutil create -volname "SessionMaster" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
shasum -a 256 "$DMG"
