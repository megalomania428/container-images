#!/usr/bin/env bash
# cspell:ignore realname transmail
# Mail a notice about a finished torrent, called by transmission-daemon.
set -ueo pipefail
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
if [[ -z "${TRANSMAIL_FROM:-}" || -z "${TRANSMAIL_TO:-}" ]]; then
  echo 'transmail: TRANSMAIL_FROM or TRANSMAIL_TO is not set, mail skipped' >&2
  exit 0
fi
echo "transmission [${TR_TORRENT_NAME:-}] finished" |
  EMAIL="${TRANSMAIL_FROM}" mutt \
    -e 'set copy=no' \
    -e 'set send_charset=utf-8' \
    -e 'set realname=transmission' \
    -s "transmission done: ${TR_TORRENT_NAME:-}" \
    -- "${TRANSMAIL_TO}"
