#!/usr/bin/env bash
# Build BEAM's wallet-api as an in-process static library for iOS (device arm64 and
# simulator arm64), from tag beam-7.5.14493 with Campfire's core patch series
# (../patches) plus the iOS patch (./patches/0101), and package both slices as an
# XCFramework.
#
#   scripts/beam/core/ios/build_deps.sh            # once: static OpenSSL + Boost per slice
#   scripts/beam/core/ios/build_wallet_api.sh      # both slices + XCFramework + verify
#   scripts/beam/core/ios/build_wallet_api.sh ios-arm64-simulator   # one slice (no XCFramework
#                                                  # unless the other slice is already in out/)
#   scripts/beam/core/ios/build_wallet_api.sh --prepare-only        # just the patched source tree
#
# Outputs:
#   $BUILD_ROOT/out/ios-arm64/libbeam_wallet_api.a            (+ include/beam_wallet_api.h, .source)
#   $BUILD_ROOT/out/ios-arm64-simulator/libbeam_wallet_api.a
#   $BUILD_ROOT/out/ios-xcframework/BeamWalletApi.xcframework  (both slices, headers)
#   $BUILD_ROOT/out/ios-xcframework/SHA256SUMS                  (the two archives)
#
# libbeam_wallet_api.a is one archive: the beam_wallet_api_lib target (patch 0101)
# and every BEAM library it links, plus static Boost and OpenSSL. An app links it and
# calls the C functions in beam_wallet_api.h; nothing else is exported by design.
#
# Source tree: a PRIVATE clone at $BUILD_ROOT/ios/src, taken from the desktop
# builds' full clone (local, no network) when it exists, otherwise from
# $BEAM_REPO_URL. A tree that is not exactly "pinned commit + this patch series"
# is thrown away and cloned again (same rules as the Android build).
#
# Env: JOBS (default 6), BEAM_CORE_BUILD_ROOT, KEEP_BUILD=1 to keep the CMake trees.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need_cmd git; need_cmd patch
check_toolchain

prepare_only=0
slices=()
for a in "$@"; do
    case "$a" in
        --prepare-only) prepare_only=1 ;;
        *) slices+=("$(slice_normalize "$a")") ;;
    esac
