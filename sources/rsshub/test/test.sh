#!/usr/bin/env bash
# shellcheck disable=SC2034
# Sourced by _shared/_all/build.sh: the smoke test of the image runs in a child shell.
if bash "${IMAGE_DIR}/test/smoke.sh" "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}"; then
  TEST_RESULT=0
else
  TEST_RESULT=1
fi
