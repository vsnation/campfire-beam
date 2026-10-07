#!/usr/bin/env bash
# Build BEAM's Android core, wallet-api and beam-wallet, for arm64-v8a and x86_64 from
# tag beam-7.5.14493 with Campfire's core patches (../patches) plus the Android-only
# ones (./patches).
#
#   scripts/beam/core/android/build_deps.sh          # once: static OpenSSL + Boost per ABI
#   scripts/beam/core/android/build_wallet_api.sh    # both targets, both ABIs
#   scripts/beam/core/android/build_wallet_api.sh x86_64
#   TARGETS=wallet-api scripts/beam/core/android/build_wallet_api.sh   # one target
#   scripts/beam/core/android/build_wallet_api.sh --prepare-only   # just the patched source tree
#
# Output, per ABI ($BUILD_ROOT/out/android-arm64/, $BUILD_ROOT/out/android-x86_64/):
#   wallet-api   the wallet core       -> jniLibs/<abi>/libbeam_wallet_api.so in the app
#   beam-wallet  create/restore CLI    -> jniLibs/<abi>/libbeam_wallet.so
# Both are stripped PIE executables. Each gets .<target>.source (commit + patch series)
# and .<target>.build_seconds, and must pass verify_android.sh for its own checks.
#
# Source tree: a PRIVATE clone at $BUILD_ROOT/android/src. It is never the shared
# desktop tree ($BUILD_ROOT/beam) and never ~/beam: it is cloned from the shared tree
# when that exists (local, no network; full history, so the version is 7.5.14493),
# otherwise from $BEAM_REPO_URL. A tree that is not exactly "pinned commit + this
# patch series" is thrown away and cloned again.
#
# Env: TARGETS (default "wallet-api beam-wallet"), JOBS (default 8), ANDROID_SDK_ROOT,
#      ANDROID_NDK, BEAM_CORE_BUILD_ROOT, CLEAN_BUILD=1 to delete each ABI's CMake tree
#      after its binaries are collected.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need_cmd git; need_cmd patch
check_toolchain

prepare_only=0
abis=()
for a in "$@"; do
    case "$a" in
        --prepare-only) prepare_only=1 ;;
        *) abis+=("$(abi_normalize "$a")") ;;
    esac
