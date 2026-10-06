#!/usr/bin/env bash
# Host (macOS) Dart-level loop for Campfire: configure -> pub get -> analyze -> test.
# Needs only Flutter 3.47.2, git, cmake and python3. No Xcode, no Rust, no device.
#
#   scripts/beam/host_test.sh                          # analyze + full test suite
#   scripts/beam/host_test.sh --no-analyze test/beam   # only the given test paths
#   scripts/beam/host_test.sh --no-test                # analyze only
#   scripts/beam/host_test.sh --update-goldens test/beam/screenshot_smoke_test.dart
#   scripts/beam/host_test.sh --copy-goldens --update-goldens test/beam
#
# Arguments after the options are passed to `flutter test`.
#
# Why the tests run in a copy of the tree (CFB_HOST_WORKDIR, default /private/tmp/cfb-host):
#   flutter test rewrites each native-asset dylib's install name to its absolute path
#   under <project>/build/native_assets/macos/. tor_ffi_plugin's pinned prebuilt
#   dylib has only 56 spare header bytes, so that path must be <= 87 characters,
#   i.e. the project root must be <= 37 characters. This checkout's path is longer,
#   and install_name_tool then fails before a single test runs. The copy also keeps
#   the host's tracked pubspec.lock and generated files untouched.
#
# Why the package is renamed to `stackwallet` in the copy:
#   configure_campfire.sh names the package `paymint`, but every upstream test
#   imports `package:stackwallet/...` (upstream CI tests the Stack Wallet config).
#   lib/ only uses relative imports, so the rename changes nothing in the app; it
#   only lets the 200+ upstream test files compile against the Campfire config.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_ROOT="${FLUTTER_ROOT:-$HOME/development/flutter-3.47.2}"
WORK="${CFB_HOST_WORKDIR:-/private/tmp/cfb-host}"
LOG_DIR="${LOG_DIR:-$WORK/.beam-logs}"
REQUIRED_FLUTTER=3.47.2
SECP_COMMIT=e3a885d42a7800c1ccebad94ad1e2b82c4df5c65   # v0.5.0, coinlib's own pin

DO_ANALYZE=1; DO_TEST=1; COPY_GOLDENS=0; TEST_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-analyze) DO_ANALYZE=0 ;;
    --no-test) DO_TEST=0 ;;
    --copy-goldens) COPY_GOLDENS=1 ;;
    -h|--help) sed -n 2,26p "$0"; exit 0 ;;
    *) TEST_ARGS+=("$1") ;;
  esac
  shift
done

export PATH="$FLUTTER_ROOT/bin:$PATH"
ts() { date +%s; }
log() { echo "[$(date +%H:%M:%S)] $*"; }
T0=$(ts)

