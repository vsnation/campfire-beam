#!/usr/bin/env bash
# Build BEAM's WebAssembly wallet client (wasmclient/, the engine of BEAM's own
# web wallet) for the Campfire web app (pwa/), from the same pinned tag and
# patches as the desktop core, plus scripts/beam/wasm/patches.
#
# Why not npm's beam-wasm-client: its newest version (7.5.14349, 2025-12) is
# older than the HF6 hard fork at block 3928666 and cannot follow mainnet.
# BeamMW's own CI built 7.5.14493 but its npm publish failed.
#
# Recipe as BeamMW's .github/workflows/build.yml job build_wasm (emsdk 3.1.10,
# the same CMake switches), except that everything comes from pinned sources:
# emsdk by commit, Boost headers and OpenSSL 3.5.9 from the SHA-256-checked
# tarballs in ../core/common.sh (BeamMW links a prebuilt OpenSSL 1.1.1).
#
# Outputs $WASM_ROOT/out/: wasm-client.js, wasm-client.wasm,
# wasm-client.worker.js and SHA256SUMS.txt.
#
# Env: JOBS (default 8), BEAM_CORE_BUILD_ROOT (default ~/Desktop/Beam/beam-core-build),
#      BEAM_WASM_BUILD_ROOT (default $BEAM_CORE_BUILD_ROOT/wasm),
#      BEAM_REPO_URL (default GitHub; a local clone of BeamMW/beam saves the download).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../core/common.sh"

EMSDK_REPO_URL="https://github.com/emscripten-core/emsdk.git"
EMSDK_VERSION="3.1.10"
EMSDK_COMMIT="891b4491419c42f9d2b9f97c47d1043b26dfd3e5"   # tag 3.1.10

JOBS="${JOBS:-8}"
WASM_ROOT="${BEAM_WASM_BUILD_ROOT:-${BUILD_ROOT}/wasm}"
WASM_PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches"
EMSDK_DIR="${WASM_ROOT}/emsdk"
DEPS="${WASM_ROOT}/deps"
WORK="${WASM_ROOT}/work"
BUILD_DIR="${WASM_ROOT}/build"
OUT="${WASM_ROOT}/out"

# The wasm build gets its own source tree, so the desktop tree stays exactly
# "pinned commit + core patches" (prepare_source checks that).
BEAM_SRC="${WASM_ROOT}/beam"
mkdir -p "$WASM_ROOT" "$DEPS" "$WORK" "$OUT"

