#!/usr/bin/env bash
# Campfire for BEAM, Android only. Called by
# scripts/app_config/configure_campfire.sh when the build platform is android,
# after the template files were copied and before platform_config.sh fills in
# the app id. Stack Wallet and Stack Duo builds never run it.
#
# 1. Makes the generated android/app/build.gradle apply campfire_beam.gradle
#    (legacy jniLibs packaging so the core is extracted to nativeLibraryDir and
#    executable, unstripped pinned binaries, release signing from
#    ~/.config/campfire-beam/android/).
# 2. Empties the desktop core's asset folders, so the APK carries no desktop
#    executables.
# 3. Stages the pinned BEAM core into android/app/src/main/jniLibs/<abi>/.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADLE="$REPO/android/app/build.gradle"
LINE='apply from: "campfire_beam.gradle"'

if ! grep -qxF "$LINE" "$GRADLE"; then
  printf '\n// Campfire for BEAM (scripts/android/campfire_android.sh)\n%s\n' "$LINE" >> "$GRADLE"
fi
echo "campfire_android: $GRADLE applies campfire_beam.gradle"

# The desktop binaries are pubspec assets (assets/beam/bin/<os>-<arch>/), and
# stage_binaries.sh leaves them in place for android. An APK must not carry
# ~40 MB of macOS/Linux executables it can never run, so empty those folders
# (the next desktop configure stages them again from beam-core-build/out).
find "$REPO/assets/beam/bin" -mindepth 2 -maxdepth 2 -type f -delete 2>/dev/null || true

bash "$REPO/scripts/android/stage_beam_core.sh"
