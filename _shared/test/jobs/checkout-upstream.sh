#!/usr/bin/env bash
# cspell:ignore gitfile gpgsign mktree noprofile norc NOSYSTEM toplevel
# Tests for checkout_upstream of _shared/vars.sh. Every case runs the real function in
# a clean bash started by env -i inside a synthetic project repository, with a local
# origin instead of the network, and checks both the upstream directory and that the
# uncommitted work of the enclosing project survives.
set -ueo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d -t checkout-upstream-XXXXXX)"
ORIGIN="${WORK_DIR}/origin"
# URL passed to checkout_upstream; file:// makes git use its transport, not a local copy
ORIGIN_URL="file://${ORIGIN}"
# upstream directory relative to the project root, as sources/*/vars.sh pass it
UPSTREAM='sources/demo/_shared/upstream'
PASS=0
FAIL=0
CASE_NUM=0
CASE_DIR=''
CASE_RC=0
# project HEAD of the current case, set by new_case
PROJECT_HEAD=''
# commits of the origin tags, set by make_origin
TAG1=''
TAG2=''
cleanup() {
  local rc=$?
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}
# Run git without the user and system configuration and outside the real repository.
run_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_CEILING_DIRECTORIES="${WORK_DIR}" git \
    -c user.name=checkout-tests -c user.email=checkout-tests@example.invalid \
    -c commit.gpgsign=false -c init.defaultBranch=master "$@"
}
# Origin repository with the tags v1 and v2 on consecutive commits.
make_origin() {
  run_git init -q "${ORIGIN}"
  echo v1 >"${ORIGIN}/file"
  run_git -C "${ORIGIN}" add -A
  run_git -C "${ORIGIN}" commit -qm v1
  run_git -C "${ORIGIN}" tag v1
  echo v2 >"${ORIGIN}/file"
  run_git -C "${ORIGIN}" commit -qam v2
  run_git -C "${ORIGIN}" tag v2
  TAG1="$(run_git -C "${ORIGIN}" rev-parse 'v1^{commit}')"
  TAG2="$(run_git -C "${ORIGIN}" rev-parse 'v2^{commit}')"
}
# New case directory with a project repository that ignores sources/*/_shared like the
# real one, plus an uncommitted change of a tracked file and an untracked file.
new_case() {
  CASE_NUM=$((CASE_NUM + 1))
  CASE_DIR="${WORK_DIR}/case-${CASE_NUM}"
  mkdir -p "${CASE_DIR}/project"
  run_git init -q "${CASE_DIR}/project"
  printf '/sources/*/_shared\n' >"${CASE_DIR}/project/.gitignore"
  echo committed >"${CASE_DIR}/project/tracked"
  run_git -C "${CASE_DIR}/project" add -A
  run_git -C "${CASE_DIR}/project" commit -qm init
  PROJECT_HEAD="$(run_git -C "${CASE_DIR}/project" rev-parse HEAD)"
  echo uncommitted >"${CASE_DIR}/project/tracked"
  echo untracked >"${CASE_DIR}/project/untracked"
}
# Call checkout_upstream ORIGIN_URL <tag> [path] in a clean bash from [dir] with [vars]
# sourced and the current directory changed to [call dir] after that, by default
# UPSTREAM from the project root with _shared/vars.sh of this repository. Leaves CASE_RC
# and the log (stdout and stderr) in CASE_DIR.
run_checkout() {
  local vars="${4:-${REPO_ROOT}/_shared/vars.sh}"
  CASE_RC=0
  (
    cd "${3:-${CASE_DIR}/project}"
    # shellcheck disable=2016
    env -i PATH="${PATH}" PWD="${PWD}" HOME="${CASE_DIR}" LC_ALL=C \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="${WORK_DIR}" \
      VARS="${vars}" CALL_DIR="${5:-.}" bash --noprofile --norc -c '
        source "${VARS}"
        cd "${CALL_DIR}"
        checkout_upstream "$@"' checkout-upstream "${ORIGIN_URL}" "$1" \
      "${2:-${UPSTREAM}}" >"${CASE_DIR}/log" 2>&1
  ) || CASE_RC=$?
}
pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}
# Report a failure with details and the tail of the function output.
fail() {
  local desc="$1" line
  shift
  echo "  FAIL  ${desc}"
  for line in "$@"; do
    echo "        ${line}"
  done
  while IFS= read -r line; do
    echo "        | ${line}"
  done < <(tail -n 20 "${CASE_DIR}/log" 2>/dev/null || true)
  FAIL=$((FAIL + 1))
}
# check 'description' <tag commit> [marker]
# Expects success, UPSTREAM as the top level of its own clone at the given commit with
# a clean tree, and the project HEAD, tracked change and untracked file intact. With
# marker, also expects the clone reused: the local config value test.marker survives.
check() {
  local desc="$1" want="$2" marker="${3:-}" up="${CASE_DIR}/project/${UPSTREAM}"
  local real='' top='' head='' dirty='' got_marker='' tracked='' project_head=''
  real="$(cd "${up}" && pwd -P)" || true
  top="$(run_git -C "${up}" rev-parse --show-toplevel 2>/dev/null)" || true
  head="$(run_git -C "${up}" rev-parse HEAD 2>/dev/null)" || true
  dirty="$(run_git -C "${up}" status --porcelain 2>&1)" || true
  got_marker="$(run_git -C "${up}" config --local test.marker 2>/dev/null)" || true
  if [[ -f "${CASE_DIR}/project/tracked" ]]; then
    tracked="$(<"${CASE_DIR}/project/tracked")"
  fi
  project_head="$(run_git -C "${CASE_DIR}/project" rev-parse HEAD 2>/dev/null)" || true
  if [[ "${CASE_RC}" -eq 0 && "${top}" == "${real}" &&
    "${head}" == "${want}" && -z "${dirty}" && "${got_marker}" == "${marker}" &&
    "${tracked}" == 'uncommitted' && -f "${CASE_DIR}/project/untracked" &&
    "${project_head}" == "${PROJECT_HEAD}" ]]; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "upstream top level: ${top}" \
      "upstream HEAD: ${head}, expected ${want}" "upstream status: ${dirty}" \
      "marker: ${got_marker}, expected ${marker}" "project tracked: ${tracked}" \
      "project HEAD: ${project_head}, expected ${PROJECT_HEAD}"
  fi
}
# check_refused 'description'
# Expects exit code 66 that names the refusal and leaves the project files and .git
# intact.
check_refused() {
  local desc="$1" project="${CASE_DIR}/project" tracked=''
  if [[ -f "${project}/tracked" ]]; then
    tracked="$(<"${project}/tracked")"
  fi
  if [[ "${CASE_RC}" -eq 66 && "${tracked}" == 'uncommitted' &&
    -f "${project}/untracked" && -f "${project}/.git/config" ]] &&
    grep -q '^checkout_upstream: .* refusing$' "${CASE_DIR}/log" 2>/dev/null; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "project tracked: ${tracked}"
  fi
}
main() {
  trap cleanup INT QUIT ABRT TERM EXIT
  make_origin
  local up='' obj=''
  echo '=== checkout-upstream.sh tests ==='
  new_case
  run_checkout v1
  check 'missing directory is cloned' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" checkout -q v1
  run_git -C "${up}" config test.marker reused
  echo local >"${up}/file"
  echo junk >"${up}/junk"
  run_checkout v2
  check 'own clone is reused and reset to the tag' "${TAG2}" reused
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q --separate-git-dir="${CASE_DIR}/separate.git" "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker gitfile
  run_checkout v1
  check 'own clone with a .git file is reused' "${TAG1}" gitfile
  new_case
  mkdir -p "${CASE_DIR}/project/${UPSTREAM}"
  run_checkout v1
  check 'empty directory in the project is cloned again' "${TAG1}"
  new_case
  mkdir -p "${CASE_DIR}/project/${UPSTREAM}"
  echo partial >"${CASE_DIR}/project/${UPSTREAM}/file"
  run_checkout v1
  check 'interrupted clone without .git is cloned again' "${TAG1}"
  new_case
  mkdir -p "${CASE_DIR}/project/${UPSTREAM}/.git/objects"
  echo partial >"${CASE_DIR}/project/${UPSTREAM}/file"
  run_checkout v1
  check 'interrupted clone with an incomplete .git is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git init -q "${up}"
  printf 'ref: refs/heads/.invalid\n' >"${up}/.git/HEAD"
  run_git -C "${up}" remote add origin "${ORIGIN_URL}"
  echo partial >"${up}/file"
  run_checkout v1
  check 'interrupted clone with an unborn HEAD is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git init -q "${up}"
  echo partial >"${up}/file"
  obj="$(run_git -C "${up}" hash-object -w file)"
  echo "${obj}" >"${up}/.git/HEAD"
  run_checkout v1
  check 'broken clone with HEAD at a blob is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git init -q "${up}"
  echo partial >"${up}/file"
  obj="$(run_git -C "${up}" mktree </dev/null)"
  echo "${obj}" >"${up}/.git/HEAD"
  run_checkout v1
  check 'broken clone with HEAD at a tree is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git init -q "${up}"
  echo partial >"${up}/file"
  echo 0123456789abcdef0123456789abcdef01234567 >"${up}/.git/HEAD"
  run_checkout v1
  check 'broken clone with HEAD at a missing object is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  touch "${up}/.git/index.lock"
  run_checkout v1
  check 'clone interrupted during checkout is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q --separate-git-dir="${CASE_DIR}/separate.git" "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  touch "${CASE_DIR}/separate.git/index.lock"
  run_checkout v1
  check 'clone with a .git file interrupted during checkout is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  ln -s missing "${up}/.git/index.lock"
  run_checkout v1
  check 'clone with a dangling index.lock symlink is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q --separate-git-dir="${CASE_DIR}/separate.git" "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  ln -s missing "${CASE_DIR}/separate.git/index.lock"
  run_checkout v1
  check 'clone with a .git file and a dangling index.lock is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  touch "${up}/.git/HEAD.lock"
  run_checkout v1
  check 'clone with a stale HEAD.lock is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  run_git -C "${up}" update-ref refs/remotes/origin/master "${TAG1}"
  touch "${up}/.git/refs/remotes/origin/master.lock"
  run_checkout v1
  check 'clone with a stale ref lock is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  ln -s missing "${up}/.git/HEAD.lock"
  run_checkout v1
  check 'clone with a dangling HEAD.lock symlink is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  run_git -C "${up}" update-ref refs/remotes/origin/master "${TAG1}"
  ln -s missing "${up}/.git/refs/remotes/origin/master.lock"
  run_checkout v1
  check 'clone with a dangling ref lock symlink is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${up}"
  run_git -C "${up}" config test.marker locked
  ln -s missing "${up}/.git/refs/heads/master.lock"
  run_checkout v1
  check 'clone with a dangling branch lock symlink is cloned again' "${TAG1}"
  new_case
  up="${CASE_DIR}/project/${UPSTREAM}"
  run_git clone -q "${ORIGIN}" "${CASE_DIR}/main"
  run_git -C "${CASE_DIR}/main" worktree add -q --detach "${up}" v1
  run_git -C "${up}" config test.marker locked
  run_git -C "${up}" update-ref refs/remotes/origin/master "${TAG1}"
  touch "${CASE_DIR}/main/.git/refs/remotes/origin/master.lock"
  run_checkout v1
  check 'linked worktree with a stale lock in the common directory is cloned again' \
    "${TAG1}"
  new_case
  mkdir -p "${CASE_DIR}/project/sources/demo/_shared"
  ln -s ../../.. "${CASE_DIR}/project/${UPSTREAM}"
  run_checkout v1
  check_refused 'symlink to the project root is refused'
  new_case
  printf 'ref: refs/heads/.invalid\n' >"${CASE_DIR}/project/.git/HEAD"
  run_checkout v1 "${CASE_DIR}/project"
  check_refused 'project root with an unborn HEAD is refused'
  new_case
  run_checkout v1 "${CASE_DIR}"
  check_refused 'directory above the project root is refused'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}" \
    "${CASE_DIR}/project/_shared/vars.sh"
  check_refused 'project root is refused when called from outside of it'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared" "${CASE_DIR}/outside"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  ln -s "${CASE_DIR}/project/_shared/vars.sh" "${CASE_DIR}/outside/vars.sh"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/outside" \
    "${CASE_DIR}/outside/vars.sh"
  check_refused 'project root is refused when vars.sh is sourced through a symlink'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared" "${CASE_DIR}/outside"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/outside/vars.sh"
  ln -s "${CASE_DIR}/outside/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/outside" \
    "${CASE_DIR}/project/_shared/vars.sh"
  check_refused 'project root is refused when vars.sh is a symlink in the project'
  new_case
  mkdir -p "${CASE_DIR}/outside/shared"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/outside/shared/vars.sh"
  ln -s "${CASE_DIR}/outside/shared" "${CASE_DIR}/project/_shared"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/outside" \
    "${CASE_DIR}/project/_shared/vars.sh"
  check_refused 'project root is refused when _shared in the project is a symlink'
  new_case
  mkdir -p "${CASE_DIR}/outside"
  ln -s "${CASE_DIR}/outside" "${CASE_DIR}/project/link"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/project/link"
  check_refused 'project root is refused when called through a symlink in it'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared" "${CASE_DIR}/outside"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/project" _shared/vars.sh \
    "${CASE_DIR}/outside"
  check_refused 'project root is refused after a relative source and a cd outside'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared" "${CASE_DIR}/outside"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  printf 'ref: refs/heads/.invalid\n' >"${CASE_DIR}/project/.git/HEAD"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/project" _shared/vars.sh \
    "${CASE_DIR}/outside"
  check_refused 'unborn project root is refused after a relative source and a cd outside'
  new_case
  mkdir -p "${CASE_DIR}/project/_shared" "${CASE_DIR}/outside" "${CASE_DIR}/elsewhere"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/project/_shared/vars.sh"
  ln -s "${CASE_DIR}/project/_shared/vars.sh" "${CASE_DIR}/outside/vars.sh"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/outside" ./vars.sh \
    "${CASE_DIR}/elsewhere"
  check_refused 'project root is refused after a relative source of a symlink to vars.sh'
  new_case
  mkdir -p "${CASE_DIR}/outside/shared" "${CASE_DIR}/elsewhere"
  cp "${REPO_ROOT}/_shared/vars.sh" "${CASE_DIR}/outside/shared/vars.sh"
  ln -s "${CASE_DIR}/outside/shared" "${CASE_DIR}/project/_shared"
  run_checkout v1 "${CASE_DIR}/project" "${CASE_DIR}/project" _shared/vars.sh \
    "${CASE_DIR}/elsewhere"
  check_refused 'project root is refused after a relative source through _shared symlink'
  new_case
  mkdir -p "${CASE_DIR}/project/elsewhere" "${CASE_DIR}/project/sources/demo/_shared"
  echo partial >"${CASE_DIR}/project/elsewhere/file"
  ln -s ../../../elsewhere "${CASE_DIR}/project/${UPSTREAM}"
  run_checkout v1
  check 'symlink to a directory without .git is cloned again' "${TAG1}"
  if [[ -f "${CASE_DIR}/project/elsewhere/file" &&
    "$(<"${CASE_DIR}/project/elsewhere/file")" == 'partial' ]]; then
    pass 'symlink target directory is kept'
  else
    fail 'symlink target directory is kept' 'elsewhere/file is missing or changed'
  fi
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]]
}
main "$@"
