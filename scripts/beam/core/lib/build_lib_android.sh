#!/usr/bin/env bash
# Build libbeam_core.so for Android arm64-v8a and x86_64: wallet-api and the
# integrated node in one shared library (src/beam_core.h), loaded by the app with
# dart:ffi (DynamicLibrary.open('libbeam_core.so') from jniLibs/<abi>/).
#
#   scripts/beam/core/lib/build_lib_android.sh            # both ABIs
#   scripts/beam/core/lib/build_lib_android.sh x86_64     # one
#
# Outputs ($BUILD_ROOT/out/lib-android-arm64/, $BUILD_ROOT/out/lib-android-x86_64/):
#   libbeam_core.so   SONAME libbeam_core.so, only beam_* exported (version script),
#                     libc++ linked statically (c++_static), 16 KB LOAD alignment
#   include/beam_core.h, SHA256SUMS, .source
#
# Toolchain and dependencies are the Android cores' (../android/env.sh): NDK r27c
# (27.2.12479018), API 24, the SDK's CMake 3.22.1, and the static OpenSSL and Boost
# that ../android/build_deps.sh built into $BUILD_ROOT/android/deps/<abi> with that
# NDK. They are reused as they are; nothing is rebuilt. The source tree is the
# library's private clone ($BUILD_ROOT/lib/src, core series + ./patches).
#
# Env: JOBS (default 8), KEEP_BUILD=1 keeps $BUILD_ROOT/build/lib-android-<abi>.
set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Android toolchain pins first, then the library's settings (which win where both
# define something, e.g. offline()).
source "${LIB_DIR}/../android/env.sh"
source "${LIB_DIR}/env.sh"

need_cmd git; need_cmd patch
check_toolchain

