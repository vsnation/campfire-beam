#!/usr/bin/env bash
# Shared settings for libbeam_core, the BEAM core as ONE shared library that runs
# inside the app (wallet-api + the integrated node; see src/beam_core.h). Sourced by
# build_lib_macos.sh, build_lib_android.sh, build_lib_linux.sh, build_lib_windows.sh
# and verify_lib.sh.
#
# Pins (BEAM tag + commit, Boost, OpenSSL with their SHA-256) and the core patch
# series come from ../common.sh, so the library is built from exactly the inputs of
# the shipped executables. On top of the core series (../patches, in order) this
# applies ./patches, numbered from 0201 so they always sort after it:
#   0201 wallet-api: --proxy/--proxy_addr (SOCKS5, fail closed)       [core-series candidate]
#   0202 beam::Node: outbound peers through Config::m_ProxyAddr        [core-series candidate]
#   0203 beam::Node: get_PeerStats() for the status snapshot           [library only]
#   0204 CMake: the beam_core SHARED target                            [library only]
#   0205 WalletDB: close a database that fails to open (wrong password) [core-series candidate]
#
# The build never edits the shared desktop tree ($BUILD_ROOT/beam). It works in a
# private clone at $BUILD_ROOT/lib/src, taken from that tree (local, no network).

LIB_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${LIB_SCRIPTS_DIR}/../common.sh"

LIB_PATCH_DIR="${LIB_SCRIPTS_DIR}/patches"
LIB_ROOT="${BUILD_ROOT}/lib"
LIB_SRC="${LIB_ROOT}/src"          # private clone: pinned commit + core series + ./patches
LIB_LOGS="${LIB_ROOT}/logs"
LIB_SRC_STAMP="${LIB_ROOT}/.src_stamp"
LIB_PATCHSET="${LIB_ROOT}/patchset" # snapshot of the series the tree was patched with

# The library's own sources (src/), copied into each CMake tree before configuring
# so that __FILE__ records them under the neutral /build prefix.
LIB_SOURCES=(beam_core_wallet_api.cpp beam_core_node.cpp beam_core_log.cpp)
LIB_HEADERS=(beam_core.h beam_core_internal.h beam_core_thread.h)

# Neutral prefixes for -ffile-prefix-map: the account name is part of $HOME and
# must not end up in a public binary.
PREFIX_MAP_SRC="/beam"
PREFIX_MAP_DEPS="/deps"
PREFIX_MAP_BUILD="/build"

# BEAM configuration shared by every platform. Atomic swap and the asset-swap
# board are off, as in the iOS and Android cores: Campfire uses neither, and the
# C interface is the same everywhere.
LIB_BEAM_OPTIONS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DBUILD_SHARED_LIBS=OFF
    -DBEAM_LINK_TYPE=Static
    -DBEAM_NO_QT_UI_WALLET=ON
    -DBEAM_IPFS_SUPPORT=OFF
    -DBEAM_LASER_SUPPORT=OFF
    -DBEAM_TESTS_ENABLED=OFF
    -DBEAM_HW_WALLET=OFF
    -DBEAM_ATOMIC_SWAP_SUPPORT=OFF
    -DBEAM_ASSET_SWAP_SUPPORT=OFF
    -DBEAM_CORE_LIBRARY=ON
    -DBRANCH_NAME="${BEAM_TAG}-campfire"
    -DBEAM_RECORDED_SOURCE_DIR="$PREFIX_MAP_SRC"
)

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# ---- network-free execution of untrusted build tooling ----------------------------
# BEAM's CMake configure and build run with the network denied (as the iOS and
# Android builds do). Only the clone of the pinned commit touches the network, and
# only when no local full clone exists.
SANDBOX_PROFILE='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound)(deny network-bind (local ip))'
offline() {
    case "$(uname -s)" in
        Darwin) sandbox-exec -p "$SANDBOX_PROFILE" "$@" ;;
        Linux)
            if unshare -rn true 2>/dev/null; then unshare -rn "$@"
            else log "WARNING: cannot drop network (unshare -rn not permitted); running $1 with network"; "$@"; fi ;;
        *) "$@" ;;
    esac
}

