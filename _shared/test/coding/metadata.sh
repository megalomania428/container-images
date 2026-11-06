#!/usr/bin/env bash
set -ueo pipefail
filter="$(dirname -- "${BASH_SOURCE[0]}")/store.jq"
work="$(mktemp -d /tmp/coding-metadata.XXXXXX)"
trap 'rm -rf -- "${work}"' EXIT
jq -n '{
  host: {security: {rootless: true}, serviceIsRemote: false, cgroupManager: "systemd"},
  store: {
    graphDriverName: "overlay",
    graphRoot: "/srv/data/podman/coder",
    graphOptions: {"overlay.mount_program": {Executable: "/usr/bin/fuse-overlayfs"}}
  }
}' >"${work}/podman6.json"
jq '.store.configFile = "/workspace/coder/config/containers/storage.conf"' \
  "${work}/podman6.json" >"${work}/podman5.json"
jq -e -f "${filter}" "${work}/podman5.json" >/dev/null
jq -e -f "${filter}" "${work}/podman6.json" >/dev/null
jq '.store.graphOptions = {}' "${work}/podman5.json" >"${work}/native.json"
jq -e -f "${filter}" "${work}/native.json" >/dev/null
for change in \
  '.host.security.rootless = false' \
  '.host.serviceIsRemote = true' \
  '.host.cgroupManager = "cgroupfs"' \
  '.store.graphDriverName = "vfs"' \
  '.store.graphRoot = "/var/lib/containers/storage"' \
  '.store.configFile = "/root/.config/containers/storage.conf"'; do
  jq "${change}" "${work}/podman5.json" >"${work}/invalid.json"
  if jq -e -f "${filter}" "${work}/invalid.json" >/dev/null; then
    echo "metadata validation accepted incorrect setting: ${change}" >&2
    exit 1
  fi
done
image_filter="$(dirname -- "${BASH_SOURCE[0]}")/image.jq"
jq -n '[{Config: {User: "", Volumes: {
  "/home/coder": {}, "/srv/data/podman/coder": {}, "/var/lib/host-identity": {}
}}}]' >"${work}/image.json"
for user in '' root 0 root:root 0:0; do
  jq --arg user "${user}" '.[0].Config.User = $user' "${work}/image.json" \
    >"${work}/valid-image.json"
  jq -e -f "${image_filter}" "${work}/valid-image.json" >/dev/null
done
for change in \
  '.[0].Config.User = "coder"' \
  '.[0].Config.User = "1000:0"' \
  'del(.[0].Config.Volumes["/srv/data/podman/coder"])' \
  'del(.[0].Config.Volumes["/home/coder"])' \
  'del(.[0].Config.Volumes["/var/lib/host-identity"])'; do
  jq "${change}" "${work}/image.json" >"${work}/invalid-image.json"
  if jq -e -f "${image_filter}" "${work}/invalid-image.json" >/dev/null; then
    echo "image validation accepted incorrect setting: ${change}" >&2
    exit 1
  fi
done
echo 'Podman 5/6 storage and image metadata tests: passed'
