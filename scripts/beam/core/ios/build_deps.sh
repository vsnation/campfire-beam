#!/usr/bin/env bash
# Cross-build OpenSSL and Boost as static libraries for iOS, per slice (device
# arm64, simulator arm64). Same tarballs and SHA-256 pins as the desktop and
# Android builds (../common.sh): Boost 1.90.0, OpenSSL 3.5.9.
#
#   scripts/beam/core/ios/build_deps.sh                       # both slices
#   scripts/beam/core/ios/build_deps.sh ios-arm64-simulator
#
# Output (kept as a cache; a rebuild is skipped when the stamp matches):
#   $BUILD_ROOT/ios/deps/<slice>/openssl/{include,lib/libcrypto.a,lib/libssl.a}
#   $BUILD_ROOT/ios/deps/<slice>/boost/{include,lib/libboost_*.a}
# The Boost layout is the one BEAM's iOS CMake path reads
# ($BOOST_ROOT_IOS/include, $BOOST_ROOT_IOS/lib/libboost_<component>.a).
#
# The tarballs are untrusted input: they are checked against their pins before
# extraction, and their build tooling (bootstrap.sh, b2, Configure, make) runs
# with network access denied (env.sh: offline). Only the parts of the Boost
# tarball a build needs are extracted (no docs, tests or examples: ~1 GB less).
#
# Env: JOBS (default 6), BEAM_CORE_BUILD_ROOT, FORCE=1 to rebuild.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

need_cmd perl; need_cmd make; need_cmd tar; need_cmd curl
check_toolchain

slices=()
if [[ $# -eq 0 ]]; then slices=("${IOS_SLICES_DEFAULT[@]}"); else for a in "$@"; do slices+=("$(slice_normalize "$a")"); done; fi

mkdir -p "$IOS_DEPS" "$IOS_WORK" "$IOS_LOGS"
fetch_deps   # common.sh: download if missing, then verify both SHA-256 pins

# The desktop Boost component list minus locale, as on Android. In BEAM only
# 3rdparty/libbitcoin uses Boost.Locale, and libbitcoin is built only with atomic
# swap support, which BEAM's CMake forces off on iOS.
IOS_BOOST_LIBS=()
for l in "${BOOST_LIBS[@]}"; do [[ "$l" == "locale" ]] || IOS_BOOST_LIBS+=("$l"); done

# Stamps: what a cached install was built from (pins + Xcode + the exact text of the
# function that built it). Any change rebuilds that library, and only that library.
recipe_sha() { declare -f "$@" | shasum -a 256 | cut -d' ' -f1; }
toolchain_id() { xcodebuild -version 2>/dev/null | tr '\n' ' '; xcrun --sdk "$(slice_sdk "$1")" --show-sdk-version; }
openssl_stamp() {
    printf 'xcode=%s min=%s openssl=%s:%s neutral=%s recipe=%s\n' \
        "$(toolchain_id "$1")" "$IOS_MIN" "$OPENSSL_VERSION" "$OPENSSL_SHA256" "$OPENSSL_NEUTRAL_PREFIX" \
        "$(recipe_sha build_openssl)"
}
boost_stamp() {
    printf 'xcode=%s min=%s boost=%s:%s libs=%s maps=%s recipe=%s\n' \
        "$(toolchain_id "$1")" "$IOS_MIN" "$BOOST_VERSION" "$BOOST_SHA256" \
        "$(IFS=,; echo "${IOS_BOOST_LIBS[*]}")" "$(prefix_map_flags | shasum -a 256 | cut -c1-16)" \
        "$(recipe_sha build_boost prepare_boost_src)"
}

min_flag() {
    case "$1" in
        ios-arm64) echo "-mios-version-min=${IOS_MIN}" ;;
        ios-arm64-simulator) echo "-mios-simulator-version-min=${IOS_MIN}" ;;
    esac
}

