<!-- cspell:ignore rsshub diygod healthz httperror graphql prerelease vitest httpbingo patchright -->
<!-- markdownlint-disable MD013 -->
# RSSHub container

[DIYgod/RSSHub](https://github.com/DIYgod/RSSHub) built by its own upstream `Dockerfile` without overriding its build arguments: the same variant as the upstream `latest` image, without a bundled Chromium. Upstream is pinned in `vars.sh` to the tag `v2026.11.17-8661.cf95739` together with its full commit, and a moved tag fails the build. The tag is cloned with depth 1, since the upstream `Dockerfile` copies `.git` into the image to report the commit hash.

The container listens on port `1200`; the upstream health check endpoint is `/healthz`.

## Patches

Files from `patches/` are applied in filename order before the build.

### 000-upstream-tests-in-build.patch

The upstream `Dockerfile` runs `pnpm build` without the upstream tests. The patch adds the stage `test` on top of `dep-builder`: it runs `pnpm build:routes` and then `pnpm test`, that is `format:check` and `vitest:coverage` of upstream, and leaves a marker. The checks see the build context, so the files that `.dockerignore` drops, such as `*.md`, `.github` and `test`, are not checked there. The stage `docker-minifier` copies the marker before `pnpm build`, so a failed check stops the image build. The working image stays the same: nothing of the stage `test` gets into it, and `vitest.config.ts`, `eslint-plugins` and `.gitignore`, now kept in the build context for the checks, are removed after `pnpm build`.

The stage sets `RSSHUB_BUILD_TEST=1`. It skips the tests that need what the build lacks, a Redis server, a browser or the Internet, and the tests that fail on the unchanged upstream; elsewhere these tests run as before. Skipped in the build:

- `lib/utils/cache/index.test.ts`: `redis`, `redis with quit`, `throws TTL key`, `retains atomic claims and release for redis` – Redis.
- `lib/middleware/cache.test.ts`: `redis`, `redis with quit` – Redis.
- `lib/middleware/cache.test.ts`: `memory` – it needs 8 to 10 s of its 10 s limit when the whole suite runs in parallel and may time out: on the unchanged upstream it timed out in 3 of 12 runs of the suite without network, with patch `000` it did not time out in 12 such runs, but it did in 2 of 4 earlier runs outside the image build and in one debug run of the build test stage; the image build skips it, so a slow builder cannot fail the image.
- `lib/utils/playwright.test.ts`: `playwright run`, `getPlaywrightPage` – a browser and the Internet.
- `lib/utils/playwright-utils.test.ts`: `getCookies httpbingo`, `setCookies httpbingo`, `setCookies & getCookies example.org` – a browser and the Internet.
- `lib/errors/index.test.ts`: `httperror` – the Internet.
- `lib/errors/index.test.ts`: `route path error should have path mounted` – the Internet: it counts the request of the skipped `httperror`.
- `lib/app.test.ts`: `should rewrite request` – the Internet.
- `lib/worker.test.ts`: `should handle /test/httperror route` – the Internet.
- `lib/utils/github-releases/store.test.ts`: `redis store` from `001-github-releases.patch` – Redis.

### 001-github-releases.patch

The route `/github/releases` follows new and changed published releases of public repositories of several organizations, users or explicitly listed repositories. All data comes from GitHub GraphQL: repositories, releases, notes and assets, without REST calls. The code is in `lib/utils/github-releases/` with its tests, the route `lib/routes/github/releases.ts` only describes it, and the response cache middleware skips paths under `/github/releases/`, since the route keeps its own snapshots.

Forms of the URL, sources are separated by commas, case, order and repetition do not matter:

- `/github/releases/org/org1,org2` – public repositories of organizations.
- `/github/releases/user/user1,user2` – public repositories owned by users.
- `/github/releases/repo/owner1/project1,owner2/project2` – listed repositories.

Query parameters, an unsupported value is an error rather than a default:

- `release_type`: `all` (default), `stable` or `prerelease`. Drafts are never included.
- `per_repo`: from 1 to 22, default 3. The window of the latest created releases of every repository, taken before the filters, so fewer releases or none may remain.
- `include_forks` and `include_archived`: `true` or `false` (default). They also apply to listed repositories.
- `limit` of RSSHub only shortens the response. The feed holds at most 111 entries, revisions included.

The entry title is `owner/repo name`, then the tag in parentheses when it differs from the name, `[pre-release]` for a pre-release and the repository description in parentheses. The entry holds the release notes and every uploaded asset with its link and size; the automatic source archives are not assets. A significant change of a published release, its name, tag, pre-release flag, notes or assets, adds a new entry titled with a leading `[updated]` and keeps the previous ones; download counters and dates alone do not. The GUID of an entry is `<release ID>#r<revision>-<the first 12 hex digits of the content digest>-<the time of the latest change of the release or its assets, seconds in base 36>`, so a change back to an earlier content is a new revision too, and after a lost state the earlier GUID returns only when the content and the time of the latest change of the release and its assets match the first entry, for example for an unchanged release, otherwise the GUID is new; GitHub gives times in whole seconds, so changes back and forth within one second are not told apart.

Settings, whole seconds unless noted; an empty value keeps the default, a value that is not an integer is a configuration error:

- `GITHUB_ACCESS_TOKEN` – the existing token of RSSHub, required: GitHub GraphQL needs authentication even for public data.
- `GITHUB_RELEASES_RESPONSE_TIMEOUT`, 10 – the longest wait of a request for a running crawl.
- `GITHUB_RELEASES_CRAWL_DEADLINE`, 1800 – the longest run of one background crawl.
- `GITHUB_RELEASES_REFRESH_INTERVAL`, 3600 – a feed is checked again this long after the end of its last successful crawl.
- `GITHUB_RELEASES_MIN_AGE`, 5940 – a release is published only when the latest of its publication and update times is older; 0 disables the delay.
- `GITHUB_RELEASES_MAX_OWNERS`, 7 logins and `GITHUB_RELEASES_MAX_REPOS`, 33 repositories – more sources are an error, never cut silently.
- `GITHUB_RELEASES_CONCURRENCY`, 2 – GraphQL requests at once in one process.
- `GITHUB_RELEASES_ATTEMPT_TIMEOUT`, 30 – the longest single GraphQL request.
- `GITHUB_RELEASES_MAX_RETRIES_TIME`, 111 – the budget of pauses between retries of one page; negative disables retries, 0 keeps the default.
- `GITHUB_RELEASES_BACKOFF_INITIAL`, 1, `GITHUB_RELEASES_BACKOFF_STEP`, 1, `GITHUB_RELEASES_BACKOFF_STEP_ATTEMPTS`, 3 attempts, `GITHUB_RELEASES_BACKOFF_CAP`, 7 – the pause starts at the initial value, grows by the step every given number of attempts up to the cap, stays there for one more block and starts over; non-positive values keep the defaults.
- `GITHUB_RELEASES_GRAPHQL_URL`, `https://api.github.com/graphql` – the GraphQL endpoint, for tests. `GITHUB_ACCESS_TOKEN` is sent to it, so anything but a local mock needs `https`.

Retries follow `fetch.go` and `retryAPI` of `go-lib-ci`, except the statuses: every response other than HTTP 200 (redirects are not followed, so a 3xx status is such a response), a missing response and a body that is not GraphQL JSON are retried within the budget with the same cursor and page size, and pauses requested by `Retry-After` or an exhausted `X-RateLimit-Remaining` count in the same budget. The HTTP client of RSSHub adds no retries of its own on this path; its request queue does not delay an attempt past its timeout or the end of the crawl, because the wait for the response stops at once when either comes. A page holds 100 repositories and keeps that size while pages succeed; only `RESOURCE_LIMITS_EXCEEDED` shrinks it to `max(1, floor(returned_releases / per_repo) - 1)`, where `returned_releases` counts the release objects that arrived whole and that no error of the response points at. The repositories received completely before the first damaged one are kept, and the next request starts after the last of them; complete repositories after the damaged one are stored as well, but the cursor never moves past it. A response with an error that names no repository, `RESOURCE_LIMITS_EXCEEDED` included, confirms nothing: no release of it is stored and the cursor stays, so the page is read again, after `RESOURCE_LIMITS_EXCEEDED` with the smaller size. The smaller page size stays for the rest of the crawl and applies to every owner and every request of listed repositories in it, down to one repository per request. The releases of a page that need no extra asset pages are stored before the extra pages of other releases are read. Explicitly listed repositories do not share a cursor: a repository that keeps failing until its retry budget is spent fails alone, and the others are read. A request of several listed repositories that keeps failing as a whole is split in halves after each spent budget, down to one repository per request, so a repository that breaks the whole response fails alone too; the repositories of a response with an error that names no repository are read again. The query cost and the points left of every GraphQL response are logged at the `debug` level.

A request that finds the feed due starts one background crawl and waits for it at most `GITHUB_RELEASES_RESPONSE_TIMEOUT`, then gets the entries ready so far, an empty feed with a status in its description included; the crawl goes on and stores every confirmed page. Other requests for the same task do not start another crawl. A crawl with a failed source keeps what the others read, counts as an update and is repeated after 1, 2, 4 and more minutes, at most `GITHUB_RELEASES_REFRESH_INTERVAL`, until a crawl ends without errors; a crawl stopped by its deadline after storing some releases counts the same way. A crawl that read no source completely and stored no release, for example because no listed repository exists or the pages read before the failure held no release for the filters, does not count as an update, ends in an error for a feed without stored entries and is retried on the same schedule. A source read completely without a release for the filters counts as read: such a crawl is an update with an empty result, and a feed without stored entries says that no releases match the filters, or that the last crawl had errors when other sources failed.

The state and the crawl lease live in the cache of RSSHub. With `CACHE_TYPE=redis` every process that shares the Redis sees one crawl per task and one history, which survives a restart of RSSHub, and a restart of Redis only as far as Redis persists its data. While RSSHub finds the Redis unavailable, each process keeps a separate state of its own, as without a usable cache, and returns to the shared one when the Redis is back: entries published from the separate state may be published once more from the shared one. Every Redis command of the feed gives up after 3 seconds, and a request issues several of them one after another: 4 to 5 for a feed that is served or started, more while it waits for a crawl of another process. A Redis that stops answering therefore turns a request into an error 3 seconds after its last answered command instead of holding it, and a Redis that answers slowly can still hold a request for up to 3 seconds per command, about 15 seconds without the waiting for another process. A running crawl stops on such an error and is retried later. A lease that could not be released then, or that Redis set after its command had given up, holds off new crawls of that task until it expires, `GITHUB_RELEASES_CRAWL_DEADLINE` plus 60 seconds after it was taken. With `CACHE_TYPE=memory` the state lives in the memory cache of one process, may be evicted by other entries of the cache and vanishes on restart, the lease stays in the process apart from the cache; processes do not coordinate. Without a usable cache, `CACHE_TYPE=http` included, they stay private to the process: every process crawls on its own and keeps its own history. The state expires 7 days after the last crawl that wrote it, or 24 refresh intervals if that is longer. The state is written after every batch that changes the feed and once more at the end of the crawl; a batch that changes nothing writes nothing, so a warm crawl in which no release changed writes only at its end. The state holds up to 111 entries with their release notes and the fingerprints of all releases seen, which takes up to 1–2 MB, so the first crawl of a large organization after the page size dropped to small values writes that much many times.

Known limitations:

- `per_repo` counts the latest created releases: an old draft published later may stay out of the window, and more new releases than the window push older ones out.
- Changes of releases outside the window are not seen; changes between two crawls are seen only as their final state.
- With hourly checks a release appears 99 to 159 minutes after its last change, later without readers, and a release edited again and again waits until the edits stop.
- Before a crawl ends the feed shows only what is ready, a cold start without stored entries shows an empty feed.
- After the loss of the state the first crawl publishes the releases in the window again as revision 1, without the earlier revisions, and numbers later changes from there. A release whose content and time of the latest change, assets included, match its first entry, for example an unchanged release, gets the GUID of that entry back; otherwise the GUID is new, so the release appears again even when its first entry was already read.
- A repository of an organization or a user that keeps failing stops the crawl of that owner at it after the retry budget: the repositories after it are read only as far as they arrive in the same responses, until the failure ends.
- A crawl does not keep its cursor for the next one: when `GITHUB_RELEASES_CRAWL_DEADLINE` ends a crawl in the middle of an owner, the next crawl starts from the beginning again, and the repositories that never fit into the deadline are not read.
- Only mocks of GitHub checked this patch; a live crawl with assets was not run. Earlier manual requests without assets cost 1 point per page of 100 repositories, the same pages with assets cost 6 points and ended with `RESOURCE_LIMITS_EXCEEDED`, so the cost and the number of requests of a full crawl with assets for about 1550 repositories, from 16 pages of 100 to one request per repository after `RESOURCE_LIMITS_EXCEEDED`, plus the asset pages, are not known yet, and the recovery after a real `RESOURCE_LIMITS_EXCEEDED` is not proven live.
- `GITHUB_RELEASES_MAX_RETRIES_TIME` limits the sum of pauses, not the time of the attempts themselves.

## Image test

`test/test.sh` is the `IMAGE_TEST` of the recipe. It runs `test/smoke.sh`, which starts the GraphQL mock `test/graphql-mock.mjs` with the built image on an internal Podman network without a way out, starts RSSHub on the same network with a dummy token and the mock as `GITHUB_RELEASES_GRAPHQL_URL`, and requests the route in its forms through `curl` inside the container.
