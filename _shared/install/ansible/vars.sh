#!/usr/bin/env bash
# Shared recipe of sources/ansible-NN, sourced from their vars.sh: builds the ansible
# stage as ansible-NN and the docker stage as docker-ansible-NN from one Dockerfile.
set -ueo pipefail
# shellcheck disable=2034
{
  SHARED_ASSETS=(
    '_shared/install/ansible/:_shared'
    '_shared/sudoers:_shared/sudoers'
    '_shared/prepare2check.sh:_shared/prepare2check.sh'
    '_shared/install/docker.sh:_shared/docker.sh'
    '_shared/test/systemd/test.sh:_shared/test.sh'
  )
  IMAGE_TARGET='ansible'
  EXTRA_IMAGES=("docker-${TAG}:docker:../../_shared/test/systemd/test.sh")
}
BASE_IMAGE="${ANSIBLE_BASE_IMAGE}"
if [[ -z "${APPIMAGE_TARGET:-}" ]]; then
  # the podman repository has no packages for the AppImage Ubuntu release
  SHARED_ASSETS+=('podman.sh:_shared/podman.sh')
else
  BASE_IMAGE="${APPIMAGE_BASE_IMAGE}"
  # shellcheck disable=2034
  {
    IMAGE_TARGET='builder'
    EXTRA_IMAGES=()
  }
fi
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  # shellcheck disable=2034
  PODMAN_EXTRA_ARGS=(
    --file "sources/${TAG}/_shared/Dockerfile"
    --build-arg BASE_IMAGE="${BASE_IMAGE}"
  )
  if [[ -n "${APPIMAGE_TARGET:-}" ]]; then
    # keep tags of the real ansible-NN image intact
    TAG="${TAG}-appimage"
  fi
fi