# --- preflight -------------------------------------------------------------------
FV=$(flutter --version --machine 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')
[ "$FV" = "$REQUIRED_FLUTTER" ] || { echo "need Flutter $REQUIRED_FLUTTER at $FLUTTER_ROOT, found $FV"; exit 1; }
WORK_PHYS="$(mkdir -p "$WORK" && cd "$WORK" && pwd -P)"
LIMIT_PATH="$WORK_PHYS/build/native_assets/macos/libtor_ffi_plugin.dylib"
if [ "${#LIMIT_PATH}" -gt 87 ]; then
  echo "CFB_HOST_WORKDIR resolves to $WORK_PHYS: too long (${#LIMIT_PATH} > 87, see header)"; exit 1
fi
mkdir -p "$LOG_DIR"

# --- 1. sync the tree (uncommitted edits included) -------------------------------
log "sync $REPO -> $WORK_PHYS"
rsync -a --delete \
  --exclude '/build/' --exclude '/.dart_tool/' \
  --exclude '/.flutter-plugins' --exclude '/.flutter-plugins-dependencies' \
  --exclude '/pubspec.yaml' --exclude '/lib/app_config.g.dart' --exclude '/lib/wl_gen/generated/' \
  --exclude '/assets/default_themes' --exclude '/assets/icon' --exclude '/assets/lottie' \
  --exclude '/assets/in_app_logo_icons' --exclude '/assets/svg' \
  --exclude '/linux/flutter/ephemeral/' --exclude '/macos/Flutter/ephemeral/' \
  --exclude '/ios/Flutter/ephemeral/' --exclude '/macos/Pods/' --exclude '/ios/Pods/' \
  --exclude '/scripts/linux/build/' --exclude '/docs/beam/screenshots/' \
  --exclude '/.beam-logs/' --exclude '/.beam-secp256k1/' \
  "$REPO/" "$WORK_PHYS/"
cd "$WORK_PHYS"
T_SYNC=$(ts)

# --- 2. configure as Campfire, the way scripts/build_app.sh does ------------------
# -p macos: the Dart-level config is identical for every platform except iOS, and the
#           linux platform step uses GNU sed. -i: no platform native deps.
# -d: pinned, sha256-verified native-asset prebuilts (tor) instead of compiling Rust.
log "configure Campfire (build_app.sh -a campfire -p macos -i -d)"
(cd scripts && echo yes | ./build_app.sh -v 0.0.1 -b 1 -p macos -a campfire -i -d) \
  > "$LOG_DIR/configure.log" 2>&1 || { tail -40 "$LOG_DIR/configure.log"; exit 1; }
sed -i '' 's/^name: paymint$/name: stackwallet/' pubspec.yaml
grep -q '^name: stackwallet$' pubspec.yaml || { echo "package rename failed"; exit 1; }
(cd scripts && ./prebuild.sh) >> "$LOG_DIR/configure.log" 2>&1
T_CONF=$(ts)

# --- 3. secp256k1 for coinlib (loaded from <cwd>/build/libsecp256k1.dylib) ---------
if [ ! -f build/libsecp256k1.dylib ]; then
  log "build secp256k1 $SECP_COMMIT with cmake"
  (
    set -e
    mkdir -p .beam-secp256k1 && cd .beam-secp256k1
    [ -d secp256k1 ] || git clone -q https://github.com/bitcoin-core/secp256k1 secp256k1
    cd secp256k1 && git checkout -q "$SECP_COMMIT"
    cmake -S . -B _build -DCMAKE_BUILD_TYPE=Release -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
      -DSECP256K1_BUILD_TESTS=OFF -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
      -DSECP256K1_BUILD_BENCHMARK=OFF -DSECP256K1_BUILD_EXAMPLES=OFF
    cmake --build _build -j
  ) > "$LOG_DIR/secp256k1.log" 2>&1 || { tail -30 "$LOG_DIR/secp256k1.log"; exit 1; }
  mkdir -p build
  SECP_LIB=$(find .beam-secp256k1/secp256k1/_build -name 'libsecp256k1*.dylib' | head -1)
  [ -n "$SECP_LIB" ] || { echo "secp256k1 dylib not found"; tail -30 "$LOG_DIR/secp256k1.log"; exit 1; }
  cp -L "$SECP_LIB" build/libsecp256k1.dylib
fi
T_SECP=$(ts)

log "flutter pub get"
flutter pub get > "$LOG_DIR/pub_get.log" 2>&1 || { tail -30 "$LOG_DIR/pub_get.log"; exit 1; }
T_PUB=$(ts)

RC=0
if [ "$DO_ANALYZE" = 1 ]; then
  log "flutter analyze"
  flutter analyze --no-fatal-infos --no-fatal-warnings > "$LOG_DIR/analyze.log" 2>&1 || true
  for sev in error warning info; do
    n=$(grep -cE "^ *$sev • " "$LOG_DIR/analyze.log" || true)
    nl=$(grep -E "^ *$sev • " "$LOG_DIR/analyze.log" | grep -c ' • lib/' || true)
    echo "  analyze $sev: $n (lib/: $nl)"
  done
  tail -1 "$LOG_DIR/analyze.log"
  if grep -qE "^ *error • .* • lib/" "$LOG_DIR/analyze.log"; then RC=1; fi
fi
T_AN=$(ts)

if [ "$DO_TEST" = 1 ]; then
  log "flutter test ${TEST_ARGS[*]:-(all)}"
  rm -f "$LOG_DIR/test.json"
  set +e
  flutter test --file-reporter "json:$LOG_DIR/test.json" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} \
    > "$LOG_DIR/test.log" 2>&1
  TEST_RC=$?
  set -e
  if [ -s "$LOG_DIR/test.json" ]; then
    python3 -I "$REPO/scripts/beam/summarize_test_json.py" "$LOG_DIR/test.json" || true
  else
    echo "no test report produced; last lines of test.log:"; tail -30 "$LOG_DIR/test.log"
  fi
  [ "$TEST_RC" = 0 ] || RC=1
  if [ "$COPY_GOLDENS" = 1 ]; then
    # Bring (re)generated golden PNGs back into the real tree, but only
    # those of what this run tested: several workers share the tree, and
    # copying every goldens/ folder back overwrote their fresh images with
    # this workdir's stale copies.
    copied=0; paths=()
    for t in "${TEST_ARGS[@]}"; do
      case "$t" in -*) ;; *) paths+=("$t") ;; esac
    done
    [ "${#paths[@]}" -gt 0 ] || paths=(test)   # whole suite: every golden
    for t in "${paths[@]}"; do
      t="${t%/}"
      [ -e "$WORK_PHYS/$t" ] || continue
      if [ -d "$WORK_PHYS/$t" ]; then
        src="$WORK_PHYS/$t"; dst="$REPO/$t"
      else
        src="$(dirname "$WORK_PHYS/$t")"; dst="$(dirname "$REPO/$t")"
      fi
      mkdir -p "$dst"
      rsync -a --include '*/' --include 'goldens/*.png' --exclude '*' "$src/" "$dst/"
      copied=$((copied + 1))
    done
    log "copied goldens back for $copied tested path(s)"
  fi
fi
T_END=$(ts)

log "timings: sync=$((T_SYNC-T0))s configure=$((T_CONF-T_SYNC))s secp256k1=$((T_SECP-T_CONF))s pub_get=$((T_PUB-T_SECP))s analyze=$((T_AN-T_PUB))s test=$((T_END-T_AN))s total=$((T_END-T0))s"
log "logs: $LOG_DIR"
exit "$RC"
