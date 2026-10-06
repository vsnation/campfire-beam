#!/usr/bin/env bash
# Build wallet-api, beam-node and beam-wallet for macOS arm64 from tag
# beam-7.5.14493, with Campfire's patches (scripts/beam/core/patches).
# Outputs: $BUILD_ROOT/out/macos-arm64/.
#
# Differs from LightWallet docs/BUILDING_BEAM_MACOS.md in one deliberate way:
# Boost and OpenSSL are built here from pinned source and linked STATICALLY,
# for macOS 12.0+. The LightWallet binaries link Homebrew's dylibs by absolute
# path (/opt/homebrew/opt/boost/lib/*.dylib, openssl@3), so they only start on
# a Mac that has those exact Homebrew kegs installed, and Homebrew's own static
# libraries are built for macOS 15.0 (LC_BUILD_VERSION minos 15.0), above
# Campfire's macOS 12 floor.
#
# Prerequisites: Xcode Command Line Tools (clang), cmake, git, curl.
# Env: JOBS (default 8), BEAM_CORE_BUILD_ROOT (default ~/Desktop/Beam/beam-core-build)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "build on an Apple Silicon host (BEAM picks -mcpu from the host arch)"

JOBS="${JOBS:-8}"
MACOS_MIN="12.0"
PLAT="macos-arm64"
DEPS_PREFIX="${BUILD_ROOT}/deps/${PLAT}"
WORK="${BUILD_ROOT}/work/${PLAT}"
BUILD_DIR="${BUILD_ROOT}/build/${PLAT}"
OUT="${OUT_ROOT}/${PLAT}"
BRANCH_LABEL="${BEAM_TAG}-campfire"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
MINFLAG="-mmacosx-version-min=${MACOS_MIN}"

fetch_deps
prepare_source

t_start=$(date +%s)

# ---- OpenSSL (static) --------------------------------------------------------
if [[ ! -f "${DEPS_PREFIX}/openssl/lib/libcrypto.a" ]]; then
    log "building OpenSSL ${OPENSSL_VERSION} (static, macOS ${MACOS_MIN}+)"
    rm -rf "${WORK}/openssl" && mkdir -p "${WORK}/openssl"
    tar xzf "${DL_DIR}/${OPENSSL_TARBALL}" -C "${WORK}/openssl" --strip-components=1
    (
        cd "${WORK}/openssl"
        ./Configure darwin64-arm64-cc no-shared no-tests no-docs "$MINFLAG" \
            --prefix="${DEPS_PREFIX}/openssl" --libdir=lib > configure.log 2>&1
        make -j"$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
        make install_sw > install.log 2>&1
    )
    rm -rf "${WORK}/openssl"
fi
"${DEPS_PREFIX}/openssl/bin/openssl" version

# ---- Boost (static) ----------------------------------------------------------
if [[ ! -f "${DEPS_PREFIX}/boost/lib/libboost_log.a" ]]; then
    log "building Boost ${BOOST_VERSION} (static, macOS ${MACOS_MIN}+)"
    rm -rf "${WORK}/boost" && mkdir -p "${WORK}/boost"
    tar xjf "${DL_DIR}/${BOOST_TARBALL}" -C "${WORK}/boost" --strip-components=1
    (
        cd "${WORK}/boost"
        libs="$(IFS=,; echo "${BOOST_LIBS[*]}")"
        ./bootstrap.sh --with-toolset=clang --without-icu --with-libraries="$libs" > bootstrap.log 2>&1
        ./b2 -j"$JOBS" -d0 toolset=clang link=static runtime-link=shared threading=multi variant=release \
            architecture=arm address-model=64 \
            cxxflags="$MINFLAG" cflags="$MINFLAG" linkflags="$MINFLAG" \
            --disable-icu boost.locale.icu=off \
            --prefix="${DEPS_PREFIX}/boost" install
    )
    rm -rf "${WORK}/boost"
fi
t_deps=$(date +%s)
log "dependencies ready ($((t_deps - t_start)) s)"

# ---- BEAM ----------------------------------------------------------------------
cmake_args=(
    -S "$BEAM_SRC" -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DBUILD_SHARED_LIBS=OFF
    -DBEAM_LINK_TYPE=Static
    -DBEAM_IPFS_SUPPORT=OFF
    -DBEAM_LASER_SUPPORT=OFF
    -DBEAM_TESTS_ENABLED=OFF
    -DBEAM_HW_WALLET=OFF
    -DBRANCH_NAME="$BRANCH_LABEL"
    -DBOOST_ROOT="${DEPS_PREFIX}/boost"
    -DBoost_NO_SYSTEM_PATHS=ON
    -DOPENSSL_ROOT_DIR="${DEPS_PREFIX}/openssl"
    # Keep Homebrew out of the link: nothing from /opt/homebrew or /usr/local.
    "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
)
log "configuring BEAM"
mkdir -p "$BUILD_DIR"
cmake "${cmake_args[@]}" > "${BUILD_DIR}/configure.log" 2>&1 || { tail -60 "${BUILD_DIR}/configure.log"; exit 1; }
check_cmake_version "$BUILD_DIR"
grep -E '^(Boost_DIR|OPENSSL_CRYPTO_LIBRARY|OPENSSL_SSL_LIBRARY):' "${BUILD_DIR}/CMakeCache.txt" >&2 || true

log "building ${BEAM_TARGETS[*]} with -j${JOBS}"
t_b0=$(date +%s)
cmake --build "$BUILD_DIR" --target "${BEAM_TARGETS[@]}" -j"$JOBS" > "${BUILD_DIR}/build.log" 2>&1 \
    || { grep -nE 'error:' "${BUILD_DIR}/build.log" | head -40; tail -40 "${BUILD_DIR}/build.log"; exit 1; }
t_b1=$(date +%s)
log "BEAM build took $((t_b1 - t_b0)) s"

# ---- collect -------------------------------------------------------------------
mkdir -p "$OUT"
install -m 0755 "${BUILD_DIR}/wallet/api/wallet-api"  "$OUT/wallet-api"
install -m 0755 "${BUILD_DIR}/beam/beam-node"         "$OUT/beam-node"
install -m 0755 "${BUILD_DIR}/wallet/cli/beam-wallet" "$OUT/beam-wallet"
for b in "${BEAM_TARGETS[@]}"; do
    strip -S -x "$OUT/$b"
    # strip invalidates the linker's ad-hoc signature; arm64 macOS will not run
    # an unsigned binary, so re-sign ad hoc.
    codesign --force --sign - "$OUT/$b" 2>/dev/null
    if otool -L "$OUT/$b" | tail -n +2 | grep -vE '^\s+/(usr/lib|System/Library)/' ; then
        die "$b links a non-system library (see above)"
    fi
    printf '%s: version=%s size=%s minos=%s\n' "$b" "$("$OUT/$b" --version)" "$(stat -f %z "$OUT/$b")" \
        "$(otool -l "$OUT/$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')" >&2
done
echo "$((t_b1 - t_b0))" > "$OUT/.build_seconds"
echo "$((t_deps - t_start))" > "$OUT/.deps_seconds"
log "done: $OUT"
