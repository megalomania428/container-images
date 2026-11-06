#!/usr/bin/env bash
# shellcheck disable=SC2034
# Sourced by _shared/_all/build.sh: the user session variables reach only the children.
_coding_dir="$(dirname -- "${BASH_SOURCE[0]}")"
_coding_run="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
_coding_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${_coding_run}/bus}"
if [[ ${GITHUB_ACTIONS:-} == 'true' ]] &&
  ! XDG_RUNTIME_DIR="${_coding_run}" DBUS_SESSION_BUS_ADDRESS="${_coding_bus}" \
    bash "${_coding_dir}/ci-host.sh"; then
  TEST_RESULT=1
elif XDG_RUNTIME_DIR="${_coding_run}" DBUS_SESSION_BUS_ADDRESS="${_coding_bus}" \
  bash "${_coding_dir}/outer.sh" "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}"; then
  TEST_RESULT=0
else
  TEST_RESULT=1
fi
unset _coding_dir _coding_run _coding_bus
