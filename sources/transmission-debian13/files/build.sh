#!/usr/bin/env bash
# cspell:ignore buildpackage devscripts fakeroot msmtp msmtpq
# cspell:ignore DEBFULLNAME DEBEMAIL newversion
# Builder stage: build patched transmission and msmtp packages.
set -ueo pipefail
export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null
source /build/versions.env
apt-get update
apt-get install -y --no-install-recommends build-essential devscripts dpkg-dev fakeroot
cd /build
apt-get build-dep -y --no-install-recommends ./transmission ./msmtp
export DEBFULLNAME='raven428' DEBEMAIL='raven428@gmail.com'
DEB_BUILD_OPTIONS="parallel=$(nproc)"
export DEB_BUILD_OPTIONS
cd /build/transmission
dch --newversion "${TR_DEB_VER}" --distribution trixie --force-distribution \
  'Rebuild of upstream 4.1.4 with raven428 patches.'
dpkg-buildpackage -b -uc -us
cd /build/msmtp
dch --newversion "${MSMTP_DEB_VER}" --distribution trixie --force-distribution \
  'Rebuild with flock based msmtpq queue lock.'
dpkg-buildpackage -b -uc -us
mkdir -p /build/debs
mv /build/transmission-cli_*.deb /build/transmission-common_*.deb \
  /build/transmission-daemon_*.deb /build/msmtp_*.deb /build/debs/
