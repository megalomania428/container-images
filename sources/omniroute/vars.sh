#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='005'
  SHARED_ASSETS=()
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  _upstream="sources/${TAG}/_shared/upstream"
  checkout_upstream 'https://github.com/diegosouzapw/OmniRoute.git' \
    'v3.8.1' "${_upstream}"
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    patch -d "${_upstream}" -p1 <"${_patch}"
  done
  # shellcheck disable=2034
  BUILD_CONTEXT_DIR="${_upstream}"
  # shellcheck disable=2034
  PODMAN_EXTRA_ARGS=(--target runner-base)
  unset _patch _upstream
fi
