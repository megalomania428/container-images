#!/usr/bin/env bash
set -ueo pipefail
: "${DIR2CHECK:="."}"
: "${PATH2CONT:="/data"}"
: "${CONT_NAME:="linters-ansible-${USER}"}"
: "${ANSIBLENTRY:=""}"
: "${USE_GITIGNORE:=""}"
: "${USE_LINTIGNORE:=""}"
: "${IMAGE_NAME:="ghcr.io/megalomania428/ansible-11:003"}"
: "${PODMAN_ARGS:=""}"
DIR2CHECK="$(readlink -f "${DIR2CHECK}")"
export ANSIBLENTRY USE_GITIGNORE USE_LINTIGNORE PATH2CONT
# shellcheck disable=2086
/usr/bin/env podman run --rm -i -w "${PATH2CONT}" -e ANSIBLENTRY -e USE_GITIGNORE \
  -e USE_LINTIGNORE -e PATH2CONT --hostname="${CONT_NAME}" --name="${CONT_NAME}" \
  -v "${DIR2CHECK}:${PATH2CONT}:ro" ${PODMAN_ARGS} "${IMAGE_NAME}" /check-syntax.sh
