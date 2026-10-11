#!/usr/bin/env bash
_validate_version_suffix() {
  local _suffix="$1"
  if [[ ! "${_suffix}" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]]; then
    echo "invalid VERSION_SUFFIX '${_suffix}': expected dot-separated ASCII" \
      'letters, digits, or hyphens' >&2
    return 66
  fi
  local -a _identifiers
  local _identifier
  IFS='.' read -r -a _identifiers <<<"${_suffix}"
  for _identifier in "${_identifiers[@]}"; do
    if [[ "${_identifier}" =~ ^[0-9]+$ && "${_identifier}" == 0* &&
      "${_identifier}" != '0' ]]; then
      echo "invalid VERSION_SUFFIX '${_suffix}': numeric identifier" \
        "'${_identifier}' has a leading zero" >&2
      return 66
    fi
  done
}
_set_dev_tag_args() {
  local -n _dev_tag_args="$1"
  _dev_tag_args=()
  if [[ -n "${DEV_TAG}" ]]; then
    _dev_tag_args=("${TARGET_REGISTRY}/${TAG}:${DEV_TAG}")
  fi
}
# shellcheck disable=SC2034
_set_image_version() {
  case "${PUBLISH_MODE:-}" in
  dev | skip) printf -v IMAGE_VER '%s' '999' ;;
  esac
}
# Resolve diff lines for the current event. Honors MANUAL_DIFF for local runs.
_diff_lines() {
  if [[ -n "${MANUAL_DIFF:-}" ]]; then
    /usr/bin/env printf '%s\n' "${MANUAL_DIFF}"
    return
  fi
  local _before
  case "${GITHUB_EVENT_NAME:-${CI_PIPELINE_SOURCE:-}}" in
  push)
    _before="${GITHUB_EVENT_BEFORE:-${CI_COMMIT_BEFORE_SHA:-}}"
    # null SHA means first push to branch or force-push; fall back to HEAD^1
    if [[ -z "${_before}" ]] || [[ "${_before}" =~ ^0+$ ]]; then
      _before='HEAD^1'
    fi
    /usr/bin/env git diff --name-only \
      "${_before}" "${GITHUB_SHA:-${CI_COMMIT_SHA:-HEAD}}" 2>/dev/null || true
    ;;
  pull_request)
    /usr/bin/env git diff --name-only \
      "remotes/origin/${GITHUB_BASE_REF:-master}"...HEAD 2>/dev/null || true
    ;;
  merge_request_event)
    /usr/bin/env git diff --name-only \
      "remotes/origin/${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME}" \
      "remotes/origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}" 2>/dev/null || true
    ;;
  *)
    # local invocation: compare working tree to HEAD
    /usr/bin/env git diff --name-only HEAD 2>/dev/null || true
    ;;
  esac
}
# Fill IMAGES_DIRS with every directory under sources/ that has vars.sh.
_fill_all_images() {
  IMAGES_DIRS=()
  for _dir in sources/*/; do
    [[ -f "${_dir}vars.sh" ]] && IMAGES_DIRS+=("${_dir%/}")
  done
  return 0
}
# Fallback to every image only on the default branch; elsewhere build nothing.
_fill_fallback_images() {
  IMAGES_DIRS=()
  local _default="${DEFAULT_BRANCH:-${CI_DEFAULT_BRANCH:-master}}"
  local _ref="${GITHUB_REF:-refs/heads/${CI_COMMIT_BRANCH:-}}"
  if [[ "${_ref}" == "refs/heads/${_default}" ]]; then
    _fill_all_images
  else
    echo "fallback to all images is allowed only on [${_default}] branch, skipping"
  fi
}
# Source vars.sh without side effects and print the requested metadata.
_probe_vars() {
  local _image="$1" _field="$2"
  (
    # shellcheck disable=2034
    TAG="${_image#sources/}"
    # shellcheck disable=2034
    IMAGE_DIR="${_image}"
    # shellcheck disable=2034
    PUSHING=1
    # shellcheck disable=2034
    NPM_PACKAGE=''
    # shellcheck disable=2034
    APP_IMAGE=0
    SHARED_ASSETS=()
    # shellcheck disable=SC1091,SC1090
    source "${_image}/vars.sh" >/dev/null
    case "${_field}" in
    package) /usr/bin/env printf '%s' "${NPM_PACKAGE}" ;;
    assets) /usr/bin/env printf '%s\n' "${SHARED_ASSETS[@]:-}" ;;
    metadata)
      /usr/bin/env printf '%s|%s\n' "${NPM_PACKAGE}" "${APP_IMAGE}"
      ;;
    esac
  )
}
# Add every npm source to the associative array named by the first argument.
_pick_npm_sources() {
  local -n _picked="$1"
  local _dir _image _package
  for _dir in sources/*/; do
    [[ -f "${_dir}vars.sh" ]] || continue
    _image="${_dir%/}"
    _package="$(_probe_vars "${_image}" package)"
    [[ -n "${_package}" ]] && _picked["${_image}"]=1
  done
  return 0
}
DEV_TAG=''
if [[ -z "${PUBLISH_MODE:-}" && -z "${VERSION_SUFFIX:-}" ]]; then
  :
elif [[ -z "${PUBLISH_MODE:-}" || -z "${VERSION_SUFFIX:-}" ]]; then
  echo 'PUBLISH_MODE and VERSION_SUFFIX must both be set or both be empty:' \
    "PUBLISH_MODE='${PUBLISH_MODE:-}', VERSION_SUFFIX='${VERSION_SUFFIX:-}'" >&2
  (exit 66)
else
  _validate_version_suffix "${VERSION_SUFFIX}"
  case "${PUBLISH_MODE}" in
  dev | skip)
    DEV_TAG="dev.${VERSION_SUFFIX}"
    ;;
  release | schedule) ;;
  *)
    echo "invalid PUBLISH_MODE '${PUBLISH_MODE}': expected release, schedule," \
      'dev, or skip' >&2
    (exit 66)
    ;;
  esac
fi
