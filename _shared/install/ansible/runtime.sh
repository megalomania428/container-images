#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=SC1091
source /etc/os-release
case "${ID}" in
ubuntu)
  rm -f /etc/apt/sources.list.d/*
  _mirror='http://azure.archive.ubuntu.com/ubuntu' # DevSkim: ignore DS137138
  _components='main restricted universe multiverse'
  for _suite in '' '-updates' '-security'; do
    echo "deb ${_mirror} ${VERSION_CODENAME}${_suite} ${_components}"
  done >/etc/apt/sources.list
  ;;
esac
export DEBIAN_FRONTEND='noninteractive'
apt-get update
# shellcheck disable=SC1091
source /files/common.sh
[[ -e /files/podman.sh ]] && /files/podman.sh
add_pkg=''
[[ "${ID}" = 'ubuntu' && "${VERSION_ID%%.*}" -ge 24 ]] && add_pkg='systemd-resolved'
# shellcheck disable=2046
apt-get install -y --no-install-recommends bash sudo ssh-client apt-utils xz-utils less \
  ca-certificates rsync ${add_pkg} \
  $(python_runtime_packages)
