# Shared by build_macos_dmg.sh and build_android_apk.sh (sourced, not run).
#
# prepare_release_tree: a clean clone (CFB_RELEASE_DIR, default
# ~/Desktop/Beam/cfb-release) reset to the repository's committed HEAD, so
# unfinished files in the working tree never reach a build. Sets REL, HEAD_SHA
# and SUFFIX ("" for a release).
#
# CFB_PACKAGING_FROM_WORKTREE=1 is for testing packaging changes before they
# are committed: it copies the packaging files below from the working tree
# over the clone and adds "-worktree-packaging" to the artifact's name, so
# such a build can never pass for a release. The app's source stays HEAD.
#
# dart_core_pin <key>: the libbeam_core SHA-256 compiled into the app
# (kBeamCoreLibraryManifest in the clone's beam_core_location.dart). A staged
# library must equal it, or the app refuses to load its own core.

PACKAGING_FILES=(
  scripts/beam/core/stage_binaries.sh
  scripts/beam/core/lib/stage_lib.sh
  scripts/beam/core/lib/manifest.json
  scripts/android/campfire_android.sh
  scripts/android/stage_beam_core.sh
  android/app/campfire_beam.gradle
)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "$*" >&2; exit 1; }
sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

prepare_release_tree() {
  REL="${CFB_RELEASE_DIR:-$HOME/Desktop/Beam/cfb-release}"
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  [[ -d "$REL/.git" ]] || git clone --quiet --no-hardlinks "$REPO" "$REL"
  git -C "$REL" fetch --quiet "$REPO" "$HEAD_SHA"
  git -C "$REL" checkout --quiet --force --detach "$HEAD_SHA"
  # Also undoes edits to tracked files (configure steps, an earlier overlay).
  git -C "$REL" reset --quiet --hard "$HEAD_SHA"
  git -C "$REL" clean -fdqx -e assets/beam/bin -e build -e .dart_tool
  # Kept across builds for speed, but nothing from an earlier build may be
  # packaged again: the staging scripts fill these per platform.
  find "$REL/assets/beam/bin" -type f -delete 2>/dev/null || true
  SUFFIX=""
  if [[ "${CFB_PACKAGING_FROM_WORKTREE:-}" == 1 ]]; then
    SUFFIX="-worktree-packaging"
    local f
    for f in "${PACKAGING_FILES[@]}"; do
      [[ -f "$REPO/$f" ]] || continue
      mkdir -p "$(dirname "$REL/$f")"
      cp -p "$REPO/$f" "$REL/$f"
    done
    log "NOT A RELEASE: packaging files from the working tree: ${PACKAGING_FILES[*]}"
  fi
  log "building $(git -C "$REL" log -1 --format='%h %s')"
}

dart_core_pin() {
  local pin
  pin=$(grep -A1 "'$1':" "$REL/lib/wallets/beam/host/beam_core_location.dart" \
    | grep -o '[0-9a-f]\{64\}' | sed -n 1p || true)
  [[ -n "$pin" ]] || die "no libbeam_core pin for $1 in beam_core_location.dart"
  echo "$pin"
}
