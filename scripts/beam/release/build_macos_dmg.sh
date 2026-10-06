#!/usr/bin/env bash
# Builds Campfire for BEAM for macOS (Apple Silicon) from the COMMITTED tree and
# packages a DMG.
#
#   scripts/beam/release/build_macos_dmg.sh [version] [build-number]
#
# Works in a clean clone reset to HEAD (CFB_RELEASE_DIR, default
# ~/Desktop/Beam/cfb-release), so unfinished files in the working tree never
# reach a build. The BEAM core is staged from beam-core-build/out with its
# pinned SHA-256 checked. The app is signed ad hoc (no Developer ID yet), so
# the first launch needs right-click -> Open. Output: dist/ in the clone.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REL="${CFB_RELEASE_DIR:-$HOME/Desktop/Beam/cfb-release}"
VERSION="${1:-1.0.0}"; BUILD="${2:-1}"
FLUTTER="${FLUTTER:-$HOME/development/flutter-3.47.2/bin/flutter}"
# Campfire's configure step calls `dart` and `flutter` by name.
export PATH="$(dirname "$FLUTTER"):$PATH"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

head=$(git -C "$REPO" rev-parse HEAD)
[[ -d "$REL/.git" ]] || git clone --quiet --no-hardlinks "$REPO" "$REL"
git -C "$REL" fetch --quiet "$REPO" "$head"
git -C "$REL" checkout --quiet --detach "$head"
git -C "$REL" clean -fdqx -e assets/beam/bin -e build -e .dart_tool
log "building $(git -C "$REL" log -1 --format='%h %s')"

cd "$REL"
scripts/beam/core/stage_binaries.sh macos
(cd scripts && echo yes | ./build_app.sh -v "$VERSION" -b "$BUILD" -p macos -a campfire -d) > /dev/null
"$FLUTTER" build macos --release

APP="$(ls -d build/macos/Build/Products/Release/*.app | head -1)"
[[ -d "$APP" ]] || { echo "no .app produced"; exit 1; }
log "re-signing $(basename "$APP") ad hoc, without the sandbox"
codesign --force --deep --sign - \
  --entitlements scripts/beam/release/campfire_beam_unsandboxed.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# Nothing from this machine (account name, home path) may ship in the app.
acct="$(basename "$HOME")"
if grep -rIl --exclude='*.png' -e "/Users/$acct" -e "$acct" "$APP" >/dev/null 2>&1 \
   || find "$APP" -type f -perm -u+x -exec strings {} + 2>/dev/null | grep -q -e "/Users/$acct"; then
  echo "the app contains this machine's account name or home path; not packaging it" >&2
  exit 1
fi

mkdir -p dist && rm -rf dist/stage && mkdir dist/stage
cp -R "$APP" dist/stage/ && ln -s /Applications dist/stage/Applications
DMG="dist/Campfire-BEAM-${VERSION}-${BUILD}-macos-arm64.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Campfire" -srcfolder dist/stage -ov -format UDZO "$DMG"
rm -rf dist/stage
log "DMG: $REL/$DMG ($(du -h "$DMG" | cut -f1)), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