abis=()
for a in "$@"; do abis+=("$(abi_normalize "$a")"); done
[[ ${#abis[@]} -gt 0 ]] || abis=("${ANDROID_ABIS_DEFAULT[@]}")
JOBS="${JOBS:-8}"

mkdir -p "$LIB_LOGS"
lib_prepare_source

toolchain="NDK $(sed -n 's/^Pkg.Revision *= *//p' "${ANDROID_NDK}/source.properties" | tr -d '\r'), API ${ANDROID_API}, $("$ANDROID_CMAKE" --version | head -1)"

build_abi() {
    local abi="$1" plat; plat="lib-$(abi_platform "$abi")"
    local deps="${ANDROID_DEPS}/${abi}" bdir="${BUILD_ROOT}/build/${plat}" out="${OUT_ROOT}/${plat}"
    [[ -f "${deps}/.stamp" ]] || die "no dependencies for ${abi}: run scripts/beam/core/android/build_deps.sh ${abi} first"
    local boost="${deps}/boost" ossl="${deps}/openssl"

    # BEAM's Android path makes imported targets for its Boost components only,
    # without their link dependencies: add every other Boost archive to the link.
    local extra=() f c
    for f in "${boost}/libs/${abi}"/libboost_*.a; do
        c="$(basename "$f" .a)"; c="${c#libboost_}"
        case " filesystem program_options thread regex log locale date_time context coroutine " in
            *" $c "*) ;;
            *) extra+=("$f") ;;
        esac
    done

    rm -rf "$bdir" && mkdir -p "$bdir"
    local sources; sources="$(lib_stage_sources "$bdir")"
    lib_exports_elf "${bdir}/campfire/exports.txt" > "${bdir}/campfire/exports.map"
    local maps="-ffile-prefix-map=${LIB_SRC}=${PREFIX_MAP_SRC} -ffile-prefix-map=${ANDROID_DEPS}=${PREFIX_MAP_DEPS} -ffile-prefix-map=${ANDROID_WORK}=${PREFIX_MAP_DEPS} -ffile-prefix-map=${bdir}=${PREFIX_MAP_BUILD} -ffile-prefix-map=${ANDROID_NDK}=${PREFIX_MAP_NDK}"
    local link="-Wl,--version-script=${bdir}/campfire/exports.map -Wl,--exclude-libs,ALL -Wl,--gc-sections -Wl,--no-undefined -Wl,-soname,libbeam_core.so ${extra[*]}"

    local cmake_args=(
        -G Ninja -DCMAKE_MAKE_PROGRAM="$ANDROID_NINJA"
        -S "$LIB_SRC" -B "$bdir"
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK}/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="$abi"
        -DANDROID_PLATFORM="android-${ANDROID_API}"
        -DANDROID_STL=c++_static
        -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
        -DBEAM_ANDROID_EXECUTABLES=ON           # core 0005: the full tree, not only the JNI client library
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        "${LIB_BEAM_OPTIONS[@]}"
        -DBEAM_CORE_LIBRARY_SOURCES="$sources"
        "-DBEAM_CORE_LIBRARY_LINK_FLAGS=${link}"
        "-DCMAKE_C_FLAGS=${maps} -ffunction-sections -fdata-sections"
        "-DCMAKE_CXX_FLAGS=${maps} -ffunction-sections -fdata-sections"
        -DOPENSSL_USE_STATIC_LIBS=TRUE
        -DOPENSSL_ROOT_DIR="$ossl"
        -DOPENSSL_INCLUDE_DIR="${ossl}/include"
        -DOPENSSL_CRYPTO_LIBRARY="${ossl}/lib/libcrypto.a"
        -DOPENSSL_SSL_LIBRARY="${ossl}/lib/libssl.a"
    )
    log "[${abi}] configuring (log: ${LIB_LOGS/#$HOME/~}/configure-${plat}.log)"
    BOOST_ROOT_ANDROID="$boost" offline "$ANDROID_CMAKE" "${cmake_args[@]}" > "${LIB_LOGS}/configure-${plat}.log" 2>&1 \
        || { tail -60 "${LIB_LOGS}/configure-${plat}.log"; die "[${abi}] configure failed"; }
    check_cmake_version "$bdir"
    log "[${abi}] building beam_core with -j${JOBS} (log: ${LIB_LOGS/#$HOME/~}/build-${plat}.log)"
    local t0 t1; t0=$(date +%s)
    BOOST_ROOT_ANDROID="$boost" offline "$ANDROID_CMAKE" --build "$bdir" --target beam_core -j"$JOBS" > "${LIB_LOGS}/build-${plat}.log" 2>&1 \
        || { grep -nE 'error:|undefined' "${LIB_LOGS}/build-${plat}.log" | head -40; tail -30 "${LIB_LOGS}/build-${plat}.log"; die "[${abi}] build failed"; }
    t1=$(date +%s)
    log "[${abi}] built in $((t1 - t0)) s"

    local so; so="$(find "$bdir" -name 'libbeam_core.so' -type f | head -1)"
    [[ -n "$so" ]] || die "[${abi}] libbeam_core.so not found"
    rm -rf "$out" && mkdir -p "$out/include"
    "${NDK_TC}/bin/llvm-strip" --strip-unneeded -o "${out}/libbeam_core.so" "$so"
    chmod 0755 "${out}/libbeam_core.so"
    install -m 0644 "${LIB_SCRIPTS_DIR}/src/beam_core.h" "${out}/include/beam_core.h"
    echo "$((t1 - t0))" > "${out}/.build_seconds"
    lib_fingerprint "$toolchain, ${abi}" > "${out}/.source"
    (cd "$out" && printf '%s  %s\n' "$(sha256_of libbeam_core.so)" "${plat}/libbeam_core.so") > "${out}/SHA256SUMS"
    cat "${out}/SHA256SUMS" >&2
    if [[ "${KEEP_BUILD:-0}" != "1" ]]; then rm -rf "$bdir"; log "[${abi}] removed ${bdir/#$HOME/~}"; fi
    PATH="${NDK_TC}/bin:${PATH}" "${LIB_SCRIPTS_DIR}/verify_lib.sh" --static "${out}/libbeam_core.so"
}

for abi in "${abis[@]}"; do build_abi "$abi"; done
log "done"
