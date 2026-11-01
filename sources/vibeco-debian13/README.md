<!-- markdownlint-disable MD013 -->
# Vibe coding container with systemd and Podman support

The image defaults to the unprivileged `coder` user for interactive commands. The Quadlet overrides that default so systemd runs as PID 1 and UID 0 inside the container; the host Podman service can remain rootless. The inherited Node entrypoint is cleared so Podman recognizes `/sbin/init` and enables its systemd mounts. The init wrapper streams the journal to `podman logs`.

## Rootless Podman Quadlet

`~/.config/containers/systemd/vibecoding-main.container`:

```ini
[Unit]
Description=main vibecoding
Wants=network-online.target
Requires=podman.socket
After=network-online.target podman.socket
StartLimitIntervalSec=0

[Container]
User=0
Group=0
WorkingDir=/workspace
Image=ghcr.io/megalomania428/vibeco-debian13:003
Volume=%h/work/github:/workspace/github
Volume=%h/vscode:/workspace/vscode
Volume=%h/.pi:/home/coder/.pi
Volume=%h/.local:/home/coder/.local
Volume=%h/.claude:/home/coder/.claude
Volume=%h/.happier:/home/coder/.happier
Volume=%h/.cache/opencode:/home/coder/.cache/opencode
Volume=%h/.cache/claude-cli-nodejs:/home/coder/.cache/claude-cli-nodejs
Volume=%h/.config/opencode:/workspace/coder/config/opencode
Volume=%h/volumes/home/coder:/home/coder
Volume=/srv/data/podman/coder:/srv/data/podman/coder
Volume=/srv/data/podman/opencode-root:/var/lib/containers
Volume=/srv/data/home/coder/.npm:/home/coder/.npm
Volume=/srv/data/home/coder/.bun:/home/coder/.bun
Volume=/srv/data/home/coder/.pyenv:/home/coder/.pyenv
Volume=/srv/data/home/coder/.rustup:/srv/data/home/coder/.rustup
Volume=/srv/data/home/coder/.cargo:/srv/data/home/coder/.cargo
Volume=/srv/data/home/coder/go:/srv/data/home/coder/go
Volume=/srv/data/home/coder/.cache:/home/coder/.cache
Volume=%t/podman/podman.sock:/home/coder/.local/podman.sock
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/coder/.local/bin:/home/coder/.local/go/bin:/home/coder/.local/pi-dev/node_modules/.bin
Environment=XDG_CONFIG_HOME=/workspace/coder/config
Environment=GOCACHE=/srv/data/home/coder/go/cache
Environment=GOPATH=/srv/data/home/coder/go
Environment=GOROOT=/home/coder/.local/go
Environment=PI_OFFLINE=1
Environment=CONTAINER_HOST=unix:///home/coder/.local/podman.sock
ContainerName=vibecoding-main
HostName=vibecoding-main
PublishPort=4096:4096
PublishPort=4097:4097
PublishPort=8787:8787
AddHost=vibecoding-main:127.0.0.1
Network=pasta
AddCapability=CAP_SYS_ADMIN
AddCapability=CAP_NET_ADMIN
AddDevice=/dev/kvm
AddDevice=/dev/fuse
AddDevice=/dev/net/tun
UIDMap=0:1:1000
UIDMap=1000:0:1
UIDMap=1001:1001:9898999
GIDMap=0:1:1000
GIDMap=1000:0:1
GIDMap=1001:1001:9898999

[Service]
RestartSec=1
Restart=always
SyslogIdentifier=vibecoding-main
TimeoutStopSec=22s
TimeoutStartSec=11m
Delegate=yes

[Install]
WantedBy=default.target
```

- `Image` must reference the rebuilt image; an older `:999` tag does not acquire these changes automatically. The example uses version `003` from `vars.sh`.
- `User=0` and `Group=0` override the image's `USER coder` default and apply only inside the container. They are required because `coder` cannot start the system manager. A direct `podman run` of the image must likewise use `--user root` when starting its default `/sbin/init`; interactive commands keep the safer image default. Agent privileges belong in their own systemd units, not in the container's `GroupAdd` setting.
- No `Exec` override or `--init` is needed: the image starts `/sbin/init`, which must remain PID 1. Quadlet already defaults to `--cgroups=split`; the duplicate `PodmanArgs` setting is unnecessary. The host needs cgroup v2 with delegation.
- The UID/GID maps retain the host user's identity for container `coder` (1000). They require at least 9,899,999 subordinate UIDs and GIDs; the host `/etc/subuid` and `/etc/subgid` allocations must cover those ranges.
- `%t/podman/podman.sock` resolves to the host user's runtime directory. The host `podman.socket` must be active. This socket grants agents control of the host user's Podman containers and host-accessible bind mounts; it is not an isolated nested engine. Omitting both its `Volume` and `CONTAINER_HOST` selects the Podman installation inside the sandbox instead.
- All bind sources and devices must exist on the host and have suitable permissions. Rootless device access may also require `GroupAdd=keep-groups` with crun when access comes from supplementary host groups. Internal services still need access through their own mapped UID/GID and `SupplementaryGroups`; changing their user can discard inherited groups.
- The Rust directories retain the supplied `/srv/data/home/coder` destinations. Toolchains using them need matching `RUSTUP_HOME` and `CARGO_HOME`, or mounts at their default `/home/coder/.rustup` and `/home/coder/.cargo` paths.
- Published ports bind on all host interfaces. A local-only setup can use `PublishPort=127.0.0.1:4096:4096`, and similarly for the other ports. Agents inside the container must listen on its network interface, not only on loopback.

## Shell access and service checks

```bash
podman exec --user coder -it vibecoding-main bash
podman exec vibecoding-main systemctl is-system-running
podman exec vibecoding-main systemctl --failed
podman logs --tail 100 vibecoding-main
```

Plain `podman exec` uses root, which is useful for managing system units. `--user coder` explicitly selects the unprivileged shell; it does not create a login session or a `systemctl --user` manager.

## Agent services

Agents can run as system services with `User=coder`, without a separate user manager. A transient smoke test:

```bash
podman exec vibecoding-main systemd-run --wait --pipe --collect \
  --property=User=coder --property=Group=coder \
  --property=WorkingDirectory=/workspace /usr/bin/id
```

Persistent agent units need `User=coder`, `Group=coder`, `WorkingDirectory=/workspace` and an absolute `ExecStart` path. Any required supplementary groups, such as `tcpdump`, belong in the unit's `SupplementaryGroups`. Membership in `sudo` is already configured for `coder`.

System services do not automatically inherit the Quadlet's container environment. Variables required by an agent, including `PATH`, `XDG_CONFIG_HOME`, Go settings and optional `CONTAINER_HOST`, must also be set through the unit's `Environment` or `EnvironmentFile`. A mount alone does not configure a toolchain's environment.

Units written only inside a container disappear when Quadlet recreates it. Persistent units and their environment files should be kept on the host and mounted individually into the container; mounting over all of `/etc/systemd/system` would hide the image's masks and enabled services.
