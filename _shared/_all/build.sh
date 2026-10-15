#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=1091
MY_BIN="$(readlink -f "$0")"
MY_PATH="$(dirname "${MY_BIN}")"
# shellcheck source=/dev/null
source "${MY_PATH}/vars.sh"
# shellcheck source=/dev/null
source "${MY_PATH}/../vars.sh"
INITIAL_PYENV_VERSION_PYTHON="${PYENV_VERSION_PYTHON}"
# shellcheck source=/dev/null
source "${MY_PATH}/../npm/lib.sh"
# Build, tag and test one image of the recipe: the main one or an EXTRA_IMAGES entry.
# Build args stay those of the main image, so stages before the target come from cache.
# Usage: _build_image <name> <stage or empty> <test relative to IMAGE_DIR or empty>
# shellcheck disable=2153
_build_image() {
  local _name="$1" _stage="$2" _test="$3" _main_tag="${TAG}" _dev_tag
  local lh_var='localhost' # DevSkim: ignore DS162092
  local -a _target_args=() _dev_tags=() _dev_build_args=()
  if [[ -n "${_stage}" ]]; then
    _target_args=(--target "${_stage}")
  fi
  # dev tags and the test read the image name from TAG
  TAG="${_name}"
  _set_dev_tag_args _dev_tags
  for _dev_tag in "${_dev_tags[@]+"${_dev_tags[@]}"}"; do
    _dev_build_args+=(-t "${_dev_tag}")
  done
  /usr/bin/env podman build \
    --network host \
    --build-arg TAG="${_main_tag}" \
    --build-arg PYENV_VERSION_PYTHON="${PYENV_VERSION_PYTHON}" \
    --build-arg PYENV_ROOT="${PYENV_ROOT}" \
    --cap-add=MAC_ADMIN,SYS_ADMIN \
    --security-opt apparmor=unconfined \
    -t "${lh_var}/${TAG}:local" \
    -t "${TARGET_REGISTRY}/${TAG}:latest" \
    -t "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}" \
    -t "${TARGET_REGISTRY}/${TAG}:${current_date}" \
    -t "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}-${current_date}" \
    "${_dev_build_args[@]+"${_dev_build_args[@]}"}" \
    "${_target_args[@]+"${_target_args[@]}"}" \
    "${PODMAN_EXTRA_ARGS[@]+"${PODMAN_EXTRA_ARGS[@]}"}" \
    "${BUILD_CONTEXT_DIR}"
  if [[ -n "${_test}" ]]; then
    unset TEST_RESULT
    # shellcheck source=/dev/null
    source "${IMAGE_DIR}/${_test}"
    if [[ ${TEST_RESULT:-1} -gt 0 ]]; then
      /usr/bin/env podman image rm -f \
        "${TARGET_REGISTRY}/${TAG}:latest" \
        "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}" \
        "${TARGET_REGISTRY}/${TAG}:${current_date}" \
        "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}-${current_date}" \
        "${_dev_tags[@]+"${_dev_tags[@]}"}"
      TOTAL_RESULT=$((TOTAL_RESULT + ${TEST_RESULT:-1}))
    fi
  fi
  TAG="${_main_tag}"
}
/usr/bin/env printf "\n———⟨ building: ⟩———\n"
TOTAL_RESULT=0
# shellcheck disable=2153
for IMAGE_DIR in "${IMAGES_DIRS[@]}"; do
  TAG=${IMAGE_DIR//sources\//}
  echo
  echo "building [${TAG}] from [${IMAGE_DIR}] dir…"
  DEPENDS=''
  PYENV_VERSION_PYTHON="${INITIAL_PYENV_VERSION_PYTHON}"
  BUILD_CONTEXT_DIR="${IMAGE_DIR}"
  PODMAN_EXTRA_ARGS=()
  NPM_PACKAGE=''
  NPM_CHECKS=()
  # stage of the main image, empty for the last one
  IMAGE_TARGET=''
  # more images of the same build: '<name>:<stage>[:<test relative to IMAGE_DIR>]'
  EXTRA_IMAGES=()
  # shellcheck source=/dev/null
  source "${IMAGE_DIR}/vars.sh"
  [[ -n "${DEPENDS}" ]] && {
    echo "found depends [${DEPENDS}] to build"
    BUILD_PYENV_VERSION_PYTHON="${PYENV_VERSION_PYTHON}" APPIMAGE_TARGET='' \
      MANUAL_IMAGES_DIRS="${DEPENDS}" ${MY_BIN}
    echo "returning to [${TAG}] building…"
  }
  if [[ -n "${NPM_PACKAGE}" ]]; then
    if ! _npm_build "${TAG}" "${NPM_CHECKS[@]+"${NPM_CHECKS[@]}"}"; then
      echo "npm build failed for [${TAG}]"
      TOTAL_RESULT=$((TOTAL_RESULT + 1))
    fi
    unset IMAGE_TEST
    continue
  fi
  _set_image_version
  current_date="$(/usr/bin/env date '+%Y%m%d')"
  _build_image "${TAG}" "${IMAGE_TARGET}" "${IMAGE_TEST:-}"
  for extra_image in "${EXTRA_IMAGES[@]+"${EXTRA_IMAGES[@]}"}"; do
    IFS=':' read -r extra_name extra_stage extra_test <<<"${extra_image}"
    _build_image "${extra_name}" "${extra_stage}" "${extra_test}"
  done
  unset IMAGE_TEST
done
exit "${TOTAL_RESULT}"
