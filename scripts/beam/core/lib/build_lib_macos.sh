#!/usr/bin/env bash
# Build libbeam_core.dylib for macOS arm64 (12.0+): wallet-api and the integrated
# node in one shared library (src/beam_core.h), from tag beam-7.5.14493 with the
# core series (../patches) and the library series (./patches).
#
#   scripts/beam/core/lib/build_lib_macos.sh             # build, then verify_lib.sh --static
#   scripts/beam/core/lib/build_lib_macos.sh --prepare-only
#
# Outputs ($BUILD_ROOT/out/lib-macos-arm64/):
#   libbeam_core.dylib    install_name @rpath/libbeam_core.dylib, only beam_* exported
#   include/beam_core.h
#   SHA256SUMS, .source   the dylib's hash; everything it was built from
#
# Dependencies: the static Boost 1.90 and OpenSSL 3.5.9 that ../build_macos.sh
# builds into $BUILD_ROOT/deps/macos-arm64 (same flags, macOS 12.0, neutral
# OpenSSL prefix). This script reuses them and builds nothing else.
#
# Env: JOBS (default 6), BEAM_CORE_BUILD_ROOT, KEEP_BUILD=1 keeps the CMake tree
# ($BUILD_ROOT/build/lib-macos-arm64; otherwise deleted after a successful build).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "build on an Apple Silicon host (BEAM picks -mcpu from the host arch)"
need_cmd cmake; need_cmd git; need_cmd patch; need_cmd clang

PLAT="macos-arm64"
MACOS_MIN="12.0"
DEPS_PREFIX="${BUILD_ROOT}/deps/${PLAT}"
BUILD_DIR="${BUILD_ROOT}/build/lib-${PLAT}"
OUT="${OUT_ROOT}/lib-${PLAT}"
JOBS="${JOBS:-6}"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export ZERO_AR_DATE=1

prepare_only=0
for a in "$@"; do
    case "$a" in
        --prepare-only) prepare_only=1 ;;
        *) die "unknown argument $a" ;;
    esac
done

[[ -f "${DEPS_PREFIX}/openssl/lib/libcrypto.a" && -f "${DEPS_PREFIX}/boost/lib/libboost_log.a" ]] \
    || die "no static deps in ${DEPS_PREFIX/#$HOME/~}: run scripts/beam/core/build_macos.sh once (it builds them)"
grep -q "/opt/campfire-beam/openssl" <(strings "${DEPS_PREFIX}/openssl/lib/libcrypto.a" | grep -m1 'OPENSSLDIR' || true) \
    || log "WARNING: could not confirm the neutral OpenSSL prefix in libcrypto.a"

mkdir -p "$LIB_LOGS"
lib_prepare_source
[[ "$prepare_only" == "1" ]] && { log "prepared ${LIB_SRC/#$HOME/~}"; exit 0; }

toolchain="$(clang --version | head -1); $(cmake --version | head -1); macOS SDK $(xcrun --show-sdk-version)"
log "toolchain: ${toolchain}"

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
sources="$(lib_stage_sources "$BUILD_DIR")"
lib_exports_macho "${BUILD_DIR}/campfire/exports.txt" > "${BUILD_DIR}/campfire/exports_macho.txt"

prefix_maps="-ffile-prefix-map=${LIB_SRC}=${PREFIX_MAP_SRC} -ffile-prefix-map=${DEPS_PREFIX}=${PREFIX_MAP_DEPS} -ffile-prefix-map=${BUILD_DIR}=${PREFIX_MAP_BUILD}"
link_flags="-Wl,-exported_symbols_list,${BUILD_DIR}/campfire/exports_macho.txt -Wl,-dead_strip -Wl,-install_name,@rpath/libbeam_core.dylib"

cmake_args=(
    -S "$LIB_SRC" -B "$BUILD_DIR"
    -G "Unix Makefiles"
    "${LIB_BEAM_OPTIONS[@]}"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
    -DBEAM_CORE_LIBRARY_SOURCES="$sources"
    "-DBEAM_CORE_LIBRARY_LINK_FLAGS=${link_flags}"
    "-DCMAKE_C_FLAGS=${prefix_maps}"
    "-DCMAKE_CXX_FLAGS=${prefix_maps}"
    -DBOOST_ROOT="${DEPS_PREFIX}/boost"
    -DBoost_NO_SYSTEM_PATHS=ON
    -DOPENSSL_ROOT_DIR="${DEPS_PREFIX}/openssl"
    -DOPENSSL_USE_STATIC_LIBS=TRUE
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
)
log "configuring (log: ${LIB_LOGS/#$HOME/~}/configure-${PLAT}.log)"
offline cmake "${cmake_args[@]}" > "${LIB_LOGS}/configure-${PLAT}.log" 2>&1 \
    || { tail -60 "${LIB_LOGS}/configure-${PLAT}.log"; die "configure failed"; }
check_cmake_version "$BUILD_DIR"
grep -E '^(BEAM_CORE_LIBRARY|BEAM_BRANCH_NAME|OPENSSL_CRYPTO_LIBRARY|Boost_DIR|BEAM_ATOMIC_SWAP_SUPPORT)[:=]' "${BUILD_DIR}/CMakeCache.txt" >&2 || true

log "building beam_core with -j${JOBS} (log: ${LIB_LOGS/#$HOME/~}/build-${PLAT}.log)"
t0=$(date +%s)
offline cmake --build "$BUILD_DIR" --target beam_core -j"$JOBS" > "${LIB_LOGS}/build-${PLAT}.log" 2>&1 \
    || { grep -nE 'error:|Undefined|duplicate symbol' "${LIB_LOGS}/build-${PLAT}.log" | head -40; tail -30 "${LIB_LOGS}/build-${PLAT}.log"; die "build failed"; }
t1=$(date +%s)
log "built in $((t1 - t0)) s"

dylib="$(find "$BUILD_DIR" -name 'libbeam_core.dylib' -type f | head -1)"
[[ -n "$dylib" ]] || die "libbeam_core.dylib not found in the build tree"
rm -rf "$OUT" && mkdir -p "$OUT/include"
install -m 0755 "$dylib" "$OUT/libbeam_core.dylib"
# Local symbols and debug info go; the exported C interface stays.
strip -x -S "$OUT/libbeam_core.dylib"
# strip invalidates the linker's ad-hoc signature; arm64 macOS will not load an
# unsigned image. The app's own signing replaces this one.
codesign --force --sign - "$OUT/libbeam_core.dylib" 2>/dev/null
install -m 0644 "${LIB_SCRIPTS_DIR}/src/beam_core.h" "$OUT/include/beam_core.h"
echo "$((t1 - t0))" > "$OUT/.build_seconds"
lib_fingerprint "$toolchain" > "$OUT/.source"
(cd "$OUT" && printf '%s  %s\n' "$(sha256_of libbeam_core.dylib)" "lib-${PLAT}/libbeam_core.dylib") > "$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS" >&2
log "size: $(stat -f %z "$OUT/libbeam_core.dylib") bytes"

if [[ "${KEEP_BUILD:-0}" != "1" ]]; then rm -rf "$BUILD_DIR"; log "removed ${BUILD_DIR/#$HOME/~}"; fi
"${LIB_SCRIPTS_DIR}/verify_lib.sh" --static "$OUT/libbeam_core.dylib"
log "done: ${OUT/#$HOME/~}"
