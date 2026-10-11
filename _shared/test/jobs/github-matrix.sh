#!/usr/bin/env bash
# cspell:ignore gpgsign noprofile norc NOSYSTEM
# Tests for the image selection behind the define-matrix jobs of containers.yaml and
# appimages.yaml: _shared/_all/matrix.sh with vars.sh and lib.sh. Every scenario runs
# the real scripts copied into a synthetic tree in a clean bash started by env -i, so
# CI variables and secrets of the caller never reach the scripts under test.
set -ueo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d -t github-matrix-XXXXXX)"
# fixture root of the current section, switched by main
ROOT=''
PASS=0
FAIL=0
CASE_NUM=0
CASE_DIR=''
CASE_RC=0
# commits of the git fixture, set by make_git_fixture
GIT_INIT=''
GIT_C1=''
# every source of the base fixture in matrix order; omega has no vars.sh
ALL_PKG='img:alpha img:beta img:delta img:epsilon npm:gamma'
ALL_APP='beta'
cleanup() {
  local rc=$?
  rm -rf "${WORK_DIR}"
  exit "${rc}"
}
# Copy the scripts under test; _shared/vars.sh resolves SHARED_ASSETS globs relative
# to its own location, so it must live inside the fixture as well.
copy_scripts() {
  local root="$1"
  mkdir -p "${root}/_shared/_all" "${root}/sources"
  cp "${REPO_ROOT}/_shared/_all/matrix.sh" "${REPO_ROOT}/_shared/_all/vars.sh" \
    "${REPO_ROOT}/_shared/_all/lib.sh" "${root}/_shared/_all/"
  cp "${REPO_ROOT}/_shared/vars.sh" "${root}/_shared/vars.sh"
}
# Write sources/<name>/vars.sh: the strict mode header plus the given body.
write_source() {
  local root="$1" name="$2" body="$3"
  mkdir -p "${root}/sources/${name}"
  printf '#!/usr/bin/env bash\nset -ueo pipefail\n%s\n' "${body}" \
    >"${root}/sources/${name}/vars.sh"
}
# Base fixture: plain, AppImage, npm, shared directory/file and glob asset sources,
# plus omega, the leftover of a source removed by git rm -r with an ignored _shared/.
make_fixture() {
  local root="$1"
  copy_scripts "${root}"
  write_source "${root}" alpha "IMAGE_VER='001'"
  write_source "${root}" beta 'APP_IMAGE=1'
  write_source "${root}" gamma "NPM_PACKAGE='@raven428/gamma'"
  write_source "${root}" delta "SHARED_ASSETS=(
  '_shared/install/delta/:_shared/files'
  '_shared/install/tools.sh:_shared/tools.sh'
)"
  write_source "${root}" epsilon "SHARED_ASSETS=(
  '_shared/install/glob/**/*.conf:_shared/conf'
  '_shared/install/parts/*/:_shared/parts'
)"
  mkdir -p "${root}/sources/omega/_shared" "${root}/_shared/install/delta" \
    "${root}/_shared/install/glob/sub" "${root}/_shared/install/parts/one"
  touch "${root}/_shared/install/delta/file.sh" "${root}/_shared/install/tools.sh" \
    "${root}/_shared/install/glob/a.conf" "${root}/_shared/install/glob/sub/b.conf" \
    "${root}/_shared/install/parts/one/file.sh"
}
# Run git in the fixture without the user and system configuration.
fixture_git() {
  local root="$1"
  shift
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${root}" \
    -c user.name=matrix-tests -c user.email=matrix-tests@example.invalid \
    -c commit.gpgsign=false "$@"
}
# Git fixture: the base fixture as history init -> c1 (alpha) -> c2 (beta) on the
# checked out branch feature, master and origin/master diverged from c1 by m1 (gamma),
# origin/feature at c2, an uncommitted change of a delta asset and an untracked file.
make_git_fixture() {
  local root="$1"
  make_fixture "${root}"
  fixture_git "${root}" init -q -b master
  fixture_git "${root}" add -A
  fixture_git "${root}" commit -qm init
  GIT_INIT="$(fixture_git "${root}" rev-parse HEAD)"
  echo c1 >"${root}/sources/alpha/x"
  fixture_git "${root}" add -A
  fixture_git "${root}" commit -qm c1
  GIT_C1="$(fixture_git "${root}" rev-parse HEAD)"
  fixture_git "${root}" checkout -qb feature
  echo c2 >"${root}/sources/beta/x"
  fixture_git "${root}" add -A
  fixture_git "${root}" commit -qm c2
  fixture_git "${root}" checkout -q master
  echo m1 >"${root}/sources/gamma/x"
  fixture_git "${root}" add -A
  fixture_git "${root}" commit -qm m1
  fixture_git "${root}" update-ref refs/remotes/origin/master master
  fixture_git "${root}" update-ref refs/remotes/origin/feature feature
  fixture_git "${root}" checkout -q feature
  echo local >>"${root}/_shared/install/tools.sh"
  touch "${root}/sources/alpha/untracked"
}
# Source matrix.sh in ROOT with only the given VAR=value words in the environment.
# Leaves CASE_RC and CASE_DIR with log (stdout and stderr), pkg, app and dirs files.
run_matrix() {
  CASE_NUM=$((CASE_NUM + 1))
  CASE_DIR="${WORK_DIR}/case-${CASE_NUM}"
  mkdir -p "${CASE_DIR}"
  CASE_RC=0
  # GIT_CEILING_DIRECTORIES keeps git from finding a repository above the fixture
  (
    cd "${ROOT}"
    # shellcheck disable=2016
    env -i PATH="${PATH}" HOME="${CASE_DIR}" LC_ALL=C \
      GIT_CEILING_DIRECTORIES="${WORK_DIR}" "$@" CASE_DIR="${CASE_DIR}" \
      bash --noprofile --norc -c '
        source _shared/_all/matrix.sh >"${CASE_DIR}/log" 2>&1
        printf "%s\n" "${PKG_MATRIX}" >"${CASE_DIR}/pkg"
        printf "%s\n" "${APP_MATRIX}" >"${CASE_DIR}/app"
        printf "%s\n" "${IMAGES_DIRS[@]}" >"${CASE_DIR}/dirs"'
  ) || CASE_RC=$?
}
# Expected PKG_MATRIX from "kind:tag" words given in matrix order.
pkg_json() {
  jq -cnS --arg list "$1" \
    '{include: [$list | splits(" +") | select(. != "") | split(":")
      | {kind: .[0], tag: .[1]}]}'
}
# Expected APP_MATRIX from tag words; no tags means the __skip__ sentinel.
app_json() {
  jq -cnS --arg list "$1" \
    '{include: ([$list | splits(" +") | select(. != "") | {tag: .}]
      | if . == [] then [{tag: "__skip__"}] else . end)}'
}
# Read a case file normalized for comparison; a missing or broken file reads empty.
read_json() {
  jq -cS '.' "${CASE_DIR}/$1" 2>/dev/null || true
}
pass() {
  echo "  PASS  $1"
  PASS=$((PASS + 1))
}
# Report a failure with details and the tail of the scripts output.
fail() {
  local desc="$1" line start
  shift
  echo "  FAIL  ${desc}"
  for line in "$@"; do
    echo "        ${line}"
  done
  local -a log_lines=()
  [[ -f "${CASE_DIR}/log" ]] && readarray -t log_lines <"${CASE_DIR}/log"
  start=$((${#log_lines[@]} > 20 ? ${#log_lines[@]} - 20 : 0))
  for line in "${log_lines[@]:${start}}"; do
    echo "        | ${line}"
  done
  FAIL=$((FAIL + 1))
}
# run_case 'description' 'kind:tag ...' 'app tag ...' [VAR=value ...]
# Expects success and both matrices exactly as given.
run_case() {
  local desc="$1" want_pkg want_app got_pkg got_app
  want_pkg="$(pkg_json "$2")"
  want_app="$(app_json "$3")"
  shift 3
  run_matrix "$@"
  got_pkg="$(read_json pkg)"
  got_app="$(read_json app)"
  if [[ "${CASE_RC}" -eq 0 && "${got_pkg}" == "${want_pkg}" &&
    "${got_app}" == "${want_app}" ]]; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "expected PKG: ${want_pkg}" \
      "actual PKG:   ${got_pkg}" "expected APP: ${want_app}" "actual APP:   ${got_app}"
  fi
}
# run_fail 'description' exit-code 'expected message' [VAR=value ...]
# Expects exactly this exit code and the message somewhere in the scripts output.
run_fail() {
  local desc="$1" want_rc="$2" want_msg="$3" log=''
  shift 3
  run_matrix "$@"
  [[ -f "${CASE_DIR}/log" ]] && log="$(<"${CASE_DIR}/log")"
  if [[ "${CASE_RC}" -eq "${want_rc}" && "${log}" == *"${want_msg}"* ]]; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "expected exit code: ${want_rc}" \
      "expected message: ${want_msg}"
  fi
}
# run_dirs_case 'description' 'sources/a sources/b' [VAR=value ...]
# Expects success and IMAGES_DIRS in exactly this order, unlike the sorted matrices.
run_dirs_case() {
  local desc="$1" want="$2" got=''
  shift 2
  run_matrix "$@"
  [[ -f "${CASE_DIR}/dirs" ]] && got="$(<"${CASE_DIR}/dirs")"
  got="${got//$'\n'/ }"
  if [[ "${CASE_RC}" -eq 0 && "${got}" == "${want}" ]]; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "expected dirs: ${want}" \
      "actual dirs:   ${got}"
  fi
}
# run_log_case 'description' 'expected text' 'forbidden text' [VAR=value ...]
# Expects success, the first text in the scripts output and the second one absent.
run_log_case() {
  local desc="$1" want="$2" forbidden="$3" log=''
  shift 3
  run_matrix "$@"
  [[ -f "${CASE_DIR}/log" ]] && log="$(<"${CASE_DIR}/log")"
  if [[ "${CASE_RC}" -eq 0 && "${log}" == *"${want}"* &&
    "${log}" != *"${forbidden}"* ]]; then
    pass "${desc}"
  else
    fail "${desc}" "exit code: ${CASE_RC}" "expected text: ${want}" \
      "forbidden text: ${forbidden}"
  fi
}
main() {
  trap cleanup INT QUIT ABRT TERM EXIT
  make_fixture "${WORK_DIR}/base"
  # broken: the base fixture plus a manifest that fails while being sourced
  make_fixture "${WORK_DIR}/broken"
  write_source "${WORK_DIR}/broken" kappa 'false'
  # empty: the scripts without any source
  copy_scripts "${WORK_DIR}/empty"
  make_git_fixture "${WORK_DIR}/git"
  # GitHub pull request and default branch push contexts reused by many cases
  local -a pr=(GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge
    DEFAULT_BRANCH=master)
  local -a master=(GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master
    DEFAULT_BRANCH=master)
  ROOT="${WORK_DIR}/base"
  echo '=== github-matrix.sh tests ==='
  echo '--- MANUAL_IMAGES_DIRS ---'
  run_case 'manual single source' 'img:alpha' '' MANUAL_IMAGES_DIRS='alpha/'
  run_case 'manual npm and AppImage kinds' 'img:beta npm:gamma' 'beta' \
    MANUAL_IMAGES_DIRS='gamma beta'
  run_dirs_case 'manual drops duplicates and sources/ prefix, keeps order' \
    'sources/beta sources/alpha' MANUAL_IMAGES_DIRS='sources/beta/ beta alpha// beta'
  run_case 'manual wins over schedule and diff' 'npm:gamma' '' \
    MANUAL_IMAGES_DIRS='gamma' GITHUB_EVENT_NAME=schedule MANUAL_DIFF='sources/alpha/x'
  run_fail 'manual source without vars.sh fails loudly' 66 \
    'failed to read [sources/omega/vars.sh]' MANUAL_IMAGES_DIRS='omega'
  echo '--- schedule and tags ---'
  run_case 'schedule builds every source with vars.sh' "${ALL_PKG}" "${ALL_APP}" \
    GITHUB_EVENT_NAME=schedule GITHUB_REF=refs/heads/master
  run_case 'schedule ignores the diff' "${ALL_PKG}" "${ALL_APP}" \
    GITHUB_EVENT_NAME=schedule MANUAL_DIFF='sources/alpha/x'
  run_case 'tag push builds everything without sources in diff' "${ALL_PKG}" \
    "${ALL_APP}" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1 MANUAL_DIFF='README.md'
  run_case 'tag push builds everything despite a narrow diff' "${ALL_PKG}" \
    "${ALL_APP}" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1 \
    MANUAL_DIFF='sources/alpha/Dockerfile'
  echo '--- direct hits under sources/ ---'
  run_case 'pull request direct hit' 'img:alpha' '' "${pr[@]}" \
    MANUAL_DIFF='sources/alpha/Dockerfile'
  run_case 'pull request repeated and mixed hits' 'img:beta npm:gamma' 'beta' \
    "${pr[@]}" MANUAL_DIFF=$'sources/beta/vars.sh\nsources/beta/x\nsources/gamma/y'
  run_case 'pull request removing a source builds nothing' '' '' "${pr[@]}" \
    MANUAL_DIFF='sources/omega/vars.sh'
  run_case 'pull request removing a source keeps live hits' 'img:alpha' '' \
    "${pr[@]}" MANUAL_DIFF=$'sources/omega/vars.sh\nsources/alpha/x'
  run_case 'pull request touching an unknown source builds nothing' '' '' "${pr[@]}" \
    MANUAL_DIFF='sources/ghost/vars.sh'
  echo '--- framework and npm changes ---'
  run_case 'framework change in _shared/_all/ builds everything' "${ALL_PKG}" \
    "${ALL_APP}" "${pr[@]}" MANUAL_DIFF='_shared/_all/lib.sh'
  run_case 'framework change in _shared/vars.sh builds everything' "${ALL_PKG}" \
    "${ALL_APP}" "${pr[@]}" MANUAL_DIFF='_shared/vars.sh'
  run_case 'look-alike of _shared/vars.sh is no framework change' '' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/vars.sh.bak'
  run_case '_shared/npm/ change selects npm sources only' 'npm:gamma' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/npm/lib.sh'
  run_case '_shared/npm/ change adds to direct hits' 'img:alpha npm:gamma' '' \
    "${pr[@]}" MANUAL_DIFF=$'_shared/npm/lib.sh\nsources/alpha/x'
  echo '--- SHARED_ASSETS ---'
  run_case 'asset directory hit' 'img:delta' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/delta/file.sh'
  run_case 'asset file hit' 'img:delta' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/tools.sh'
  run_case 'asset directory is no prefix of a sibling' '' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/delta2/file.sh'
  run_case 'asset glob hit in a subdirectory' 'img:epsilon' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/glob/sub/b.conf'
  run_case 'asset glob **/ matches zero directories' 'img:epsilon' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/glob/a.conf'
  run_case 'asset glob matches a removed file' 'img:epsilon' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/glob/removed.conf'
  run_case 'asset glob ignores other extensions' '' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/glob/a.txt'
  run_case 'asset directory glob matches a removed directory' 'img:epsilon' '' \
    "${pr[@]}" MANUAL_DIFF='_shared/install/parts/removed/file.sh'
  run_case 'asset directory glob is no prefix of a sibling' '' '' "${pr[@]}" \
    MANUAL_DIFF='_shared/install/parts.txt'
  run_case 'asset directory glob ignores files beside its directories' '' '' \
    "${pr[@]}" MANUAL_DIFF='_shared/install/parts/README.md'
  echo '--- fallback outside the default branch ---'
  run_case 'pull request with an empty diff builds nothing' '' '' "${pr[@]}" \
    MANUAL_DIFF=$'\n'
  run_case 'pull request without sources in diff builds nothing' '' '' "${pr[@]}" \
    MANUAL_DIFF='.github/workflows/containers.yaml'
  run_case 'push to another branch builds nothing' '' '' GITHUB_EVENT_NAME=push \
    GITHUB_REF=refs/heads/feature DEFAULT_BRANCH=master MANUAL_DIFF='.github/x'
  run_case 'push of master when main is default builds nothing' '' '' \
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master DEFAULT_BRANCH=main \
    MANUAL_DIFF='.github/x'
  run_case 'local run without sources in diff builds nothing' '' '' \
    MANUAL_DIFF='.github/x'
  echo '--- fallback on the default branch ---'
  run_case 'default branch push with an empty diff' "${ALL_PKG}" "${ALL_APP}" \
    "${master[@]}" MANUAL_DIFF=$'\n'
  run_case 'default branch push without sources in diff' "${ALL_PKG}" "${ALL_APP}" \
    "${master[@]}" MANUAL_DIFF='.github/x'
  run_case 'default branch push removing a source' "${ALL_PKG}" "${ALL_APP}" \
    "${master[@]}" MANUAL_DIFF='sources/omega/vars.sh'
  run_case 'default branch push with a hit needs no fallback' 'img:alpha' '' \
    "${master[@]}" MANUAL_DIFF='sources/alpha/x'
  run_case 'empty DEFAULT_BRANCH means master' "${ALL_PKG}" "${ALL_APP}" \
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/master DEFAULT_BRANCH= \
    MANUAL_DIFF='.github/x'
  run_case 'custom default branch' "${ALL_PKG}" "${ALL_APP}" GITHUB_EVENT_NAME=push \
    GITHUB_REF=refs/heads/main DEFAULT_BRANCH=main MANUAL_DIFF='.github/x'
  echo '--- git diff errors ---'
  run_fail 'push without git repository fails' 66 'git diff --name-only' \
    "${master[@]}" GITHUB_EVENT_BEFORE=0000000 GITHUB_SHA=HEAD
  run_fail 'pull request without git repository fails' 66 'git diff --name-only' \
    "${pr[@]}"
  run_fail 'local run without git repository fails' 66 'git diff --name-only'
  echo '--- environment dump ---'
  run_log_case 'selection inputs are printed, secrets are not' \
    'GITHUB_REF=refs/pull/1/merge' 'secret-token' "${pr[@]}" \
    MANUAL_DIFF='sources/alpha/x' NODE_AUTH_TOKEN=secret-token
  echo '--- GitLab ---'
  run_case 'GitLab schedule builds everything' "${ALL_PKG}" "${ALL_APP}" \
    CI_PIPELINE_SOURCE=schedule
  run_case 'GitLab tag builds everything' "${ALL_PKG}" "${ALL_APP}" \
    CI_PIPELINE_SOURCE=push CI_COMMIT_TAG=v1 MANUAL_DIFF='README.md'
  run_case 'GitLab default branch fallback' "${ALL_PKG}" "${ALL_APP}" \
    CI_PIPELINE_SOURCE=push CI_COMMIT_BRANCH=master CI_DEFAULT_BRANCH=master \
    MANUAL_DIFF='.github/x'
  run_case 'GitLab custom default branch fallback' "${ALL_PKG}" "${ALL_APP}" \
    CI_PIPELINE_SOURCE=push CI_COMMIT_BRANCH=main CI_DEFAULT_BRANCH=main \
    MANUAL_DIFF='.github/x'
  run_case 'GitLab other branch builds nothing' '' '' CI_PIPELINE_SOURCE=push \
    CI_COMMIT_BRANCH=feature CI_DEFAULT_BRANCH=master MANUAL_DIFF='.github/x'
  run_case 'GitLab merge request direct hit' 'img:beta' 'beta' \
    CI_PIPELINE_SOURCE=merge_request_event MANUAL_DIFF='sources/beta/x'
  run_case 'GitLab merge request builds nothing as fallback' '' '' \
    CI_PIPELINE_SOURCE=merge_request_event CI_DEFAULT_BRANCH=master \
    MANUAL_DIFF='.github/x'
  # the environment dump always prints the variable name, so expect the bash error;
  # bash exits with 1 on a failed ${VAR:?} expansion
  run_fail 'GitLab merge request without branch names fails' 1 \
    'CI_MERGE_REQUEST_TARGET_BRANCH_NAME: is required' \
    CI_PIPELINE_SOURCE=merge_request_event
  run_case 'GitHub event wins over GitLab one' 'img:alpha' '' \
    GITHUB_EVENT_NAME=pull_request CI_PIPELINE_SOURCE=schedule \
    MANUAL_DIFF='sources/alpha/x'
  echo '--- git diff ranges ---'
  ROOT="${WORK_DIR}/git"
  run_case 'push diffs before..sha' 'img:alpha' '' "${master[@]}" \
    GITHUB_EVENT_BEFORE="${GIT_INIT}" GITHUB_SHA="${GIT_C1}"
  run_case 'push with a null before diffs HEAD^1..HEAD' 'img:beta' 'beta' \
    "${master[@]}" GITHUB_EVENT_BEFORE=0000000000000000000000000000000000000000
  run_fail 'push with an unknown before fails' 66 'git diff --name-only' \
    "${master[@]}" GITHUB_EVENT_BEFORE=1111111111111111111111111111111111111111
  run_case 'pull request diffs from the merge base' 'img:beta' 'beta' "${pr[@]}" \
    GITHUB_BASE_REF=master
  run_case 'GitLab push diffs before..sha' 'img:alpha' '' CI_PIPELINE_SOURCE=push \
    CI_COMMIT_BRANCH=master CI_COMMIT_BEFORE_SHA="${GIT_INIT}" CI_COMMIT_SHA="${GIT_C1}"
  run_case 'GitLab merge request diffs from the merge base' 'img:beta' 'beta' \
    CI_PIPELINE_SOURCE=merge_request_event CI_MERGE_REQUEST_TARGET_BRANCH_NAME=master \
    CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature
  run_case 'local run diffs tracked changes against HEAD' 'img:delta' ''
  echo '--- broken and empty trees ---'
  ROOT="${WORK_DIR}/broken"
  run_fail 'failing vars.sh breaks building everything' 66 \
    'failed to read [sources/kappa/vars.sh]' GITHUB_EVENT_NAME=schedule
  run_fail 'failing vars.sh breaks the SHARED_ASSETS scan' 66 \
    'failed to read [sources/kappa/vars.sh]' "${pr[@]}" MANUAL_DIFF='sources/alpha/x'
  ROOT="${WORK_DIR}/empty"
  run_case 'tree without sources gives empty matrices' '' '' \
    GITHUB_EVENT_NAME=schedule
  echo
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]]
}
main "$@"
