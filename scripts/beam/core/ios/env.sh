#!/usr/bin/env bash
# Shared settings for building BEAM's wallet-api as an in-process library for iOS
# (see README.md here). Sourced by build_deps.sh, build_wallet_api.sh,
# verify_ios.sh and stage_ios.sh.
#
# The BEAM tag/commit, the Boost and OpenSSL tarballs with their SHA-256 pins and
# the core patch series all come from ../common.sh, so the iOS library is built
# from exactly the same inputs as the desktop and Android binaries. Only the iOS
# toolchain settings live here.

IOS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "${IOS_SCRIPTS_DIR}/../common.sh"

# ---- toolchain -----------------------------------------------------------------
# Built and verified with Xcode 27.0 (27A266a), iOS SDK 27.0. Another Xcode is
# allowed (the output is then not the pinned one; verify_ios.sh says so).
IOS_XCODE_EXPECTED="Xcode 27.0 27A266a"
# Campfire's iOS floor (ios/Podfile `platform :ios, '15.0'`, Runner
# IPHONEOS_DEPLOYMENT_TARGET).
IOS_MIN="15.0"
IOS_SLICES_DEFAULT=(ios-arm64 ios-arm64-simulator)

# The name of the static library and of the XCFramework that carries it.
IOS_LIB_NAME="libbeam_wallet_api.a"
IOS_XCFRAMEWORK_NAME="BeamWalletApi.xcframework"

# ---- paths -----------------------------------------------------------------------
# Everything lives under $BUILD_ROOT/ios, next to (never inside) the desktop and
# Android trees. Outputs go to $OUT_ROOT/ios-<slice> and $OUT_ROOT/ios-xcframework.
IOS_ROOT="${BUILD_ROOT}/ios"
IOS_SRC="${IOS_ROOT}/src"         # private BEAM clone: pinned commit + core series + ./patches
IOS_DEPS="${IOS_ROOT}/deps"       # installed static OpenSSL / Boost per slice (kept as a cache)
IOS_WORK="${IOS_ROOT}/work"       # extracted dependency sources (deleted after each build)
IOS_BUILD="${IOS_ROOT}/build"     # CMake trees per slice (deleted unless KEEP_BUILD=1)
IOS_LOGS="${IOS_ROOT}/logs"
IOS_XCF_OUT="${OUT_ROOT}/ios-xcframework"

# The prefix OpenSSL is configured with. OpenSSL compiles OPENSSLDIR, ENGINESDIR and
# MODULESDIR into libcrypto; a neutral prefix (installed through DESTDIR) keeps the
# build machine's home directory out of the library. Nothing on a phone lives
# there; wallet-api never loads OpenSSL modules or config.
OPENSSL_NEUTRAL_PREFIX="/opt/campfire-beam/openssl"

# What source paths are rewritten to in __FILE__ (-ffile-prefix-map). The account
# name is part of $HOME and must not end up in a shipped library.
PREFIX_MAP_SRC="/beam"
PREFIX_MAP_DEPS="/deps"
PREFIX_MAP_BUILD="/build"

JOBS="${JOBS:-6}"

# ---- slice tables ------------------------------------------------------------------
slice_normalize() {
    case "$1" in
        ios-arm64|device|iphoneos) echo "ios-arm64" ;;
        ios-arm64-simulator|simulator|sim|iphonesimulator) echo "ios-arm64-simulator" ;;
        *) die "unknown slice '$1' (use ios-arm64 or ios-arm64-simulator)" ;;
    esac
}
slice_sdk() {                # xcrun --sdk
    case "$1" in ios-arm64) echo "iphoneos" ;; ios-arm64-simulator) echo "iphonesimulator" ;; esac
}
slice_triple() {             # clang -target
    case "$1" in
        ios-arm64) echo "arm64-apple-ios${IOS_MIN}" ;;
        ios-arm64-simulator) echo "arm64-apple-ios${IOS_MIN}-simulator" ;;
    esac
}
slice_openssl_target() {
    case "$1" in ios-arm64) echo "ios64-xcrun" ;; ios-arm64-simulator) echo "iossimulator-arm64-xcrun" ;; esac
}
slice_macho_platform() {     # LC_BUILD_VERSION platform number (otool -l)
    case "$1" in ios-arm64) echo "2" ;; ios-arm64-simulator) echo "7" ;; esac
}
slice_sdk_path() { xcrun --sdk "$(slice_sdk "$1")" --show-sdk-path; }

prefix_map_flags() {
    printf '%s ' \
        "-ffile-prefix-map=${IOS_SRC}=${PREFIX_MAP_SRC}" \
        "-ffile-prefix-map=${IOS_DEPS}=${PREFIX_MAP_DEPS}" \
        "-ffile-prefix-map=${IOS_WORK}=${PREFIX_MAP_DEPS}" \
        "-ffile-prefix-map=${IOS_BUILD}=${PREFIX_MAP_BUILD}"
}

# ---- checks ----------------------------------------------------------------------
check_toolchain() {
    [[ "$(uname -s)" == "Darwin" ]] || die "iOS builds need macOS with Xcode"
    need_cmd xcrun; need_cmd xcodebuild; need_cmd cmake; need_cmd libtool; need_cmd lipo
    local x; x="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/Build version //; s/ *$//')"
    if [[ "$x" != "$IOS_XCODE_EXPECTED" ]]; then
        log "WARNING: ${x:-no Xcode}; the pinned library was built with ${IOS_XCODE_EXPECTED}"
    fi
    local s
    for s in iphoneos iphonesimulator; do
        xcrun --sdk "$s" --show-sdk-path >/dev/null 2>&1 || die "no ${s} SDK (install Xcode and its iOS platform)"
    done
    log "${x}; iOS SDK $(xcrun --sdk iphoneos --show-sdk-version), simulator SDK $(xcrun --sdk iphonesimulator --show-sdk-version); $(cmake --version | head -1)"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# ---- network-free execution of untrusted build tooling ------------------------------
# Dependency sources (Boost's bootstrap/b2, OpenSSL's Configure/make) and BEAM's CMake
# run with network access denied. Only fetch_verify (curl of pinned tarballs) and the
# clone of the pinned BEAM commit touch the network. Same profile as the Android build.
SANDBOX_PROFILE='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-inbound)(deny network-bind (local ip))'
offline() { sandbox-exec -p "$SANDBOX_PROFILE" "$@"; }

# ---- patch series ------------------------------------------------------------------
# The core series (../patches, in order, exactly as the desktop and Android builds
# apply it), then the iOS-only patches here (./patches, numbered from 0101 so they
# always sort after the core series). 0101 adds the in-process library target; no
# other build applies it.
IOS_PATCH_DIR="${IOS_SCRIPTS_DIR}/patches"
patch_series() {
    local p
    for p in "${PATCH_DIR}"/*.patch "${IOS_PATCH_DIR}"/*.patch; do
        [[ -f "$p" ]] && echo "$p"
    done
}

# Fingerprint of everything that defines the source tree: commit + patch hashes.
source_fingerprint() {
    echo "commit ${BEAM_COMMIT}"
    local p
    while IFS= read -r p; do echo "$(sha256_of "$p")  $(basename "$p")"; done < <(patch_series)
}
