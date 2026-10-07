#!/usr/bin/env bash
# Put the pinned in-process BEAM core into an app checkout for an iOS build:
# copies BeamWalletApi.xcframework into <repo>/ios/BeamCore/, where the BeamCore
# pod (ios/BeamCore/BeamCore.podspec) picks it up at `pod install`.
#
#   scripts/beam/core/ios/stage_ios.sh [<repo root>]     default: this checkout
#
# Each slice's libbeam_wallet_api.a must match scripts/beam/core/ios/SHA256SUMS,
# or nothing is copied. Source: $BEAM_CORE_OUT/ios-xcframework (default
# ~/Desktop/Beam/beam-core-build/out), the output of build_wallet_api.sh. Nothing
# is downloaded or built here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "$HERE/../../../.." && pwd)}"
SRC="${BEAM_CORE_OUT:-$HOME/Desktop/Beam/beam-core-build/out}/ios-xcframework/BeamWalletApi.xcframework"
PINS="$HERE/SHA256SUMS"
DEST="$REPO/ios/BeamCore"

[[ -d "$DEST" ]] || { echo "stage_ios: $DEST missing (not a Campfire for BEAM checkout?)" >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "stage_ios: no XCFramework at $SRC; run build_wallet_api.sh" >&2; exit 1; }
[[ -f "$PINS" ]] || { echo "stage_ios: no pins at $PINS" >&2; exit 1; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Every pinned slice must be in the XCFramework with its pinned hash, and the
# XCFramework must hold nothing else.
declare -i n=0
while read -r want slice_lib; do
    [[ -n "$want" ]] || continue
    slice="${slice_lib%%/*}"
    lib="$SRC/$slice/libbeam_wallet_api.a"
    [[ -f "$lib" ]] || { echo "stage_ios: REFUSED: $slice missing from the XCFramework" >&2; exit 1; }
    got="$(sha "$lib")"
    if [[ "$got" != "$want" ]]; then
        echo "stage_ios: REFUSED $slice: sha256 $got does not match the pin $want" >&2
        exit 1
    fi
    n+=1
done < "$PINS"
found="$(find "$SRC" -name '*.a' | wc -l | tr -d ' ')"
[[ "$found" == "$n" ]] || { echo "stage_ios: REFUSED: $found libraries in the XCFramework, $n pinned" >&2; exit 1; }

rm -rf "$DEST/BeamWalletApi.xcframework"
cp -R "$SRC" "$DEST/BeamWalletApi.xcframework"
echo "stage_ios: staged BeamWalletApi.xcframework ($n slices, pins verified) into ${DEST/#$HOME/~}"
