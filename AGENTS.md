<!-- cspell:ignore mktemp patchset worktrees -->
<!-- markdownlint-disable MD013 -->
# Agent instructions

## Upstream sources and working directories

- Upstream repositories are studied and patched through local clones in `/workspace/github`, never through fresh clones in temporary directories. Look first in `/workspace/github/<repo>`, then search other clones by remote URL: `grep -lis 'github.com[:/]<owner>/<repo>' /workspace/github/*/.git/config /workspace/github/*/*/.git/config`.
- If no clone exists, check the repository size in KB with `curl -s https://api.github.com/repos/<owner>/<repo> | jq .size`. Above `1048576`, study the repository remotely through GitHub MCP or search and agree on a working tree with the user before patching. Otherwise clone with `git -C /workspace/github clone https://github.com/<owner>/<repo>`.
- Update a found clone only with `git fetch`; switch an SSH origin to HTTPS first. The clone's branch, index and working tree are shared and stay untouched: no `checkout`, `pull`, `reset`, `commit` or edits in it.
- Project changes are made in the current project working copy. Temporary detached upstream patch worktrees live only under `/var/tmp/wt4gh`, separately from the project working copy; patch cleanup must not remove the project working copy.
- Patch worktrees `a`, `b` and `c` are additional working directories authorized by these project instructions. Read upstream sources in the local clone or its patch worktrees; edit upstream code and tests only in `b`. Generate patches by comparing `a` and `b`; install dependencies, build and test upstream only in `c` after applying the full patch set. Save generated patches and accompanying project files in the project working copy.
- When delegating patch work, the coordinating agent creates and removes the patch worktrees according to the workflow below. Other agents use the prepared directories without creating branches, worktrees or commits. Without delegation, the agent performing the task manages the patch worktrees directly. Each assignment must include absolute paths to the clone, `a`, `b`, `c` and project output files, the operations allowed in each directory and the agent responsible for cleanup. Commands must explicitly select their working directory; these permissions never allow edits to the shared clone or unrelated project working copies.

## Tests

- Explicit user instructions to create new tests or test cases, including instructions given during ongoing work, must be followed for both existing and new code; they take precedence over the default restrictions below.
- By default, when existing code is changed for the user's task, update existing tests to match the agreed new behavior without adding new tests or test cases, except for the mandatory regression coverage below. This applies to both repository code and patched upstream code.
- When a test fails, first thoroughly inspect the affected implementation, related call paths and failure cause for defects and deviations from the task. Fix implementation defects in the code. Change test expectations only after confirming that the agreed behavior change made them obsolete; never weaken assertions, delete tests or skip them merely to get a passing run.
- For new code, add tests when explicitly requested by the user, for especially complex cases at the model's discretion or for the mandatory regression coverage below. By default, do not add tests for other new-code cases.
- After fixing a bug found by a reviewer or expert, tests must cover all scenarios of that bug, including applicable edge cases. This requirement overrides the restriction on new tests for both existing and new code: add tests and test cases as needed, verifying that they fail before the fix and pass after it.
- For upstream patches, edit test sources only in `${W}/b` and include their changes in the corresponding generated patch; never edit test sources directly in `${W}/c` or the shared clone. Regenerate a changed patch through the workflow below, then apply the full patch set to a clean `c` and run the relevant tests there. For upstream work, dependency installs, builds and tests belong only in `c`, an additional working directory explicitly authorized by these project instructions.
- Reports must state failure causes, implementation findings, reasons for changed expectations, covered regression scenarios and commands with results. Respect task limits on long, heavy runs; explicitly report checks that were not run rather than claiming they passed.

## Generating patches for upstream sources

Patches in `sources/<name>/patches/` are applied via `patch -p1` to a clean upstream checkout. Use plain unified diff (`diff -u`), not `git diff`.

### Why not git diff

`git diff` embeds `index <sha>..<sha>` lines and requires a git repository context. Plain `diff -u` produces portable patches that apply with standard `patch(1)` regardless of git history.

### Workflow

For each new or regenerated patch N, run from the project repository root with absolute paths:

```bash
NAME='<source name>'
UP='/workspace/github/<repo>'
REF='<pinned upstream ref from the source configuration>'
PATCH="${PWD}/sources/${NAME}/patches/000N-description.patch"
```

- Fetch the pinned ref without changing the shared clone's checkout:

  ```bash
  git -C "${UP}" fetch origin "${REF}"
  COMMIT="$(git -C "${UP}" rev-parse --verify 'FETCH_HEAD^{commit}')"
  ```

