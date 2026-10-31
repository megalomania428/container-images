#!/usr/bin/env bash
# cspell:ignore Muttrc libexec msmtp msmtpq msmtprc transmail
# Runtime stage: install rebuilt packages and mail glue.
set -ueo pipefail
export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
apt-get update
apt-get install -y --no-install-recommends ca-certificates jq mutt /tmp/debs/*.deb
rm -f /usr/sbin/policy-rc.d
grep -q 'source-muttrc.d' /etc/Muttrc
install -m 0644 /files/msmtpq.rc /etc/Muttrc.d/msmtpq.rc
ln -s /usr/libexec/msmtp/msmtpq/msmtpq /usr/bin/msmtpq
ln -sf /etc/transmission-daemon/msmtprc /etc/msmtprc
install -m 0755 /files/transmail.sh /usr/local/bin/transmail.sh
install -m 0755 /files/msmtpq-flush.sh /usr/local/bin/msmtpq-flush.sh
install -m 0755 /files/entrypoint.sh /usr/local/bin/transmission-entrypoint.sh
install -D -m 0644 /files/settings.json \
  /usr/local/share/transmission-debian13/settings.json
rm -f /etc/transmission-daemon/settings.json
install -d -m 0700 /var/spool/msmtpq
apt-get clean
rm -rf /usr/share/doc /usr/share/man /var/lib/apt/lists/* /tmp/debs /files
