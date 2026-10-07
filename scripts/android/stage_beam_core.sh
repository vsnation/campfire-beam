#!/usr/bin/env bash
# Stage the pinned BEAM core for Android: one library per ABI, loaded into the
# app's process (wallet-api and its node connection run as threads of the
# app; nothing is executed as a child process).
#
#   libbeam_core.so -> android/app/src/main/jniLibs/arm64-v8a/libbeam_core.so
#                      android/app/src/main/jniLibs/x86_64/libbeam_core.so
#
# scripts/beam/core/lib/stage_lib.sh copies each only when its SHA-256 equals
# the pin in scripts/beam/core/lib/manifest.json (keys android-arm64,
# android-x86_64), the same pin the app checks before it loads the library
# (kBeamCoreLibraryManifest), and refuses a mismatch (exit 1). Each must also
# be a 64-bit ELF shared object for its ABI.
#
# The app hashes the file on disk in ApplicationInfo.nativeLibraryDir, so
# android/app/campfire_beam.gradle keeps legacy packaging (the installer
# extracts it there) and keeps AGP from stripping it (stripping would change
# its hash).
#
# Earlier builds shipped wallet-api and beam-wallet as libbeam_wallet_api.so
# and libbeam_wallet.so; every libbeam_*.so is removed first so none of them
# is ever packaged again. With no library built at all the APK still builds
# and the app says "BEAM core not installed"; scripts/beam/release/
# build_android_apk.sh refuses such an APK.
#
# Source: $BEAM_CORE_LIB_OUT (default ~/Desktop/Beam/beam-core-build/out),
# folders lib-android-arm64/ and lib-android-x86_64/. Nothing is downloaded.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${BEAM_CORE_LIB_OUT:-$HOME/Desktop/Beam/beam-core-build/out}"
DEST="$REPO/android/app/src/main/jniLibs"

# <abi> <out folder> <`file` machine string>
TARGETS=(
  "arm64-v8a lib-android-arm64 aarch64"
  "x86_64 lib-android-x86_64 x86-64"
)

built=0
for t in "${TARGETS[@]}"; do
  read -r abi dir _ <<<"$t"
  mkdir -p "$DEST/$abi"
  rm -f "$DEST/$abi"/libbeam_*.so
  [ -f "$OUT/$dir/libbeam_core.so" ] && built=$((built + 1))
done
if [ "$built" -eq 0 ]; then
  echo "stage_beam_core: libbeam_core.so not built ($OUT/lib-android-*) - the APK has no BEAM core"
  exit 0
fi

bash "$REPO/scripts/beam/core/lib/stage_lib.sh" android "$DEST"

for t in "${TARGETS[@]}"; do
  read -r abi _ machine <<<"$t"
  f="$DEST/$abi/libbeam_core.so"
  kind="$(file -b "$f")"
  if ! grep -q "ELF 64-bit.*shared object.*$machine" <<<"$kind"; then
    rm -f "$f"
    echo "stage_beam_core: REFUSED $abi/libbeam_core.so - not a 64-bit $machine ELF library: $kind" >&2
    exit 1
  fi
done
echo "stage_beam_core: libbeam_core.so staged for arm64-v8a and x86_64 (pins verified)"
