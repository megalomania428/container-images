#!/usr/bin/env bash
set -ueo pipefail
: "${TARGET_REGISTRY:=ghcr.io/megalomania428}"
: "${NPM_REGISTRY:=https://npm.pkg.github.com}"
: "${NPM_IMAGE:=ghcr.io/raven428/node-builder:latest}"
: "${NPM_REPO_URL:=git+https://github.com/megalomania428/container-images.git}"
MY_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${MY_PATH}/lib.sh"
# MANUAL_IMAGES_DIRS='docker-alpine/ systemd-ubuntu-22_04/' ./build.sh for manual build
: "${MANUAL_IMAGES_DIRS:=}"
/usr/bin/env printf "\n———⟨ environment: ⟩———\n"
set
/usr/bin/env which git >/dev/null ||
  if /usr/bin/env fgrep debian /etc/os-release; then
    export DEBIAN_FRONTEND=noninteractive
    /usr/bin/env apt-get update && /usr/bin/env apt-get install -y \
      --no-install-recommends git
  else
    /usr/bin/env apk update && /usr/bin/env apk add git
  fi

# shellcheck source=/dev/null
source "${MY_PATH}/../vars.sh"

if [[ "${MANUAL_IMAGES_DIRS}" != '' ]]; then
  IMAGES_DIRS=()
  declare -A manual_seen=()
  for dir in ${MANUAL_IMAGES_DIRS}; do
    while [[ "${dir}" == */ ]]; do dir="${dir%/}"; done
    dir="${dir#sources/}"
    # keep the first occurrence only: the order matters for DEPENDS builds
    [[ -n "${manual_seen[${dir}]:-}" ]] && continue
    manual_seen["${dir}"]=1
    IMAGES_DIRS+=("sources/${dir}")
  done
elif [[ "${GITHUB_EVENT_NAME:-${CI_PIPELINE_SOURCE:-}}" == 'schedule' ]]; then
  # cron: rebuild everything, no diff needed
  _fill_all_images
else
  diff="$(_diff_lines)"
  /usr/bin/env printf "\n———⟨ diff: ⟩———\n\
%s\n\n———⟨ images: ⟩———\n" "${diff}"
  # empty diff (e.g. initial push with null before-sha, or nothing outside
  # sources/) — fall back to rebuilding everything on the default branch only
  if [[ -z "${diff//[[:space:]]/}" ]]; then
    _fill_fallback_images
  elif /usr/bin/env printf '%s\n' "${diff}" |
    /usr/bin/env grep -qE '^(_shared/_all/|_shared/vars\.sh$)'; then
    # framework-level change: rebuild everything
    _fill_all_images
  else
    declare -A picked=()
    # direct hits under sources/<image>/, skipping sources removed by the diff
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      if [[ "${_line}" =~ ^sources/([^/]+)/ ]] &&
        [[ -f "sources/${BASH_REMATCH[1]}/vars.sh" ]]; then
        picked["sources/${BASH_REMATCH[1]}"]=1
      fi
    done <<<"${diff}"
    if /usr/bin/env printf '%s\n' "${diff}" | /usr/bin/env grep -qE '^_shared/npm/'; then
      _pick_npm_sources picked
    fi
    # transitive hits via SHARED_ASSETS: source each vars.sh with PUSHING set
    # so manifests expose metadata without changing the working tree
    for _dir in sources/*/; do
      [[ -f "${_dir}vars.sh" ]] || continue
      _image="${_dir%/}"
      [[ -n "${picked[${_image}]:-}" ]] && continue
      _assets="$(_probe_vars "${_image}" assets)"
      [[ -z "${_assets}" ]] && continue
      _hit=0
      while IFS= read -r _entry; do
        [[ -z "${_entry}" ]] && continue
        _entry_src="${_entry%%:*}"
        _entry_src="${_entry_src#./}"
        while IFS= read -r _expanded; do
          [[ -z "${_expanded}" ]] && continue
          # use bash string comparison to avoid regex special chars in paths
          while IFS= read -r _diff_line; do
            [[ -z "${_diff_line}" ]] && continue
            if [[ "${_diff_line}" == "${_expanded}" ]] ||
              [[ "${_diff_line}" == "${_expanded}/"* ]]; then
              _hit=1
              break 3
            fi
          done <<<"${diff}"
        done < <(_expand_asset_src "${_entry_src}")
      done <<<"${_assets}"
      [[ ${_hit} -eq 1 ]] && picked["${_image}"]=1
    done
    # if diff had changes but nothing matched any manifest, rebuild everything on
    # the default branch only (e.g. changes only in .github/ or removed sources)
    if [[ ${#picked[@]} -eq 0 ]]; then
      _fill_fallback_images
    else
      IMAGES_DIRS=()
      readarray -t IMAGES_DIRS < <(
        /usr/bin/env printf '%s\n' "${!picked[@]}" | /usr/bin/env sort
      )
    fi
  fi
fi

for IMAGE_DIR in "${IMAGES_DIRS[@]}"; do
  echo "image [${IMAGE_DIR}] to rebuild"
done
