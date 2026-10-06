#!/usr/bin/env bash
# Build the Campfire Linux desktop app in Docker, run it under Xvfb (1280x800) and
# save a screenshot of its first screen.
#
#   scripts/beam/linux_run_screenshot.sh                 # debug build, default PNG path
#   BUILD_MODE=profile scripts/beam/linux_run_screenshot.sh
#   SKIP_BUILD=1 scripts/beam/linux_run_screenshot.sh    # relaunch + reshoot only
#   OUT_DIR=docs/beam/screenshots/my_change SHOT_NAME=x.png scripts/beam/linux_run_screenshot.sh
#   RESET=1 scripts/beam/linux_run_screenshot.sh         # wipe cached volumes first
#
# Needs: docker (colima on this Mac), nothing else on the host. The host tree is
# mounted read-only and copied into a named volume, so building here never touches
# the host's pubspec.yaml, .dart_tool or build/ (which belong to the macOS host loop).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-campfire-beam/linux-dev:3.47.2}"
PLATFORM=linux/amd64
VOL_WORK="${VOL_WORK:-campfire-beam-linux-work}"
VOL_PUB="${VOL_PUB:-campfire-beam-linux-pubcache}"
OUT_DIR="${OUT_DIR:-docs/beam/screenshots/baseline}"
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$REPO/$OUT_DIR" ;; esac
# Outside the repo, but under $HOME: colima only shares $HOME with the VM.
LOG_DIR="${LOG_DIR:-$HOME/.cache/campfire-beam/linux-logs}"
mkdir -p "$OUT_DIR" "$LOG_DIR"

if [ "${RESET:-0}" = "1" ]; then
  docker volume rm -f "$VOL_WORK" "$VOL_PUB" >/dev/null
fi

echo "== image $IMAGE ($PLATFORM)"
docker build --platform "$PLATFORM" -t "$IMAGE" \
  -f "$REPO/scripts/beam/docker/Dockerfile.linux-dev" "$REPO/scripts/beam/docker"

docker volume create "$VOL_WORK" >/dev/null
docker volume create "$VOL_PUB" >/dev/null

echo "== build + run + screenshot"
docker run --rm --platform "$PLATFORM" \
  --shm-size=1g \
  -v "$REPO:/src:ro" \
  -v "$VOL_WORK:/work" \
  -v "$VOL_PUB:/home/dev/.pub-cache" \
  -v "$OUT_DIR:/out" \
  -v "$LOG_DIR:/logs" \
  -e BUILD_MODE="${BUILD_MODE:-debug}" \
  -e APP_ID="${APP_ID:-campfire}" \
  -e SHOT_NAME="${SHOT_NAME:-linux_first_screen.png}" \
  -e SETTLE_SECS="${SETTLE_SECS:-6}" \
  -e TIMEOUT_SECS="${TIMEOUT_SECS:-240}" \
  -e SKIP_BUILD="${SKIP_BUILD:-0}" \
  "$IMAGE" bash /src/scripts/beam/docker/linux_build_and_shoot.sh

echo "== screenshot: $OUT_DIR/${SHOT_NAME:-linux_first_screen.png}"
echo "== logs: $LOG_DIR"
