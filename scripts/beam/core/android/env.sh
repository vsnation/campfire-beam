#!/usr/bin/env bash
# Shared settings for building BEAM's wallet-api for Android (see README.md here).
# Sourced by build_deps.sh, build_wallet_api.sh and verify_android.sh.
#
# The BEAM tag/commit, the Boost and OpenSSL tarballs and their SHA-256 pins, and
# the core patch series all come from ../common.sh, so the Android binaries are
# built from exactly the same inputs as the desktop ones. Only the Android
# toolchain pins and the Android-only patches live here.

ANDROID_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${ANDROID_SCRIPTS_DIR}/../common.sh"

# ---- toolchain pins ------------------------------------------------------------
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
NDK_VERSION="27.2.12479018"                 # r27c
ANDROID_NDK="${ANDROID_NDK:-${ANDROID_SDK_ROOT}/ndk/${NDK_VERSION}}"
ANDROID_CMAKE_VERSION="3.22.1"              # the SDK's CMake (BEAM's 3rdparty is happy with 3.x)
ANDROID_API=24                              # Flutter 3.47's flutter.minSdkVersion
ANDROID_ABIS_DEFAULT=(arm64-v8a x86_64)

case "$(uname -s)" in
    Darwin) NDK_HOST_TAG="darwin-x86_64" ;;   # universal binaries, runs natively on arm64
    Linux)  NDK_HOST_TAG="linux-x86_64" ;;
    *) die "unsupported build host $(uname -s)" ;;
esac
NDK_TC="${ANDROID_NDK}/toolchains/llvm/prebuilt/${NDK_HOST_TAG}"
ANDROID_CMAKE="${ANDROID_SDK_ROOT}/cmake/${ANDROID_CMAKE_VERSION}/bin/cmake"
ANDROID_NINJA="${ANDROID_SDK_ROOT}/cmake/${ANDROID_CMAKE_VERSION}/bin/ninja"

# ---- paths -----------------------------------------------------------------------
# Everything lives under $BUILD_ROOT/android, next to (never inside) the desktop tree.
ANDROID_PATCH_DIR="${ANDROID_SCRIPTS_DIR}/patches"
ANDROID_ROOT="${BUILD_ROOT}/android"
ANDROID_SRC="${ANDROID_ROOT}/src"           # private BEAM clone: pinned commit + core + Android patches
ANDROID_DEPS="${ANDROID_ROOT}/deps"         # installed static OpenSSL / Boost, per ABI (kept as a cache)
ANDROID_WORK="${ANDROID_ROOT}/work"         # extracted dependency sources (deleted after each build)
ANDROID_BUILD="${ANDROID_ROOT}/build"       # CMake trees, per ABI (delete with CLEAN_BUILD=1)
ANDROID_LOGS="${ANDROID_ROOT}/logs"

# The prefix OpenSSL is configured with. OpenSSL compiles OPENSSLDIR, ENGINESDIR and
# MODULESDIR into libcrypto; a neutral prefix (installed through DESTDIR) keeps the
# build machine's home directory out of the shipped binary. Nothing on a phone
# lives at this path; wallet-api never loads OpenSSL modules or config.
OPENSSL_NEUTRAL_PREFIX="/opt/campfire-beam/openssl"

# What source paths are rewritten to in __FILE__ / debug info (-ffile-prefix-map).
# The account name is part of $HOME; it must not end up in a public binary.
PREFIX_MAP_SRC="/beam"
PREFIX_MAP_DEPS="/deps"
PREFIX_MAP_NDK="/ndk"
PREFIX_MAP_BUILD="/build"

JOBS="${JOBS:-8}"