build_openssl() {
    local slice="$1" prefix="${IOS_DEPS}/$1/openssl"
    local src="${IOS_WORK}/openssl-$1" stage="${IOS_WORK}/openssl-stage-$1"
    local log="${IOS_LOGS}/openssl-$1.log"
    log "OpenSSL ${OPENSSL_VERSION} for ${slice} (static, iOS ${IOS_MIN}+)"
    rm -rf "$src" "$stage" "$prefix" && mkdir -p "$src" "$stage"
    tar xzf "${DL_DIR}/${OPENSSL_TARBALL}" -C "$src" --strip-components=1
    (
        cd "$src"
        # no-shared: static libcrypto/libssl only. OPENSSLDIR etc. point at a neutral
        # path (env.sh); files go through DESTDIR. No -ffile-prefix-map: OpenSSL
        # compiles with in-tree relative paths, and it records its configure command
        # line in libcrypto (OpenSSL_version(OPENSSL_CFLAGS)), so a prefix-map flag
        # would itself put the build machine's home directory into the library.
        offline ./Configure "$(slice_openssl_target "$slice")" \
            no-shared no-tests no-docs no-apps no-engine no-module \
            "$(min_flag "$slice")" \
            --prefix="$OPENSSL_NEUTRAL_PREFIX" --openssldir="${OPENSSL_NEUTRAL_PREFIX}/ssl" --libdir=lib \
            > "$log" 2>&1 || { tail -40 "$log"; exit 1; }
        offline make -j"$JOBS" build_libs >> "$log" 2>&1 || { tail -60 "$log"; exit 1; }
        offline make install_dev DESTDIR="$stage" >> "$log" 2>&1 || { tail -40 "$log"; exit 1; }
    )
    mkdir -p "$prefix"
    cp -R "${stage}${OPENSSL_NEUTRAL_PREFIX}/include" "${stage}${OPENSSL_NEUTRAL_PREFIX}/lib" "$prefix/"
    rm -rf "${prefix}/lib/pkgconfig" "${prefix}/lib/cmake"   # they name the neutral prefix; unused
    rm -rf "$src" "$stage"
    [[ -f "${prefix}/lib/libcrypto.a" && -f "${prefix}/lib/libssl.a" ]] || die "OpenSSL install incomplete for $slice"
}

# Boost: the host b2 is bootstrapped once per run, in a scratch copy of the sources.
BOOST_SRC="${IOS_WORK}/boost-src"
prepare_boost_src() {
    [[ -x "${BOOST_SRC}/b2" ]] && return 0
    log "extracting Boost ${BOOST_VERSION} (no docs/tests/examples) and bootstrapping b2 (host)"
    rm -rf "$BOOST_SRC" && mkdir -p "$BOOST_SRC"
    tar xjf "${DL_DIR}/${BOOST_TARBALL}" -C "$BOOST_SRC" --strip-components=1 \
        --exclude='boost_1_90_0/doc' --exclude='*/libs/*/doc' --exclude='*/libs/*/test' \
        --exclude='*/libs/*/example' --exclude='*/libs/*/examples' --exclude='*/libs/*/bench' \
        --exclude='*/libs/*/*/doc' --exclude='*/libs/*/*/test' --exclude='*/libs/*/*/example' \
        --exclude='*/tools/boostbook' --exclude='*/tools/quickbook' --exclude='*/tools/auto_index' \
        --exclude='*.html' --exclude='*.png' --exclude='*.svg' --exclude='*.pdf'
    (cd "$BOOST_SRC" && offline ./bootstrap.sh --without-icu > "${IOS_LOGS}/boost-bootstrap.log" 2>&1) \
        || { tail -30 "${IOS_LOGS}/boost-bootstrap.log"; die "Boost bootstrap failed"; }
}

