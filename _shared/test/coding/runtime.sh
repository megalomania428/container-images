#!/usr/bin/env bash
# cspell:ignore getaddrinfo urlopen
# shellcheck disable=SC2016,SC2317
set -ueo pipefail
unset CONTAINER_HOST CONTAINER_CONNECTION
# The root run keeps the sudo environment, so the root drop-in must supply the rest.
case "$(id -u)" in
1000)
  mode=coder
  export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/workspace/coder/config}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  : "${DBUS_SESSION_BUS_ADDRESS:=unix:path=${XDG_RUNTIME_DIR}/bus}"
  export DBUS_SESSION_BUS_ADDRESS
  ;;
0)
  mode=root
  ;;
*)
  echo 'run the suite as coder (UID 1000) or as root through sudo (UID 0)' >&2
  exit 1
  ;;
esac
for capability in cap_sys_admin cap_net_admin; do
  if capsh --has-b="${capability}" 2>/dev/null; then
    echo "unexpected outer capability: ${capability}" >&2
    exit 1
  fi
done
if [[ ${mode} == coder ]]; then
  systemctl --user is-active --quiet basic.target
else
  systemctl is-active --quiet user@0.service
fi
work="$(mktemp -d "${CODING_TEST_TMPDIR:-/tmp}/coding-tests.XXXXXX")"
engine=(podman --remote=false --root "${work}/graph" --runroot "${work}/run"
  --storage-driver=overlay --storage-opt=overlay.mount_program=/usr/bin/fuse-overlayfs)
