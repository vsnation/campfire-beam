#!/usr/bin/env bash
# Build beam_core.dll for Windows x64: wallet-api and the integrated node in one
# shared library (src/beam_core.h). Not run on the maintainer's Mac: it runs in Git
# Bash on a windows-2022 GitHub runner (Visual Studio 2022), like ../build_windows.sh.
#
# Same pins as ../build_windows.sh: the source is the library's private clone
# ($BUILD_ROOT/lib/src: pinned commit + core series + ./patches), Boost and OpenSSL
# are the prebuilt libraries BEAM's own Windows release uses, each pinned to a commit
# (read from ../build_windows.sh, so there is one place to update them). Static CRT
# (/MT, BEAM_USE_STATIC_RUNTIME): the DLL needs no Visual C++ redistributable. Only
# the functions marked BEAM_CORE_API (__declspec(dllexport)) are exported; the
# import library beam_core.lib comes alongside.
#
# Output: $BEAM_CORE_BUILD_ROOT/out/lib-windows-x86_64/{beam_core.dll,beam_core.lib,
#         include/beam_core.h,SHA256SUMS,.source}
# Env: BEAM_CORE_BUILD_ROOT (keep it short: MSBuild paths get long), JOBS.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

[[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] || die "run this in Git Bash on Windows"
command -v cmake >/dev/null || die "cmake not found"
eval "$(grep -E '^(BOOST_PREBUILD_URL|BOOST_PREBUILD_BRANCH|BOOST_PREBUILD_COMMIT|BEAM_LIBS_URL|BEAM_LIBS_COMMIT)="[^"]*"$' "${CORE_SCRIPTS_DIR}/build_windows.sh")"
[[ -n "${BOOST_PREBUILD_COMMIT:-}" && -n "${BEAM_LIBS_COMMIT:-}" ]] || die "could not read the dependency pins from ../build_windows.sh"
JOBS="${JOBS:-4}"
OUT="${OUT_ROOT}/lib-windows-x86_64"
DEPS="${BUILD_ROOT}/deps-win"
BUILD="${BUILD_ROOT}/lb"

clone_pinned() {
    local url="$1" branch="$2" commit="$3" dir="$4"
    if [[ ! -d "$dir/.git" ]]; then
        log "cloning $url"
        if [[ -n "$branch" ]]; then git clone -q -b "$branch" "$url" "$dir"; else git clone -q "$url" "$dir"; fi
    fi
    git -C "$dir" checkout -q "$commit"
    [[ "$(git -C "$dir" rev-parse HEAD)" == "$commit" ]] || die "$url is not at $commit"
}

mkdir -p "$LIB_LOGS"
lib_prepare_source
clone_pinned "$BOOST_PREBUILD_URL" "$BOOST_PREBUILD_BRANCH" "$BOOST_PREBUILD_COMMIT" "$DEPS/boost"
clone_pinned "$BEAM_LIBS_URL" "" "$BEAM_LIBS_COMMIT" "$DEPS/libs"

win() { cygpath -w "$1"; }
rm -rf "$BUILD" && mkdir -p "$BUILD"
sources="$(lib_stage_sources "$BUILD")"
wsources="$(tr ';' '\n' <<< "$sources" | while read -r f; do cygpath -m "$f"; done | paste -sd ';' -)"
cmake_args=(
    -S "$(win "$LIB_SRC")" -B "$(win "$BUILD")"
    -G "Visual Studio 17 2022" -A x64
    "${LIB_BEAM_OPTIONS[@]}"
    -DBEAM_USE_STATIC_RUNTIME=On
    -DBEAM_BUILD_JNI=Off
    -DBEAM_CORE_LIBRARY_SOURCES="$wsources"
    -DBOOST_ROOT="$(win "$DEPS/boost")"
    -DOPENSSL_ROOT_DIR="$(win "$DEPS/libs/openssl")"
)
# MSVC treats C4996 ("strncpy may be unsafe") as an error under BEAM's /WX;
# the calls are bounded. Set through CL so no flag of BEAM's own is replaced
# and the macOS/Android/Linux builds stay byte-identical.
export CL="${CL:-} /D_CRT_SECURE_NO_WARNINGS"
log "configuring"
cmake "${cmake_args[@]}" > "${LIB_LOGS}/configure-windows.log" 2>&1 \
    || { tail -80 "${LIB_LOGS}/configure-windows.log"; die "cmake configure failed"; }
grep -E '^BEAM_VERSION:INTERNAL=' "$BUILD/CMakeCache.txt" >&2 || true
check_cmake_version "$BUILD"

start=$(date +%s)
cmake --build "$(win "$BUILD")" --config Release --target beam_core --parallel "$JOBS" > "${LIB_LOGS}/build-windows.log" 2>&1 \
    || { grep -E ' error |error C|error LNK|fatal' "${LIB_LOGS}/build-windows.log" | head -60; tail -40 "${LIB_LOGS}/build-windows.log"; die "build failed"; }
t1=$(date +%s)
log "built in $((t1 - start)) s"

rm -rf "$OUT" && mkdir -p "$OUT/include"
dll="$(find "$BUILD" -iname 'beam_core.dll' -path '*Release*' | head -1)"
implib="$(find "$BUILD" -iname 'beam_core.lib' -path '*Release*' | head -1)"
[[ -n "$dll" ]] || die "beam_core.dll not found"
cp "$dll" "$OUT/beam_core.dll"
[[ -n "$implib" ]] && cp "$implib" "$OUT/beam_core.lib"
install -m 0644 "${LIB_SCRIPTS_DIR}/src/beam_core.h" "$OUT/include/beam_core.h"
echo "$((t1 - start))" > "$OUT/.build_seconds"
lib_fingerprint "Visual Studio 2022 x64; boost ${BOOST_PREBUILD_COMMIT}; libs ${BEAM_LIBS_COMMIT}" > "$OUT/.source"
(cd "$OUT" && printf '%s  %s\n' "$(sha256_of beam_core.dll)" "lib-windows-x86_64/beam_core.dll") > "$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS" >&2

# Exports: exactly src/exports.txt (dumpbin from the VS toolchain, when on PATH).
if command -v dumpbin >/dev/null 2>&1; then
    got="$(dumpbin //exports "$(win "$OUT/beam_core.dll")" | awk '/ordinal hint RVA/{f=1; next} f && NF>=4 {print $4}' | sort)"
    want="$(sed '/^$/d' "${LIB_SCRIPTS_DIR}/src/exports.txt" | sort)"
    [[ "$got" == "$want" ]] || { diff <(echo "$want") <(echo "$got"); die "beam_core.dll exports differ from src/exports.txt"; }
    log "exports: exactly the $(wc -l <<< "$want" | tr -d ' ') functions of src/exports.txt"
    dumpbin //dependents "$(win "$OUT/beam_core.dll")" | grep -iE '\.dll$' >&2 || true
fi
"${LIB_SCRIPTS_DIR}/verify_lib.sh" --static "$OUT/beam_core.dll"
