#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=1091
source /etc/os-release
case "${ID}" in
ubuntu)
  docker_repo='https://download.docker.com/linux/ubuntu'
  docker_units=(systemd-resolved docker)
  ;;
debian)
  docker_repo='https://download.docker.com/linux/debian'
  docker_units=(docker)
  ;;
*)
  echo "unsupported distribution [${ID}]" >&2
  exit 66
  ;;
esac

# generic packages
apt-get update
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends systemd iproute2 python3-apt aptitude less \
  xz-utils python3-psutil python3-zstd python3-lz4 secure-delete openssh-server curl \
  ca-certificates xz-utils git

# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "${docker_repo}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  ${docker_repo} ${VERSION_CODENAME} stable" |
  tee /etc/apt/sources.list.d/docker.list >/dev/null
apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# image configuration
update-ca-certificates
systemctl enable "${docker_units[@]}"
systemctl disable systemd-networkd ssh

# docker 29 update working in podman
# TODO: investigate how to overlayfs replace DevSkim: ignore DS176209
/usr/bin/env cat <<EOF >'/etc/docker/daemon.json'
{
  "storage-driver": "vfs"
}
EOF

# Remove unnecessary getty and udev targets that result in high CPU usage when using
# multiple containers with Molecule (https://github.com/ansible/molecule/issues/1104)
rm -f /lib/systemd/system/systemd*udev* rm -f /lib/systemd/system/getty.target

# cleanup
rm -Rf /usr/share/doc /usr/share/man /var/lib/apt/lists/* /root/.cache/pip /files
