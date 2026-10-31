#!/usr/bin/env bash
# cspell:ignore mgmt msmtp msmtpq msmtpqrc msmtprc
# Periodically flush a non-empty msmtpq queue while /etc/msmtprc exists.
set -ueo pipefail
PERIOD="${MSMTPQ_PERIOD:-555}"
if [[ ! "${PERIOD}" =~ ^[0-9]+$ ]]; then
  echo "msmtpq-flush: invalid MSMTPQ_PERIOD [${PERIOD}]" >&2
  exit 1
fi
PERIOD=$((10#${PERIOD}))
if [[ "${PERIOD}" -eq 0 ]]; then
  exit 0
fi
# Queue directory defaults as in msmtpq, ~/.msmtpqrc is not read (the image has none).
QUEUE=${MSMTPQ_Q:-${Q:-~/.msmtp.queue}}
queue_has_mail() {
  local mail
  for mail in "${QUEUE}"/*.mail; do
    [[ -e "${mail}" ]] && return 0
  done
  return 1
}
while true; do
  sleep "${PERIOD}"
  if [[ -f /etc/msmtprc ]] && queue_has_mail; then
    /usr/bin/msmtpq --q-mgmt -r || echo 'msmtpq-flush: queue run failed' >&2
  fi
done
