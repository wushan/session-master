#!/bin/bash
# Shared signing helper. Signs a bundle with the stable dev identity from the
# dedicated keychain (no prompts), falling back to ad-hoc if it isn't set up.
# Usage: source scripts/sign.sh; sign_bundle <app-path> <bundle-identifier>
CN="SessionMaster Dev Cert"
DEV_KC="$HOME/Library/Keychains/sessionmaster-dev.keychain-db"
DEV_KC_PW="smdev"

sign_bundle() {
  local app="$1" ident="$2"
  if [ -f "$DEV_KC" ] && security find-identity -p codesigning "$DEV_KC" 2>/dev/null | grep -q "$CN"; then
    security unlock-keychain -p "$DEV_KC_PW" "$DEV_KC" 2>/dev/null || true
    # Sign by name; the keychain is on the search list (set by make-dev-cert.sh).
    codesign --force --sign "$CN" --identifier "$ident" "$app" >/dev/null 2>&1
    echo "  signed: $CN (stable)"
  else
    codesign --force --sign - --identifier "$ident" "$app" >/dev/null 2>&1
    echo "  signed: ad-hoc (run scripts/make-dev-cert.sh for a stable identity)"
  fi
}
