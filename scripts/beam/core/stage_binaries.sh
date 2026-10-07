#!/usr/bin/env bash
# Keeps the BEAM asset folders assets/beam/bin/<os>-<arch>/ present and EMPTY.
#
#   stage_binaries.sh <platform>      platform: linux | macos | windows | android | ios
#
# No build bundles BEAM executables (wallet-api, beam-node, beam-wallet) any
# more. Every platform runs the core inside the app as one library,
# libbeam_core (scripts/beam/core/lib, pins in its manifest.json and in
# lib/wallets/beam/host/beam_core_location.dart), placed by the packaging
# step, not as a Flutter asset:
#
#   macOS    BEAM Campfire.app/Contents/Frameworks/libbeam_core.dylib
#            (scripts/beam/release/build_macos_dmg.sh)
#   Android  jniLibs/<abi>/libbeam_core.so (scripts/android/stage_beam_core.sh)
#   Linux    <bundle>/lib/libbeam_core.so    (.github/workflows/beam-app.yml)
#   Windows  beam_core.dll next to the .exe  (.github/workflows/beam-app.yml)
#   iOS      linked statically (scripts/beam/core/ios)
#
# The pubspec still lists these folders (BEAM flag), so each must exist or the
# build fails; anything left in them by an older build is deleted, so it can
# never ship again. The argument is accepted for the callers
# (configure_campfire.sh passes the build platform) and changes nothing.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEST="$REPO/assets/beam/bin"

for k in macos-arm64 linux-arm64 linux-x86_64 windows-x86_64; do
  mkdir -p "$DEST/$k"
  find "$DEST/$k" -mindepth 1 -delete
done
echo "stage_binaries: ${1:-<none>}: no BEAM executables bundled (the core is libbeam_core inside the app); assets/beam/bin/* empty"
