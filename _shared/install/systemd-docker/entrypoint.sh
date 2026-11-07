#!/bin/bash
# cspell:ignore journalctl
# Installed as /sbin/init so podman enables its systemd mode by the command path.
# Starts systemd as PID 1 and streams the journal to stdout so all systemd output is
# visible via podman logs. journalctl follows new entries without -b so it is not tied
# to a boot ID and survives journal rotation.
set -uo pipefail

# An image without /etc/machine-id keeps the ID in its host identity volume: reuse a
# valid stored ID or store a new one, so systemd neither runs first boot nor derives a
# per-container ID. Images that ship /etc/machine-id are left untouched.
identity='/var/lib/host-identity/machine-id'
if [[ ! -e /etc/machine-id && ! -L /etc/machine-id ]]; then
  machine_id=''
  if [[ -f "${identity}" ]]; then
    machine_id="$(<"${identity}")"
  fi
  if [[ ! "${machine_id}" =~ ^[0-9a-f]{32}$ || "${machine_id}" =~ ^0+$ ]]; then
    uuid="$(</proc/sys/kernel/random/uuid)"
    machine_id="${uuid//-/}"
    if [[ ! "${machine_id}" =~ ^[0-9a-f]{32}$ ]] ||
      ! { printf '%s\n' "${machine_id}" 2>/dev/null >"${identity}.new" &&
        chmod 444 "${identity}.new" && mv -f "${identity}.new" "${identity}"; }; then
      rm -f "${identity}.new" 2>/dev/null
      echo "warning: cannot store machine ID in ${identity}, systemd assigns one" >&2
      machine_id=''
    fi
  fi
  if [[ -n "${machine_id}" ]]; then
    printf '%s\n' "${machine_id}" >/etc/machine-id && chmod 444 /etc/machine-id
  fi
fi
(
  # With an allocated tty systemd takes over the terminal and SIGHUPs this reader.
  # An ignored disposition survives the exec below, unlike a handler.
  trap '' HUP
  socket='/run/systemd/journal/socket'
  until [[ -S "${socket}" ]]; do
    sleep 0.05
  done
  # Wait until journald has written at least one entry so the cursor is
  # positioned correctly and -f does not miss early boot messages.
  until journalctl -n 1 --no-pager -q 2>/dev/null | grep -q .; do
    sleep 0.05
  done
  exec journalctl -f -n all -o short-monotonic --no-pager 2>/dev/null
) &

exec /lib/systemd/systemd
