#!/usr/bin/env bash
# Build wallet-api, beam-node and beam-wallet for Linux from tag beam-7.5.14493,
# with Campfire's patches (scripts/beam/core/patches), inside an ubuntu:22.04
# Docker container. Outputs: $BUILD_ROOT/out/linux-<arch>/.
#
# Usage: build_linux.sh [arm64|amd64 ...]      (default: arm64)
#   arm64 runs natively on Apple Silicon (colima aarch64 VM).
#   amd64 runs under Rosetta (colima --vz-rosetta) and is several times slower.
#
# Env: JOBS (default 4), BEAM_CORE_BUILD_ROOT (default ~/Desktop/Beam/beam-core-build)
#
# Docker objects are all prefixed `beamcore-` so they never collide with other work
# on the same Docker host:
#   images   beamcore-builder:ubuntu22.04-<arch>
#   volumes  beamcore-work-<arch>       (incremental build tree)
#   containers beamcore-build-<arch>    (removed on exit)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ARCHES=("$@"); [[ ${#ARCHES[@]} -gt 0 ]] || ARCHES=(arm64)
JOBS="${JOBS:-4}"
# ubuntu:22.04 per-platform manifests (index digest at time of pinning:
# sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401)
UBUNTU_2204_AMD64="ubuntu@sha256:08ea48a03a3e78ebc7cd526e6a275053223aadd88bfc09cc49b06d5281525fde"
UBUNTU_2204_ARM64="ubuntu@sha256:30dfd7fe96f97c5f5ddf388ce8d098aa509644ad68fdef67244fb71b8169ffcb"
BRANCH_LABEL="${BEAM_TAG}-campfire"

command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (colima start?)"

fetch_deps
prepare_source

ctx="${BUILD_ROOT}/deps/docker-context"
mkdir -p "$ctx"
cp "${CORE_SCRIPTS_DIR}/docker/Dockerfile" "$ctx/Dockerfile"
for f in "$BOOST_TARBALL" "$OPENSSL_TARBALL"; do
    # hard link (same file system) so the tarballs are not stored twice
    [[ -f "$ctx/$f" ]] || ln -f "${DL_DIR}/$f" "$ctx/$f" 2>/dev/null || cp "${DL_DIR}/$f" "$ctx/$f"
done

for arch in "${ARCHES[@]}"; do
    case "$arch" in arm64|aarch64) arch=arm64 ;; amd64|x86_64) arch=amd64 ;; *) die "unknown arch $arch" ;; esac
    image="beamcore-builder:ubuntu22.04-${arch}"
    # The per-platform manifest of ubuntu:22.04, by digest. With Docker's containerd
    # image store `ubuntu:22.04` is a multi-arch index and the legacy builder picks the
    # host's variant (arm64) for every --platform, then fails at COPY.
    case "$arch" in arm64) base="$UBUNTU_2204_ARM64" ;; amd64) base="$UBUNTU_2204_AMD64" ;; esac
    log "== linux/${arch}: builder image ${image} from ${base}"
    t0=$(date +%s)
    docker pull -q --platform "linux/${arch}" "$base" >/dev/null
    docker build --platform "linux/${arch}" --build-arg BASE_IMAGE="$base" -t "$image" "$ctx"
    t1=$(date +%s)
    log "image ready in $((t1 - t0)) s"

    mkdir -p "$OUT_ROOT"
    docker run --rm --name "beamcore-build-${arch}" --platform "linux/${arch}" \
        -e JOBS="$JOBS" -e BEAM_EXPECTED_VERSION="$BEAM_EXPECTED_VERSION" -e BRANCH_LABEL="$BRANCH_LABEL" \
        -v "${BEAM_SRC}:/src:ro" \
        -v "beamcore-work-${arch}:/work" \
        -v "${OUT_ROOT}:/out" \
        -v "${CORE_SCRIPTS_DIR}:/core:ro" \
        "$image" bash /core/docker/build_in_container.sh
    t2=$(date +%s)
    log "linux/${arch} binaries built in $((t2 - t1)) s (image $((t1 - t0)) s)"
done
