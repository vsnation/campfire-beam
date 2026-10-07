#!/usr/bin/env bash
# Stage the pinned BEAM core for Android as native libraries:
#
#   wallet-api  -> android/app/src/main/jniLibs/<abi>/libbeam_wallet_api.so
#   beam-wallet -> android/app/src/main/jniLibs/<abi>/libbeam_wallet.so
#
# Android executes app files only from ApplicationInfo.nativeLibraryDir, and
# only files packaged as jniLibs/<abi>/lib*.so land there (extracted because
# android/app/campfire_beam.gradle turns on legacy packaging). beam-node is
# never shipped: phones do not run the private node.
#
# A binary is copied only when its SHA-256 equals the pin for its platform in
# scripts/beam/core/manifest.json (keys android-arm64, android-x86_64), the
# same pin the app checks before every launch. A built but unpinned binary is
# skipped, a mismatching one refused (exit 1). Without binaries the APK still
# builds and the app says "BEAM core not installed".
#
# Source: $BEAM_CORE_OUT (default ~/Desktop/Beam/beam-core-build/out),
# folders android-arm64/ and android-x86_64/. Nothing is downloaded here.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${BEAM_CORE_OUT:-$HOME/Desktop/Beam/beam-core-build/out}"
MANIFEST="$REPO/scripts/beam/core/manifest.json"
DEST="$REPO/android/app/src/main/jniLibs"

# <abi> <manifest key and out folder> <`file` machine string>
TARGETS=(
  "arm64-v8a android-arm64 aarch64"
  "x86_64 android-x86_64 x86-64"
)

lib_name() {
  case "$1" in
    wallet-api) echo libbeam_wallet_api.so ;;
    beam-wallet) echo libbeam_wallet.so ;;
  esac
}

pin() {
  python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get(sys.argv[2], {}).get(sys.argv[3], {}).get("sha256", ""))
' "$MANIFEST" "$1" "$2"
}

sha() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d' ' -f1; }

staged=0
for t in "${TARGETS[@]}"; do
  read -r abi key machine <<<"$t"
  mkdir -p "$DEST/$abi"
  rm -f "$DEST/$abi"/libbeam_*.so
  for b in wallet-api beam-wallet; do
    from="$SRC/$key/$b"
    to="$DEST/$abi/$(lib_name "$b")"
    if [ ! -f "$from" ]; then
      echo "stage_beam_core: $key/$b not built ($from missing) - skipped"
      continue
    fi
    want="$(pin "$key" "$b")"
    if [ -z "$want" ]; then
      echo "stage_beam_core: $key/$b is NOT PINNED in scripts/beam/core/manifest.json - skipped" >&2
      continue
    fi
    got="$(sha "$from")"
    if [ "$got" != "$want" ]; then
      echo "stage_beam_core: REFUSED $key/$b - sha256 $got does not match the pin" >&2
      exit 1
    fi
    if ! file -b "$from" | grep -q "ELF 64-bit.*$machine"; then
      echo "stage_beam_core: REFUSED $key/$b - not a 64-bit $machine ELF: $(file -b "$from")" >&2
      exit 1
    fi
    cp "$from" "$to"
    chmod 0755 "$to"
    staged=$((staged + 1))
    echo "stage_beam_core: $abi/$(lib_name "$b") staged (pin verified)"
  done
done
echo "stage_beam_core: $staged binaries staged into android/app/src/main/jniLibs"