# prepare_source checks the tree is "pinned commit + core patches", so take the
# wasm patches out (newest first) before it looks, and put them back after.
unapply_wasm_patches() {
    [[ -d "${BEAM_SRC}/.git" ]] || return 0
    local p
    for p in $(ls -r "${WASM_PATCH_DIR}"/*.patch); do
        if (cd "$BEAM_SRC" && patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1); then
            (cd "$BEAM_SRC" && patch -p1 -R -s -f < "$p") || die "could not take out $(basename "$p")"
        fi
    done
}

# ---- emsdk ---------------------------------------------------------------------
if [[ ! -d "${EMSDK_DIR}/.git" ]]; then
    log "cloning emsdk"
    git clone -q "$EMSDK_REPO_URL" "$EMSDK_DIR"
fi
git -C "$EMSDK_DIR" fetch -q --tags || true
git -C "$EMSDK_DIR" checkout -q "$EMSDK_COMMIT"
[[ "$(git -C "$EMSDK_DIR" rev-parse HEAD)" == "$EMSDK_COMMIT" ]] || die "emsdk is not at $EMSDK_COMMIT"
if [[ ! -f "${EMSDK_DIR}/.emsdk_installed_${EMSDK_VERSION}" ]]; then
    log "installing emscripten ${EMSDK_VERSION}"
    (cd "$EMSDK_DIR" && ./emsdk install "$EMSDK_VERSION" && ./emsdk activate "$EMSDK_VERSION") > "${WASM_ROOT}/emsdk.log" 2>&1 \
        || { tail -40 "${WASM_ROOT}/emsdk.log"; die "emsdk install failed"; }
    touch "${EMSDK_DIR}/.emsdk_installed_${EMSDK_VERSION}"
fi
# emsdk 3.1.10 ships an x86_64-only node; on an Apple Silicon Mac without
# Rosetta it cannot start. Any node >= 14 runs Emscripten's JS tools.
for n in "${EMSDK_DIR}"/node/*/bin/node; do
    if ! "$n" --version > /dev/null 2>&1; then
        host_node="$(command -v node)" || die "the bundled node does not run here and there is no node on PATH"
        log "bundled node does not run here; using ${host_node} ($("$host_node" --version))"
        sed -i.bak "s|^NODE_JS = .*|NODE_JS = '${host_node}'|" "${EMSDK_DIR}/.emscripten"
        rm -f "${EMSDK_DIR}/.emscripten.bak"
    fi
done
# shellcheck disable=SC1091
source "${EMSDK_DIR}/emsdk_env.sh" > /dev/null 2>&1
emcc --version | head -1

# ---- sources ---------------------------------------------------------------------
fetch_deps
unapply_wasm_patches
prepare_source
for p in "${WASM_PATCH_DIR}"/*.patch; do
    if (cd "$BEAM_SRC" && patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1); then
        log "wasm patch already applied: $(basename "$p")"
    else
        (cd "$BEAM_SRC" && patch -p1 --forward -s < "$p") || die "wasm patch failed: $(basename "$p")"
        log "applied wasm patch $(basename "$p")"
    fi
done

# ---- Boost (headers only: the wasm client links no Boost library) ----------------
if [[ ! -f "${DEPS}/boost/include/boost/version.hpp" ]]; then
    log "extracting Boost ${BOOST_VERSION} headers"
    rm -rf "${WORK}/boost" && mkdir -p "${WORK}/boost" "${DEPS}/boost/include"
    tar xjf "${DL_DIR}/${BOOST_TARBALL}" -C "${WORK}/boost" --strip-components=1 "boost_${BOOST_VERSION//./_}/boost"
    mv "${WORK}/boost/boost" "${DEPS}/boost/include/boost"
    rm -rf "${WORK}/boost"
fi

# ---- OpenSSL for wasm (static) -----------------------------------------------------
if [[ ! -f "${DEPS}/openssl/lib/libcrypto.a" ]]; then
    log "building OpenSSL ${OPENSSL_VERSION} for wasm"
    rm -rf "${WORK}/openssl" && mkdir -p "${WORK}/openssl"
    tar xzf "${DL_DIR}/${OPENSSL_TARBALL}" -C "${WORK}/openssl" --strip-components=1
    (
        cd "${WORK}/openssl"
        # As BeamMW's openssl_wasm_build.yml; a neutral prefix keeps this
        # machine's paths out of the strings OpenSSL embeds.
        emconfigure ./Configure linux-generic32 no-asm threads no-engine no-hw no-weak-ssl-ciphers \
            no-dtls no-shared no-dso no-tests no-docs no-apps no-module \
            --prefix=/opt/campfire-beam/openssl --openssldir=/opt/campfire-beam/openssl --libdir=lib \
            > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
        sed -i.bak 's|^CROSS_COMPILE.*$|CROSS_COMPILE=|g' Makefile
        # OpenSSL_version(OPENSSL_CFLAGS) embeds "compiler: $(CC) ...", and
        # emconfigure's CC is emcc's absolute path (this machine's home dir).
        # emsdk_env puts emcc on PATH, so the bare name works.
        sed -i.bak -e 's|^CC=.*$|CC=emcc|' -e 's|^CXX=.*$|CXX=em++|' Makefile
        sed -i.bak '/^CFLAGS/ s/$/ -D__STDC_NO_ATOMICS__=1 -pthread/' Makefile
        sed -i.bak '/^CXXFLAGS/ s/$/ -D__STDC_NO_ATOMICS__=1 -pthread/' Makefile
        emmake make -j"$JOBS" build_generated libssl.a libcrypto.a > build.log 2>&1 || { tail -60 build.log; exit 1; }
        emmake make install_sw DESTDIR="${WORK}/openssl-stage" > install.log 2>&1 || { tail -40 install.log; exit 1; }
    ) || die "OpenSSL build failed"
    rm -rf "${DEPS}/openssl"
    mv "${WORK}/openssl-stage/opt/campfire-beam/openssl" "${DEPS}/openssl"
    rm -rf "${WORK}/openssl" "${WORK}/openssl-stage"
fi

# ---- the wasm client -----------------------------------------------------------------
# wasmclient/CMakeLists.txt runs its fix-client.py as `python`; many hosts
# (macOS, Ubuntu) only have python3.
if ! command -v python > /dev/null 2>&1 || ! python --version > /dev/null 2>&1; then
    mkdir -p "${WASM_ROOT}/bin"
    ln -sf "$(command -v python3)" "${WASM_ROOT}/bin/python"
    export PATH="${WASM_ROOT}/bin:${PATH}"
fi
mkdir -p "$BUILD_DIR"
MAP="-ffile-prefix-map=${BEAM_SRC}=/beam -ffile-prefix-map=${DEPS}=/deps -ffile-prefix-map=${BUILD_DIR}=/build -ffile-prefix-map=${EMSDK_DIR}=/emsdk"
emcmake cmake -S "$BEAM_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DBEAM_TESTS_ENABLED=Off -DBEAM_WALLET_CLIENT_LIBRARY=On -DBEAM_ATOMIC_SWAP_SUPPORT=Off \
    -DBEAM_IPFS_SUPPORT=Off -DBEAM_LASER_SUPPORT=Off -DBEAM_ASSET_SWAP_SUPPORT=Off -DBEAM_USE_STATIC=On \
    -DBRANCH_NAME="${BEAM_TAG}-campfire" \
    -DBOOST_ROOT="${DEPS}/boost" -DBoost_INCLUDE_DIR="${DEPS}/boost/include" \
    -DCMAKE_FIND_ROOT_PATH="${DEPS}/boost;${DEPS}/openssl" \
    -DOPENSSL_ROOT_DIR="${DEPS}/openssl" \
    "-DCMAKE_C_FLAGS=${MAP}" "-DCMAKE_CXX_FLAGS=${MAP}" \
    -DBEAM_RECORDED_SOURCE_DIR=/beam \
    > "${BUILD_DIR}/configure.log" 2>&1 || { tail -60 "${BUILD_DIR}/configure.log"; die "configure failed"; }
log "building wasm-client (logs: ${BUILD_DIR}/build.log)"
emmake make -C "$BUILD_DIR" -j"$JOBS" wasm-client > "${BUILD_DIR}/build.log" 2>&1 \
    || { grep -E 'error|Error' "${BUILD_DIR}/build.log" | head -40; tail -40 "${BUILD_DIR}/build.log"; die "build failed"; }

rm -f "${OUT}"/wasm-client*
for f in wasm-client.js wasm-client.wasm wasm-client.worker.js; do
    [[ -f "${BUILD_DIR}/wasmclient/$f" ]] || die "missing output $f"
    cp "${BUILD_DIR}/wasmclient/$f" "${OUT}/$f"
done
(cd "$OUT" && for f in wasm-client.js wasm-client.wasm wasm-client.worker.js; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done > SHA256SUMS.txt)
# Nothing from this machine may ride along into a public web app.
if grep -a -l -E "${HOME}|/Users/|/home/runner" "${OUT}"/wasm-client.* ; then
    die "an output names a local path (above)"
fi
cat "${OUT}/SHA256SUMS.txt"
log "done in ${SECONDS}s"
