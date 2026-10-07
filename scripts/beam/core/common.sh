#!/usr/bin/env bash
# Shared constants and helpers for building the BEAM binaries Campfire ships.
# Sourced by build_macos.sh and build_linux.sh. See the project notes.
#
# Everything is pinned: the BEAM tag AND its commit, and the SHA-256 of every
# third-party source tarball. A mismatch stops the build.

# ---- pins ------------------------------------------------------------------
BEAM_REPO_URL="${BEAM_REPO_URL:-https://github.com/BeamMW/beam.git}"   # a local clone of it works too
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

# A BEAM tree at the pinned commit that differs from "commit + our patches"
# stops the build. Set BEAM_ALLOW_MODIFIED_SOURCE=1 to build it anyway (for
# experiments): the build then leaves out/.modified_source behind, and
# make_manifest.sh refuses to pin anything from out/ until it is cleared.
BEAM_ALLOW_MODIFIED_SOURCE="${BEAM_ALLOW_MODIFIED_SOURCE:-0}"

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
    local modified
    # The marker is never removed here: binaries built from a modified tree
    # may still sit in out/ for another platform. make_manifest.sh says how
    # to clear it.
    if ! modified="$(check_source_tree "$BEAM_SRC" "$PATCH_DIR" "${BEAM_SUBMODULES[@]}")"; then
        if [[ "$BEAM_ALLOW_MODIFIED_SOURCE" == "1" ]]; then
            log "WARNING: $BEAM_SRC differs from ${BEAM_COMMIT} + patches; building it anyway (BEAM_ALLOW_MODIFIED_SOURCE=1):"
            printf '%s\n' "$modified" | sed 's/^/    /' >&2
            mkdir -p "$OUT_ROOT"
            printf '%s\n' "$modified" > "${OUT_ROOT}/.modified_source"
        else
            printf '%s\n' "$modified" | sed 's/^/    /' >&2
            die "$BEAM_SRC differs from ${BEAM_COMMIT} + patches (above). Reset it (git checkout -- . && git clean -fd, also in the submodules) or set BEAM_ALLOW_MODIFIED_SOURCE=1 for an unpinnable experiment"
        fi
    fi
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

# check_source_tree <src> <patch dir> <submodule...>
#
# The tree at the pinned commit must be exactly that commit plus our patches,
# applied in order up to any point (none, the first k, or all of them: a patch
# added to the series later finds older trees part-way). Prints every path that
# is anything else (edited, untracked, deleted, a submodule moved to another
# commit) and returns 1; prints nothing and returns 0 otherwise. Never changes
# <src>.
#
# Untracked files count: CMake reads any CMakeLists.txt or source file it finds.
# Files git ignores do not (build output lives outside the tree).
check_source_tree() {
    local src="$1" patches="$2"; shift 2
    local subs=("$@")
    local tmp; tmp="$(mktemp -d)"
    local bad=() path sm rel rec act pf

    # Every path our patches touch; $tmp/s0 holds the commit's version of each,
    # $tmp/s<k> the version after the first k patches.
    local touched=()
    while IFS= read -r path; do
        if [[ -n "$path" ]]; then touched+=("$path"); fi
    done < <(sed -n 's#^+++ b/\([^[:space:]]*\).*#\1#p' "$patches"/*.patch | sort -u)
    mkdir -p "$tmp/s0"
    for path in "${touched[@]}"; do
        mkdir -p "$tmp/s0/$(dirname "$path")"
        local owner="" r="$path"
        for sm in "${subs[@]}"; do
            if [[ "$path" == "$sm/"* ]]; then owner="$sm"; r="${path#"$sm"/}"; fi
        done
        if [[ -n "$owner" ]]; then
            # The submodule commit the superproject pins, not whatever the
            # submodule has checked out.
            rec="$(git -C "$src" ls-tree HEAD "$owner" | awk '{print $3}')"
            git -C "$src/$owner" show "$rec:$r" > "$tmp/s0/$path" 2>/dev/null || true
        else
            git -C "$src" show "HEAD:$path" > "$tmp/s0/$path" 2>/dev/null || true
        fi
    done
    local k=0
    for pf in "$patches"/*.patch; do
        cp -R "$tmp/s$k" "$tmp/s$((k + 1))"
        k=$((k + 1))
        if ! (cd "$tmp/s$k" && patch -p1 --forward -s < "$pf" >/dev/null 2>&1); then
            bad+=("$(basename "$pf") (does not apply to the pinned commit)")
        fi
    done

    is_touched() {
        local t
        for t in "${touched[@]}"; do [[ "$t" == "$1" ]] && return 0; done
        return 1
    }
    # A changed path is fine only if our patches touch it and it holds one of
    # the versions in $tmp/s0 .. $tmp/s<k>.
    check_path() {
        local f="$1" i
        if ! is_touched "$f"; then bad+=("$f"); return 0; fi
        if [[ ! -f "$src/$f" ]]; then bad+=("$f (missing)"); return 0; fi
        for ((i = 0; i <= k; i++)); do
            if cmp -s "$src/$f" "$tmp/s$i/$f"; then return 0; fi
        done
        bad+=("$f (neither the pinned nor a patched version)")
        return 0
    }

    # Superproject: modified, deleted, untracked (submodules handled below).
    while IFS= read -r path; do
        if [[ -n "$path" ]]; then check_path "$path"; fi
    done < <(git -C "$src" status --porcelain=v1 --untracked-files=all --ignore-submodules=all \
                | cut -c4- | sed 's/^"\(.*\)"$/\1/')

    for sm in "${subs[@]}"; do
        rec="$(git -C "$src" ls-tree HEAD "$sm" | awk '{print $3}')"
        act="$(git -C "$src/$sm" rev-parse HEAD 2>/dev/null || echo none)"
        if [[ "$rec" != "$act" ]]; then
            bad+=("$sm (at ${act}, the commit pins ${rec})")
            continue
        fi
        while IFS= read -r rel; do
            if [[ -n "$rel" ]]; then check_path "$sm/$rel"; fi
        done < <(git -C "$src/$sm" status --porcelain=v1 --untracked-files=all \
                    | cut -c4- | sed 's/^"\(.*\)"$/\1/')
    done

    rm -rf "$tmp"
    unset -f is_touched check_path
    if [[ ${#bad[@]} -gt 0 ]]; then
        printf '%s\n' "${bad[@]}"
        return 1
    fi
    return 0
}

# check_cmake_version <build dir>: the configured version must be the release one.
check_cmake_version() {
    local v; v="$(grep '^BEAM_VERSION:INTERNAL=' "$1/CMakeCache.txt" | cut -d= -f2)"
    [[ "$v" == "$BEAM_EXPECTED_VERSION" ]] || die "CMake configured BEAM_VERSION=$v, expected $BEAM_EXPECTED_VERSION (shallow clone or git unusable?)"
    log "CMake BEAM_VERSION=$v"
}
