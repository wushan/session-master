#!/bin/bash
# Sign with a Developer ID + notarize a release .dmg so Gatekeeper accepts it cleanly
# (no quarantine bypass needed). This is the "official" direct-distribution path — NOT the
# App Store (the sandbox forbids this app's file access / subprocesses / Accessibility).
#
# One-time setup (needs an Apple Developer Program membership, $99/yr):
#   1. Create a "Developer ID Application" certificate in your account, install it.
#   2. Store notarization credentials as a keychain profile:
#        xcrun notarytool store-credentials sessionmaster-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage: scripts/notarize.sh "Developer ID Application: Your Name (TEAMID)" [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:?usage: notarize.sh \"Developer ID Application: ... (TEAMID)\" [version]}"
VERSION="${2:-$(cat "$ROOT/VERSION")}"
PROFILE="sessionmaster-notary"

"$ROOT/scripts/bundle-app.sh" release
APP="$ROOT/build/SessionMaster.app"

# Hardened runtime + secure timestamp, signed with the Developer ID.
# NOTE: this app sends Apple Events (AppleScript to iTerm/Terminal); under the hardened
# runtime that needs the com.apple.security.automation.apple-events entitlement —
# see scripts/entitlements.plist (create it if Apple Events get blocked after notarizing).
ENT="$ROOT/scripts/entitlements.plist"
if [ -f "$ENT" ]; then EXTRA=(--entitlements "$ENT"); else EXTRA=(); fi
codesign --force --deep --options runtime --timestamp "${EXTRA[@]}" --sign "$IDENTITY" "$APP"

"$ROOT/scripts/make-dmg.sh" "$VERSION"
DMG="$ROOT/build/SessionMaster-$VERSION.dmg"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
echo "✓ Signed (Developer ID) + notarized + stapled: $DMG"
