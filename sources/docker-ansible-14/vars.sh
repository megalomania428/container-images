#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='003'
  DEPENDS='ansible-14/'
  IMAGE_TEST='../../_shared/test/systemd/test.sh'
  SHARED_ASSETS=(
    '_shared/install/docker.sh:_shared/install/docker.sh'
    '_shared/test/systemd/test.sh:_shared/test/systemd/test.sh'
  )
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
fi
