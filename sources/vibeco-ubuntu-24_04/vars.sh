#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='002'
  SHARED_ASSETS=(
    '_shared/install/coder.sh:_shared/install/coder.sh'
    '_shared/install/profile.sh:_shared/install/profile.sh'
    '_shared/sudoers:_shared/sudoers'
    'podman.sh:_shared/podman.sh'
  )
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  stage_profile "sources/${TAG}/_shared/profile-dmisu"
fi
