#!/usr/bin/env bash
# Runs INSIDE a beamcore-builder container (see ../build_lib_linux.sh).
#
#   /src       the library's BEAM tree (pinned commit + core series + lib patches), read-only
#   /campfire  the library sources, exports.map and this script, read-only
#   /work      named volume beamcore-libwork-<arch>: a copy of /src and the CMake tree
#   /out       host directory that receives lib-linux-<arch>/libbeam_core.so
#
# Env: JOBS, BEAM_EXPECTED_VERSION, BRANCH_LABEL
set -euo pipefail
JOBS="${JOBS:-$(nproc)}"
ARCH="$(uname -m)"                       # aarch64 | x86_64
OUT="/out/lib-linux-${ARCH}"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
git config --global --add safe.directory '*'

log "syncing source into /work/beam"
rsync -a --delete /src/ /work/beam/
rm -rf /work/campfire && cp -R /campfire /work/campfire
srcs="/work/campfire/beam_core_wallet_api.cpp;/work/campfire/beam_core_node.cpp;/work/campfire/beam_core_log.cpp"
maps="-ffile-prefix-map=/work/beam=/beam -ffile-prefix-map=/work/build=/build -ffile-prefix-map=/work/campfire=/build/campfire -ffile-prefix-map=/opt/deps=/deps"
link="-Wl,--version-script=/work/campfire/exports.map -Wl,--exclude-libs,ALL -Wl,--gc-sections -Wl,--no-undefined -Wl,-soname,libbeam_core.so -static-libstdc++ -static-libgcc"

rm -rf /work/build
cmake -S /work/beam -B /work/build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DBEAM_LINK_TYPE=Static -DBEAM_NO_QT_UI_WALLET=ON \
    -DBEAM_IPFS_SUPPORT=OFF -DBEAM_LASER_SUPPORT=OFF -DBEAM_TESTS_ENABLED=OFF -DBEAM_HW_WALLET=OFF \
    -DBEAM_ATOMIC_SWAP_SUPPORT=OFF -DBEAM_ASSET_SWAP_SUPPORT=OFF \
    -DBEAM_CORE_LIBRARY=ON -DBEAM_CORE_LIBRARY_SOURCES="$srcs" "-DBEAM_CORE_LIBRARY_LINK_FLAGS=$link" \
    -DBRANCH_NAME="${BRANCH_LABEL}" -DBEAM_RECORDED_SOURCE_DIR=/beam \
    "-DCMAKE_C_FLAGS=$maps -ffunction-sections -fdata-sections" \
    "-DCMAKE_CXX_FLAGS=$maps -ffunction-sections -fdata-sections" \
    -DBOOST_ROOT=/opt/deps/boost -DBoost_NO_SYSTEM_PATHS=ON \
    -DOPENSSL_ROOT_DIR=/opt/deps/openssl -DOPENSSL_USE_STATIC_LIBS=TRUE \
    > /work/configure.log 2>&1 || { tail -60 /work/configure.log; exit 1; }
v="$(grep '^BEAM_VERSION:INTERNAL=' /work/build/CMakeCache.txt | cut -d= -f2)"
[[ "$v" == "${BEAM_EXPECTED_VERSION:?}" ]] || { log "configured version $v != $BEAM_EXPECTED_VERSION"; exit 1; }

log "building beam_core with -j${JOBS}"
start=$(date +%s)
cmake --build /work/build --target beam_core -j"${JOBS}" > /work/build.log 2>&1 \
    || { grep -nE 'error|undefined reference' /work/build.log | head -40; tail -40 /work/build.log; exit 1; }
log "build took $(( $(date +%s) - start )) s"
so="$(find /work/build -name libbeam_core.so -type f | head -1)"
mkdir -p "$OUT/include"
strip --strip-unneeded -o "$OUT/libbeam_core.so" "$so"
chmod 0755 "$OUT/libbeam_core.so"
file "$OUT/libbeam_core.so" >&2
readelf -d "$OUT/libbeam_core.so" | grep -E 'NEEDED|SONAME' >&2
nm -D --defined-only "$OUT/libbeam_core.so" | awk '$2=="T"{print "  export " $3}' >&2
