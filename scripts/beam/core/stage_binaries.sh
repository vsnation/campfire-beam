#!/usr/bin/env bash
# Stage the pinned Campfire BEAM binaries into assets/beam/bin/<os>-<arch>/ so the
# app bundles them (pubspec, BEAM flag) and installs them into <data>/beam/bin at
# first start (lib/wallets/beam/host/bundled_binaries.dart).
#
#   stage_binaries.sh <platform>      platform: linux | macos | windows | android | ios
#
# Every folder the pubspec lists is created, empty when nothing applies, so the
# build never fails on a missing asset directory. Only binaries whose SHA-256
# equals scripts/beam/core/manifest.json are copied; anything else is refused.
# Source: $BEAM_CORE_OUT (default ~/Desktop/Beam/beam-core-build/out), the output
# of build_macos.sh / build_linux.sh. Nothing is downloaded here.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLATFORM="${1:-}"
SRC="${BEAM_CORE_OUT:-$HOME/Desktop/Beam/beam-core-build/out}"
DEST="$REPO/assets/beam/bin"
MANIFEST="$REPO/scripts/beam/core/manifest.json"

# platform key in manifest.json -> folder name under $SRC
declare -a KEYS=(macos-arm64 linux-arm64 linux-x86_64 windows-x86_64)
src_dir() {
  case "$1" in
    macos-arm64) echo "$SRC/macos-arm64" ;;
    linux-arm64) echo "$SRC/linux-aarch64" ;;
    linux-x86_64) echo "$SRC/linux-x86_64" ;;
    windows-x86_64) echo "$SRC/windows-x86_64" ;;
  esac
}

# Git Bash on Windows has python, not always python3.
PYTHON="$(command -v python3 || command -v python)"
pin() {
  "$PYTHON" -I -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]]['sha256'])" "$MANIFEST" "$1" "$2"
}
# Windows binaries are named <binary>.exe; the pins are keyed by <binary>.
ext() { case "$1" in windows-*) echo ".exe" ;; *) echo "" ;; esac; }

# True when $DEST/$1 already holds all three binaries with matching pins
# (staged on the host before a container build, where $SRC is not visible).
already_staged() {
  local e; e=$(ext "$1")
  for b in beam-wallet wallet-api beam-node; do
    [ -f "$DEST/$1/$b$e" ] || return 1
    got=$( (shasum -a 256 "$DEST/$1/$b$e" 2>/dev/null || sha256sum "$DEST/$1/$b$e") | cut -d' ' -f1)
    [ "$got" = "$(pin "$1" "$b")" ] || return 1
  done
}

for k in "${KEYS[@]}"; do
  mkdir -p "$DEST/$k"
done

case "$PLATFORM" in
  macos) WANT=(macos-arm64) ;;
  linux) WANT=(linux-x86_64 linux-arm64) ;;
  windows) WANT=(windows-x86_64) ;;
  *) echo "stage_binaries: nothing to bundle for '${PLATFORM:-<none>}' (desktop core only)"; exit 0 ;;
esac

# Folders for other platforms are emptied so a build never bundles them.
for k in "${KEYS[@]}"; do
  case " ${WANT[*]} " in *" $k "*) ;; *) rm -f "$DEST/$k"/* ;; esac
done

staged=0
for k in "${WANT[@]}"; do
  from="$(src_dir "$k")"
  if [ ! -d "$from" ]; then
    if already_staged "$k"; then
      echo "stage_binaries: $k already staged (pins verified)"
      staged=$((staged + 3))
    else
      rm -f "$DEST/$k"/*
      echo "stage_binaries: $k not built ($from missing) — skipped"
    fi
    continue
  fi
  e=$(ext "$k")
  for b in beam-wallet wallet-api beam-node; do
    want=$(pin "$k" "$b")
    got=$( (shasum -a 256 "$from/$b$e" 2>/dev/null || sha256sum "$from/$b$e") | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
      echo "stage_binaries: REFUSED $k/$b — sha256 $got does not match the pin" >&2
      exit 1
    fi
    cp "$from/$b$e" "$DEST/$k/$b$e"
    chmod 0644 "$DEST/$k/$b$e"   # an asset; the app installs it 0700
    staged=$((staged + 1))
  done
  echo "stage_binaries: $k staged (3 binaries, pins verified)"
done
echo "stage_binaries: $staged binaries staged into assets/beam/bin"
