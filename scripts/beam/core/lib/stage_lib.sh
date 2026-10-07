#!/usr/bin/env bash
# Puts the pinned libbeam_core (the BEAM core as one library inside the app,
# scripts/beam/core/lib) where a build packs it, after checking its SHA-256
# against scripts/beam/core/lib/manifest.json — the same pins as
# lib/wallets/beam/host/beam_core_location.dart, which the app checks again
# before it loads the library.
#
#   stage_lib.sh macos   <dir>        e.g. "BEAM Campfire.app/Contents/Frameworks"
#   stage_lib.sh android <jniLibs>    → <jniLibs>/<abi>/libbeam_core.so
#
# Built libraries come from $BEAM_CORE_LIB_OUT (default
# ~/Desktop/Beam/beam-core-build/out/lib-<platform>/). A missing or unpinned
# library stops the build: an app without its core is not packaged.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.json"
OUT="${BEAM_CORE_LIB_OUT:-$HOME/Desktop/Beam/beam-core-build/out}"
PLATFORM="${1:?platform}"; DEST="${2:?destination}"
PYTHON="$(command -v python3 || command -v python)"
field() { "$PYTHON" -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3], ""))' "$MANIFEST" "$1" "$2"; }
sha() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d' ' -f1; }

stage() { # stage <key> <target file>
  local key="$1" to="$2" from want got
  from="$OUT/$(field "$key" out)/$(field "$key" file)"
  want="$(field "$key" sha256)"
  [ -f "$from" ] || { echo "stage_lib: $key not built ($from missing)" >&2; exit 1; }
  got="$(sha "$from")"
  [ "$got" = "$want" ] || { echo "stage_lib: REFUSED $key: sha256 $got is not the pin $want" >&2; exit 1; }
  mkdir -p "$(dirname "$to")"
  cp "$from" "$to"
  chmod 0644 "$to"
  echo "stage_lib: $key -> $to (pin verified)"
}

case "$PLATFORM" in
  macos) stage macos-arm64 "$DEST/libbeam_core.dylib" ;;
  android)
    for key in android-arm64 android-x86_64; do
      stage "$key" "$DEST/$(field "$key" abi)/libbeam_core.so"
    done ;;
  *) echo "stage_lib: no library for $PLATFORM yet" >&2; exit 1 ;;
esac
