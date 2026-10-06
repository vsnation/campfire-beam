#!/usr/bin/env bash
# Runs INSIDE a beamcore-builder container (see build_linux.sh).
#
#   /src    the prepared BEAM checkout (tag pinned, patches applied), read-only
#   /work   named volume (beamcore-work-<arch>): an rsync'd copy of /src plus the
#           CMake build tree, kept between runs so rebuilds are incremental
#   /out    host directory that receives the binaries
#
# Env: JOBS (default nproc), BEAM_EXPECTED_VERSION, BRANCH_LABEL
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
ARCH="$(uname -m)"                       # aarch64 | x86_64
EXPECTED="${BEAM_EXPECTED_VERSION:?}"
BRANCH_LABEL="${BRANCH_LABEL:?}"
OUT="/out/linux-${ARCH}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# CMake derives the version revision from `git rev-list --count HEAD`, but only if
# `git status` prints nothing on stderr. A "dubious ownership" warning would make it
# fall back to 7.5.0, so trust the copied tree explicitly.
git config --global --add safe.directory '*'

log "syncing source into /work/beam"
rsync -a --delete /src/ /work/beam/

cmake_args=(
    -S /work/beam -B /work/build
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DBEAM_LINK_TYPE=Static
    -DBEAM_IPFS_SUPPORT=OFF
    -DBEAM_LASER_SUPPORT=OFF
    -DBEAM_TESTS_ENABLED=OFF
    -DBEAM_HW_WALLET=OFF
    -DBRANCH_NAME="${BRANCH_LABEL}"
    -DBOOST_ROOT=/opt/deps/boost
    -DBoost_NO_SYSTEM_PATHS=ON
    -DOPENSSL_ROOT_DIR=/opt/deps/openssl
)
log "configuring: ${cmake_args[*]}"
start=$(date +%s)
cmake "${cmake_args[@]}" > /work/cmake-configure.log 2>&1 || { tail -60 /work/cmake-configure.log; exit 1; }
grep -E 'BEAM_VERSION:|BRANCH_NAME:' /work/cmake-configure.log >&2 || true
v="$(grep '^BEAM_VERSION:INTERNAL=' /work/build/CMakeCache.txt | cut -d= -f2)"
[[ "$v" == "$EXPECTED" ]] || { log "configured version $v != $EXPECTED"; exit 1; }

log "building with -j${JOBS}"
cmake --build /work/build --target wallet-api beam-node beam-wallet -j"${JOBS}" > /work/build.log 2>&1 \
    || { grep -nE 'error|Error' /work/build.log | head -40; tail -40 /work/build.log; exit 1; }
end=$(date +%s)
log "build took $((end - start)) s"

mkdir -p "$OUT"
install -m 0755 /work/build/wallet/api/wallet-api   "$OUT/wallet-api"
install -m 0755 /work/build/beam/beam-node          "$OUT/beam-node"
install -m 0755 /work/build/wallet/cli/beam-wallet  "$OUT/beam-wallet"
strip --strip-unneeded "$OUT/wallet-api" "$OUT/beam-node" "$OUT/beam-wallet"
echo "$((end - start))" > "$OUT/.build_seconds"

for b in wallet-api beam-node beam-wallet; do
    printf '%s: version=%s size=%s\n' "$b" "$("$OUT/$b" --version | tr -d '\r')" "$(stat -c %s "$OUT/$b")" >&2
    file "$OUT/$b" >&2
    ldd "$OUT/$b" >&2 || true
done
