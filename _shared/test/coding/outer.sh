#!/usr/bin/env bash
# shellcheck disable=SC2016
# cspell:ignore readenv truename
set -ueo pipefail
[[ $# -eq 1 ]] || {
  echo "usage: $0 IMAGE" >&2
  exit 2
}
unset CONTAINER_HOST CONTAINER_CONNECTION
image="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
entrypoint="${script_dir}/../../install/systemd-docker/entrypoint.sh"
for tool in podman jq ssh-keyscan; do
  command -v "${tool}" >/dev/null || {
    echo "host ${tool} is required for the coding image suite" >&2
    exit 1
  }
done
host_info="$(podman info --format json)"
[[ $(jq -r '.host.security.rootless' <<<"${host_info}") == true ]] || {
  echo 'the coding image suite requires a rootless host Podman engine' >&2
  exit 1
}
[[ $(jq -r '.host.cgroupVersion' <<<"${host_info}") == v2 ]] || {
  echo 'cgroup v2 is required for the coding image suite' >&2
  exit 1
}
systemctl --user is-active --quiet basic.target || {
  echo 'a running user systemd manager is required: check linger, user@UID.service,' >&2
  echo 'XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS of the host user' >&2
  exit 1
}
if ! podman image inspect "${image}" | jq -e -f "${script_dir}/image.jq" >/dev/null; then
  echo 'image must default to root init and declare coder home/storage and' \
    'host identity volumes' >&2
  exit 1
fi
# The kernel accepts a nested range only inside one extent of the parent map, and the CI
# runner's map splits at container ID 65537: nested root gets a test-only range above
# coder's instead of the image's root:1001:98998, which crosses that split.
root_start=1000000
root_count=65536
last_id=$((root_start + root_count - 1))
for map in uid_map gid_map; do
  if ! podman unshare awk -v last="${last_id}" '
    { end = $1 + $3; if (end > maximum) maximum = end }
    END { exit maximum <= last }
  ' "/proc/self/${map}"; then
    echo "host rootless ${map} must cover container IDs through ${last_id}" >&2
    echo 'allocate enough host subuids/subgids before starting Podman' >&2
    exit 1
  fi
done
command -v crun >/dev/null || {
  echo 'host crun is required for keep-groups' >&2
  exit 1
}
[[ -r /dev/fuse && -w /dev/fuse ]] || {
  echo '/dev/fuse must be available to the host user' >&2
  exit 1
}
work="$(mktemp -d /tmp/coding-image-test.XXXXXX)"
suffix="${work##*.}"
container="coding-image-test-${suffix}"
home_volume="${container}-home"
store_volume="${container}-store"
identity_volume="${container}-identity"
fresh_identity_volume="${container}-identity-fresh"
root_store_volume="${container}-root-store"
persist_image="localhost/coding-persistence:${suffix}"   # DevSkim: ignore DS162092
root_image="localhost/coding-persistence-root:${suffix}" # DevSkim: ignore DS162092
runtime_logs="/tmp/coding-test-output-${suffix}"
runtime_started=0
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  podman logs "${container}" >"${work}/container.log" 2>&1
  if [[ ${runtime_started} -eq 1 &&
    (${result} -ne 0 || ${CODING_TEST_KEEP_LOGS:-0} == 1) ]]; then
    mkdir -p "${work}/runtime"
    if ! podman cp --archive=false "${container}:${runtime_logs}/." \
      "${work}/runtime"; then
      result=1
    fi
  fi
  if ! podman rm -f --volumes -t 0 "${container}" >/dev/null 2>&1; then
    result=1
  fi
  if ! podman volume rm -f "${home_volume}" "${store_volume}" "${identity_volume}" \
    "${fresh_identity_volume}" "${root_store_volume}" >/dev/null 2>&1; then
    result=1
  fi
  # the saved image may hold private keys and is never kept with the logs
  rm -rf -- "${work}/image" "${work}/layer.list"
  if [[ ${result} -eq 0 && ${CODING_TEST_KEEP_LOGS:-0} != 1 ]]; then
    rm -rf -- "${work}"
  else
    echo "outer test logs: ${work}"
    tail -n 50 "${work}/container.log"
  fi
  exit "${result}"
}
trap cleanup EXIT
outer_cases=0
pass_outer() {
  outer_cases=$((outer_cases + 1))
  echo "PASS outer ${outer_cases}: $*"
}
# Later layers only hide files of earlier ones: every layer of the saved image must be
# free of SSH host private keys and non-empty machine IDs.
podman image save --format docker-dir -o "${work}/image" "${image}" >/dev/null
layers="$(jq -r '.layers[].digest' "${work}/image/manifest.json")"
[[ -n ${layers} ]] || {
  echo 'saved image has no layers' >&2
  exit 1
}
while read -r layer; do
  tar -tvf "${work}/image/${layer#sha256:}" >"${work}/layer.list"
  if awk '
    { sub(/^\.\//, "", $6) }
    $6 ~ /^etc\/ssh\/ssh_host_[^\/]*_key$/ { found = 1 }
    $6 == "etc/machine-id" || $6 == "var/lib/dbus/machine-id" {
      # a hard link entry has size 0 but shares the content of its target
      if ($3 > 0 || substr($1, 1, 1) == "h") found = 1
    }
    END { exit !found }
  ' "${work}/layer.list"; then
    echo "image layer ${layer} ships SSH host keys or a machine ID" >&2
    exit 1
  fi
done <<<"${layers}"
rm -rf -- "${work}/image" "${work}/layer.list"
podman run --rm -i --user 0 --entrypoint /bin/bash "${image}" -ec '
  cat >/tmp/entrypoint.sh
  for path in /etc/machine-id /var/lib/dbus/machine-id; do
    if [[ -e ${path} || -L ${path} ]]; then
      echo "image ships ${path}" >&2
      exit 1
    fi
  done
  if compgen -G "/etc/ssh/ssh_host_*" >/dev/null; then
    echo "image ships SSH host keys" >&2
    exit 1
  fi
  units="$(mktemp -d)"
  printf "[Unit]\nRequires=basic.target\nAfter=basic.target\n" >"${units}/boot.target"
  mkdir "${units}/sockets.target.wants"
  ln -s /usr/lib/systemd/system/ssh.socket "${units}/sockets.target.wants/ssh.socket"
  verify="$(SYSTEMD_UNIT_PATH="${units}:" systemd-analyze verify --man=no \
    boot.target ssh.service 2>&1 || true)"
  if grep -i "ordering cycle" <<<"${verify}"; then
    echo "SSH host key generation forms an ordering cycle with ssh.socket" >&2
    exit 1
  fi
  rm -rf -- "${units}"
  init_path="$(dpkg-query -L systemd-sysv | grep -E "^(/usr)?/sbin/init$")"
  test "$(dpkg-divert --truename "${init_path}")" = "${init_path}.distrib"
  cmp /sbin/init /tmp/entrypoint.sh
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    --reinstall systemd-sysv >/dev/null
  test "$(dpkg-divert --truename "${init_path}")" = "${init_path}.distrib"
  cmp /sbin/init /tmp/entrypoint.sh' <"${entrypoint}"
pass_outer 'image without identity files or SSH unit cycles, init wrapper kept after' \
  'systemd-sysv reinstall'
profile="$(jq -r '.host.security.seccompProfilePath' <<<"${host_info}")"
[[ -r ${profile} ]] || {
  echo "cannot read host seccomp profile: ${profile}" >&2
  exit 1
}
podman --runtime=crun --cgroup-manager=systemd run --rm -i --user 0 \
  --entrypoint /usr/local/bin/coding-seccomp "${image}" \
  <"${profile}" >"${work}/seccomp.json"
for map in subuid subgid; do
  podman --runtime=crun --cgroup-manager=systemd run --rm --user 0 \
    --entrypoint /bin/sed "${image}" '/^root:/d' "/etc/${map}" >"${work}/${map}"
  echo "root:${root_start}:${root_count}" >>"${work}/${map}"
  chmod 644 "${work}/${map}"
done
bash "${script_dir}/session-env.sh" fixture >"${work}/session.env"
: >"${work}/session-empty.env"
chmod 644 "${work}/session.env" "${work}/session-empty.env"
devices=(--device=/dev/fuse)
for device in /dev/kvm /dev/net/tun; do
  if [[ -r ${device} && -w ${device} ]]; then
    devices+=(--device="${device}")
  else
    echo "host device unavailable: ${device}"
  fi
done
for volume in "${home_volume}" "${store_volume}" "${identity_volume}" \
  "${fresh_identity_volume}" "${root_store_volume}"; do
  podman volume create "${volume}" >/dev/null
done
journal_forwarded() {
  local marker="$1"
  podman exec "${container}" systemd-cat -t coding-test /bin/echo "${marker}"
  for _ in {1..10}; do
    if podman logs "${container}" 2>&1 | grep -F -- "${marker}" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "outer init journal forwarding failed: ${marker}" >&2
  return 1
}
# Starts the outer container with identity volume $1 and extra podman run options.
start_outer() {
  local identity="$1"
  local ready=0
  local publish_address=127.0.0.1::22 # DevSkim: ignore DS162092
  shift
  podman --runtime=crun --cgroup-manager=systemd run -d --name "${container}" \
    --hostname=coding-outer --network=pasta --ipc=private --publish "${publish_address}" \
    --cap-drop=SYS_ADMIN --cap-drop=NET_ADMIN --group-add=keep-groups \
    --security-opt='unmask=/proc/*' --security-opt="seccomp=${work}/seccomp.json" \
    --security-opt=apparmor=unconfined --volume /tmp --volume /var/log/journal \
    --volume "${home_volume}:/home/coder" \
    --volume "${store_volume}:/srv/data/podman/coder" \
    --volume "${root_store_volume}:/var/lib/containers" \
    --volume "${work}/subuid:/etc/subuid:ro" --volume "${work}/subgid:/etc/subgid:ro" \
    --volume "${identity}:/var/lib/host-identity" "${devices[@]}" "$@" "${image}"
  for _ in {1..60}; do
    if podman exec "${container}" systemctl is-active --quiet user@1000.service; then
      ready=1
      break
    fi
    sleep 1
  done
  [[ ${ready} -eq 1 ]] || {
    echo 'coder user manager did not start' >&2
    return 1
  }
  podman exec "${container}" timeout 60 systemctl is-system-running --wait
  journal_forwarded "coding-outer-journal-${container}"
}
ssh_port() {
  local address
  address="$(podman port "${container}" 22/tcp)"
  [[ ${address%:*} == 127.0.0.1 ]] || { # DevSkim: ignore DS162092
    echo "unexpected published SSH address: ${address}" >&2
    return 1
  }
  echo "${address##*:}"
}
# Prints the stored machine ID and the SHA256 fingerprints of the stored SSH host keys.
identity_state() {
  podman exec "${container}" bash -ec '
    set -o pipefail
    dir=/var/lib/host-identity
    id="$(cat "${dir}/machine-id")"
    [[ ${id} =~ ^[0-9a-f]{32}$ ]]
    test "$(stat -c %a "${dir}/machine-id")" = 444
    test "$(cat /etc/machine-id)" = "${id}"
    echo "${id}"
    for type in ed25519 ecdsa rsa; do
      test "$(stat -c %a "${dir}/ssh_host_${type}_key")" = 600
      ssh-keygen -lf "${dir}/ssh_host_${type}_key.pub" | cut -d " " -f 2
    done' || {
    echo 'host identity volume check failed' >&2
    return 1
  }
}
# The keys served on the published port must be exactly the keys stored in the volume.
ssh_keys_served() {
  local port scanned stored
  port="$(ssh_port)"
  local loopback=127.0.0.1 # DevSkim: ignore DS162092
  scanned="$(ssh-keyscan -T 5 -p "${port}" -t ed25519,ecdsa,rsa "${loopback}" \
    2>/dev/null | awk '$1 !~ /^#/ { print $2, $3 }' | sort)" || scanned=''
  stored="$(podman exec "${container}" sh -ec '
    cat /var/lib/host-identity/ssh_host_*_key.pub' | cut -d ' ' -f 1,2 | sort)" ||
    stored=''
  [[ $(wc -l <<<"${scanned}") -eq 3 && ${scanned} == "${stored}" ]] || {
    echo 'sshd does not serve the host keys stored in the identity volume' >&2
    return 1
  }
}
coder() {
  podman exec --user coder \
    --env XDG_CONFIG_HOME=/workspace/coder/config --env XDG_RUNTIME_DIR=/run/user/1000 \
    --env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    --env CODING_TEST_REQUIRE_DEVICES="${CODING_TEST_REQUIRE_DEVICES:-0}" \
    --env CODING_TEST_KEEP_LOGS="${CODING_TEST_KEEP_LOGS:-0}" \
    --env CODING_TEST_LOG_DIR="${runtime_logs}/coder" "${container}" "$@"
}
session_env() {
  podman exec "${container}" bash /run/coding-session-env.sh "$@"
}
session_env_setup() {
  podman exec -i "${container}" sh -ec 'cat >/run/coding-session-env.sh' \
    <"${script_dir}/session-env.sh"
  session_env prepare
}
# Saves the environments of all compared entry points under ${work}/session-env/$1.
session_snapshot() {
  local out="${work}/session-env/$1"
  session_env snapshot "$1"
  mkdir -p "${out}"
  podman exec "${container}" tar -C "/run/coding-session-env/snapshots/$1" -cf - . |
    tar -C "${out}" -xf -
  podman exec "${container}" env | bash "${script_dir}/session-env.sh" stable \
    >"${out}/exec-root"
  podman exec --user coder "${container}" env |
    bash "${script_dir}/session-env.sh" stable >"${out}/exec-coder"
}
start_outer "${identity_volume}"
pass_outer 'image boot, user manager and journal forwarding'
coder sudo bash -ec '
  for _ in {1..60}; do
    systemctl is-active --quiet user@0.service && break
    sleep 1
  done
  systemctl is-active --quiet user@0.service
  test -S /run/user/0/bus'
pass_outer 'root: user manager via linger'
podman exec "${container}" bash -ec '
  test "$(hostname)" = coding-outer
  test "$(cat /proc/1/comm)" = systemd
  test "$(systemctl --failed --no-legend --plain | wc -l)" = 0
  for unit in ssh.service sshd@probe.service; do
    for dep in Wants After; do
      systemctl show -P "${dep}" "${unit}" | tr " " "\n" |
        grep -qx ssh-host-keys.service || {
        echo "${unit} lacks ${dep}=ssh-host-keys.service" >&2
        exit 1
      }
    done
  done'
pass_outer 'hostname, systemd PID 1, no failed units, SSH units after host keys'
podman exec "${container}" journalctl --rotate
journal_forwarded "coding-outer-rotation-${container}"
pass_outer 'journal forwarding after rotation'
ssh_banner_port="$(ssh_port)"
exec {ssh_fd}<>"/dev/tcp/127.0.0.1/${ssh_banner_port}" # DevSkim: ignore DS162092
read -r -t 5 ssh_banner <&"${ssh_fd}"
exec {ssh_fd}>&-
[[ ${ssh_banner} == SSH-2.0-* ]] || {
  echo "unexpected outer SSH banner: ${ssh_banner}" >&2
  exit 1
}
pass_outer 'published SSH banner'
first_identity="$(identity_state)"
ssh_keys_served
pass_outer 'host identity created in its volume and served by sshd'
coder env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS sh -ec '
  . /etc/profile.d/coder-runtime.sh
  test "$XDG_RUNTIME_DIR" = /run/user/1000
  test "$DBUS_SESSION_BUS_ADDRESS" = unix:path=/run/user/1000/bus'
podman exec "${container}" env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS sh -ec '
  . /etc/profile.d/coder-runtime.sh
  test "${XDG_RUNTIME_DIR-unset}" = unset
  test "${DBUS_SESSION_BUS_ADDRESS-unset}" = unset'
coder env -u XDG_CONFIG_HOME -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS sh -ec '
  . /etc/coding/coder-runtime.env
  test "$XDG_CONFIG_HOME" = /workspace/coder/config
  test "$XDG_RUNTIME_DIR" = /run/user/1000
  test "$DBUS_SESSION_BUS_ADDRESS" = unix:path=/run/user/1000/bus'
pass_outer 'installed coder runtime environment and root separation'
coder sudo env >"${work}/sudo-env"
if grep -E '^(XDG_CONFIG_HOME|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)=' \
  "${work}/sudo-env"; then
  echo 'sudo keeps the coder session environment' >&2
  exit 1
fi
grep -qx 'HOME=/root' "${work}/sudo-env" || {
  echo 'sudo does not set HOME=/root' >&2
  exit 1
}
coder sudo test -f /root/.config/containers/containers.conf.d/50-coding-root.conf
coder sudo podman info --format json >/dev/null
pass_outer 'root: sudo environment and drop-in'
coder test -r /workspace/coder/config/containers/storage.conf
coder podman info --format json >"${work}/default-store.json"
# Podman 6 omits configFile; the effective settings must still match.
jq -e -f "${script_dir}/store.jq" "${work}/default-store.json" >/dev/null
coder bash -ec '
  printf "%s\n" "$1" > "$HOME/.coding-image-test"
  podman pull mirror.gcr.io/library/alpine:3
  podman tag mirror.gcr.io/library/alpine:3 "$2"
  podman run --rm --hostname=coding-default "$2" sh -ec '\''
    test "$(hostname)" = coding-default
    test "$(cat /proc/1/comm)" = sh
  '\''
' bash "${suffix}" "${persist_image}"
pass_outer 'installed default storage and configuration'
coder sudo podman info --format json >"${work}/root-store.json"
jq -e -f "${script_dir}/root-store.jq" "${work}/root-store.json" >/dev/null
coder sudo podman pull mirror.gcr.io/library/alpine:3
coder sudo podman tag mirror.gcr.io/library/alpine:3 "${root_image}"
coder sudo podman run --rm --hostname=coding-default-root "${root_image}" sh -ec '
  test "$(hostname)" = coding-default-root
  test "$(cat /proc/1/comm)" = sh'
pass_outer 'root: installed default storage and configuration'
root_limits="$(coder sudo podman run --rm --memory=128m --pids-limit=64 \
  mirror.gcr.io/library/alpine:3 \
  sh -ec 'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max')"
[[ ${root_limits} == $'134217728\n64' ]] || {
  echo "unexpected root memory and PID limits: ${root_limits}" >&2
  exit 1
}
pass_outer 'root: memory and PID limits (mqueue regression)'
outer_ipc="$(podman exec "${container}" readlink /proc/self/ns/ipc)"
root_ipc="$(coder sudo podman run --rm mirror.gcr.io/library/alpine:3 \
  readlink /proc/self/ns/ipc)"
coder_ipc="$(coder podman run --rm mirror.gcr.io/library/alpine:3 \
  readlink /proc/self/ns/ipc)"
[[ ${outer_ipc} == ipc:* && ${root_ipc} == ipc:* && ${root_ipc} != "${outer_ipc}" &&
  ${coder_ipc} == "${outer_ipc}" ]] || {
  echo "unexpected IPC namespaces: outer ${outer_ipc}, root ${root_ipc}," \
    "coder ${coder_ipc}" >&2
  exit 1
}
pass_outer 'root: private IPC for root, host IPC for coder'
session_env_setup
session_snapshot hook
session_env remove-hook
pass_outer 'session hook: /etc/pam.d differs from the removed hook only by its two lines'
session_snapshot plain
session_env restore-hook
session_env finish
diff -r -x journal "${work}/session-env/hook" "${work}/session-env/plain" || {
  echo 'the session hook changes login environments without a mounted file' >&2
  exit 1
}
pass_outer 'session hook: unchanged login environments without a mounted file'
diff "${work}/session-env/hook/journal" "${work}/session-env/plain/journal" || {
  echo 'the session hook changes PAM journal messages without a mounted file' >&2
  exit 1
}
if grep -F /etc/coding/session.env "${work}/session-env/hook/journal"; then
  echo 'PAM logs the session file without a mounted file' >&2
  exit 1
fi
pass_outer 'session hook: no new PAM journal messages without a mounted file'
# Readable private keys with missing or empty public keys must be repaired on restart.
podman exec "${container}" bash -ec '
  dir=/var/lib/host-identity
  chmod 644 "${dir}/ssh_host_ed25519_key" "${dir}/ssh_host_ecdsa_key"
  rm -f "${dir}/ssh_host_ed25519_key.pub"
  : >"${dir}/ssh_host_ecdsa_key.pub"'
podman rm -f --volumes -t 0 "${container}" >/dev/null
start_outer "${identity_volume}"
coder bash -ec '
  test "$(cat "$HOME/.coding-image-test")" = "$1"
  podman run --rm --pull=never "$2" true
' bash "${suffix}" "${persist_image}"
[[ $(identity_state) == "${first_identity}" ]] || {
  echo 'host identity changed after container re-creation' >&2
  exit 1
}
ssh_keys_served
pass_outer 'recreated image with persistent home, nested image storage and host identity'
coder sudo bash -ec '
  for _ in {1..60}; do
    systemctl is-active --quiet user@0.service && break
    sleep 1
  done
  systemctl is-active --quiet user@0.service'
coder sudo podman run --rm --pull=never "${root_image}" true
pass_outer 'root: nested image storage persists after re-creation'
podman rm -f --volumes -t 0 "${container}" >/dev/null
start_outer "${identity_volume}" --volume "${work}/session.env:/etc/coding/session.env:ro"
session_env_setup
session_env deliver "${root_image}"
pass_outer 'session hook: literal values in SSH, su, sudo, user managers and sudo podman'
session_env side-effects
for user in root coder; do
  if podman exec --user "${user}" "${container}" env | grep '^CODING_HOOK_'; then
    echo "podman exec as ${user} gets session file variables" >&2
    exit 1
  fi
done
pass_outer 'session hook: no file variables in PID 1, a system unit or podman exec'
session_env persist "${root_image}"
pass_outer 'session hook: kept after pam-auth-update and libpam-runtime reinstall'
session_env mutate "${root_image}"
pass_outer 'session hook: each delivery check fails with readenv=0 and without profile'
session_env priority
pass_outer 'session hook: priority against /etc/environment and /etc/default/locale'
session_env finish
podman rm -f --volumes -t 0 "${container}" >/dev/null
start_outer "${identity_volume}" \
  --volume "${work}/session-empty.env:/etc/coding/session.env:ro"
session_env_setup
session_snapshot empty
session_env finish
diff -r -x journal "${work}/session-env/hook" "${work}/session-env/empty" || {
  echo 'an empty mounted session file differs from no mounted file' >&2
  exit 1
}
pass_outer 'session hook: an empty mounted file equals no mounted file'
podman rm -f --volumes -t 0 "${container}" >/dev/null
start_outer "${fresh_identity_volume}"
fresh_identity="$(identity_state)"
ssh_keys_served
mapfile -t first_lines <<<"${first_identity}"
mapfile -t fresh_lines <<<"${fresh_identity}"
[[ ${#first_lines[@]} -eq 4 && ${#fresh_lines[@]} -eq 4 ]] || {
  echo 'unexpected host identity state' >&2
  exit 1
}
for index in 0 1 2 3; do
  [[ ${first_lines[index]} != "${fresh_lines[index]}" ]] || {
    echo "fresh host identity volume reused: ${first_lines[index]}" >&2
    exit 1
  }
done
pass_outer 'fresh host identity volume yields a new machine ID and SSH host keys'
runtime_started=1
runtime_result=0
coder /usr/local/libexec/coding-tests/runtime.sh || runtime_result=1
coder sudo env CODING_TEST_REQUIRE_DEVICES="${CODING_TEST_REQUIRE_DEVICES:-0}" \
  CODING_TEST_KEEP_LOGS="${CODING_TEST_KEEP_LOGS:-0}" \
  CODING_TEST_LOG_DIR="${runtime_logs}/root" \
  /usr/local/libexec/coding-tests/runtime.sh || runtime_result=1
[[ ${runtime_result} -eq 0 ]]
