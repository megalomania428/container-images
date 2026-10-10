#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='001'
  IMAGE_TEST='../../_shared/test/systemd/test.sh'
  SHARED_ASSETS=(
    '_shared/install/systemd-docker/:_shared/install/systemd-docker'
    '_shared/test/systemd/test.sh:_shared/test/systemd/test.sh'
  )
}
if [[ -z "${PUSHING:-}" ]]; then
  stage_shared_assets
  _shared="sources/${TAG}/_shared"
  _rev_chicago95='6b6ef76c58e2078c913420278b5e17e0aa566374' # DevSkim: ignore DS173237
  _rev_redmond97='f33bc057a01f091de774adbbf6abe226f0cb46e0' # DevSkim: ignore DS173237
  _rev_pastel2k='9474c53abaf7f8e15ae3403eaa7c8fbb0539c8dc'  # DevSkim: ignore DS173237
  _rev_greymond='8c4e62604ac52965209d26040870503be3d62f3b'  # DevSkim: ignore DS173237
  checkout_upstream 'https://github.com/grassmunk/Chicago95.git' "${_rev_chicago95}" \
    "${_shared}/chicago95"
  checkout_upstream 'https://github.com/matthewmx86/Redmond97.git' "${_rev_redmond97}" \
    "${_shared}/redmond97"
  checkout_upstream 'https://github.com/faithvoid/Pastel2K.git' "${_rev_pastel2k}" \
    "${_shared}/pastel2k"
  checkout_upstream 'https://github.com/parhelion22/xfce-theme-greymond.git' \
    "${_rev_greymond}" "${_shared}/greymond"
  # shellcheck disable=2153
  for _patch in "${IMAGE_DIR}/patches/"*.patch; do
    [[ -f "${_patch}" ]] || continue
    echo "applying ${_patch}"
    patch -d "${_shared}/greymond" -p1 <"${_patch}"
  done
  # Redmond97 icon set is bundled in the Redmond97 repo under Extras/Icons/
  _icons_dst="${_shared}/user-config/.icons"
  /usr/bin/env mkdir -p "${_icons_dst}"
  /usr/bin/env cp -r \
    "${_shared}/redmond97/Extras/Icons/." \
    "${_icons_dst}/"
  unset _shared _rev_chicago95 _rev_redmond97 _rev_pastel2k _rev_greymond _icons_dst
fi
