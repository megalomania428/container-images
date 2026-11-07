#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317
set -ueo pipefail
unset CONTAINER_HOST CONTAINER_CONNECTION
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/workspace/coder/config}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=${XDG_RUNTIME_DIR}/bus}"
export DBUS_SESSION_BUS_ADDRESS
[[ $(id -u) -eq 1000 ]] || {
  echo 'run the suite as coder (UID 1000)' >&2
  exit 1
}
for capability in cap_sys_admin cap_net_admin; do
  if capsh --has-b="${capability}" 2>/dev/null; then
    echo "unexpected outer capability: ${capability}" >&2
    exit 1
  fi
done
systemctl --user is-active --quiet basic.target
work="$(mktemp -d "${CODING_TEST_TMPDIR:-/tmp}/coding-tests.XXXXXX")"
engine=(podman --remote=false --root "${work}/graph" --runroot "${work}/run"
  --storage-driver=overlay --storage-opt=overlay.mount_program=/usr/bin/fuse-overlayfs)
suffix="${work##*.}"
suffix="${suffix,,}"
network="coding-net-${suffix}"
server="coding-server-${suffix}"
built_image="localhost/coding-build-${suffix}:test" # DevSkim: ignore DS162092
image='mirror.gcr.io/library/alpine:3'
server_image='mirror.gcr.io/library/python:3-alpine'
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
    echo "PASS runtime ${cases}: ${name}"
    ;;
  77)
    skipped=$((skipped + 1))
    echo "SKIP runtime ${cases}: ${name}"
    cat "${work}/${name}.log"
    ;;
  *)
    failed=$((failed + 1))
    echo "FAIL runtime ${cases}: ${name} (exit ${result})"
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
test_pasta() {
  p run --rm --network=pasta "${image}" \
    sh -ec 'nslookup example.com; wget -qO /dev/null https://example.com'
}
test_network() { p network create "${network}"; }
test_server() {
  local publish_address=127.0.0.1::8000 # DevSkim: ignore DS162092
  p run -d --name "${server}" --network="${network}" --hostname=coding-server \
    --network-alias=coding-server -p "${publish_address}" "${server_image}" \
    python -m http.server 8000
}
test_port() {
  local address
  address="$(p port "${server}" 8000/tcp)"
  [[ ${address} == 127.0.0.1:* ]] # DevSkim: ignore DS162092
  curl --retry 8 --retry-all-errors --retry-delay 1 --fail --silent --show-error \
    --output /dev/null "http://${address}/" # DevSkim: ignore DS137138
}
test_peer() {
  p run --rm --network="${network}" "${image}" sh -ec '
    nslookup coding-server.dns.podman.
    wget -qO /dev/null http://coding-server:8000/ # DevSkim: ignore DS137138
    wget -qO /dev/null https://example.com'
}
test_bind() {
  mkdir -p "${work}/bind"
  p run --rm -v "${work}/bind:/work" "${image}" sh -ec '
    printf "bind-ok\n" > /work/result
    chown 23456:23456 /work/result'
}
test_owner() {
  p unshare bash -ec 'test "$(stat -c "%u:%g" "$1")" = 23456:23456' \
    bash "${work}/bind/result"
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
printf 'runtime tests: %s cases, %s passed, %s skipped, %s failed\n' \
  "${cases}" "${passed}" "${skipped}" "${failed}"
[[ ${failed} -eq 0 ]]
