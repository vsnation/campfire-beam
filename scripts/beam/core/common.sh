#!/usr/bin/env bash
# Shared constants and helpers for building the BEAM binaries Campfire ships.
# Sourced by build_macos.sh and build_linux.sh. See the project notes.
#
# Everything is pinned: the BEAM tag AND its commit, and the SHA-256 of every
# third-party source tarball. A mismatch stops the build.

# ---- pins ------------------------------------------------------------------
BEAM_REPO_URL="https://github.com/BeamMW/beam.git"
BEAM_TAG="beam-7.5.14493"
BEAM_COMMIT="9c4366aae08e7fbde7bc8d65f828a0deace68bfc"
BEAM_EXPECTED_VERSION="7.5.14493"          # 7.5.<git rev-list --count HEAD>
BEAM_SUBMODULES=(3rdparty/secp256k1 3rdparty/re2)

BOOST_VERSION="1.90.0"
BOOST_TARBALL="boost_1_90_0.tar.bz2"
BOOST_URL="https://archives.boost.io/release/1.90.0/source/${BOOST_TARBALL}"
BOOST_SHA256="49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305"
# What BEAM's find_package asks for, plus their link-time dependencies.
BOOST_LIBS=(filesystem program_options thread regex log locale date_time context coroutine chrono atomic container charconv)

OPENSSL_VERSION="3.5.9"                    # LTS branch
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_TARBALL}"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"

BEAM_TARGETS=(wallet-api beam-node beam-wallet)

# ---- paths -----------------------------------------------------------------
CORE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${CORE_SCRIPTS_DIR}/patches"
# The build tree lives OUTSIDE any repository.
BUILD_ROOT="${BEAM_CORE_BUILD_ROOT:-$HOME/Desktop/Beam/beam-core-build}"
BEAM_SRC="${BUILD_ROOT}/beam"
DL_DIR="${BUILD_ROOT}/deps/dl"
OUT_ROOT="${BUILD_ROOT}/out"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# fetch_verify <url> <dest> <sha256>
fetch_verify() {
    local url="$1" dest="$2" want="$3"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -f "$dest" ]]; then
        log "downloading $(basename "$dest")"
        curl -fsSL --retry 3 -o "${dest}.part" "$url"
        mv "${dest}.part" "$dest"
    fi
    local got; got="$(sha256_of "$dest")"
    [[ "$got" == "$want" ]] || die "sha256 mismatch for $dest: got $got want $want"
    log "verified $(basename "$dest") $got"
}

fetch_deps() {
    fetch_verify "$BOOST_URL" "${DL_DIR}/${BOOST_TARBALL}" "$BOOST_SHA256"
    fetch_verify "$OPENSSL_URL" "${DL_DIR}/${OPENSSL_TARBALL}" "$OPENSSL_SHA256"
}

# Clone with FULL history (the version revision is `git rev-list --count HEAD`;
# a shallow clone yields 7.5.1), check out the pinned tag, verify the commit,
# init the two submodules this configuration needs, apply our patches once.
prepare_source() {
    if [[ ! -d "${BEAM_SRC}/.git" ]]; then
        log "cloning ${BEAM_REPO_URL} (full history)"
        git clone "$BEAM_REPO_URL" "$BEAM_SRC"
    fi
    if [[ "$(git -C "$BEAM_SRC" rev-parse --is-shallow-repository)" == "true" ]]; then
        log "unshallowing clone"
        git -C "$BEAM_SRC" fetch --unshallow --tags
    fi
    git -C "$BEAM_SRC" fetch --tags -q || true
    local head; head="$(git -C "$BEAM_SRC" rev-parse HEAD)"
    if [[ "$head" != "$BEAM_COMMIT" ]]; then
        # Only move HEAD on a clean tree; never discard edits silently.
        [[ -z "$(git -C "$BEAM_SRC" status --porcelain --ignore-submodules=all)" ]] \
            || die "$BEAM_SRC has local changes and HEAD is $head, not $BEAM_COMMIT"
        git -C "$BEAM_SRC" checkout -q "$BEAM_TAG"
    fi
    local tagc; tagc="$(git -C "$BEAM_SRC" rev-parse "${BEAM_TAG}^{commit}")"
    [[ "$tagc" == "$BEAM_COMMIT" ]] || die "tag $BEAM_TAG is $tagc, expected $BEAM_COMMIT"
    [[ "$(git -C "$BEAM_SRC" rev-parse HEAD)" == "$BEAM_COMMIT" ]] || die "HEAD is not $BEAM_COMMIT"
    local count; count="$(git -C "$BEAM_SRC" rev-list HEAD --count)"
    [[ "7.5.${count}" == "$BEAM_EXPECTED_VERSION" ]] || die "rev-list count $count gives 7.5.${count}, expected $BEAM_EXPECTED_VERSION"
    git -C "$BEAM_SRC" submodule update --init "${BEAM_SUBMODULES[@]}"
    apply_patches
}

apply_patches() {
    local p
    for p in "${PATCH_DIR}"/*.patch; do
        if (cd "$BEAM_SRC" && patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1); then
            log "patch already applied: $(basename "$p")"
        else
            (cd "$BEAM_SRC" && patch -p1 --forward -s < "$p") || die "patch failed: $(basename "$p")"
            log "applied $(basename "$p")"
        fi
    done
}

# check_cmake_version <build dir>: the configured version must be the release one.
check_cmake_version() {
    local v; v="$(grep '^BEAM_VERSION:INTERNAL=' "$1/CMakeCache.txt" | cut -d= -f2)"
    [[ "$v" == "$BEAM_EXPECTED_VERSION" ]] || die "CMake configured BEAM_VERSION=$v, expected $BEAM_EXPECTED_VERSION (shallow clone or git unusable?)"
    log "CMake BEAM_VERSION=$v"
}