build_boost() {
    local slice="$1" prefix="${IOS_DEPS}/$1/boost"
    local log="${IOS_LOGS}/boost-$slice.log"
    local cfg="${IOS_WORK}/user-config-$slice.jam"
    local sdk; sdk="$(slice_sdk_path "$slice")"
    local cxx; cxx="$(xcrun --sdk "$(slice_sdk "$slice")" -f clang++)"
    local ver; ver="cf$(echo "$slice" | tr -cd 'a-z0-9')"      # b2 toolset version: no dashes
    prepare_boost_src
    log "Boost ${BOOST_VERSION} for ${slice} (static, iOS ${IOS_MIN}+)"
    rm -rf "$prefix" "${IOS_WORK}/boost-build-$slice"
    # clang-darwin with an explicit -target and -isysroot: the compiler is the
    # SDK's clang++, the target triple names the platform (device or simulator),
    # so b2's own OS detection plays no part.
    local flags=(-target "$(slice_triple "$slice")" -isysroot "$sdk" $(prefix_map_flags))
    {
        printf 'using clang-darwin : %s : "%s"\n' "$ver" "$cxx"
        printf '  :\n'
        local f
        for f in "${flags[@]}"; do printf '    <compileflags>"%s"\n' "$f"; done
        printf '    <linkflags>"-target" <linkflags>"%s" <linkflags>"-isysroot" <linkflags>"%s"\n' "$(slice_triple "$slice")" "$sdk"
        printf '  ;\n'
    } > "$cfg"
    local withs=() l
    for l in "${IOS_BOOST_LIBS[@]}"; do withs+=("--with-${l}"); done
    (cd "$BOOST_SRC" && offline ./b2 -j"$JOBS" -d1 -q \
        --user-config="$cfg" --ignore-site-config \
        --build-dir="${IOS_WORK}/boost-build-$slice" \
        toolset="clang-darwin-${ver}" target-os=iphone \
        architecture=arm address-model=64 abi=aapcs binary-format=mach-o \
        link=static runtime-link=shared threading=multi variant=release cxxstd=17 \
        --disable-icu boost.locale.icu=off \
        "${withs[@]}" \
        --prefix="$prefix" --includedir="${prefix}/include" --libdir="${prefix}/lib" \
        install > "$log" 2>&1) || { grep -nE 'error|failed' "$log" | head -40; tail -30 "$log"; die "Boost build failed for $slice"; }
    rm -rf "${IOS_WORK}/boost-build-$slice" "$cfg"
    rm -rf "${prefix}/lib/cmake"   # BEAM's iOS path does not use them; they embed the build path
    for l in "${IOS_BOOST_LIBS[@]}"; do
        [[ -f "${prefix}/lib/libboost_${l}.a" ]] || die "Boost ${slice}: libboost_${l}.a missing"
    done
}

t0=$(date +%s)
# Never reuse sources extracted by an earlier (possibly interrupted) run.
rm -rf "${IOS_WORK:?}" && mkdir -p "$IOS_WORK"
up_to_date() {   # up_to_date <stamp file> <wanted content>
    [[ "${FORCE:-0}" != "1" && -f "$1" && "$(cat "$1")" == "$2" ]]
}
for slice in "${slices[@]}"; do
    dir="${IOS_DEPS}/${slice}"
    mkdir -p "$dir"
    rm -f "${dir}/.stamp"                       # written last, only when both are current
    want_o="$(openssl_stamp "$slice")"; want_b="$(boost_stamp "$slice")"
    if up_to_date "${dir}/.stamp-openssl" "$want_o"; then
        log "OpenSSL for ${slice} is up to date"
    else
        rm -f "${dir}/.stamp-openssl"; build_openssl "$slice"; printf '%s\n' "$want_o" > "${dir}/.stamp-openssl"
    fi
    if up_to_date "${dir}/.stamp-boost" "$want_b"; then
        log "Boost for ${slice} is up to date"
    else
        rm -f "${dir}/.stamp-boost"; build_boost "$slice"; printf '%s\n' "$want_b" > "${dir}/.stamp-boost"
    fi
    cat "${dir}/.stamp-openssl" "${dir}/.stamp-boost" > "${dir}/.stamp"
    log "deps for ${slice}: $(du -sh "$dir" | cut -f1) in ${dir}"
done
rm -rf "${IOS_WORK:?}"
t1=$(date +%s)
log "dependencies done in $((t1 - t0)) s"
