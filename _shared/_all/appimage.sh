#!/usr/bin/env bash
set -euo pipefail
# Builds AppImage for TAG in a podman container.
# Usage: TAG=ansible-11 ./_shared/_all/appimage.sh
#        TAG=texlive-myminimal ./_shared/_all/appimage.sh
: "${TAG:?TAG environment variable must be set (e.g., ansible-11)}"
echo "Building AppImage for ${TAG} in container…"
MY_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MY_PATH}/../vars.sh"
if [[ -f "sources/${TAG}/vars.sh" ]]; then
  # shellcheck disable=2034
  PUSHING=1
  # shellcheck source=/dev/null
  source "sources/${TAG}/vars.sh"
else
  IMAGE_VER="${IMAGE_VER:-000}"
fi
TARGET_REGISTRY="${TARGET_REGISTRY:-ghcr.io/megalomania428}"
mkdir -p appimage-output
# Select build image and inner script based on tag prefix
case "${TAG}" in
texlive-*)
  BUILD_IMAGE="${TARGET_REGISTRY}/${TAG}:latest"
  BUILD_SCRIPT='texlive-appimage.sh'
  ;;
*)
  BUILD_IMAGE="localhost/${TAG}-appimage:local" # DevSkim: ignore DS162092
  BUILD_SCRIPT='ansible/build-appimage.sh'
  ;;
esac
podman run --log-driver=none --rm --device /dev/fuse --cap-add SYS_ADMIN \
  -v "$PWD:/workspace:ro" -v "$PWD/appimage-output:/output:z" --workdir /workspace \
  -e TAG="${TAG}" -e IMAGE_VER="${IMAGE_VER}" \
  -e PYENV_VERSION_PYTHON="${PYENV_VERSION_PYTHON}" "${BUILD_IMAGE}" \
  bash "/workspace/_shared/install/${BUILD_SCRIPT}"
echo "AppImage built successfully: appimage-output/${TAG}-${IMAGE_VER}.AppImage"