- Create a collision-free directory under `/var/tmp/wt4gh` with three detached worktrees: `a` – before patch N, `b` – after patch N, `c` – verification and tests:

  ```bash
  mkdir -p /var/tmp/wt4gh
  W="$(mktemp -d -p /var/tmp/wt4gh "${NAME}-XXXXXX")"
  for tree in a b c; do
    git -C "${UP}" worktree add --detach "${W}/${tree}" "${COMMIT}"
  done
  ```

- List all patches before N in apply order using absolute paths, then apply them to `a` and `b`. When regenerating N, apply its current version to `b` too before editing:

  ```bash
  PREV=("${PWD}/sources/${NAME}/patches/0001-description.patch")
  for tree in a b; do
    for p in "${PREV[@]}"; do
      patch -d "${W}/${tree}" -p1 --batch --forward -i "${p}"
    done
  done
  ```

  Use `PREV=()` for the first patch. Edit upstream files only in `b`; never install dependencies, build or run tests in `a` or `b`.

- Generate a plain unified diff with `a/` and `b/` prefixes. Exit code 1 means differences, 0 means no changes and 2 means failure; binary differences are not allowed:

  ```bash
  rc=0
  (cd "${W}" && diff -ruN -x .git a b) >"${PATCH}" || rc=$?
  [[ "${rc}" -eq 1 ]]
  [[ -z "$(grep -n '^Binary files' "${PATCH}")" ]]
  ```

- Apply the full patch set to clean `c`, including N and every later patch, in the source's apply order. Reject fuzz, `.rej` and `.orig` files; regenerate any later patch that needs fuzz:

  ```bash
  ALL=("${PWD}/sources/${NAME}/patches/"*.patch)
  for p in "${ALL[@]}"; do
    patch -d "${W}/c" -p1 --batch --forward -i "${p}"
  done
  [[ -z "$(find "${W}/c" -name '*.rej' -o -name '*.orig')" ]]
  ```

  Adjust `ALL` to the actual patch directories, extensions and apply order of the source. When N is last, `diff -ruN -x .git "${W}/b" "${W}/c"` must print nothing before dependency installs, builds or tests. Run relevant checks only in `c`, within task limits.

- Remove only this task's patch worktrees and temporary directory, also after failure, and prune stale records. Never remove the project worktree as part of patch cleanup:

  ```bash
  for tree in a b c; do
    git -C "${UP}" worktree remove --force "${W}/${tree}"
  done
  rm -rf "${W}"
  git -C "${UP}" worktree prune
  ```

### Rules

- Each patch must apply on top of all previous patches in order.
- A patch must contain **only** its own changes — never re-include hunks already present in earlier patches.
- Do not use `git stash`, `git diff`, `git apply` or any other git commands for patch generation.
- Paths inside the patch must be `a/<relative-path>` / `b/<relative-path>` so that `patch -p1` strips exactly one path component and lands in the right place.
- Test the patched tree after applying all patches to confirm nothing is broken.

# npm sources

`NPM_PACKAGE` distinguishes an npm source from a container source. npm source `vars.sh` declares `UPSTREAM_URL` and `UPSTREAM_VER` for the pinned checkout, `PATCHSET` as a non-negative patchset number, and `NPM_CHECKS` as the allowed commands run before the one explicit build.

`PUBLISH_MODE=release` uses `<upstream>-p<PATCHSET>` and falls back to `<upstream>-p<PATCHSET>-<UTC_DATE>-<VERSION_SUFFIX>`; `schedule` publishes the dated version directly; `dev` uses `<upstream>-p<PATCHSET>-dev.<VERSION_SUFFIX>`; and `skip` builds without creating or publishing an archive.

During the automated build/publish pipeline, upstream is checked out in `sources/<name>/_shared/upstream`; tarballs are stored in `sources/<name>/_shared/npm-artifacts`. These pipeline paths are not manual patch worktrees; manual patch development follows the worktree rules above. Build compiles before a token is available, while push only uploads the prepared tarballs.

`_shared/npm/lib.sh`, `cont-prepare.sh`, and `cont-publish.sh` provide the shared npm implementation. Changes below `_shared/npm/` select all npm sources but do not select ordinary containers.

`ghcr.io/raven428/node-builder:latest` was created by the preceding task, is used with Podman's pull-if-missing policy, and is intentionally not added to `DEPENDS`.

Add an npm package with a new `sources/<name>/vars.sh`, patches, and README; do not add package-specific branches to `_shared/_all/*`.
