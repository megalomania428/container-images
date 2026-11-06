.host.security.rootless == false
and .host.serviceIsRemote == false
and .host.cgroupManager == "systemd"
and .store.graphDriverName == "overlay"
and .store.graphRoot == "/var/lib/containers/storage"
and .store.graphOptions["overlay.mount_program"].Executable == "/usr/bin/fuse-overlayfs"
