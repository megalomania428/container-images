#!/usr/bin/env bash
# cspell:ignore msmtpq urandom
# Create settings in an empty config mount, start queue flusher and daemon.
set -ueo pipefail
CONF_DIR='/etc/transmission-daemon'
DEFAULTS='/usr/local/share/transmission-debian13/settings.json'
if [[ ! -f "${CONF_DIR}/settings.json" ]]; then
  RPC_PASSWORD="${TRANSMISSION_RPC_PASSWORD:-}"
  if [[ -z "${RPC_PASSWORD}" ]]; then
    RPC_PASSWORD="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    echo "transmission: generated RPC password [${RPC_PASSWORD}]" >&2
  fi
  (
    umask 077
    jq --arg password "${RPC_PASSWORD}" '.rpc_password = $password' "${DEFAULTS}" \
      >"${CONF_DIR}/settings.json.tmp"
  )
  mv -f "${CONF_DIR}/settings.json.tmp" "${CONF_DIR}/settings.json"
  unset RPC_PASSWORD
fi
unset TRANSMISSION_RPC_PASSWORD
/usr/local/bin/msmtpq-flush.sh &
exec /usr/bin/transmission-daemon --foreground --config-dir "${CONF_DIR}"
