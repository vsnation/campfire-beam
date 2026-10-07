#!/usr/bin/env bash
# Builds the BEAM Campfire Android APKs from the COMMITTED tree, signed with
# the release key: one per ABI, arm64-v8a (phones) and x86_64 (emulators).
#
#   scripts/beam/release/build_android_apk.sh [version] [build-number]
#
# One APK per ABI, not one for both: Flutter gives a split APK the versionCode
# <abi>*1000 + build (arm64 2000+, x86_64 4000+), and 1.0.0 shipped as the
# arm64 split with versionCode 2008. A single APK would get versionCode
# <build> (10 < 2008), and Android refuses it as an update to the installed
# app; the only way in would be uninstalling, which deletes the wallets. The
# split also keeps the phone APK under Telegram's 50 MB limit for bots.
#
# Works in a clean clone reset to HEAD (release_tree.sh). The BEAM core ships
# as lib/<abi>/libbeam_core.so (scripts/android/stage_beam_core.sh), loaded
# into the app's process; no wallet-api or beam-wallet is packaged. An APK is
# refused unless it carries the pinned library for its ABI byte for byte, the
# pins equal those compiled into the app, the native libraries are extracted
# on install, its version is right, and it is signed by the release key
# below. Toolchain, signing and the reasons: the project notes. Output:
# $CFB_ARTIFACTS_DIR (default ~/Desktop/Beam/cfb-artifacts/release-<version>).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VERSION="${1:-1.0.0}"; BUILD="${2:-1}"
OUT_DIR="${CFB_ARTIFACTS_DIR:-$HOME/Desktop/Beam/cfb-artifacts/release-$VERSION}"
FLUTTER="${FLUTTER:-$HOME/development/flutter-3.47.2/bin/flutter}"
export PATH="$(dirname "$FLUTTER"):$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
. "$REPO/scripts/beam/release/release_tree.sh"
BUILD_TOOLS="$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)"
# The release key's certificate (public; the project notes §4). An APK
# signed by anything else (the debug key, when key.properties is missing)
# could never update an installed Campfire for BEAM.
RELEASE_CERT_SHA256=a6d8817eabd6a519f4778870540a0d9672a1ba466b447e7e06c511b0adc0e99f
# <abi>:<pin key>:<versionCode offset Flutter gives the split>
ABIS=(arm64-v8a:android-arm64:2000 x86_64:android-x86_64:4000)

prepare_release_tree
cd "$REL"

(cd scripts && echo yes | ./build_app.sh -v "$VERSION" -b "$BUILD" -p android -a campfire -d) > /dev/null
grep -qxF 'apply from: "campfire_beam.gradle"' android/app/build.gradle \
  || die "android/app/build.gradle does not apply campfire_beam.gradle"
[[ -z "$(find assets/beam/bin -type f)" ]] || die "desktop BEAM executables staged for Android"
for t in "${ABIS[@]}"; do
  IFS=: read -r abi key _ <<<"$t"
  [[ "$(ls android/app/src/main/jniLibs/"$abi")" == libbeam_core.so ]] \
    || die "jniLibs/$abi must hold libbeam_core.so only: $(ls android/app/src/main/jniLibs/"$abi")"
  [[ "$(sha256_of android/app/src/main/jniLibs/"$abi"/libbeam_core.so)" == "$(dart_core_pin "$key")" ]] \
    || die "jniLibs/$abi/libbeam_core.so is not the pin compiled into the app"
done
(cd scripts && ./prebuild.sh) > /dev/null
"$FLUTTER" build apk --release --split-per-abi --target-platform android-arm64,android-x64

mkdir -p "$OUT_DIR"
for t in "${ABIS[@]}"; do
  IFS=: read -r abi key offset <<<"$t"
  APK="build/app/outputs/flutter-apk/app-$abi-release.apk"
  [[ -f "$APK" ]] || die "no $APK produced"
  # The core, byte for byte; nothing of the old executables.
  [[ "$(unzip -p "$APK" "lib/$abi/libbeam_core.so" | shasum -a 256 | cut -d' ' -f1)" == "$(dart_core_pin "$key")" ]] \
    || die "lib/$abi/libbeam_core.so in $APK is not the pinned library"
  # Whole outputs first: `producer | grep -q` under pipefail fails when grep
  # stops reading early, and a match would read as no match.
  listing="$(unzip -l "$APK")"
  if grep -q -e 'libbeam_wallet' -e 'assets/beam/bin/.*/[^/ ]' <<<"$listing"; then
    die "$APK carries BEAM executables"
  fi
  manifest="$("$BUILD_TOOLS/aapt2" dump xmltree --file AndroidManifest.xml "$APK")"
  grep -q 'extractNativeLibs(.*)=true' <<<"$manifest" \
    || die "$APK does not extract its native libraries (android:extractNativeLibs)"
  badging="$("$BUILD_TOOLS/aapt2" dump badging "$APK" | sed -n 1p)"
  grep -q "versionCode='$((offset + BUILD))' versionName='$VERSION'" <<<"$badging" \
    || die "$APK has the wrong version: $badging"
  cert="$("$BUILD_TOOLS/apksigner" verify --print-certs "$APK" \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
  [[ "$cert" == "$RELEASE_CERT_SHA256" ]] || die "$APK is signed by $cert, not the release key"
  # Nothing from this machine (account name, home path) may ship.
  check_apk_no_account_name "$APK"
  OUT="$OUT_DIR/BEAM-Campfire-${VERSION}-${BUILD}-android-${abi}${SUFFIX}.apk"
  cp "$APK" "$OUT"
  log "APK: $OUT ($(du -h "$OUT" | cut -f1)), versionCode $((offset + BUILD)), sha256 $(sha256_of "$OUT")"
done
# Intermediates are ~1.5 GB per ABI and the next build regenerates them.
rm -rf build/app/intermediates build/app/tmp
(cd android && ./gradlew --stop) > /dev/null 2>&1 || true
