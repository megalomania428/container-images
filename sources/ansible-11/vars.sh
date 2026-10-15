#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='005'
  APP_IMAGE=1
}
# shellcheck source=/dev/null
source '_shared/install/ansible/vars.sh'
