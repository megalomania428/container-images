#!/usr/bin/env bash
# cspell:ignore atopacct oneshot postinst
set -ueo pipefail
# podman
/files/shared/podman.sh
# CODER_SYSTEMD=1: rootless podman image booted by systemd, legacy docker mode otherwise
coder_groups='sudo'
system_namespaces='utsns = "host"
cgroupns = "host"
cgroups = "disabled"'
cgroup_manager='cgroupfs'
user_namespaces='volumes = [
  "/proc:/proc",
]'
systemd_packages=()
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  coder_groups='root,sudo'
  system_namespaces='utsns = "private"
pidns = "private"
cgroups = "enabled"
cgroupns = "private"'
  cgroup_manager='systemd'
  user_namespaces='pidns = "private"
cgroups = "enabled"
cgroupns = "private"'
  systemd_packages=(catatonit aardvark-dns dbus-user-session libpam-systemd)
fi
# generic packages
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
  bash apt-utils apt-file ca-certificates ethtool bash-completion tcpdump less xxd \
  vim tmux screen curl wget rsync xz-utils pixz nmap atop htop traceroute sudo \
  whois iotop netcat-openbsd telnet bind9-utils bind9-host bind9-dnsutils gdisk p7zip \
  iftop nmon reptyr psmisc jq git bc lsof progress pv tree iproute2 net-tools \
  hostname dmidecode groff-base hdparm lshw iputils-ping iputils-arping locales \
  secure-delete moreutils less acl lz4 lzop lzma zstd unzip mtr-tiny patch ripgrep file \
  redis-tools mysqltuner mariadb-client postgresql-client nftables iptables \
  binutils bsdextrautils openssh-client fuse-overlayfs libcap2-bin squashfs-tools \
  squashfuse debootstrap xfsprogs qemu-system-x86 qemu-utils expect crun runc \
  "${systemd_packages[@]}"
apt-get upgrade -y
if command -v systemctl >/dev/null; then
  systemctl mask atopacct.service
fi
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  /files/shared/install/systemd-docker/protect-init.sh
  install -m 755 /files/shared/install/coding-seccomp.sh /usr/local/bin/coding-seccomp
  install -d -m 755 /usr/local/libexec/coding-tests
  install -m 755 /files/shared/test/coding/runtime.sh /usr/local/libexec/coding-tests/
  systemctl mask podman.service podman.socket \
    podman-auto-update.service podman-auto-update.timer podman-restart.service \
    podman-clean-transient.service
fi
cat >/etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
en_GB.UTF-8 UTF-8
EOF
locale-gen
pam_line='account sufficient pam_succeed_if.so uid = 0 use_uid quiet'
sed -i "/^auth[[:space:]]\+sufficient[[:space:]]\+pam_rootok\.so$/a ${pam_line}" \
  /etc/pam.d/su

# direct download
mkdir -vp /usr/local/bin
cd /usr/local/bin
curl --progress-bar -Lo kubectl "https://dl.k8s.io/release/$(curl -sL \
  https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -Lo yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
  --progress-bar
chmod -v 755 kubectl yq
curl -L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -L "https://github.com/fullstorydev/grpcurl/releases/download/v1.9.1/grpcurl\
_1.9.1_linux_amd64.deb" -o /files/grpcurl.deb && dpkg -i /files/grpcurl.deb

# image configuration
rm -Rf /root
mv -v /files/shared/profile-dmisu /root
# shellcheck disable=2016
find /root -type d -print0 | xargs chmod 755
find /root -type f -print0 | xargs chmod 644
update-ca-certificates
mv -vf /files/shared/sudoers /etc/sudoers
chmod 400 /etc/sudoers

# coder user (maps to host raven uid=1000)
# remove any existing user/group with uid/gid 1000
existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"
if [[ -n "${existing_user}" ]]; then
  userdel "${existing_user}"
fi
existing_group="$(getent group 1000 | cut -d: -f1 || true)"
if [[ -n "${existing_group}" ]]; then
  groupdel "${existing_group}"
fi
groupadd -g 1000 coder
useradd -u 1000 -g 1000 -s /bin/bash -d /home/coder coder
usermod -aG "${coder_groups}" coder
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  install -d -m 755 /etc/profile.d
  cat <<'EOF' >/etc/profile.d/coder-runtime.sh
case "$(id -u)" in
  1000)
    export XDG_RUNTIME_DIR='/run/user/1000'
    export DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/bus'
    ;;
esac
EOF
  chmod 644 /etc/profile.d/coder-runtime.sh
  install -d -m 755 /etc/coding
  cat <<'EOF' >/etc/coding/coder-runtime.env
XDG_CONFIG_HOME=/workspace/coder/config
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
EOF
  chmod 644 /etc/coding/coder-runtime.env
fi
mkdir -vp /workspace
chown coder:coder /workspace
# newuidmap/newgidmap: set capabilities instead of setuid (matches podman/stable)
chmod 0755 /usr/bin/newuidmap /usr/bin/newgidmap
setcap cap_setuid+ep /usr/bin/newuidmap
setcap cap_setgid+ep /usr/bin/newgidmap
# subuid/subgid: range visible inside outer container (uid 1..65536),
# with a hole at 1000 (coder's own uid)
printf 'root:1001:98998\ncoder:100000:899999\n' | tee /etc/subuid /etc/subgid
# system-wide containers.conf for nested podman
mkdir -vp /etc/containers
cat <<EOF >/etc/containers/containers.conf
[containers]
netns = "host"
userns = "host"
ipcns = "host"
${system_namespaces}
log_driver = "k8s-file"

