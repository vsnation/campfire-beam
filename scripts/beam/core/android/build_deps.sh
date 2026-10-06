#!/usr/bin/env bash
# Cross-build OpenSSL and Boost as static libraries for Android, per ABI, with the
# NDK pinned in env.sh. Same tarballs and SHA-256 pins as the desktop builds
# (../common.sh): Boost 1.90.0, OpenSSL 3.5.9.
#
#   scripts/beam/core/android/build_deps.sh                 # arm64-v8a and x86_64
#   scripts/beam/core/android/build_deps.sh arm64-v8a
#
# Output (kept as a cache; a rebuild is skipped when the stamp matches):
#   $BUILD_ROOT/android/deps/<abi>/openssl/{include,lib/libcrypto.a,lib/libssl.a}
#   $BUILD_ROOT/android/deps/<abi>/boost/include
#   $BUILD_ROOT/android/deps/<abi>/boost/libs/<abi>/libboost_*.a
# The Boost layout is the one BEAM's Android CMake path expects
# ($BOOST_ROOT_ANDROID/libs/$ANDROID_ABI/libboost_<component>.a).
#
# The tarballs are untrusted input: they are checked against their pins before
# extraction, and their build tooling (bootstrap.sh, b2, Configure, make) runs with
# network access denied (env.sh: offline).
#
# Env: JOBS (default 8), ANDROID_SDK_ROOT, ANDROID_NDK, BEAM_CORE_BUILD_ROOT, FORCE=1 to rebuild.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need_cmd perl; need_cmd make; need_cmd tar; need_cmd curl
check_toolchain

