#!/usr/bin/env bash
# cspell:ignore gpath nullglob toplevel
set -ueo pipefail
# shellcheck disable=2034
PYENV_VERSION_PYTHON="${BUILD_PYENV_VERSION_PYTHON:-3.11.17}"
# shellcheck disable=2034
PYENV_ROOT='/pye'
# shellcheck disable=2034
ANSIBLE_BASE_IMAGE='mirror.gcr.io/ubuntu:24.04'
# shellcheck disable=2034
APPIMAGE_BASE_IMAGE='mirror.gcr.io/ubuntu:18.04'
# Directories of this file as sourced and as resolved, fixed when it is sourced, since
# the caller may change the current directory before calling checkout_upstream.
CHECKOUT_UPSTREAM_BASES=(
  "$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -L)"
  "$(dirname "$(/usr/bin/env realpath -- "${BASH_SOURCE[0]}")")"
)
# Usage: checkout_upstream <repo_url> <repo_tag> <upstream_dir>
# <upstream_dir> is reused only as the top level of its own clone with HEAD at a commit
# and no *.lock file left in its git directories. Anything else, like a clone interrupted
# before its .git appeared, before HEAD was written or with its locks left behind, is
# removed and cloned again, since git would find the enclosing repository there and
# reset and clean it instead, or keep failing on the leftovers at every run. A path that
# holds the current directory or this file, or any directory on the way to them through
# symlinks, is refused at once, since it holds the project that calls this function.
checkout_upstream() {
  local _repo_url="$1" _repo_tag="$2" _upstream="$3" _top='' _dir='' _git_dir=''
  local _common='' _lock='' _path='' _base='' _chain='' _real=''
  _path="$(/usr/bin/env realpath -m -- "${_upstream}")"
  for _base in . "${CHECKOUT_UPSTREAM_BASES[@]}"; do
    _chain="$(CDPATH='' cd -- "${_base}" 2>/dev/null && pwd -L)" || _chain=''
    while [[ -n "${_chain}" ]]; do
      _real="$(/usr/bin/env realpath -m -- "${_chain}")"
      [[ "${_real}/" != "${_path%/}/"* ]] || {
        echo "checkout_upstream: ${_upstream} holds ${_chain}, refusing" >&2
        return 66
      }
      _chain="${_chain%/*}"
    done
  done
  if [[ -e "${_upstream}/.git" ]] &&
    /usr/bin/env git -C "${_upstream}" rev-parse -q --verify 'HEAD^{commit}' \
      >/dev/null 2>&1; then
    _top="$(/usr/bin/env git -C "${_upstream}" rev-parse --show-toplevel 2>/dev/null)" ||
      _top=''
    _dir="$(CDPATH='' cd -- "${_upstream}" && pwd -P)" || _dir=''
    _git_dir="$(/usr/bin/env git -C "${_upstream}" rev-parse --absolute-git-dir \
      2>/dev/null)" || _git_dir=''
    _common="$(/usr/bin/env git -C "${_upstream}" rev-parse --path-format=absolute \
      --git-common-dir 2>/dev/null)" || _common=''
    _lock="$(/usr/bin/env find "${_git_dir}" "${_common}" -name '*.lock' -print -quit \
      2>/dev/null)" || _lock='unreadable'
  fi
  if [[ -n "${_top}" && "${_top}" == "${_dir}" && -n "${_git_dir}" &&
    -z "${_lock}" ]]; then
    /usr/bin/env git -C "${_upstream}" reset --hard HEAD
    /usr/bin/env git -C "${_upstream}" clean -fd
    /usr/bin/env git -C "${_upstream}" fetch --tags
    /usr/bin/env git -C "${_upstream}" checkout "${_repo_tag}"
    /usr/bin/env git -C "${_upstream}" reset --hard "${_repo_tag}"
  else
    /usr/bin/env rm -rf "${_upstream}"
    /usr/bin/env git clone "${_repo_url}" "${_upstream}"
    /usr/bin/env git -C "${_upstream}" checkout "${_repo_tag}"
  fi
}

# Clone the dotfiles repo into sources/${TAG}/_shared/profile-dmisu.
# Sources _shared/install/profile.sh then calls install_profile.
stage_profile() {
  local _dest="${1:-sources/${TAG:?}/_shared/profile-dmisu}"
  # shellcheck source=/dev/null
  source '_shared/install/profile.sh'
  install_profile "${_dest}"
}

