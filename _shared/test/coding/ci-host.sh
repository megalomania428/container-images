#!/usr/bin/env bash
# Prepares a GitHub Actions runner for outer.sh; test.sh runs it only in CI with the
# same XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS as outer.sh.
set -ueo pipefail
# openssh-client provides ssh-keyscan for the published SSH port checks
sudo apt-get install -y --no-install-recommends crun jq openssh-client
start=$(awk -F: '
  { end = $2 + $3; if (end > maximum) maximum = end }
  END { print maximum + 100000 }
' /etc/subuid /etc/subgid)
end=$((start + 1999999))
sudo usermod --add-subuids "${start}-${end}" --add-subgids "${start}-${end}" "$(id -un)"
sudo loginctl enable-linger "$(id -un)"
sudo systemctl start "user@$(id -u).service"
# The rootless engine already started during the build with the old ID map.
podman system migrate
