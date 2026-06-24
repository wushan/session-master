#!/bin/bash
# Cut a release: build the .dmg, tag, create a GitHub Release, and bump the Homebrew cask.
# Develop freely on main; run this only when you want to ship a new version.
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
TAP_REPO="git@github.com:wushan/homebrew-tap.git"

# 0. sanity — clean tree, not already tagged
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "✗ working tree not clean — commit first"; exit 1; }
git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1 && { echo "✗ tag $TAG already exists"; exit 1; }

# 1. build the installer
"$ROOT/scripts/make-dmg.sh" "$VERSION"
DMG="$ROOT/build/SessionMaster-$VERSION.dmg"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

# 2. tag + push
git -C "$ROOT" tag -a "$TAG" -m "SessionMaster $VERSION"
git -C "$ROOT" push origin "$TAG"

# 3. GitHub Release with the dmg
gh release create "$TAG" "$DMG" --title "SessionMaster $VERSION" \
  --notes "Install: \`brew install --cask wushan/tap/session-master\` — or download the .dmg below."

# 4. bump the Homebrew cask in the tap
WORK="$(mktemp -d)"
git clone -q "$TAP_REPO" "$WORK/tap"
CASK="$WORK/tap/Casks/session-master.rb"
sed -i '' -e "s/version \".*\"/version \"$VERSION\"/" -e "s/sha256 \".*\"/sha256 \"$SHA\"/" "$CASK"
git -C "$WORK/tap" commit -aqm "session-master $VERSION"
git -C "$WORK/tap" push -q origin main
rm -rf "$WORK"

echo "✓ Released $TAG and bumped the cask to $VERSION"
echo "  sha256: $SHA"
