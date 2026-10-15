#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='001'
  SHARED_ASSETS=()
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  _upstream="sources/${TAG}/_shared/upstream"
  _repo_tag='v0.68.0'
  checkout_upstream 'https://github.com/Nikita-Filonov/ai-review.git' "${_repo_tag}" \
    "${_upstream}"
  # Patch 0001 rewrites the upstream Dockerfile to install from the local
  # (patched) source tree via `COPY . /app` + `pip install /app` instead of
  # the published PyPI wheel, so source patches under patches/ take effect.
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    patch -d "${_upstream}" -p1 <"${_patch}"
  done
  # shellcheck disable=2034
  BUILD_CONTEXT_DIR="${_upstream}"
  unset _patch _upstream _repo_tag
fi
# shellcheck disable=2034
PODMAN_EXTRA_ARGS=(--build-arg PYTHON_VERSION='3.11.17-slim-trixie')
