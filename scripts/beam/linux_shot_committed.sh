#!/usr/bin/env bash
# Build and screenshot the Linux app from what is COMMITTED, not the working tree.
#
#   scripts/beam/linux_shot_committed.sh <steps-file> <out-dir>
#
# Workers leave unfinished files in the working tree, and linux_run_screenshot.sh
# copies the whole tree, so one half-written file breaks every build. This keeps a
# real clone at ~/Desktop/Beam/cfb-shot (a worktree will not do: its .git points
# outside the folder Docker mounts), resets it to the current HEAD, and runs there.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHOT="${CFB_SHOT_DIR:-$HOME/Desktop/Beam/cfb-shot}"
STEPS="${1:?steps file (relative to the repo)}"
OUT="${2:?output dir}"
case "$OUT" in /*) ;; *) OUT="$REPO/$OUT" ;; esac

head=$(git -C "$REPO" rev-parse HEAD)
if [ ! -d "$SHOT/.git" ]; then
  git clone --quiet --no-hardlinks "$REPO" "$SHOT"
fi
git -C "$SHOT" fetch --quiet "$REPO" "$head"
git -C "$SHOT" checkout --quiet --detach "$head"
git -C "$SHOT" clean -fdq -e assets/beam/bin
echo "== committed tree at $(git -C "$SHOT" log -1 --format='%h %s')"
STEPS_FILE="$STEPS" OUT_DIR="$OUT" bash "$SHOT/scripts/beam/linux_run_screenshot.sh"