done
[[ ${#abis[@]} -gt 0 ]] || abis=("${ANDROID_ABIS_DEFAULT[@]}")

# CMake target -> path of the built executable in the build tree. beam-node is never
# built: phones use public nodes.
target_path() {
    case "$1" in
        wallet-api)  echo "wallet/api/wallet-api" ;;
        beam-wallet) echo "wallet/cli/beam-wallet" ;;
        *) die "unknown target '$1' (use wallet-api and/or beam-wallet)" ;;
    esac
}
read -r -a targets <<< "${TARGETS:-wallet-api beam-wallet}"
[[ ${#targets[@]} -gt 0 ]] || die "TARGETS is empty"
for tg in "${targets[@]}"; do target_path "$tg" >/dev/null; done
mkdir -p "$ANDROID_ROOT" "$ANDROID_LOGS"

# ---- source ---------------------------------------------------------------------------
SRC_STAMP="${ANDROID_ROOT}/.src_stamp"
PATCHSET="${ANDROID_ROOT}/patchset"     # snapshot of the series this tree was patched with

snapshot_patchset() {
    rm -rf "$PATCHSET" && mkdir -p "$PATCHSET"
    local p
    while IFS= read -r p; do cp "$p" "$PATCHSET/"; done < <(patch_series)
}

verify_pinned_checkout() {
    local head; head="$(git -C "$ANDROID_SRC" rev-parse HEAD)"
    [[ "$head" == "$BEAM_COMMIT" ]] || die "android/src HEAD is $head, expected $BEAM_COMMIT"
    local tagc; tagc="$(git -C "$ANDROID_SRC" rev-parse "${BEAM_TAG}^{commit}")"
    [[ "$tagc" == "$BEAM_COMMIT" ]] || die "tag $BEAM_TAG is $tagc, expected $BEAM_COMMIT"
    local count; count="$(git -C "$ANDROID_SRC" rev-list HEAD --count)"
    [[ "7.5.${count}" == "$BEAM_EXPECTED_VERSION" ]] || die "rev-list count $count gives 7.5.${count} (shallow clone?)"
    local sm rec act
    for sm in "${BEAM_SUBMODULES[@]}"; do
        rec="$(git -C "$ANDROID_SRC" ls-tree HEAD "$sm" | awk '{print $3}')"
        act="$(git -C "$ANDROID_SRC/$sm" rev-parse HEAD)"
        [[ "$rec" == "$act" ]] || die "submodule $sm is at $act, the commit pins $rec"
    done
}

fresh_source() {
    log "creating private BEAM tree at ${ANDROID_SRC}"
    rm -rf "$ANDROID_SRC" "$SRC_STAMP"
    local origin="$BEAM_REPO_URL"
    if [[ -d "${BEAM_SRC}/.git" && "$(git -C "$BEAM_SRC" rev-parse --is-shallow-repository)" == "false" ]]; then
        origin="$BEAM_SRC"            # the desktop builds' full clone: local, no network
    fi
    log "cloning from ${origin}"
    git clone -q --no-hardlinks --no-checkout "$origin" "$ANDROID_SRC"
    git -C "$ANDROID_SRC" -c advice.detachedHead=false checkout -q "$BEAM_COMMIT"
    local sm
    for sm in "${BEAM_SUBMODULES[@]}"; do
        git -C "$ANDROID_SRC" submodule init "$sm" >/dev/null
        if [[ -d "${BEAM_SRC}/${sm}" ]] && git -C "${BEAM_SRC}/${sm}" rev-parse HEAD >/dev/null 2>&1; then
            git -C "$ANDROID_SRC" config "submodule.${sm}.url" "${BEAM_SRC}/${sm}"
        fi
    done
    git -C "$ANDROID_SRC" -c protocol.file.allow=always submodule update -q "${BEAM_SUBMODULES[@]}"
    verify_pinned_checkout
    [[ -z "$(git -C "$ANDROID_SRC" status --porcelain --untracked-files=all)" ]] || die "fresh clone is not clean"
    snapshot_patchset
    local p
    for p in "$PATCHSET"/*.patch; do
        (cd "$ANDROID_SRC" && patch -p1 --forward -s < "$p") || die "patch failed: $(basename "$p")"
        log "applied $(basename "$p")"
    done
    source_fingerprint > "$SRC_STAMP"
}

source_is_reusable() {
    [[ -d "${ANDROID_SRC}/.git" && -f "$SRC_STAMP" ]] || return 1
    [[ "$(cat "$SRC_STAMP")" == "$(source_fingerprint)" ]] || { log "patch series or commit changed"; return 1; }
    (verify_pinned_checkout) >/dev/null 2>&1 || { log "android/src is not at the pinned commit"; return 1; }
    if declare -F check_source_tree >/dev/null; then
        # common.sh: every changed path must be a version our patches produce.
        local bad
        if ! bad="$(check_source_tree "$ANDROID_SRC" "$PATCHSET" "${BEAM_SUBMODULES[@]}")"; then
            log "android/src differs from commit + patches:"; printf '%s\n' "$bad" | sed 's/^/    /' >&2
            return 1
        fi
    fi
    # And the WHOLE series must be applied (check_source_tree also accepts a prefix
    # of it): un-apply it in reverse order on a copy of the touched files.
    local p path rev=() tmp; tmp="$(mktemp -d)"
    for p in "$PATCHSET"/*.patch; do rev=("$p" ${rev[@]+"${rev[@]}"}); done
    while IFS= read -r path; do
        [[ -n "$path" && -f "${ANDROID_SRC}/${path}" ]] || continue
        mkdir -p "${tmp}/$(dirname "$path")" && cp "${ANDROID_SRC}/${path}" "${tmp}/${path}"
    done < <(sed -n 's#^+++ b/\([^[:space:]]*\).*#\1#p' "$PATCHSET"/*.patch | sort -u)
    for p in "${rev[@]}"; do
        (cd "$tmp" && patch -p1 -R -s -f < "$p" >/dev/null 2>&1) || { rm -rf "$tmp"; log "$(basename "$p") is not applied"; return 1; }
    done
    rm -rf "$tmp"
    return 0
}

if source_is_reusable; then
    log "reusing ${ANDROID_SRC} ($(wc -l < "$SRC_STAMP" | tr -d ' ') pins match)"
else
    fresh_source
fi
log "source: ${BEAM_TAG} ${BEAM_COMMIT}; series:"
sed 's/^/    /' "$SRC_STAMP" >&2
[[ "$prepare_only" == "1" ]] && { log "prepared ${ANDROID_SRC}"; exit 0; }

# ---- build ------------------------------------------------------------------------------
BRANCH_LABEL="${BEAM_TAG}-campfire"

build_abi() {
    local abi="$1" plat; plat="$(abi_platform "$abi")"
    local deps="${ANDROID_DEPS}/${abi}" bdir="${ANDROID_BUILD}/${abi}" out="${OUT_ROOT}/${plat}"
    local log_cfg="${ANDROID_LOGS}/beam-configure-${abi}.log"
    [[ -f "${deps}/.stamp" ]] || die "no dependencies for ${abi}: run build_deps.sh ${abi} first"
    local boost="${deps}/boost" ossl="${deps}/openssl"

    # BEAM's Android path makes imported targets for exactly its Boost components,
    # without their link dependencies; add every other Boost archive we built
    # (atomic, chrono, container, charconv, ...) to the link. lld resolves archives
    # independent of their position on the command line.
    local extra=() f c skip
    for f in "${boost}/libs/${abi}"/libboost_*.a; do
        c="$(basename "$f" .a)"; c="${c#libboost_}"; skip=0
        case " filesystem program_options thread regex log locale date_time context coroutine " in
            *" $c "*) skip=1 ;;
        esac
        [[ "$skip" == "1" ]] || extra+=("$f")
    done

    local cmake_args=(
        -G Ninja -DCMAKE_MAKE_PROGRAM="$ANDROID_NINJA"
        -S "$ANDROID_SRC" -B "$bdir"
        -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK}/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI="$abi"
        -DANDROID_PLATFORM="android-${ANDROID_API}"
        -DANDROID_STL=c++_static                    # no libc++_shared.so to ship
        -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON    # 16 KB LOAD alignment (Android 15+ devices)
        -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=OFF
        -DBEAM_LINK_TYPE=Static
        -DBEAM_ANDROID_EXECUTABLES=ON               # patches/0005: build the executables, not only the JNI lib
        -DBEAM_NO_QT_UI_WALLET=ON
        -DBEAM_IPFS_SUPPORT=OFF
        -DBEAM_LASER_SUPPORT=OFF
        -DBEAM_TESTS_ENABLED=OFF
        -DBEAM_HW_WALLET=OFF
        -DBEAM_ATOMIC_SWAP_SUPPORT=OFF              # BEAM forces both swaps off on Android anyway
        -DBEAM_ASSET_SWAP_SUPPORT=OFF
        -DBRANCH_NAME="$BRANCH_LABEL"
        -DBEAM_RECORDED_SOURCE_DIR="$PREFIX_MAP_SRC"   # patches/0005: matches -ffile-prefix-map
        "-DCMAKE_C_FLAGS=$(prefix_map_flags)"
        "-DCMAKE_CXX_FLAGS=$(prefix_map_flags)"
        "-DCMAKE_EXE_LINKER_FLAGS=${extra[*]}"
        -DOPENSSL_USE_STATIC_LIBS=TRUE
        -DOPENSSL_ROOT_DIR="$ossl"
        -DOPENSSL_INCLUDE_DIR="${ossl}/include"
        -DOPENSSL_CRYPTO_LIBRARY="${ossl}/lib/libcrypto.a"
        -DOPENSSL_SSL_LIBRARY="${ossl}/lib/libssl.a"
    )
    log "[${abi}] configuring (log: ${log_cfg})"
    mkdir -p "$bdir"
    BOOST_ROOT_ANDROID="$boost" offline "$ANDROID_CMAKE" "${cmake_args[@]}" > "$log_cfg" 2>&1 \
        || { tail -60 "$log_cfg"; die "[${abi}] configure failed"; }
    check_cmake_version "$bdir"
    grep -E '^(BEAM_BRANCH_NAME|OPENSSL_CRYPTO_LIBRARY|OPENSSL_SSL_LIBRARY|ANDROID_ABI|ANDROID_PLATFORM)[:=]' "${bdir}/CMakeCache.txt" >&2 || true

    mkdir -p "$out"
    # Metadata of the single-target layout (one .source/.build_seconds for wallet-api).
    rm -f "${out}/.source" "${out}/.build_seconds"
    local tg log_build t0 t1
    for tg in "${targets[@]}"; do
        log_build="${ANDROID_LOGS}/beam-build-${tg}-${abi}.log"
        log "[${abi}] building ${tg} with -j${JOBS} (log: ${log_build})"
        t0=$(date +%s)
        BOOST_ROOT_ANDROID="$boost" offline "$ANDROID_CMAKE" --build "$bdir" --target "$tg" -j"$JOBS" > "$log_build" 2>&1 \
            || { grep -nE 'error:|undefined' "$log_build" | head -40; tail -30 "$log_build"; die "[${abi}] ${tg} build failed"; }
        t1=$(date +%s)
        log "[${abi}] ${tg} built in $((t1 - t0)) s"

        "${NDK_TC}/bin/llvm-strip" --strip-all -o "${out}/${tg}" "${bdir}/$(target_path "$tg")"
        chmod 0755 "${out}/${tg}"
        echo "$((t1 - t0))" > "${out}/.${tg}.build_seconds"
        source_fingerprint > "${out}/.${tg}.source"
        # A failed check fails the build (set -e).
        "${ANDROID_SCRIPTS_DIR}/verify_android.sh" "$abi" "${out}/${tg}" "$tg"
    done
    if [[ "${CLEAN_BUILD:-0}" == "1" ]]; then rm -rf "$bdir"; log "[${abi}] removed ${bdir}"; fi
}

for abi in "${abis[@]}"; do build_abi "$abi"; done
log "done"
for abi in "${abis[@]}"; do
    for tg in "${targets[@]}"; do
        f="${OUT_ROOT}/$(abi_platform "$abi")/${tg}"
        printf '%s  %s  %s bytes\n' "$(sha256_of "$f")" "$f" "$(wc -c < "$f" | tr -d ' ')"
    done
done
