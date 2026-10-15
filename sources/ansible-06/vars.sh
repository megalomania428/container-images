#!/usr/bin/env bash
set -ueo pipefail
# shellcheck disable=2034
{
  IMAGE_VER='005'
  APP_IMAGE=1
}
# shellcheck source=/dev/null
source '_shared/install/ansible/vars.sh'
# shellcheck disable=2153
if [[ -z "${PUSHING:-}" ]]; then
  /usr/bin/env cat "${IMAGE_DIR}/_shared/async-check.patch" |
    /usr/bin/env awk \
      '/^--- .+site-packages\/ansible\/plugins\/action\/__init__/ { exit } { print }' |
    /usr/bin/env sed -rz \
      's/\x0d\x0a/\x0a/g; s/\x0d/\x0a/g; s/[ \t]+\x0a/\x0a/g; s/\x0a*$/\x0a/g' \
      >"${IMAGE_DIR}/_shared/async-check-new.patch"
  /usr/bin/env mv -fv "${IMAGE_DIR}/_shared/async-check-new.patch" \
    "${IMAGE_DIR}/_shared/async-check.patch"
fi