# ---- ABI tables ------------------------------------------------------------------
abi_normalize() {
    case "$1" in
        arm64-v8a|arm64|aarch64) echo "arm64-v8a" ;;
        x86_64|x64|amd64)        echo "x86_64" ;;
        *) die "unknown ABI '$1' (use arm64-v8a or x86_64)" ;;
    esac
}
abi_platform() {             # out/ dir and manifest key
    case "$1" in arm64-v8a) echo "android-arm64" ;; x86_64) echo "android-x86_64" ;; esac
}
abi_triple() {
    case "$1" in arm64-v8a) echo "aarch64-linux-android" ;; x86_64) echo "x86_64-linux-android" ;; esac
}
abi_openssl_target() {
    case "$1" in arm64-v8a) echo "android-arm64" ;; x86_64) echo "android-x86_64" ;; esac
}
abi_b2_props() {             # Boost.Context picks its assembly from these
    case "$1" in
        arm64-v8a) echo "architecture=arm address-model=64 abi=aapcs binary-format=elf" ;;
        x86_64)    echo "architecture=x86 address-model=64 abi=sysv binary-format=elf" ;;
    esac
}
abi_elf_machine() {          # readelf -h "Machine:"
    case "$1" in arm64-v8a) echo "AArch64" ;; x86_64) echo "Advanced Micro Devices X86-64" ;; esac
}

prefix_map_flags() {
    printf '%s ' \
        "-ffile-prefix-map=${ANDROID_SRC}=${PREFIX_MAP_SRC}" \
        "-ffile-prefix-map=${ANDROID_DEPS}=${PREFIX_MAP_DEPS}" \
        "-ffile-prefix-map=${ANDROID_WORK}=${PREFIX_MAP_DEPS}" \
        "-ffile-prefix-map=${ANDROID_BUILD}=${PREFIX_MAP_BUILD}" \
        "-ffile-prefix-map=${ANDROID_NDK}=${PREFIX_MAP_NDK}"
}

# ---- checks ----------------------------------------------------------------------
check_toolchain() {
    [[ -f "${ANDROID_NDK}/source.properties" ]] || die "NDK not found at ${ANDROID_NDK} (install ndk;${NDK_VERSION} with sdkmanager)"
    local rev; rev="$(sed -n 's/^Pkg.Revision *= *//p' "${ANDROID_NDK}/source.properties" | tr -d '\r')"
    [[ "$rev" == "$NDK_VERSION" ]] || die "NDK at ${ANDROID_NDK} is ${rev}, expected ${NDK_VERSION}"
    [[ -x "${NDK_TC}/bin/clang++" ]] || die "no clang++ in ${NDK_TC}/bin"
    [[ -x "$ANDROID_CMAKE" ]] || die "CMake ${ANDROID_CMAKE_VERSION} not found at ${ANDROID_CMAKE} (install cmake;${ANDROID_CMAKE_VERSION} with sdkmanager)"
    [[ -x "$ANDROID_NINJA" ]] || die "ninja not found at ${ANDROID_NINJA}"
    log "NDK ${rev}: $("${NDK_TC}/bin/clang" --version | head -1)"
    log "CMake: $("$ANDROID_CMAKE" --version | head -1), ninja $("$ANDROID_NINJA" --version)"
}

# ---- network-free execution of untrusted build tooling ------------------------------
# Dependency sources (Boost's bootstrap/b2, OpenSSL's Configure/make) and BEAM's CMake
# run with network access denied. Only fetch_verify (curl of pinned tarballs) and the
# git clone of the pinned BEAM commit touch the network.
SANDBOX_PROFILE='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound)(deny network-bind (local ip))'
offline() {
    case "$(uname -s)" in
        Darwin) sandbox-exec -p "$SANDBOX_PROFILE" "$@" ;;
        Linux)
            if unshare -rn true 2>/dev/null; then unshare -rn "$@"
            else log "WARNING: cannot drop network (unshare -rn not permitted); running $1 with network"; "$@"; fi ;;
    esac
}

# ---- patch series ------------------------------------------------------------------
# The core patches (../patches, in order) followed by the Android ones (./patches).
# Printed one path per line, in application order.
patch_series() {
    local p
    for p in "${PATCH_DIR}"/*.patch "${ANDROID_PATCH_DIR}"/*.patch; do
        [[ -f "$p" ]] && echo "$p"
    done
}

# Fingerprint of everything that defines the source tree: commit + patch hashes.
source_fingerprint() {
    echo "commit ${BEAM_COMMIT}"
    local p
    while IFS= read -r p; do echo "$(sha256_of "$p")  $(basename "$p")"; done < <(patch_series)
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
