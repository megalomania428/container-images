#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='005'
  IMAGE_TEST='../../_shared/test/coding/test.sh'
  SHARED_ASSETS=(
    '_shared/install/systemd-docker/:_shared/install/systemd-docker'
    '_shared/install/coder.sh:_shared/install/coder.sh'
    '_shared/install/coding-seccomp.sh:_shared/install/coding-seccomp.sh'
    '_shared/test/coding/:_shared/test/coding'
    '_shared/install/profile.sh:_shared/install/profile.sh'
    '_shared/install/debian/13/podman.sh:_shared/podman.sh'
    '_shared/sudoers:_shared/sudoers'
  )
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  stage_profile "sources/${TAG}/_shared/profile-dmisu"
fi
