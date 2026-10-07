# Shared by build_macos_dmg.sh and build_android_apk.sh (sourced, not run).
#
# prepare_release_tree: a clean clone (CFB_RELEASE_DIR, default
# /Users/Shared/cfb-release) reset to the repository's committed HEAD, so
# unfinished files in the working tree never reach a build. Sets REL, HEAD_SHA
# and SUFFIX ("" for a release).
#
# The clone lives OUTSIDE the home folder: the build's absolute path ends up
# inside the shipped binaries (the Dart snapshot keeps the file:// URI of
# .dart_tool/flutter_build/dart_plugin_registrant.dart), and a path under
# /Users/<account> would publish the account name (1.0.0 shipped it this way).
# A CFB_RELEASE_DIR containing the account name is refused.
#
# check_no_account_name <dir>: fails when any file under <dir> contains this
# Mac's account name, raw bytes, binary files included (`strings` skips the
# Mach-O symbol table, where the debug map's paths are).
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
  REL="${CFB_RELEASE_DIR:-/Users/Shared/cfb-release}"
  [[ "$REL" != *"$(basename "$HOME")"* ]] \
    || die "CFB_RELEASE_DIR ($REL) contains the account name, which would ship inside the app"
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

# check_apk_no_account_name <apk>: the same, for every entry of an APK, read
# from the archive (entries such as res/9n.9.png and res/9N.9.png collide on a
# case-insensitive disk, so it is not unpacked).
check_apk_no_account_name() {
  local hits
  hits="$("${PYTHON:-python3}" -I -c '
import sys, zipfile
acct = sys.argv[2].encode()
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        if acct in z.read(n) or acct in n.encode():
            print(n)
' "$1" "$(basename "$HOME")")"
  [[ -z "$hits" ]] || die "this Mac's account name is inside $1; not shipping it:
$hits"
}

check_no_account_name() {
  local acct hits
  acct="$(basename "$HOME")"
  hits="$(LC_ALL=C grep -rlaF -e "$acct" "$1" || true)"
  [[ -z "$hits" ]] || die "this Mac's account name is inside the package; not shipping it:
$hits"
}
