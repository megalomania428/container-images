#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='002'
  SHARED_ASSETS=(
    '_shared/install/coder.sh:_shared/install/coder.sh'
    '_shared/install/profile.sh:_shared/install/profile.sh'
    '_shared/install/debian/13/podman.sh:_shared/podman.sh'
    '_shared/sudoers:_shared/sudoers'
  )
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  stage_profile "sources/${TAG}/_shared/profile-dmisu"
  # Patches under patches/ tweak the staged _shared tree (not an upstream
  # checkout): 0001 appends the opencode binary download to coder.sh so the
  # image ships /usr/local/bin/opencode.
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    patch -d "sources/${TAG}/_shared" -p1 <"${_patch}"
  done
  unset _patch
fi
