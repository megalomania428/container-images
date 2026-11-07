#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
helper="$root/_shared/install/coding-seccomp.sh"
tmp=$(mktemp -d /tmp/coding-seccomp-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
printf '%s\n' '{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "extra": {"keep": true},
  "syscalls": [
    {"names": ["sethostname", "read", "setdomainname"], "action": "SCMP_ACT_ERRNO"},
    {"names": ["sethostname"], "action": "SCMP_ACT_ALLOW",
    "includes": {"caps": ["CAP_SYS_ADMIN"]}, "args": [{"index": 0}]},
    {"names": ["setdomainname", "write"], "action": "SCMP_ACT_ALLOW",
    "args": [{"index": 1, "value": 42, "op": "SCMP_CMP_EQ"}], "extra": 3},
    {"names": ["setdomainname"], "action": "SCMP_ACT_KILL"},
    {"names": ["setns"], "action": "SCMP_ACT_ALLOW"}
  ]
}' >"$tmp/input.json"
printf '%s\n' '{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "extra": {"keep": true},
  "syscalls": [
    {"names": ["read"], "action": "SCMP_ACT_ERRNO"},
    {"names": ["write"], "action": "SCMP_ACT_ALLOW",
    "args": [{"index": 1, "value": 42, "op": "SCMP_CMP_EQ"}], "extra": 3},
    {"names": ["setns"], "action": "SCMP_ACT_ALLOW"},
    {"names": ["sethostname", "setdomainname"], "action": "SCMP_ACT_ALLOW"}
  ]
}' >"$tmp/expected.json"
assert_equal() {
  jq -e -n --slurpfile actual "$1" --slurpfile expected "$2" \
    '$actual == $expected' >/dev/null
}
expect_failure() {
  if "$@" >"$tmp/failure.out" 2>"$tmp/failure.err"; then
    printf 'Expected failure: %s\n' "$*" >&2
    exit 1
  fi
  if [[ -s "$tmp/failure.out" ]]; then
    printf 'Unexpected output on failure: %s\n' "$*" >&2
    exit 1
  fi
}
bash "$helper" <"$tmp/input.json" >"$tmp/stdin.json"
assert_equal "$tmp/stdin.json" "$tmp/expected.json"
bash "$helper" "$tmp/input.json" >"$tmp/file.json"
assert_equal "$tmp/file.json" "$tmp/stdin.json"
bash "$helper" "$tmp/file.json" >"$tmp/twice.json"
assert_equal "$tmp/twice.json" "$tmp/file.json"
cp "$tmp/input.json" "$tmp/profile with spaces.json"
bash "$helper" "$tmp/profile with spaces.json" >"$tmp/spaces.json"
assert_equal "$tmp/spaces.json" "$tmp/file.json"
printf '%s\n' '{broken' >"$tmp/malformed.json"
: >"$tmp/empty.json"
printf '%s\n' '{} {}' >"$tmp/multiple.json"
printf '%s\n' '{"syscalls":[{"names":"read"}]}' >"$tmp/invalid.json"
expect_failure bash "$helper" "$tmp/malformed.json"
expect_failure bash "$helper" "$tmp/empty.json"
expect_failure bash "$helper" <"$tmp/empty.json"
expect_failure bash "$helper" "$tmp/multiple.json"
expect_failure bash "$helper" "$tmp/invalid.json"
expect_failure bash "$helper" "$tmp/missing.json"
expect_failure bash "$helper" "$tmp/input.json" "$tmp/input.json"
if [[ -f /usr/share/containers/seccomp.json ]]; then
  bash "$helper" /usr/share/containers/seccomp.json >"$tmp/real.json"
  bash "$helper" "$tmp/real.json" >"$tmp/real-twice.json"
  assert_equal "$tmp/real.json" "$tmp/real-twice.json"
  jq -e '[.syscalls[] | select(.names | index("sethostname") or index("setdomainname"))]
    == [{"names": ["sethostname", "setdomainname"], "action": "SCMP_ACT_ALLOW"}]' \
    "$tmp/real.json" >/dev/null
  jq -e -n --slurpfile input /usr/share/containers/seccomp.json \
    --slurpfile output "$tmp/real.json" '
      def without_uts:
        .syscalls |= (map(.names |= map(select(
          . != "sethostname" and . != "setdomainname")))
          | map(select(.names | length > 0)));
      ($input[0] | without_uts) == ($output[0] | without_uts)
    ' >/dev/null
  printf '%s\n' 'Real Podman profile: passed'
else
  printf '%s\n' 'Real Podman profile: skipped (not available)'
fi
printf '%s\n' 'Seccomp generator tests: passed'
