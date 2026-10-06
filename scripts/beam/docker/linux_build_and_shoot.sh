#!/usr/bin/env bash
# Runs INSIDE the campfire-beam/linux-dev container (see linux_run_screenshot.sh).
#
#   /src   host repo, read-only
#   /work  named volume: a synced copy of /src plus .dart_tool, build/, native-asset
#          outputs and the secp256k1 build. Kept between runs so rebuilds are fast.
#   /out   host directory that receives the PNG
#   /logs  host directory that receives the build/run logs
#
# Env:
#   BUILD_MODE    debug | profile | release      (default debug)
#   APP_ID        campfire | stack_wallet         (default campfire)
#   SHOT_NAME     output file name                (default linux_first_screen.png)
#   SETTLE_SECS   seconds the frame must stay unchanged before it counts as "drawn"
#   TIMEOUT_SECS  give up waiting for a drawn frame after this long
#   SKIP_BUILD=1  reuse the existing bundle; only launch and screenshot
set -euo pipefail

BUILD_MODE="${BUILD_MODE:-debug}"
APP_ID="${APP_ID:-campfire}"
SHOT_NAME="${SHOT_NAME:-linux_first_screen.png}"
SETTLE_SECS="${SETTLE_SECS:-6}"
TIMEOUT_SECS="${TIMEOUT_SECS:-240}"
SCREEN_W=1280
SCREEN_H=800

ts() { date +%s; }
L=/logs; mkdir -p "$L"
log() { echo "[$(date +%H:%M:%S)] $*"; }
T0=$(ts)

# --- 1. sync the working tree (including uncommitted edits) into /work ------------
# Generated / per-platform files are excluded so the host's macOS configuration and
# the container's Linux configuration never overwrite each other. Excluded paths are
# also protected from --delete, so the caches below survive.
log "rsync /src -> /work"
rsync -a --delete \
  --exclude '/build/' \
  --exclude '/.dart_tool/' \
  --exclude '/.flutter-plugins' \
  --exclude '/.flutter-plugins-dependencies' \
  --exclude '/pubspec.yaml' \
  --exclude '/lib/app_config.g.dart' \
  --exclude '/lib/wl_gen/generated/' \
  --exclude '/assets/default_themes' --exclude '/assets/icon' --exclude '/assets/lottie' \
  --exclude '/assets/in_app_logo_icons' --exclude '/assets/svg' \
  --exclude '/linux/flutter/ephemeral/' \
  --exclude '/linux/CMakeLists.txt' --exclude '/linux/my_application.cc' \
  --exclude '/linux/flutter/generated_plugin_registrant.cc' \
  --exclude '/linux/flutter/generated_plugins.cmake' \
  --exclude '/macos/Flutter/ephemeral/' --exclude '/ios/Flutter/ephemeral/' \
  --exclude '/macos/Pods/' --exclude '/ios/Pods/' \
  --exclude '/scripts/linux/build/' \
  --exclude '/docs/beam/screenshots/' \
  /src/ /work/
T_SYNC=$(ts)

cd /work
export USE_SYSTEM_SECURE_STORAGE_DEPS=1

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  # --- 2. configure exactly as upstream CI does, but for the Campfire app ---------
  # -d: native-assets prebuilts (tor_ffi_plugin downloads a pinned, sha256-verified
  #     binary instead of compiling Rust). -s: system jsoncpp/libsecret.
  # -i: skip the secp256k1 rebuild when it is already in /work/build (cached volume).
  NATIVE_FLAG=""
  [ -f /work/build/libsecp256k1.so ] && NATIVE_FLAG="-i"
  log "configure: build_app.sh -a ${APP_ID} -p linux -d -s ${NATIVE_FLAG}"
  (cd scripts && echo yes | ./build_app.sh -v 0.0.1 -b 1 -p linux -a "${APP_ID}" -d -s ${NATIVE_FLAG}) \
    > $L/linux_configure.log 2>&1 || { tail -40 $L/linux_configure.log; exit 1; }
  (cd scripts && ./prebuild.sh) >> $L/linux_configure.log 2>&1
  T_CONF=$(ts)

  log "flutter pub get"
  flutter pub get > $L/linux_pub_get.log 2>&1 || { tail -40 $L/linux_pub_get.log; exit 1; }
  T_PUB=$(ts)

  # A CMake configure that failed on its first run leaves CMAKE_INSTALL_PREFIX at
  # /usr/local in the cache (the template only redirects it to bundle/ when it is
  # "initialized to default"), and every later build then dies installing into
  # /usr/local. Drop such a poisoned cache.
  CMAKE_CACHE="/work/build/linux/x64/${BUILD_MODE}/CMakeCache.txt"
  if [ -f "$CMAKE_CACHE" ] && ! grep -q '^CMAKE_INSTALL_PREFIX:PATH=.*/bundle$' "$CMAKE_CACHE"; then
    log "removing CMake cache with a non-bundle install prefix"
    rm -f "$CMAKE_CACHE"
  fi

  log "flutter build linux --${BUILD_MODE}"
  flutter build linux "--${BUILD_MODE}" > $L/linux_build.log 2>&1 \
    || { tail -60 $L/linux_build.log; exit 1; }
  T_BUILD=$(ts)
  log "timings: sync=$((T_SYNC-T0))s configure=$((T_CONF-T_SYNC))s pub_get=$((T_PUB-T_CONF))s build=$((T_BUILD-T_PUB))s"