abis=()
if [[ $# -eq 0 ]]; then abis=("${ANDROID_ABIS_DEFAULT[@]}"); else for a in "$@"; do abis+=("$(abi_normalize "$a")"); done; fi

mkdir -p "$ANDROID_DEPS" "$ANDROID_WORK" "$ANDROID_LOGS"
fetch_deps   # common.sh: download if missing, then verify both SHA-256 pins

# The desktop Boost component list minus locale. Boost 1.90's Boost.Locale needs iconv
# or ICU; bionic has iconv only from API 28, and b2 then skips the library ("Boost.Locale
# needs either iconv or ICU library to be built"). In BEAM only 3rdparty/libbitcoin uses
# Boost.Locale, and libbitcoin is built only with atomic swap support, which Android
# forces off. The wallet-api link proves nothing else needs it.
ANDROID_BOOST_LIBS=()
for l in "${BOOST_LIBS[@]}"; do [[ "$l" == "locale" ]] || ANDROID_BOOST_LIBS+=("$l"); done

# Stamps: what a cached install was built from (pins + the exact text of the function
# that built it). Any change rebuilds that library, and only that library.
recipe_sha() { declare -f "$@" | shasum -a 256 | cut -d' ' -f1; }
openssl_stamp() {
    printf 'ndk=%s api=%s openssl=%s:%s neutral=%s recipe=%s\n' \
        "$NDK_VERSION" "$ANDROID_API" "$OPENSSL_VERSION" "$OPENSSL_SHA256" "$OPENSSL_NEUTRAL_PREFIX" \
        "$(recipe_sha build_openssl)"
}
boost_stamp() {
    printf 'ndk=%s api=%s boost=%s:%s libs=%s maps=%s recipe=%s\n' \
        "$NDK_VERSION" "$ANDROID_API" "$BOOST_VERSION" "$BOOST_SHA256" \
        "$(IFS=,; echo "${ANDROID_BOOST_LIBS[*]}")" "$(prefix_map_flags | shasum -a 256 | cut -c1-16)" \
        "$(recipe_sha build_boost prepare_boost_src)"
}

build_openssl() {
    local abi="$1" prefix="${ANDROID_DEPS}/$1/openssl"
    local src="${ANDROID_WORK}/openssl-$1" stage="${ANDROID_WORK}/openssl-stage-$1"
    local log="${ANDROID_LOGS}/openssl-$1.log"
    log "OpenSSL ${OPENSSL_VERSION} for ${abi} (static, API ${ANDROID_API})"
    rm -rf "$src" "$stage" "$prefix" && mkdir -p "$src" "$stage"
    tar xzf "${DL_DIR}/${OPENSSL_TARBALL}" -C "$src" --strip-components=1
    (
        cd "$src"
        export ANDROID_NDK_ROOT="$ANDROID_NDK"
        export PATH="${NDK_TC}/bin:$PATH"
        # no-shared: static libcrypto/libssl only. -fPIC: linked into a PIE.
        # OPENSSLDIR etc. point at a neutral path (see env.sh); files go through DESTDIR.
        # No -ffile-prefix-map here: OpenSSL compiles with in-tree relative paths anyway,
        # and it records its whole configure command line in libcrypto
        # (OpenSSL_version(OPENSSL_CFLAGS), "compiler: ..."), so a prefix-map flag would
        # itself put the build machine's home directory into the binary.
        offline ./Configure "$(abi_openssl_target "$abi")" \
            no-shared no-tests no-docs no-apps no-engine no-module \
            -D__ANDROID_API__="${ANDROID_API}" -fPIC \
            --prefix="$OPENSSL_NEUTRAL_PREFIX" --openssldir="${OPENSSL_NEUTRAL_PREFIX}/ssl" --libdir=lib \
            > "$log" 2>&1 || { tail -40 "$log"; exit 1; }
        offline make -j"$JOBS" build_libs >> "$log" 2>&1 || { tail -60 "$log"; exit 1; }
        offline make install_dev DESTDIR="$stage" >> "$log" 2>&1 || { tail -40 "$log"; exit 1; }
    )
    mkdir -p "$prefix"
    cp -R "${stage}${OPENSSL_NEUTRAL_PREFIX}/include" "${stage}${OPENSSL_NEUTRAL_PREFIX}/lib" "$prefix/"
    rm -rf "${prefix}/lib/pkgconfig" "${prefix}/lib/cmake"   # they name the neutral prefix; unused
    rm -rf "$src" "$stage"
    [[ -f "${prefix}/lib/libcrypto.a" && -f "${prefix}/lib/libssl.a" ]] || die "OpenSSL install incomplete for $abi"
}

# Boost: the host b2 is bootstrapped once per run, in a scratch copy of the sources.
BOOST_SRC="${ANDROID_WORK}/boost-src"
prepare_boost_src() {
    [[ -x "${BOOST_SRC}/b2" ]] && return 0
    log "extracting Boost ${BOOST_VERSION} and bootstrapping b2 (host)"
    rm -rf "$BOOST_SRC" && mkdir -p "$BOOST_SRC"
    tar xjf "${DL_DIR}/${BOOST_TARBALL}" -C "$BOOST_SRC" --strip-components=1
    (cd "$BOOST_SRC" && offline ./bootstrap.sh --without-icu > "${ANDROID_LOGS}/boost-bootstrap.log" 2>&1) \
        || { tail -30 "${ANDROID_LOGS}/boost-bootstrap.log"; die "Boost bootstrap failed"; }
}

build_boost() {
    local abi="$1" prefix="${ANDROID_DEPS}/$1/boost"
    local triple; triple="$(abi_triple "$abi")"
    local log="${ANDROID_LOGS}/boost-$abi.log"
    local cfg="${ANDROID_WORK}/user-config-$abi.jam"
    local ver; ver="ndk$(echo "$abi" | tr -cd 'a-z0-9')"     # b2 toolset version: no dashes
    prepare_boost_src
    log "Boost ${BOOST_VERSION} for ${abi} (static, API ${ANDROID_API})"
    rm -rf "$prefix" "${ANDROID_WORK}/boost-build-$abi"
    local flags=(--target="${triple}${ANDROID_API}" -fPIC $(prefix_map_flags))
    # clang-linux, not clang: on a macOS host b2's generic "clang" forwards to
    # clang-darwin (Mach-O linker flags). For target-os=android b2 adds no --target
    # of its own, so the one below is the only one. llvm-ar writes the archive index
    # itself (b2 runs "ar rsc"), so no ranlib is configured.
    {
        printf 'using clang-linux : %s : "%s"\n' "$ver" "${NDK_TC}/bin/clang++"
        printf '  : <archiver>"%s"\n' "${NDK_TC}/bin/llvm-ar"
        local f
        for f in "${flags[@]}"; do printf '    <compileflags>"%s"\n' "$f"; done
        printf '    <linkflags>"--target=%s%s"\n' "$triple" "$ANDROID_API"
        printf '  ;\n'
    } > "$cfg"
    local withs=() l
    for l in "${ANDROID_BOOST_LIBS[@]}"; do withs+=("--with-${l}"); done
    # shellcheck disable=SC2046
    (cd "$BOOST_SRC" && offline ./b2 -j"$JOBS" -d1 -q \
        --user-config="$cfg" --ignore-site-config \
        --build-dir="${ANDROID_WORK}/boost-build-$abi" \
        toolset="clang-linux-${ver}" target-os=android $(abi_b2_props "$abi") \
        link=static runtime-link=shared threading=multi variant=release cxxstd=17 \
        --disable-icu boost.locale.icu=off boost.locale.iconv=off \
        "${withs[@]}" \
        --prefix="$prefix" --includedir="${prefix}/include" --libdir="${prefix}/libs/${abi}" \
        install > "$log" 2>&1) || { grep -nE 'error|failed' "$log" | head -40; tail -30 "$log"; die "Boost build failed for $abi"; }
    rm -rf "${ANDROID_WORK}/boost-build-$abi" "$cfg"
    rm -rf "${prefix}/libs/${abi}/cmake"   # BEAM's Android path does not use them; they embed the build path
    for l in "${ANDROID_BOOST_LIBS[@]}"; do
        [[ -f "${prefix}/libs/${abi}/libboost_${l}.a" ]] || die "Boost ${abi}: libboost_${l}.a missing"
    done
}

t0=$(date +%s)
# Never reuse sources extracted by an earlier (possibly interrupted) run.
rm -rf "${ANDROID_WORK:?}" && mkdir -p "$ANDROID_WORK"
up_to_date() {   # up_to_date <stamp file> <wanted content>
    [[ "${FORCE:-0}" != "1" && -f "$1" && "$(cat "$1")" == "$2" ]]
}
for abi in "${abis[@]}"; do
    dir="${ANDROID_DEPS}/${abi}"
    mkdir -p "$dir"
    rm -f "${dir}/.stamp"                       # written last, only when both are current
    want_o="$(openssl_stamp)"; want_b="$(boost_stamp)"
    if up_to_date "${dir}/.stamp-openssl" "$want_o"; then
        log "OpenSSL for ${abi} is up to date"
    else
        rm -f "${dir}/.stamp-openssl"; build_openssl "$abi"; printf '%s\n' "$want_o" > "${dir}/.stamp-openssl"
    fi
    if up_to_date "${dir}/.stamp-boost" "$want_b"; then
        log "Boost for ${abi} is up to date"
    else
        rm -f "${dir}/.stamp-boost"; build_boost "$abi"; printf '%s\n' "$want_b" > "${dir}/.stamp-boost"
    fi
    cat "${dir}/.stamp-openssl" "${dir}/.stamp-boost" > "${dir}/.stamp"
    log "deps for ${abi}: $(du -sh "$dir" | cut -f1) in ${dir}"
done
rm -rf "$BOOST_SRC"
t1=$(date +%s)
log "dependencies done in $((t1 - t0)) s"
