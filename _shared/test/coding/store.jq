.host.security.rootless == true
and .host.serviceIsRemote == false
and .host.cgroupManager == "systemd"
and .store.graphDriverName == "overlay"
and .store.graphRoot == "/srv/data/podman/coder"
and (.store.configFile == null
  or .store.configFile == "/workspace/coder/config/containers/storage.conf")
