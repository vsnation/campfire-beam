#!/usr/bin/env bash
# Build libbeam_core.so for Linux (glibc 2.35+, x86_64 and/or arm64): wallet-api and
# the integrated node in one shared library (src/beam_core.h). Not run on the
# maintainer's Mac so far: it needs Docker; CI runs it (see the job in the report /
# .github/workflows/beam-core.yml).
#
#   scripts/beam/core/lib/build_lib_linux.sh [arm64|amd64 ...]     (default: arm64)
#
# Same container as ../build_linux.sh (the shipped executables): the builder image
# beamcore-builder:ubuntu22.04-<arch> from ../docker/Dockerfile on ubuntu:22.04
# pinned by digest (the digests are read from ../build_linux.sh, so there is one
# place to update them), with Boost 1.90 and OpenSSL 3.5.9 built from the pinned,
# SHA-256-checked tarballs, static and -fPIC. The source is the library's private
# clone ($BUILD_ROOT/lib/src: pinned commit + core series + ./patches), mounted
# read-only.
#
# Output: $BUILD_ROOT/out/lib-linux-<x86_64|aarch64>/libbeam_core.so (+ include/,
# SHA256SUMS, .source). SONAME libbeam_core.so, only beam_* exported (version
# script), libstdc++/libgcc linked statically, NEEDED: libc, libm, (libdl,
# libpthread on older glibc).
#
# Env: JOBS (default 4), BEAM_CORE_BUILD_ROOT.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

ARCHES=("$@"); [[ ${#ARCHES[@]} -gt 0 ]] || ARCHES=(arm64)
JOBS="${JOBS:-4}"
eval "$(grep -E '^UBUNTU_2204_(AMD64|ARM64)="ubuntu@sha256:[0-9a-f]{64}"$' "${CORE_SCRIPTS_DIR}/build_linux.sh")"
[[ -n "${UBUNTU_2204_AMD64:-}" && -n "${UBUNTU_2204_ARM64:-}" ]] || die "could not read the ubuntu:22.04 digests from ../build_linux.sh"

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (colima start?)"

fetch_deps
need_cmd git; need_cmd patch
mkdir -p "$LIB_LOGS"
lib_prepare_source

ctx="${BUILD_ROOT}/deps/docker-context"
mkdir -p "$ctx"
cp "${CORE_SCRIPTS_DIR}/docker/Dockerfile" "$ctx/Dockerfile"
for f in "$BOOST_TARBALL" "$OPENSSL_TARBALL"; do
    [[ -f "$ctx/$f" ]] || ln -f "${DL_DIR}/$f" "$ctx/$f" 2>/dev/null || cp "${DL_DIR}/$f" "$ctx/$f"
done

for arch in "${ARCHES[@]}"; do
    case "$arch" in arm64|aarch64) arch=arm64 ;; amd64|x86_64) arch=amd64 ;; *) die "unknown arch $arch" ;; esac
    image="beamcore-builder:ubuntu22.04-${arch}"
    case "$arch" in arm64) base="$UBUNTU_2204_ARM64"; mach=aarch64 ;; amd64) base="$UBUNTU_2204_AMD64"; mach=x86_64 ;; esac
    log "== linux/${arch}: builder image ${image}"
    docker pull -q --platform "linux/${arch}" "$base" >/dev/null
    docker build -q --platform "linux/${arch}" --build-arg BASE_IMAGE="$base" -t "$image" "$ctx" >/dev/null

    stage="${LIB_ROOT}/stage-linux-${arch}"
    rm -rf "$stage" && mkdir -p "$stage"
    for f in "${LIB_SOURCES[@]}" "${LIB_HEADERS[@]}" exports.txt; do cp "${LIB_SCRIPTS_DIR}/src/$f" "$stage/"; done
    lib_exports_elf "$stage/exports.txt" > "$stage/exports.map"
    cp "${LIB_SCRIPTS_DIR}/docker/build_lib_in_container.sh" "$stage/"
    mkdir -p "$OUT_ROOT"
    t0=$(date +%s)
    docker run --rm --name "beamcore-lib-${arch}" --platform "linux/${arch}" \
        -e JOBS="$JOBS" -e BEAM_EXPECTED_VERSION="$BEAM_EXPECTED_VERSION" -e BRANCH_LABEL="${BEAM_TAG}-campfire" \
        -v "${LIB_SRC}:/src:ro" \
        -v "${stage}:/campfire:ro" \
        -v "beamcore-libwork-${arch}:/work" \
        -v "${OUT_ROOT}:/out" \
        "$image" bash /campfire/build_lib_in_container.sh
    t1=$(date +%s)
    out="${OUT_ROOT}/lib-linux-${mach}"
    install -m 0644 "${LIB_SCRIPTS_DIR}/src/beam_core.h" "$out/include/beam_core.h" 2>/dev/null || { mkdir -p "$out/include"; install -m 0644 "${LIB_SCRIPTS_DIR}/src/beam_core.h" "$out/include/beam_core.h"; }
    echo "$((t1 - t0))" > "$out/.build_seconds"
    lib_fingerprint "$(docker image inspect -f '{{.Id}}' "$image") ${base}" > "$out/.source"
    (cd "$out" && printf '%s  %s\n' "$(sha256_of libbeam_core.so)" "lib-linux-${mach}/libbeam_core.so") > "$out/SHA256SUMS"
    cat "$out/SHA256SUMS" >&2
    rm -rf "$stage"
    "${LIB_SCRIPTS_DIR}/verify_lib.sh" --static "$out/libbeam_core.so"
done