# ---- patch series -------------------------------------------------------------------
lib_patch_series() {
    local p
    for p in "${PATCH_DIR}"/*.patch "${LIB_PATCH_DIR}"/*.patch; do
        [[ -f "$p" ]] && echo "$p"
    done
}

# Everything that defines the source tree: commit + patch hashes.
lib_source_fingerprint() {
    echo "commit ${BEAM_COMMIT}"
    local p
    while IFS= read -r p; do echo "$(sha256_of "$p")  $(basename "$p")"; done < <(lib_patch_series)
}

# Everything a library was built from: the tree, the library sources, the toolchain.
lib_fingerprint() {
    lib_source_fingerprint
    local f
    for f in "${LIB_SOURCES[@]}" "${LIB_HEADERS[@]}" exports.txt; do
        echo "$(sha256_of "${LIB_SCRIPTS_DIR}/src/${f}")  src/${f}"
    done
    echo "toolchain: $1"
}

lib_verify_checkout() {
    local head; head="$(git -C "$LIB_SRC" rev-parse HEAD)"
    [[ "$head" == "$BEAM_COMMIT" ]] || die "lib/src HEAD is $head, expected $BEAM_COMMIT"
    local tagc; tagc="$(git -C "$LIB_SRC" rev-parse "${BEAM_TAG}^{commit}")"
    [[ "$tagc" == "$BEAM_COMMIT" ]] || die "tag $BEAM_TAG is $tagc, expected $BEAM_COMMIT"
    local count; count="$(git -C "$LIB_SRC" rev-list HEAD --count)"
    [[ "7.5.${count}" == "$BEAM_EXPECTED_VERSION" ]] || die "rev-list count $count gives 7.5.${count} (shallow clone?)"
    local sm rec act
    for sm in "${BEAM_SUBMODULES[@]}"; do
        rec="$(git -C "$LIB_SRC" ls-tree HEAD "$sm" | awk '{print $3}')"
        act="$(git -C "$LIB_SRC/$sm" rev-parse HEAD)"
        [[ "$rec" == "$act" ]] || die "submodule $sm is at $act, the commit pins $rec"
    done
}

lib_fresh_source() {
    log "creating private BEAM tree at ${LIB_SRC}"
    rm -rf "$LIB_SRC" "$LIB_SRC_STAMP"
    mkdir -p "$LIB_ROOT"
    local origin="$BEAM_REPO_URL"
    if [[ -d "${BEAM_SRC}/.git" && "$(git -C "$BEAM_SRC" rev-parse --is-shallow-repository)" == "false" ]]; then
        origin="$BEAM_SRC"            # the desktop builds' full clone: local, no network
    fi
    log "cloning from ${origin/#$HOME/~}"
    git clone -q --no-checkout "$origin" "$LIB_SRC"
    git -C "$LIB_SRC" -c advice.detachedHead=false checkout -q "$BEAM_COMMIT"
    local sm
    for sm in "${BEAM_SUBMODULES[@]}"; do
        git -C "$LIB_SRC" submodule init "$sm" >/dev/null
        if [[ -d "${BEAM_SRC}/${sm}" ]] && git -C "${BEAM_SRC}/${sm}" rev-parse HEAD >/dev/null 2>&1; then
            git -C "$LIB_SRC" config "submodule.${sm}.url" "${BEAM_SRC}/${sm}"
        fi
    done
    git -C "$LIB_SRC" -c protocol.file.allow=always submodule update -q "${BEAM_SUBMODULES[@]}"
    lib_verify_checkout
    [[ -z "$(git -C "$LIB_SRC" status --porcelain --untracked-files=all)" ]] || die "fresh clone is not clean"
    rm -rf "$LIB_PATCHSET" && mkdir -p "$LIB_PATCHSET"
    local p
    while IFS= read -r p; do cp "$p" "$LIB_PATCHSET/"; done < <(lib_patch_series)
    for p in "$LIB_PATCHSET"/*.patch; do
        (cd "$LIB_SRC" && patch -p1 --forward -s < "$p") || die "patch failed: $(basename "$p")"
        log "applied $(basename "$p")"
    done
    lib_source_fingerprint > "$LIB_SRC_STAMP"
}

lib_source_is_reusable() {
    [[ -d "${LIB_SRC}/.git" && -f "$LIB_SRC_STAMP" ]] || return 1
    [[ "$(cat "$LIB_SRC_STAMP")" == "$(lib_source_fingerprint)" ]] || { log "patch series or commit changed"; return 1; }
    (lib_verify_checkout) >/dev/null 2>&1 || { log "lib/src is not at the pinned commit"; return 1; }
    local bad
    if ! bad="$(check_source_tree "$LIB_SRC" "$LIB_PATCHSET" "${BEAM_SUBMODULES[@]}")"; then
        log "lib/src differs from commit + patches:"; printf '%s\n' "$bad" | sed 's/^/    /' >&2
        return 1
    fi
    # check_source_tree also accepts a prefix of the series: the WHOLE series must
    # un-apply, in reverse order, on a copy of the touched files.
    local p path rev=() tmp; tmp="$(mktemp -d)"
    for p in "$LIB_PATCHSET"/*.patch; do rev=("$p" ${rev[@]+"${rev[@]}"}); done
    while IFS= read -r path; do
        [[ -n "$path" && -f "${LIB_SRC}/${path}" ]] || continue
        mkdir -p "${tmp}/$(dirname "$path")" && cp "${LIB_SRC}/${path}" "${tmp}/${path}"
    done < <(sed -n 's#^+++ b/\([^[:space:]]*\).*#\1#p' "$LIB_PATCHSET"/*.patch | sort -u)
    for p in "${rev[@]}"; do
        (cd "$tmp" && patch -p1 -R -s -f < "$p" >/dev/null 2>&1) || { rm -rf "$tmp"; log "$(basename "$p") is not applied"; return 1; }
    done
    rm -rf "$tmp"
    return 0
}

lib_prepare_source() {
    if lib_source_is_reusable; then
        log "reusing ${LIB_SRC/#$HOME/~} ($(wc -l < "$LIB_SRC_STAMP" | tr -d ' ') pins match)"
    else
        lib_fresh_source
    fi
    grep -q 'BEAM_CORE_LIBRARY' "${LIB_SRC}/wallet/api/CMakeLists.txt" || die "the series lacks 0204 (BEAM_CORE_LIBRARY)"
    log "source: ${BEAM_TAG} ${BEAM_COMMIT}; series:"
    sed 's/^/    /' "$LIB_SRC_STAMP" >&2
}

# lib_stage_sources <cmake build dir>: the library sources into <dir>/campfire, and
# the CMake list of them on stdout.
lib_stage_sources() {
    local dir="$1/campfire" f list=""
    mkdir -p "$dir"
    for f in "${LIB_SOURCES[@]}" "${LIB_HEADERS[@]}" exports.txt; do
        install -m 0644 "${LIB_SCRIPTS_DIR}/src/${f}" "${dir}/${f}"
    done
    for f in "${LIB_SOURCES[@]}"; do list="${list:+${list};}${dir}/${f}"; done
    printf '%s' "$list"
}

# Export lists generated from src/exports.txt (one C symbol per line).
lib_exports_macho() { sed -e '/^$/d' -e 's/^/_/' "$1"; }
lib_exports_elf() {
    echo "{"
    echo "  global:"
    sed -e '/^$/d' -e 's/^/    /' -e 's/$/;/' "$1"
    echo "  local: *;"
    echo "};"
}
