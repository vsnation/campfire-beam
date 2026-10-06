# Builder image for the BEAM binaries Campfire ships on Linux.
#
# ubuntu:22.04 so the binaries need only glibc 2.35 (the same base BeamMW's own
# CI uses for the official Linux assets). 22.04's Boost 1.74 is older than the
# 1.83 BEAM requires, so Boost and OpenSSL are built here from pinned, verified
# source tarballs, static and -fPIC (Ubuntu's gcc links PIE by default).
#
# Built by scripts/beam/core/build_linux.sh, which stages the two tarballs into
# the build context after checking their SHA-256. Image tag: beamcore-builder:*.
# BASE_IMAGE is always pinned by digest, never a floating tag: build_linux.sh
# passes the per-platform ubuntu:22.04 manifest digest for the target arch.
# Naming the platform's own manifest matters: the classic builder otherwise
# reuses whatever platform the local ubuntu:22.04 tag points at (arm64 on Apple
# Silicon) and then fails the COPY platform check. The default below is the
# multi-arch index digest those per-platform digests were taken from, for a
# direct `docker build`.
ARG BASE_IMAGE=ubuntu@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401
FROM ${BASE_IMAGE}

ARG BOOST_TARBALL=boost_1_90_0.tar.bz2
ARG BOOST_SHA256=49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305
ARG BOOST_LIBS=filesystem,program_options,thread,regex,log,locale,date_time,context,coroutine,chrono,atomic,container,charconv
ARG OPENSSL_TARBALL=openssl-3.5.9.tar.gz
ARG OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake git perl python3 ca-certificates file lsof patch rsync procps binutils \
 && rm -rf /var/lib/apt/lists/*

COPY ${OPENSSL_TARBALL} ${BOOST_TARBALL} /tmp/deps/

RUN cd /tmp/deps \
 && echo "${OPENSSL_SHA256}  ${OPENSSL_TARBALL}" | sha256sum -c - \
 && tar xzf ${OPENSSL_TARBALL} && cd openssl-* \
 && ./Configure no-shared no-tests no-docs -fPIC --prefix=/opt/deps/openssl --libdir=lib \
 && make -j"$(nproc)" >/tmp/openssl-build.log 2>&1 || (tail -50 /tmp/openssl-build.log; exit 1) \
 && make install_sw >/dev/null \
 && cd /tmp/deps && rm -rf openssl-* \
 && /opt/deps/openssl/bin/openssl version

RUN cd /tmp/deps \
 && echo "${BOOST_SHA256}  ${BOOST_TARBALL}" | sha256sum -c - \
 && tar xjf ${BOOST_TARBALL} && cd boost_* \
 && ./bootstrap.sh --without-icu --with-libraries=${BOOST_LIBS} >/dev/null \
 && ./b2 -j"$(nproc)" -d0 link=static runtime-link=shared threading=multi variant=release \
      cxxflags=-fPIC cflags=-fPIC --disable-icu boost.locale.icu=off \
      --prefix=/opt/deps/boost install \
 && cd /tmp && rm -rf /tmp/deps \
 && ls /opt/deps/boost/lib

WORKDIR /work