[engine]
cgroup_manager = "${cgroup_manager}"
events_logger = "file"
runtime = "crun"
EOF
chmod 644 /etc/containers/containers.conf
# storage.conf: enable fuse-overlayfs and shared image store
cat <<'EOF' >/etc/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
[storage.options]
additionalimagestores = [
  "/var/lib/shared",
]
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
EOF
# shared image store dirs
mkdir -vp \
  /var/lib/shared/overlay-images \
  /var/lib/shared/overlay-layers \
  /var/lib/shared/vfs-images \
  /var/lib/shared/vfs-layers
touch \
  /var/lib/shared/overlay-images/images.lock \
  /var/lib/shared/overlay-layers/layers.lock \
  /var/lib/shared/vfs-images/images.lock \
  /var/lib/shared/vfs-layers/layers.lock
# per-user containers config for coder
mkdir -vp /home/coder/.cache /workspace/coder/config/containers /srv/data/podman/coder
cat <<EOF >/workspace/coder/config/containers/containers.conf
[containers]
${user_namespaces}
default_sysctls = []
EOF
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  install -d -m 755 /var/lib/systemd/linger
  touch /var/lib/systemd/linger/coder
  touch /var/lib/systemd/linger/root
  cat <<'EOF' >>/workspace/coder/config/containers/containers.conf
[engine]
cgroup_manager = "systemd"
EOF
fi
cat <<'EOF' >/workspace/coder/config/containers/storage.conf
[storage]
driver = "overlay"
graphRoot = "/srv/data/podman/coder"
EOF
chown -R coder:coder /home/coder /workspace/coder /srv/data/podman/coder
mkdir -vp /root/.config/containers
cp -v /workspace/coder/config/containers/containers.conf /root/.config/containers
# root podman: private IPC and the root user manager for netavark's aardvark-dns
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  install -d -m 755 /root/.config/containers/containers.conf.d
  cat <<'EOF' >/root/.config/containers/containers.conf.d/50-coding-root.conf
[containers]
ipcns = "private"
[engine]
env = [
  "XDG_RUNTIME_DIR=/run/user/0",
  "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus",
]
EOF
  chmod 644 /root/.config/containers/containers.conf.d/50-coding-root.conf
fi

# cleanup
apt-get clean
rm -Rf /usr/share/doc /usr/share/man /root/.cache/pip /files
# host identity: machine ID and SSH host keys live in the /var/lib/host-identity volume
if [[ "${CODER_SYSTEMD:-0}" == '1' ]]; then
  install -d -m 700 /var/lib/host-identity
  install -d -m 755 /etc/ssh/sshd_config.d
  cat <<'EOF' >/etc/ssh/sshd_config.d/10-host-identity.conf
HostKey /var/lib/host-identity/ssh_host_ed25519_key
HostKey /var/lib/host-identity/ssh_host_ecdsa_key
HostKey /var/lib/host-identity/ssh_host_rsa_key
EOF
  chmod 644 /etc/ssh/sshd_config.d/10-host-identity.conf
  install -d -m 755 /usr/local/libexec
  cat <<'EOF' >/usr/local/libexec/ssh-host-keys
#!/usr/bin/env bash
# Generates only the missing SSH host keys in the persistent host identity directory.
set -ueo pipefail
for type in ed25519 ecdsa rsa; do
  key="/var/lib/host-identity/ssh_host_${type}_key"
  if [[ ! -s "${key}" ]]; then
    rm -f -- "${key}" "${key}.pub"
    ssh-keygen -q -N '' -t "${type}" -f "${key}"
  fi
  # ssh-keygen and sshd refuse private keys readable by others
  chmod 600 "${key}"
  if [[ ! -s "${key}.pub" ]]; then
    ssh-keygen -y -f "${key}" >"${key}.pub"
  fi
  chmod 644 "${key}.pub"
done
EOF
  chmod 755 /usr/local/libexec/ssh-host-keys
  cat <<'EOF' >/etc/systemd/system/ssh-host-keys.service
[Unit]
Description=Generate missing SSH host keys in /var/lib/host-identity
# Before=ssh.socket would cycle through basic.target, Before=sshd@.service names only
# the instance sshd@ssh-host-keys.service, so sshd@.service orders itself in a drop-in
Before=ssh.service
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/ssh-host-keys
[Install]
WantedBy=ssh.service ssh.socket
EOF
  chmod 644 /etc/systemd/system/ssh-host-keys.service
  install -d -m 755 /etc/systemd/system/sshd@.service.d
  cat <<'EOF' >/etc/systemd/system/sshd@.service.d/10-host-identity.conf
[Unit]
Wants=ssh-host-keys.service
After=ssh-host-keys.service
EOF
  chmod 644 /etc/systemd/system/sshd@.service.d/10-host-identity.conf
  systemctl enable ssh-host-keys.service
  # last step after all apt operations: dbus postinst recreates its machine-id copy
  rm -f /etc/ssh/ssh_host_* /etc/machine-id /var/lib/dbus/machine-id
fi
