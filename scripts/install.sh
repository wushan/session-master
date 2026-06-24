#!/bin/bash
# Build a release SessionMaster.app, sign it with the stable dev identity, and install
# it to /Applications. The cert-based signature means the Accessibility grant persists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/make-dev-cert.sh"
"$ROOT/scripts/bundle-app.sh" release

DEST="/Applications/SessionMaster.app"
rm -rf "$DEST"
cp -R "$ROOT/build/SessionMaster.app" "$DEST"

echo
echo "Installed → $DEST"
echo "Launch:    open \"$DEST\""
echo "Then click the ▦ menu-bar icon ▸ Dashboard, and grant Accessibility when prompted"
echo "(System Settings ▸ Privacy & Security ▸ Accessibility ▸ enable SessionMaster)."
