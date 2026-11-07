#!/usr/bin/env bash
set -ueo pipefail
# Keep the journal-forwarding wrapper when systemd-sysv installs or updates init.
init_path="$(dpkg-query -L systemd-sysv | grep -E '^(/usr)?/sbin/init$')"
dpkg-divert --local --add --rename --divert "${init_path}.distrib" "${init_path}"
install -m 755 "$(dirname -- "$0")/entrypoint.sh" "${init_path}"
