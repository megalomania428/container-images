#!/usr/bin/env bash
# cspell:ignore Bdeb Bdfsg cmake dfsg libutp msmtp rpavlik
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='000'
  SHARED_ASSETS=()
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  _snap='https://snapshot.debian.org/archive/debian'
  _upstream="sources/${TAG}/_shared/upstream"
  _downloads="sources/${TAG}/_shared/downloads"
  # Commit of the upstream tag 4.1.4, a moved tag fails the build
  _tr_commit='a6d907d9ea2313143af714d7830feb6c1b60b84c'
  # Debian packaging donor transmission 4.1.0~beta2+dfsg-3+deb13u2, the .dsc is signed
  # by B6E62F3D12AC38495C0DA90510C293B6C37C4E36 (checked once with debian-keyring)
  _tr_pool="${_snap}/20260904T145907Z/pool/main/t/transmission"
  _tr_deb_url="${_tr_pool}/transmission_4.1.0~beta2%2Bdfsg-3%2Bdeb13u2.debian.tar.xz"
  _tr_deb_sha='4358756595f9920a4588c53f11d3100801a1ae911e22eda9cf3590a10616e9af'
  # msmtp 1.8.28-3, the .dsc is signed by 4D0D537E8C37BC99DFF10B874B077723929D42C3
  # (checked once with debian-keyring)
  _ms_orig_url="${_snap}/20250118T085913Z/pool/main/m/msmtp/msmtp_1.8.28.orig.tar.xz"
  _ms_orig_sha='3a57f155f54e4860f7dd42138d9bea1af615b99dfab5ab4cd728fc8c09a647a4'
  _ms_deb_url="${_snap}/20250417T023536Z/pool/main/m/msmtp/msmtp_1.8.28-3.debian.tar.xz"
  _ms_deb_sha='4e5d1d60da59e1cf129c1417e9ede302def7d45acde3d4688e818f6f1a489abd'
  # Usage: _fetch_verified <url> <sha256> <file>
  # Cache only a verified download, any checksum mismatch fails the build.
  _fetch_verified() {
    local _url="$1" _sha="$2" _file="$3"
    if [[ ! -f "${_file}" ]]; then
      /usr/bin/env rm -f "${_file}.tmp"
      /usr/bin/env curl -fsSL -o "${_file}.tmp" "${_url}"
      if ! echo "${_sha}  ${_file}.tmp" | /usr/bin/env sha256sum -c; then
        /usr/bin/env rm -f "${_file}.tmp"
        return 1
      fi
      /usr/bin/env mv -f "${_file}.tmp" "${_file}"
    fi
    echo "${_sha}  ${_file}" | /usr/bin/env sha256sum -c
  }
  /usr/bin/env mkdir -p "${_upstream}" "${_downloads}"
  _fetch_verified "${_tr_deb_url}" "${_tr_deb_sha}" \
    "${_downloads}/transmission.debian.tar.xz"
  _fetch_verified "${_ms_orig_url}" "${_ms_orig_sha}" "${_downloads}/msmtp.orig.tar.xz"
  _fetch_verified "${_ms_deb_url}" "${_ms_deb_sha}" "${_downloads}/msmtp.debian.tar.xz"
  checkout_upstream 'https://github.com/transmission/transmission.git' '4.1.4' \
    "${_upstream}/transmission"
  _tr_head="$(/usr/bin/env git -C "${_upstream}/transmission" rev-parse 'HEAD^{commit}')"
  if [[ "${_tr_head}" != "${_tr_commit}" ]]; then
    echo "transmission 4.1.4 is ${_tr_head}, expected ${_tr_commit}" >&2
    exit 1
  fi
  /usr/bin/env git -C "${_upstream}/transmission" submodule update --init -- \
    third-party/dht third-party/libutp third-party/small third-party/wide-integer \
    third-party/rpavlik-cmake-modules
  /usr/bin/env rm -rf "${_upstream}/transmission/debian" "${_upstream}/msmtp"
  /usr/bin/env tar -xJf "${_downloads}/transmission.debian.tar.xz" \
    -C "${_upstream}/transmission"
  /usr/bin/env mkdir -p "${_upstream}/msmtp"
  /usr/bin/env tar -xJf "${_downloads}/msmtp.orig.tar.xz" --strip-components=1 \
    -C "${_upstream}/msmtp"
  /usr/bin/env tar -xJf "${_downloads}/msmtp.debian.tar.xz" -C "${_upstream}/msmtp"
  printf '%s\n' "TR_DEB_VER='4.1.4-1+p001'" "MSMTP_DEB_VER='1.8.28-3+p001'" \
    >"${_upstream}/versions.env"
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    /usr/bin/env patch -d "${_upstream}" -p1 --batch --forward --fuzz=0 <"${_patch}"
  done
  unset -f _fetch_verified
  unset _snap _upstream _downloads _patch _tr_pool _tr_deb_url _tr_deb_sha _ms_orig_url \
    _ms_orig_sha _ms_deb_url _ms_deb_sha _tr_commit _tr_head
fi