fi

BUNDLE=/work/build/linux/x64/${BUILD_MODE}/bundle
BIN="${BUNDLE}/${APP_ID}"
[ -x "$BIN" ] || { echo "missing binary $BIN"; ls "${BUNDLE}" || true; exit 1; }
du -sh "$BUNDLE" | sed 's/^/bundle size: /'

# --- 3. headless display, session bus, unlocked keyring --------------------------
log "starting Xvfb ${SCREEN_W}x${SCREEN_H}"
export DISPLAY=:99
Xvfb :99 -screen 0 "${SCREEN_W}x${SCREEN_H}x24" -nolisten tcp > $L/linux_xvfb.log 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
xdpyinfo >/dev/null 2>&1 || { echo "Xvfb did not start"; cat $L/linux_xvfb.log; exit 1; }

# Fresh app data dir every run, so the screenshot is the true first-run screen.
DATA_DIR=$(mktemp -d /tmp/campfire-data.XXXXXX)

# flutter_secure_storage on Linux talks to the Secret Service over D-Bus.
# Run the app inside a private session bus with an unlocked gnome-keyring.
cat > /tmp/run_app.sh <<EOF
#!/usr/bin/env bash
set -e
printf '' | gnome-keyring-daemon --unlock --components=secrets >/tmp/keyring.env 2>/dev/null || true
xdg-user-dirs-update >/dev/null 2>&1 || true   # ~/.config/user-dirs.dirs + ~/Documents
export LIBGL_ALWAYS_SOFTWARE=1
exec "$BIN" -d "$DATA_DIR"
EOF
chmod +x /tmp/run_app.sh

log "launching $BIN"
T_LAUNCH=$(ts)
dbus-run-session -- /tmp/run_app.sh > $L/linux_app_stdout.log 2>&1 &
APP_PID=$!

cleanup() { kill "$APP_PID" 2>/dev/null || true; kill "$XVFB_PID" 2>/dev/null || true; }
trap cleanup EXIT

# --- 4. wait for the window, then for a settled frame, fill the screen, settle again --
WID=""
for _ in $(seq 1 $((TIMEOUT_SECS*2))); do
  WID=$(xdotool search --onlyvisible --name '.' 2>/dev/null | head -1 || true)
  [ -n "$WID" ] && break
  kill -0 "$APP_PID" 2>/dev/null || { echo "app exited early"; tail -60 $L/linux_app_stdout.log; exit 1; }
  sleep 0.5
done
[ -n "$WID" ] || { echo "no window after ${TIMEOUT_SECS}s"; tail -60 $L/linux_app_stdout.log; exit 1; }
T_WIN=$(ts)
log "window $WID mapped after $((T_WIN-T_LAUNCH))s: $(xdotool getwindowname "$WID" 2>/dev/null || true)"

# A frame counts as drawn when the screen has real content (more than a handful of
# colours) and its pixels have not changed for SETTLE_SECS consecutive probes.
# Loading states do not pass for the first real screen because they keep changing.
SETTLED=1
wait_settled() {
  local prev="" stable=0 colors sum deadline=$(( $(ts) + TIMEOUT_SECS ))
  while :; do
    import -window root /tmp/probe.png 2>/dev/null || true
    colors=$(convert /tmp/probe.png -format '%k' info: 2>/dev/null || echo 0)
    # pixel-data signature (a file hash would differ every time: PNG date chunks)
    sum=$(identify -format '%#' /tmp/probe.png 2>/dev/null || echo none)
    if [ "${colors}" -gt 16 ] && [ "$sum" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi
    prev="$sum"
    [ "$stable" -ge "$SETTLE_SECS" ] && return 0
    kill -0 "$APP_PID" 2>/dev/null || { echo "app exited"; tail -60 $L/linux_app_stdout.log; exit 1; }
    if [ "$(ts)" -ge "$deadline" ]; then
      echo "frame did not settle in ${TIMEOUT_SECS}s (colors=$colors)"; SETTLED=0; return 0
    fi
    sleep 1
  done
}

wait_settled
T_FIRST=$(ts)
log "first settled frame after $((T_FIRST-T_LAUNCH))s"
# main() sets its own window frame (1220 x 75% of screen height) during startup, which
# overrides a resize done at map time, so fill the screen only now.
xdotool windowmove "$WID" 0 0 windowsize "$WID" "$SCREEN_W" "$SCREEN_H" 2>/dev/null || true
[ "$SETTLED" = 1 ] && wait_settled
T_SHOT=$(ts)

import -window root "/out/${SHOT_NAME}"
log "saved /out/${SHOT_NAME}: $(identify -format '%wx%h, %k colours' "/out/${SHOT_NAME}")"
log "timings: window=$((T_WIN-T_LAUNCH))s first_frame=$((T_FIRST-T_LAUNCH))s shot=$((T_SHOT-T_LAUNCH))s total=$((T_SHOT-T0))s"
if [ "$SETTLED" != 1 ]; then
  echo "FAILED: no settled, non-blank frame (PNG kept for inspection). App log tail:"
  tail -30 "$L/linux_app_stdout.log"
  exit 1
fi