done
[[ ${#slices[@]} -gt 0 ]] || slices=("${IOS_SLICES_DEFAULT[@]}")
mkdir -p "$IOS_ROOT" "$IOS_LOGS"

# ---- source ---------------------------------------------------------------------------
SRC_STAMP="${IOS_ROOT}/.src_stamp"
PATCHSET="${IOS_ROOT}/patchset"     # snapshot of the series this tree was patched with

snapshot_patchset() {
    rm -rf "$PATCHSET" && mkdir -p "$PATCHSET"
    local p
    while IFS= read -r p; do cp "$p" "$PATCHSET/"; done < <(patch_series)
}

verify_pinned_checkout() {
    local head; head="$(git -C "$IOS_SRC" rev-parse HEAD)"
    [[ "$head" == "$BEAM_COMMIT" ]] || die "ios/src HEAD is $head, expected $BEAM_COMMIT"
    local tagc; tagc="$(git -C "$IOS_SRC" rev-parse "${BEAM_TAG}^{commit}")"
    [[ "$tagc" == "$BEAM_COMMIT" ]] || die "tag $BEAM_TAG is $tagc, expected $BEAM_COMMIT"
    local count; count="$(git -C "$IOS_SRC" rev-list HEAD --count)"
    [[ "7.5.${count}" == "$BEAM_EXPECTED_VERSION" ]] || die "rev-list count $count gives 7.5.${count} (shallow clone?)"
    local sm rec act
    for sm in "${BEAM_SUBMODULES[@]}"; do
        rec="$(git -C "$IOS_SRC" ls-tree HEAD "$sm" | awk '{print $3}')"
        act="$(git -C "$IOS_SRC/$sm" rev-parse HEAD)"
        [[ "$rec" == "$act" ]] || die "submodule $sm is at $act, the commit pins $rec"
    done
}

fresh_source() {
    log "creating private BEAM tree at ${IOS_SRC}"
    rm -rf "$IOS_SRC" "$SRC_STAMP"
    local origin="$BEAM_REPO_URL"
    if [[ -d "${BEAM_SRC}/.git" && "$(git -C "$BEAM_SRC" rev-parse --is-shallow-repository)" == "false" ]]; then
        origin="$BEAM_SRC"            # the desktop builds' full clone: local, no network
    fi
    log "cloning from ${origin}"
    git clone -q --no-checkout "$origin" "$IOS_SRC"
    git -C "$IOS_SRC" -c advice.detachedHead=false checkout -q "$BEAM_COMMIT"
    local sm
    for sm in "${BEAM_SUBMODULES[@]}"; do
        git -C "$IOS_SRC" submodule init "$sm" >/dev/null
        if [[ -d "${BEAM_SRC}/${sm}" ]] && git -C "${BEAM_SRC}/${sm}" rev-parse HEAD >/dev/null 2>&1; then
            git -C "$IOS_SRC" config "submodule.${sm}.url" "${BEAM_SRC}/${sm}"
        fi
    done
    git -C "$IOS_SRC" -c protocol.file.allow=always submodule update -q "${BEAM_SUBMODULES[@]}"
    verify_pinned_checkout
    [[ -z "$(git -C "$IOS_SRC" status --porcelain --untracked-files=all)" ]] || die "fresh clone is not clean"
    snapshot_patchset
    local p
    for p in "$PATCHSET"/*.patch; do
        (cd "$IOS_SRC" && patch -p1 --forward -s < "$p") || die "patch failed: $(basename "$p")"
        log "applied $(basename "$p")"
    done
    source_fingerprint > "$SRC_STAMP"
}

source_is_reusable() {
    [[ -d "${IOS_SRC}/.git" && -f "$SRC_STAMP" ]] || return 1
    [[ "$(cat "$SRC_STAMP")" == "$(source_fingerprint)" ]] || { log "patch series or commit changed"; return 1; }
    (verify_pinned_checkout) >/dev/null 2>&1 || { log "ios/src is not at the pinned commit"; return 1; }
    # common.sh: every changed path must be a version our patches produce.
    local bad
    if ! bad="$(check_source_tree "$IOS_SRC" "$PATCHSET" "${BEAM_SUBMODULES[@]}")"; then
        log "ios/src differs from commit + patches:"; printf '%s\n' "$bad" | sed 's/^/    /' >&2
        return 1
    fi
    # And the WHOLE series must be applied (check_source_tree also accepts a prefix
    # of it): un-apply it in reverse order on a copy of the touched files.
    local p path rev=() tmp; tmp="$(mktemp -d)"
    for p in "$PATCHSET"/*.patch; do rev=("$p" ${rev[@]+"${rev[@]}"}); done
    while IFS= read -r path; do
        [[ -n "$path" && -f "${IOS_SRC}/${path}" ]] || continue
        mkdir -p "${tmp}/$(dirname "$path")" && cp "${IOS_SRC}/${path}" "${tmp}/${path}"
    done < <(sed -n 's#^+++ b/\([^[:space:]]*\).*#\1#p' "$PATCHSET"/*.patch | sort -u)
    for p in "${rev[@]}"; do
        (cd "$tmp" && patch -p1 -R -s -f < "$p" >/dev/null 2>&1) || { rm -rf "$tmp"; log "$(basename "$p") is not applied"; return 1; }
    done
    rm -rf "$tmp"
    return 0
}

if source_is_reusable; then
    log "reusing ${IOS_SRC} ($(wc -l < "$SRC_STAMP" | tr -d ' ') pins match)"
else
    fresh_source
fi
grep -q 'BEAM_WALLET_API_LIBRARY' "${IOS_SRC}/wallet/api/CMakeLists.txt" \
    || die "the patch series lacks 0101 (BEAM_WALLET_API_LIBRARY); nothing to build for iOS"
log "source: ${BEAM_TAG} ${BEAM_COMMIT}; series:"
sed 's/^/    /' "$SRC_STAMP" >&2
[[ "$prepare_only" == "1" ]] && { log "prepared ${IOS_SRC}"; exit 0; }

# ---- build ------------------------------------------------------------------------------
# What a library was built from: the tree's fingerprint, the library's own sources,
# the dependency stamps and the toolchain.
library_fingerprint() {
    source_fingerprint
    local f
    for f in "${IOS_SCRIPTS_DIR}"/src/*; do echo "$(sha256_of "$f")  src/$(basename "$f")"; done
    echo "$(xcodebuild -version | tr '\n' ' ')"
}
BRANCH_LABEL="${BEAM_TAG}-campfire"
export ZERO_AR_DATE=1      # libtool/ar write zero timestamps: the archive hash is reproducible

build_slice() {
    local slice="$1"
    local deps="${IOS_DEPS}/${slice}" bdir="${IOS_BUILD}/${slice}" out="${OUT_ROOT}/${slice}"
    local log_cfg="${IOS_LOGS}/beam-configure-${slice}.log" log_build="${IOS_LOGS}/beam-build-${slice}.log"
    [[ -f "${deps}/.stamp" ]] || die "no dependencies for ${slice}: run build_deps.sh ${slice} first"
    local boost="${deps}/boost" ossl="${deps}/openssl"

    # A fresh tree, so that every archive in it afterwards belongs to the
    # beam_wallet_api_lib link closure (only that target is built).
    rm -rf "$bdir" && mkdir -p "$bdir/campfire"
    # The library's own source (src/, not part of the BEAM tree), copied into the
    # build tree so __FILE__ records it under the neutral /build prefix.
    install -m 0644 "${IOS_SCRIPTS_DIR}/src/api_cli_library.cpp" "${IOS_SCRIPTS_DIR}/src/beam_wallet_api.h" "$bdir/campfire/"
    local cmake_args=(
        -S "$IOS_SRC" -B "$bdir"
        -G "Unix Makefiles"
        -DCMAKE_SYSTEM_NAME=iOS
        # BEAM's top-level CMakeLists.txt reads IOS before project() (to define
        # __IOS__, which keeps the macOS-only HID key keeper and IOKit out); CMake
        # itself sets IOS only inside project(). Toolchain files set it early too.
        -DIOS=ON
        -DCMAKE_OSX_SYSROOT="$(slice_sdk "$slice")"
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=OFF
        -DBEAM_LINK_TYPE=Static
        -DBEAM_WALLET_API_LIBRARY=ON                # patch 0101: wallet-api as beam_wallet_api_run()
        -DBEAM_WALLET_API_LIBRARY_SOURCE="$bdir/campfire/api_cli_library.cpp"
        -DBEAM_NO_QT_UI_WALLET=ON
        -DBEAM_IPFS_SUPPORT=OFF
        -DBEAM_LASER_SUPPORT=OFF
        -DBEAM_TESTS_ENABLED=OFF
        -DBEAM_HW_WALLET=OFF
        -DBEAM_ATOMIC_SWAP_SUPPORT=OFF              # BEAM forces atomic swap off on iOS anyway
        -DBEAM_ASSET_SWAP_SUPPORT=OFF               # as on Android
        -DBRANCH_NAME="$BRANCH_LABEL"
        -DBEAM_RECORDED_SOURCE_DIR="$PREFIX_MAP_SRC"   # patch 0005: matches -ffile-prefix-map
        "-DCMAKE_C_FLAGS=$(prefix_map_flags)"
        "-DCMAKE_CXX_FLAGS=$(prefix_map_flags)"
        -DOPENSSL_USE_STATIC_LIBS=TRUE
        -DOPENSSL_ROOT_DIR="$ossl"
        -DOPENSSL_INCLUDE_DIR="${ossl}/include"
        -DOPENSSL_CRYPTO_LIBRARY="${ossl}/lib/libcrypto.a"
        -DOPENSSL_SSL_LIBRARY="${ossl}/lib/libssl.a"
    )
    log "[${slice}] configuring (log: ${log_cfg})"
    BOOST_ROOT_IOS="$boost" offline cmake "${cmake_args[@]}" > "$log_cfg" 2>&1 \
        || { tail -60 "$log_cfg"; die "[${slice}] configure failed"; }
    check_cmake_version "$bdir"
    grep -E '^(BEAM_BRANCH_NAME|BEAM_WALLET_API_LIBRARY|OPENSSL_CRYPTO_LIBRARY|CMAKE_OSX_SYSROOT|CMAKE_OSX_DEPLOYMENT_TARGET)[:=]' "${bdir}/CMakeCache.txt" >&2 || true

    log "[${slice}] building beam_wallet_api_lib with -j${JOBS} (log: ${log_build})"
    local t0 t1; t0=$(date +%s)
    BOOST_ROOT_IOS="$boost" offline cmake --build "$bdir" --target beam_wallet_api_lib -j"$JOBS" > "$log_build" 2>&1 \
        || { grep -nE 'error:' "$log_build" | head -40; tail -30 "$log_build"; die "[${slice}] build failed"; }
    t1=$(date +%s)
    log "[${slice}] built in $((t1 - t0)) s"

    # One archive: the closure, Boost and OpenSSL. Members nobody references are
    # left out by the app's linker.
    local parts=() f
    while IFS= read -r f; do parts+=("$f"); done < <(find "$bdir" -name '*.a' -type f | sort)
    for f in "${boost}"/lib/libboost_*.a; do parts+=("$f"); done
    parts+=("${ossl}/lib/libssl.a" "${ossl}/lib/libcrypto.a")
    log "[${slice}] merging ${#parts[@]} archives"
    printf '%s\n' "${parts[@]}" | sed "s#^${HOME}#~#" > "${IOS_LOGS}/archives-${slice}.txt"
    mkdir -p "$out/include"
    rm -f "$out/${IOS_LIB_NAME}"
    libtool -static -no_warning_for_no_symbols -o "$out/${IOS_LIB_NAME}" "${parts[@]}" 2> "${IOS_LOGS}/libtool-${slice}.log" \
        || { tail -20 "${IOS_LOGS}/libtool-${slice}.log"; die "[${slice}] libtool failed"; }
    # Debug info and local symbols are not needed to link; the C API stays global.
    strip -S -x "$out/${IOS_LIB_NAME}" 2> "${IOS_LOGS}/strip-${slice}.log" || { tail "${IOS_LOGS}/strip-${slice}.log"; die "strip failed"; }
    install -m 0644 "${IOS_SCRIPTS_DIR}/src/beam_wallet_api.h" "$out/include/beam_wallet_api.h"
    echo "$((t1 - t0))" > "${out}/.build_seconds"
    library_fingerprint > "${out}/.source"
    printf '%s  %s\n' "$(sha256_of "$out/${IOS_LIB_NAME}")" "${slice}/${IOS_LIB_NAME}" >&2
    if [[ "${KEEP_BUILD:-0}" != "1" ]]; then rm -rf "$bdir"; log "[${slice}] removed ${bdir}"; fi
}

for slice in "${slices[@]}"; do build_slice "$slice"; done

# ---- XCFramework --------------------------------------------------------------------------
xcf_args=() have=()
for slice in "${IOS_SLICES_DEFAULT[@]}"; do
    lib="${OUT_ROOT}/${slice}/${IOS_LIB_NAME}"
    if [[ -f "$lib" ]]; then
        xcf_args+=(-library "$lib" -headers "${OUT_ROOT}/${slice}/include")
        have+=("$slice")
    fi
done
rm -rf "${IOS_XCF_OUT:?}" && mkdir -p "$IOS_XCF_OUT"
xcodebuild -create-xcframework "${xcf_args[@]}" -output "${IOS_XCF_OUT}/${IOS_XCFRAMEWORK_NAME}" >/dev/null \
    || die "xcodebuild -create-xcframework failed"
(
    cd "$OUT_ROOT"
    for slice in "${have[@]}"; do printf '%s  %s\n' "$(sha256_of "${slice}/${IOS_LIB_NAME}")" "${slice}/${IOS_LIB_NAME}"; done
) > "${IOS_XCF_OUT}/SHA256SUMS"
library_fingerprint > "${IOS_XCF_OUT}/.source"
log "XCFramework with ${have[*]}: ${IOS_XCF_OUT}/${IOS_XCFRAMEWORK_NAME}"
[[ ${#have[@]} -eq 2 ]] || log "WARNING: only ${have[*]} built; the app needs both slices for a device and a simulator build"

for slice in "${slices[@]}"; do
    "${IOS_SCRIPTS_DIR}/verify_ios.sh" "$slice" "${OUT_ROOT}/${slice}/${IOS_LIB_NAME}"
done
log "done"
cat "${IOS_XCF_OUT}/SHA256SUMS"
