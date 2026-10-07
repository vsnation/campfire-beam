#!/usr/bin/env bash
# Campfire for BEAM, Android only. Called by
# scripts/app_config/configure_campfire.sh when the build platform is android,
# after the template files were copied and before platform_config.sh fills in
# the app id. Stack Wallet and Stack Duo builds never run it.
#
# 1. Makes the generated android/app/build.gradle apply campfire_beam.gradle
#    (legacy jniLibs packaging so the core library is extracted to
#    nativeLibraryDir, where the app checks its hash before loading it; the
#    pinned library left unstripped; release signing from
#    ~/.config/campfire-beam/android/).
# 2. Empties the BEAM asset folders (assets/beam/bin/*), so the APK carries no
#    executables.
# 3. Stages the pinned BEAM core library (libbeam_core.so) into
#    android/app/src/main/jniLibs/<abi>/.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADLE="$REPO/android/app/build.gradle"
LINE='apply from: "campfire_beam.gradle"'

if ! grep -qxF "$LINE" "$GRADLE"; then
  printf '\n// Campfire for BEAM (scripts/android/campfire_android.sh)\n%s\n' "$LINE" >> "$GRADLE"
fi
echo "campfire_android: $GRADLE applies campfire_beam.gradle"

# assets/beam/bin/<os>-<arch>/ are pubspec asset folders. stage_binaries.sh
# keeps them empty on every platform now; emptied here as well, so an APK can
# never carry desktop executables left by an older build.
find "$REPO/assets/beam/bin" -mindepth 2 -maxdepth 2 -type f -delete 2>/dev/null || true

bash "$REPO/scripts/android/stage_beam_core.sh"
