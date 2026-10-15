#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=1091
MY_BIN="$(readlink -f "$0")"
MY_PATH="$(dirname "${MY_BIN}")"
# shellcheck source=/dev/null
source "${MY_PATH}/vars.sh"
# shellcheck source=/dev/null
source "${MY_PATH}/../vars.sh"
# shellcheck source=/dev/null
source "${MY_PATH}/../npm/lib.sh"
# Push every tag of one image of the recipe, then remove the tags locally.
# Usage: _push_image <name>
# shellcheck disable=2153
_push_image() {
  local _main_tag="${TAG}" _dev_image
  local -a _dev_tags=()
  # dev tags read the image name from TAG
  TAG="$1"
  _set_dev_tag_args _dev_tags
  if [[ "${IMAGE_VER}" != "999" ]]; then
    /usr/bin/env podman push "${TARGET_REGISTRY}/${TAG}:latest"
    /usr/bin/env podman push "${TARGET_REGISTRY}/${TAG}:${current_date}"
  fi
  /usr/bin/env podman push "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}"
  /usr/bin/env podman push "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}-${current_date}"
  for _dev_image in "${_dev_tags[@]+"${_dev_tags[@]}"}"; do
    /usr/bin/env podman push "${_dev_image}"
  done
  /usr/bin/env podman image rm -f \
    "${TARGET_REGISTRY}/${TAG}:latest" \
    "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}" \
    "${TARGET_REGISTRY}/${TAG}:${current_date}" \
    "${TARGET_REGISTRY}/${TAG}:${IMAGE_VER}-${current_date}" \
    "${_dev_tags[@]+"${_dev_tags[@]}"}"
  TAG="${_main_tag}"
}
/usr/bin/env printf "\n———⟨ pushing: ⟩———\n"
# shellcheck disable=2153
for IMAGE_DIR in "${IMAGES_DIRS[@]}"; do
  TAG=${IMAGE_DIR//sources\//}
  echo
  echo "pushing [${TAG}] from [${IMAGE_DIR}] dir…"
  NPM_PACKAGE=''
  EXTRA_IMAGES=()
  # shellcheck disable=2034
  PUSHING=1
  # shellcheck source=/dev/null
  source "${IMAGE_DIR}/vars.sh"
  if [[ -n "${NPM_PACKAGE}" ]]; then
    _npm_push "${TAG}"
    continue
  fi
  _set_image_version
  current_date="$(/usr/bin/env date '+%Y%m%d')"
  _push_image "${TAG}"
  for extra_image in "${EXTRA_IMAGES[@]+"${EXTRA_IMAGES[@]}"}"; do
    _push_image "${extra_image%%:*}"
  done
done
