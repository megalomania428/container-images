#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='005'
  APP_IMAGE=1
  PYENV_VERSION_PYTHON='3.14.8'
}
# shellcheck source=/dev/null
source '_shared/install/ansible/vars.sh'
