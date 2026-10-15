#!/usr/bin/env bash
# cspell:ignore libncurses
set -ueo pipefail
export PATH="$PYENV_ROOT/bin:$PATH"
export DEBIAN_FRONTEND='noninteractive'
apt-get update
apt-get install -y --no-install-recommends git curl libreadline-dev libsqlite3-dev less \
  libbz2-dev gcc g++ make zlib1g-dev libssl-dev libffi-dev liblzma-dev patch patchelf \
  libncurses5-dev libncursesw5-dev xz-utils pkg-config file fuse
rm -rf /var/lib/apt/lists/*
# Install pyenv
curl -sLm 11 \
  https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
pyenv install "${PYENV_VERSION_PYTHON}"
