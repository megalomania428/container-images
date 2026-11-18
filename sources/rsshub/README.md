<!-- cspell:ignore rsshub diygod healthz -->
<!-- markdownlint-disable MD013 -->
# RSSHub container

[DIYgod/RSSHub](https://github.com/DIYgod/RSSHub) built by its own upstream `Dockerfile` without overriding its build arguments: the same variant as the upstream `latest` image, without a bundled Chromium. Upstream is pinned in `vars.sh` to the tag `v2026.11.17-8661.cf95739` together with its full commit, and a moved tag fails the build. The tag is cloned with depth 1, since the upstream `Dockerfile` copies `.git` into the image to report the commit hash.

The container listens on port `1200`; the upstream health check endpoint is `/healthz`.

## Patches

None yet. Files from `patches/` are applied in filename order before the build once they appear.