suffix="${work##*.}"
suffix="${suffix,,}"
network="coding-net-${suffix}"
server="coding-server-${suffix}"
built_image="localhost/coding-build-${suffix}:test" # DevSkim: ignore DS162092
image='mirror.gcr.io/library/alpine:3'
server_image='mirror.gcr.io/library/python:3-slim'
passed=0
failed=0
skipped=0
cases=0
p() { "${engine[@]}" "$@"; }
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  p rm -af -t 0 >/dev/null 2>&1
  p network rm "${network}" >/dev/null 2>&1
  if [[ ${CODING_TEST_KEEP_LOGS:-0} == 1 || ${failed} -gt 0 ]]; then
    if ! clean_paths "${work}/graph" "${work}/run" "${work}/bind"; then
      result=1
    fi
    if [[ -n ${CODING_TEST_LOG_DIR:-} ]]; then
      if ! mkdir -p -- "${CODING_TEST_LOG_DIR}" ||
        ! cp -- "${work}"/*.log "${CODING_TEST_LOG_DIR}/"; then
        result=1
      fi
      echo "exported test logs: ${CODING_TEST_LOG_DIR}"
    fi
    echo "test logs: ${work}"
  elif ! clean_paths "${work}"; then
    echo "failed to clean test storage: ${work}" >&2
    result=1
  fi
  exit "${result}"
}
trap cleanup EXIT
clean_paths() {
  if [[ ${mode} == root ]]; then
    if mountpoint -q "${work}/graph/overlay"; then
      umount -R "${work}/graph/overlay" || return 1
    fi
    rm -rf -- "$@"
    return
  fi
  p unshare bash -ec '
    if mountpoint -q "$1/graph/overlay"; then
      umount -R "$1/graph/overlay"
    fi
    shift
    rm -rf -- "$@"
  ' bash "${work}" "$@"
}
run_case() {
  local name="$1" result
  shift
  cases=$((cases + 1))
  set +e
  (
    trap - EXIT
    set -e
    "$@"
  ) >"${work}/${name}.log" 2>&1
  result=$?
  set -e
  case "${result}" in
  0)
    passed=$((passed + 1))
    echo "PASS runtime[${mode}] ${cases}: ${name}"
    ;;
  77)
    skipped=$((skipped + 1))
    echo "SKIP runtime[${mode}] ${cases}: ${name}"
    cat "${work}/${name}.log"
    ;;
  *)
    failed=$((failed + 1))
    echo "FAIL runtime[${mode}] ${cases}: ${name} (exit ${result})"
    cat "${work}/${name}.log"
    ;;
  esac
}
require_device() {
  if [[ ! -e "$1" ]]; then
    echo "device unavailable: $1"
    [[ ${CODING_TEST_REQUIRE_DEVICES:-0} != 1 ]] && return 77
    return 1
  fi
}
test_proc() {
  p run --rm "${image}" sh -ec 'test "$(cat /proc/1/comm)" = sh; ps'
}
test_hostname() {
  p run --rm --hostname=coding-private "${image}" \
    sh -ec 'test "$(hostname)" = coding-private'
}
test_init() {
  p run --rm --init "${image}" sh -ec '
    case "$(cat /proc/1/comm)" in catatonit|podman-init) ;; *) exit 1 ;; esac'
}
test_none() {
  p run --rm --network=none "${image}" sh -ec 'test -z "$(ip route show default)"'
}
test_limits() {
  p run --rm --memory=128m --pids-limit=64 "${image}" sh -ec '
    test "$(cat /sys/fs/cgroup/memory.max)" = 134217728
    test "$(cat /sys/fs/cgroup/pids.max)" = 64'
}
# Network cases use Python: busybox wget ignores no_proxy and sends HTTPS to a proxy
# without CONNECT, while urllib takes the proxy variables Podman passes into containers.
test_pasta() {
  p run --rm -i --network=pasta "${server_image}" python - <<'PY'
import socket
import urllib.request
print(sorted({a[4][0] for a in socket.getaddrinfo('example.com', 443)}))
urllib.request.urlopen('https://example.com', timeout=30).read()
PY
}
test_network() { p network create "${network}"; }
test_server() {
  local publish_address=127.0.0.1::8000 # DevSkim: ignore DS162092
  p run -d --name "${server}" --network="${network}" --hostname=coding-server \
    --network-alias=coding-server -p "${publish_address}" "${server_image}" \
    python -m http.server 8000
}
# Succeeds only when the port accepts a TCP connection and sends not a single byte back
# to a complete HTTP request within five seconds.
port_silent() {
  local result=0
  rm -f "${work}/port-connected"
  timeout 5 bash -c '
    exec 3<>"/dev/tcp/${1%:*}/${1##*:}"
    : >"$2"
    printf "GET / HTTP/1.0\r\nHost: %s\r\n\r\n" "$1" >&3
    exec cat <&3
  ' bash "$1" "${work}/port-connected" >"${work}/port-response" || result=$?
  [[ ${result} -eq 124 && -e ${work}/port-connected && ! -s ${work}/port-response ]]
}
test_port() {
  local address result=0
  address="$(p port "${server}" 8000/tcp)"
  [[ ${address} == 127.0.0.1:* ]] # DevSkim: ignore DS162092
  if [[ ${mode} == coder ]]; then
    curl --retry 8 --retry-all-errors --retry-delay 1 --fail --silent --show-error \
      --output /dev/null "http://${address}/" # DevSkim: ignore DS137138
    return
  fi
  local url="http://${address}/" attempt other=0 silent=1 # DevSkim: ignore DS137138
  local sizes
  for attempt in 1 2 3 4 5 6 7 8 9; do
    result=0
    sizes="$(curl --max-time 5 --fail --silent --show-error --output /dev/null \
      --write-out '%{size_header} %{size_download}' "${url}")" || result=$?
    case "${result}" in
    0) return 0 ;;
    7) ;;
    28) [[ ${sizes} == '0 0' ]] && port_silent "${address}" || silent=0 ;;
    *) other=1 ;;
    esac
    [[ ${attempt} -eq 9 ]] || sleep 1
  done
  # The known timeout requires zero curl header/body bytes and a silent port after
  # every timed-out attempt, with no attempt failing for another reason.
  if [[ ${result} -ne 28 || ${other} -ne 0 || ${silent} -ne 1 ]]; then
    # curl exit code 77 must not be reported as a skipped case.
    [[ ${result} -ne 77 ]] || result=1
    return "${result}"
  fi
  echo 'bridge port forwarding of root podman without CAP_SYS_ADMIN'
  return 77
}
# The peer is reached directly, the proxy of the environment is kept for the rest.
test_peer() {
  local bypass="${no_proxy:-${NO_PROXY:-}}"
  bypass="${bypass:+${bypass},}coding-server"
  p run --rm -i --network="${network}" --env "no_proxy=${bypass}" \
    --env "NO_PROXY=${bypass}" "${server_image}" python - <<'PY'
import socket
import urllib.request
print(sorted({a[4][0] for a in socket.getaddrinfo('coding-server.dns.podman.', 8000)}))
peer = 'http://coding-server:8000/'  # DevSkim: ignore DS137138
urllib.request.urlopen(peer, timeout=30).read()
urllib.request.urlopen('https://example.com', timeout=30).read()
PY
}
test_bind() {
  mkdir -p "${work}/bind"
  p run --rm -v "${work}/bind:/work" "${image}" sh -ec '
    printf "bind-ok\n" > /work/result
    chown 23456:23456 /work/result'
}
# Prints the outer ID of container ID 23456 from the root range of the given file.
root_subordinate_id() {
  local name start count
  while IFS=: read -r name start count; do
    [[ ${name} == root ]] || continue
    if [[ ! ${start} =~ ^[0-9]+$ || ! ${count} =~ ^[0-9]+$ || ${count} -lt 23456 ]]; then
      echo "root range in $1 does not cover ID 23456: ${start}:${count}" >&2
      return 1
    fi
    echo $((start + 23456 - 1))
    return
  done <"$1"
  echo "no root range in $1" >&2
  return 1
}
test_owner() {
  local uid gid
  if [[ ${mode} == coder ]]; then
    p unshare bash -ec 'test "$(stat -c "%u:%g" "$1")" = 23456:23456' \
      bash "${work}/bind/result"
    return
  fi
  uid="$(root_subordinate_id /etc/subuid)"
  gid="$(root_subordinate_id /etc/subgid)"
  [[ $(stat -c %u:%g "${work}/bind/result") == "${uid}:${gid}" ]]
}
test_build() {
  p build --network=host -t "${built_image}" - <<'EOF'
FROM mirror.gcr.io/library/alpine:3
RUN mkdir /artifact && chown 23456:23456 /artifact
USER 23456:23456
RUN printf 'build-ok\n' > /artifact/result
CMD ["cat", "/artifact/result"]
EOF
}
test_built() { [[ $(p run --rm --pull=never "${built_image}") == build-ok ]]; }
test_kvm() {
  require_device /dev/kvm
  p run --rm -i --device=/dev/kvm --group-add=keep-groups "${server_image}" \
    python - <<'PY'
import fcntl
with open('/dev/kvm', 'rb+', buffering=0) as device:
  assert fcntl.ioctl(device, 0xAE00) == 12
print('KVM API=12')
PY
}
test_tun() {
  require_device /dev/net/tun
  p run --rm -i --network=pasta --cap-add=NET_ADMIN --device=/dev/net/tun \
    "${server_image}" python - <<'PY'
import fcntl
import struct
with open('/dev/net/tun', 'rb+', buffering=0) as device:
  result = fcntl.ioctl(device, 0x400454ca, struct.pack('16sH', b'coding0', 0x1001))
  assert result.split(b'\0', 1)[0] == b'coding0'
PY
}
test_mount() {
  local path result=0
  if [[ ${mode} == root ]]; then
    path="$(p image mount "${image}" 2>"${work}/image-mount.err")" || result=$?
    cat "${work}/image-mount.err"
    if [[ ${result} -ne 0 ]]; then
      if grep -qF \
        -e 'panic: runtime error: invalid memory address or nil pointer dereference' \
        -e 'cannot mount using driver overlay in rootless mode' \
        "${work}/image-mount.err"; then
        echo 'image mount is unavailable to root podman without CAP_SYS_ADMIN'
        return 77
      fi
      return "${result}"
    fi
    test -r "${path}/etc/alpine-release" || result=1
    p image unmount "${image}"
    return "${result}"
  fi
  p unshare bash -ec '
    args=(podman --remote=false --root "$1/graph" --runroot "$1/run"
      --storage-driver=overlay
      --storage-opt=overlay.mount_program=/usr/bin/fuse-overlayfs)
    image="$2"
    path="$("${args[@]}" image mount "${image}")"
    trap '\''"${args[@]}" image unmount "${image}"'\'' EXIT
    test -r "${path}/etc/alpine-release"
  ' bash "${work}" "${image}"
}
test_api() {
  local body
  "${engine[@]}" system service --time=0 "unix://${work}/api.sock" \
    >"${work}/api-server.log" 2>&1 &
  api_pid=$!
  trap 'kill "${api_pid}" 2>/dev/null || true; wait "${api_pid}" 2>/dev/null || true' EXIT
  for _ in 1 2 3 4 5; do
    [[ -S ${work}/api.sock ]] && break
    sleep 1
  done
  local api_url=http://localhost/_ping # DevSkim: ignore DS162092,DS137138
  body="$(curl --fail --silent --unix-socket "${work}/api.sock" "${api_url}")"
  [[ ${body} == OK ]]
  [[ $(cat "/proc/${api_pid}/comm") == podman ]]
}
test_bad_pid() {
  if p run --rm --pid=host --cgroups=disabled "${image}" true \
    >"${work}/bad-pid.log" 2>&1; then
    return 1
  fi
  grep -F 'must create a private PID namespace' "${work}/bad-pid.log"
}
test_bad_uts() {
  if p run --rm --uts=host --hostname=invalid "${image}" true \
    >"${work}/bad-uts.log" 2>&1; then
    return 1
  fi
  grep -F 'cannot set hostname' "${work}/bad-uts.log"
}
run_case own-proc test_proc
run_case private-hostname test_hostname
run_case init test_init
run_case network-none test_none
run_case resource-limits test_limits
run_case pasta-dns-https test_pasta
run_case bridge-create test_network
run_case bridge-server test_server
run_case published-port test_port
run_case bridge-peer-dns-http-https test_peer
run_case bind-write test_bind
run_case subordinate-owner test_owner
run_case oci-build test_build
run_case built-image test_built
run_case kvm test_kvm
run_case tun test_tun
run_case image-mount test_mount
run_case docker-api test_api
run_case incompatible-pid-rejected test_bad_pid
run_case incompatible-uts-rejected test_bad_uts
printf 'runtime[%s] tests: %s cases, %s passed, %s skipped, %s failed\n' \
  "${mode}" "${cases}" "${passed}" "${skipped}" "${failed}"
[[ ${failed} -eq 0 ]]
