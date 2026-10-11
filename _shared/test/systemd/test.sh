#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2016
test_cont_name=$(
  /usr/bin/env mktemp -u |
    # workaround for "mktemp: Invalid argument" with busybox from alpine
    /usr/bin/env awk -F '.' '{ print "test-systemd-ubuntu-" $2 }'
)
/usr/bin/env podman run \
  -d --name "${test_cont_name}" --user root \
  "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}"
count=7
while ! /usr/bin/env podman exec "${test_cont_name}" systemctl status; do
  echo "waiting container ready, left [$count] tries"
  count=$((count - 1))
  if [[ $count -le 0 ]]; then
    echo 'container failed'
    break
  fi
  sleep 1
done
if [[ $count -gt 0 ]]; then
  echo 'test success'
  TEST_RESULT=0
else
  echo 'test failed'
  # shellcheck disable=2034
  TEST_RESULT=1
fi
/usr/bin/env podman rm -f "${test_cont_name}" |
  /usr/bin/awk '{print "container [" $0 "] destroyed"}'
