#!/usr/bin/env bash
# Build wallet-api, beam-node and beam-wallet for Windows x64 from tag beam-7.5.14493
# with Campfire's patches (scripts/beam/core/patches). Runs in Git Bash on a
# windows-2022 GitHub runner (Visual Studio 2022), from .github/workflows/beam-core.yml.
#
# Source: the same pinned tag, commit and patch series as build_linux.sh and
# build_macos.sh (common.sh: prepare_source checks the tree is exactly the commit
# plus our patches). Boost and OpenSSL: the prebuilt libraries BEAM's own release
# CI uses for Windows (BeamMW/boost_prebuild_windows-2022 branch boost-1.90 and
# BeamMW/libs), each pinned to a commit here, as in BEAM's
# .github/workflows/build.yml at that tag.
#
# Output: $BEAM_CORE_BUILD_ROOT/out/windows-x86_64/{wallet-api,beam-node,beam-wallet}.exe
# Env: BEAM_CORE_BUILD_ROOT (keep it short: MSBuild paths get long), JOBS.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BOOST_PREBUILD_URL="https://github.com/BeamMW/boost_prebuild_windows-2022.git"
BOOST_PREBUILD_BRANCH="boost-1.90"
BOOST_PREBUILD_COMMIT="a53681df38cf63fad4dc7d1c778024a951da622b"
BEAM_LIBS_URL="https://github.com/BeamMW/libs.git"
BEAM_LIBS_COMMIT="7c009700b45f1206a388df9f79ec2f5ab6c3789f"

[[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] || die "run this in Git Bash on Windows"
command -v cmake >/dev/null || die "cmake not found"
JOBS="${JOBS:-4}"
OUT="${OUT_ROOT}/windows-x86_64"
DEPS="${BUILD_ROOT}/deps-win"
BUILD="${BUILD_ROOT}/b"

# clone_pinned <url> <branch|""> <commit> <dir>
clone_pinned() {
    local url="$1" branch="$2" commit="$3" dir="$4"
    if [[ ! -d "$dir/.git" ]]; then
        log "cloning $url"
        if [[ -n "$branch" ]]; then git clone -q -b "$branch" "$url" "$dir"; else git clone -q "$url" "$dir"; fi
    fi
    git -C "$dir" checkout -q "$commit"
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]] || die "$url is not at $commit"
}

prepare_source
clone_pinned "$BOOST_PREBUILD_URL" "$BOOST_PREBUILD_BRANCH" "$BOOST_PREBUILD_COMMIT" "$DEPS/boost"
clone_pinned "$BEAM_LIBS_URL" "" "$BEAM_LIBS_COMMIT" "$DEPS/libs"

win() { cygpath -w "$1"; }
cmake_args=(
    -S "$(win "$BEAM_SRC")" -B "$(win "$BUILD")"
    -G "Visual Studio 17 2022" -A x64
    -DBEAM_LINK_TYPE=Static
    -DBEAM_USE_STATIC_RUNTIME=On
    -DBEAM_BUILD_JNI=Off
    -DBEAM_HW_WALLET=Off
    -DBEAM_IPFS_SUPPORT=OFF
    -DBEAM_LASER_SUPPORT=OFF
    -DBEAM_TESTS_ENABLED=OFF
    -DBRANCH_NAME="${BEAM_TAG}-campfire"
    -DBOOST_ROOT="$(win "$DEPS/boost")"
    -DOPENSSL_ROOT_DIR="$(win "$DEPS/libs/openssl")"
)
log "configuring: ${cmake_args[*]}"
cmake "${cmake_args[@]}" > "${BUILD_ROOT}/cmake-configure.log" 2>&1 \
    || { tail -80 "${BUILD_ROOT}/cmake-configure.log"; die "cmake configure failed"; }
grep -E 'BEAM_VERSION|BRANCH_NAME' "${BUILD_ROOT}/cmake-configure.log" >&2 || true

start=$(date +%s)
cmake --build "$(win "$BUILD")" --config Release --target wallet-api beam-node beam-wallet \
    --parallel "$JOBS" > "${BUILD_ROOT}/build.log" 2>&1 \
    || { grep -E ' error |error C|error LNK|fatal' "${BUILD_ROOT}/build.log" | head -60; tail -40 "${BUILD_ROOT}/build.log"; die "build failed"; }
log "built in $(( $(date +%s) - start )) s"

mkdir -p "$OUT"
cp "$BUILD/wallet/api/Release/wallet-api.exe" "$OUT/"
cp "$BUILD/beam/Release/beam-node.exe" "$OUT/"
cp "$BUILD/wallet/cli/Release/beam-wallet.exe" "$OUT/"
for b in wallet-api beam-node beam-wallet; do
    log "$b.exe $(sha256_of "$OUT/$b.exe")  $(wc -c < "$OUT/$b.exe") bytes"
done