# Expand a SHARED_ASSETS src field to a list of concrete filesystem paths.
# Reads from repo root. Prints one path per line on stdout.
# Paths are returned relative to repo root for diff-matching.
# - directories (src ending with /): prints the directory path itself
# - globs (src containing * or **): prints each matched path
# - regular files: prints the path as-is
_expand_asset_src() {
  local _src="$1"
  local _repo_root
  _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # strip leading ./
  _src="${_src#./}"
  # glob?
  if [[ "${_src}" == *'*'* ]]; then
    # shellcheck disable=2086
    (cd "${_repo_root}" && shopt -s nullglob globstar && printf '%s\n' ${_src})
    return
  fi
  # directory? (either trailing / or actual dir)
  if [[ "${_src}" == */ ]] || [[ -d "${_repo_root}/${_src%/}" ]]; then
    printf '%s\n' "${_src%/}"
    return
  fi
  # regular file
  printf '%s\n' "${_src}"
}

# Stage SHARED_ASSETS into sources/${TAG}/_shared/.
# Reads ${TAG} and ${SHARED_ASSETS[@]} from environment.
# Each entry: "src:dst"
# - src: path relative to repo root (any location)
# - dst: path relative to sources/${TAG}/ — MUST start with _shared/
# - if dst omitted, mirrors the src path (which must already start with _shared/)
# - src ending with / => recursive directory copy
# - src with glob => expanded and copied element-wise
stage_shared_assets() {
  local _tag="${TAG:?TAG must be set}"
  local _dest="sources/${_tag}"
  [[ -d "${_dest}" ]] || {
    echo "stage_shared_assets: destination dir ${_dest} not found" >&2
    return 66
  }
  # clean _shared once before first write
  local _shared_cleaned=0
  local _entry _src _dst _full_src _full_dst _repo_root
  _repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for _entry in "${SHARED_ASSETS[@]:-}"; do
    [[ -z "${_entry}" ]] && continue
    _src="${_entry%%:*}"
    _dst="${_entry#*:}"
    [[ "${_dst}" == "${_entry}" ]] && _dst=''
    # strip leading ./
    _src="${_src#./}"
    # default dst: mirror src path
    if [[ -z "${_dst}" ]]; then
      _dst="${_src%/}"
    fi
    # dst must stay inside _shared/ to not pollute sources/<image>/ directly
    if [[ "${_dst}" != _shared/* && "${_dst}" != _shared ]]; then
      echo "stage_shared_assets: dst '${_dst}' must start with _shared/" >&2
      return 66
    fi
    if [[ ${_shared_cleaned} -eq 0 ]]; then
      /usr/bin/env rm -rf "${_dest}/_shared"
      _shared_cleaned=1
    fi
    _full_dst="${_dest}/${_dst}"
    # ensure parent dir exists
    /usr/bin/env mkdir -p "$(/usr/bin/env dirname "${_full_dst}")"
    # glob handling
    if [[ "${_src}" == *'*'* ]]; then
      local _matched=0
      local _gpath
      while IFS= read -r _gpath; do
        [[ -z "${_gpath}" ]] && continue
        _matched=1
        if [[ -d "${_gpath}" ]]; then
          /usr/bin/env cp -rf "${_gpath}" "${_full_dst%/}/"
        elif [[ -f "${_gpath}" ]]; then
          /usr/bin/env cp -f "${_gpath}" "${_full_dst}"
        fi
      done < <(
        # shellcheck disable=2086
        cd "${_repo_root}" && shopt -s nullglob globstar && printf '%s\n' ${_src}
      )
      if [[ ${_matched} -eq 0 ]]; then
        echo "stage_shared_assets: glob '${_src}' matched nothing" >&2
        return 66
      fi
      continue
    fi
    _full_src="${_repo_root}/${_src%/}"
    if [[ ! -e "${_full_src}" ]]; then
      echo "stage_shared_assets: source '${_full_src}' not found" >&2
      return 66
    fi
    if [[ -d "${_full_src}" ]]; then
      /usr/bin/env mkdir -p "${_full_dst}"
      /usr/bin/env cp -rf "${_full_src}/." "${_full_dst}/"
    else
      /usr/bin/env cp -f "${_full_src}" "${_full_dst}"
    fi
  done
}
