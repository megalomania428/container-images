#!/usr/bin/env bash
# cspell:ignore rsshub diygod
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='000'
  IMAGE_TEST='test/test.sh'
  SHARED_ASSETS=()
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  _upstream="sources/${TAG}/_shared/upstream"
  _rsshub_tag='v2026.11.17-8661.cf95739'
  # Commit of the upstream tag, a moved tag fails the build
  _rsshub_commit='cf957392f2d1a42085f182fca83caa6e7a293359' # DevSkim: ignore DS173237
  # The upstream Dockerfile copies .git into the image for the commit hash, so only the
  # tag is cloned instead of the whole history.
  CHECKOUT_UPSTREAM_DEPTH=1 checkout_upstream 'https://github.com/DIYgod/RSSHub.git' \
    "${_rsshub_tag}" "${_upstream}"
  _rsshub_head="$(/usr/bin/env git -C "${_upstream}" rev-parse 'HEAD^{commit}')"
  if [[ "${_rsshub_head}" != "${_rsshub_commit}" ]]; then
    echo "rsshub ${_rsshub_tag} is ${_rsshub_head}, expected ${_rsshub_commit}" >&2
    exit 1
  fi
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    patch -d "${_upstream}" -p1 <"${_patch}"
  done
  # shellcheck disable=2034
  BUILD_CONTEXT_DIR="${_upstream}"
  unset _patch _rsshub_commit _rsshub_head _rsshub_tag _upstream
fi
