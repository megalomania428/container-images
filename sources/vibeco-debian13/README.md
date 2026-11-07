<!-- markdownlint-disable MD013 -->
# Vibe coding container with systemd and rootless Podman

The Quadlet runs systemd as PID 1 and UID 0 inside the container. Coding commands run as `coder` (UID 1000), whose nested Podman uses its own engine, storage and user namespaces. No host Podman socket, outer `CAP_SYS_ADMIN` or outer `CAP_NET_ADMIN` is required. The init wrapper forwards the container journal to stdout for `podman logs` and the host Quadlet journal.

## Generate the host seccomp profile

Rootless nested containers need `sethostname` and `setdomainname` in their own UTS namespaces. The host's default seccomp profile may deny these syscalls when the outer container lacks `CAP_SYS_ADMIN`. The generator removes only their existing conditional/deny rules and adds an unconditional allow; all other rules and profile fields are preserved. Kernel namespace and capability checks still apply.

From this repository checkout on the host, with Bash and jq installed:

```bash
mkdir -p ~/.config/containers
profile="$(podman info --format json | jq -r '.host.security.seccompProfilePath')"
_shared/install/coding-seccomp.sh "$profile" \
  > ~/.config/containers/seccomp-coding.json
```

The image installs the same helper as `/usr/local/bin/coding-seccomp`. It accepts one optional input filename, otherwise reads JSON from stdin, and writes JSON to stdout. For an existing container, the host profile can be supplied explicitly:

```bash
profile="$(podman info --format json | jq -r '.host.security.seccompProfilePath')"
podman exec -i vibecoding-main coding-seccomp < "$profile" \
  > ~/.config/containers/seccomp-coding.json
```

Use the **host** profile, not the image's profile, because the result controls the outer container. Seccomp cannot remove procfs masks: the separate `unmask=/proc/*` option below is also required. Regenerate the JSON after changes to the host's default profile.

## Rootless Podman Quadlet

`~/.config/containers/systemd/vibecoding-main.container`:

```ini
[Unit]
Description=main vibecoding
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Container]
User=0
Group=0
WorkingDir=/workspace
Image=ghcr.io/megalomania428/vibeco-debian13:004
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
Volume=%h/volumes/identity/vibeco:/var/lib/host-identity
Volume=/srv/data/podman/coder:/srv/data/podman/coder
Volume=/srv/data/podman/opencode-root:/var/lib/containers
Volume=/srv/data/home/coder/.npm:/home/coder/.npm
Volume=/srv/data/home/coder/.bun:/home/coder/.bun
Volume=/srv/data/home/coder/.pyenv:/home/coder/.pyenv
Volume=/srv/data/home/coder/.rustup:/home/coder/.rustup
Volume=/srv/data/home/coder/.cargo:/home/coder/.cargo
Volume=/srv/data/home/coder/go:/srv/data/home/coder/go
Volume=/srv/data/home/coder/.cache:/home/coder/.cache
Volume=/tmp
Volume=/var/log/journal
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/coder/.local/bin:/home/coder/.local/go/bin:/home/coder/.local/pi-dev/node_modules/.bin
Environment=XDG_CONFIG_HOME=/workspace/coder/config
Environment=GOCACHE=/srv/data/home/coder/go/cache
Environment=GOPATH=/srv/data/home/coder/go
Environment=GOROOT=/home/coder/.local/go
Environment=PI_OFFLINE=1
ContainerName=vibecoding-main
HostName=vibecoding-main
PublishPort=3022:22
PublishPort=4096:4096
PublishPort=4097:4097
PublishPort=8787:8787
AddHost=vibecoding-main:127.0.0.1
Network=pasta
PodmanArgs=--security-opt=unmask=/proc/* \
  --security-opt=seccomp=%h/.config/containers/seccomp-coding.json
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

- `Image` must reference the rebuilt image. Existing home or configuration mounts do not automatically acquire new files from an image; persistent `containers.conf` files must not retain the old `/proc:/proc` bind or `cgroups="disabled"` settings.
- `User=0` and `Group=0` are for the outer systemd. No `Exec` override or `--init` is needed. Interactive commands should explicitly select `coder`.
- No `Requires=podman.socket`, host socket mount or `CONTAINER_HOST` is needed. A host API socket would grant agents the host account's container-management and bind-mount privileges again.
- Never bind the outer `/proc` over nested `/proc`. Nested containers use their own PID namespace and procfs. Otherwise `ps`, journald and other PID-aware software can malfunction. The outer unmask option allows the rootless engine to create that procfs; it weakens procfs masking but does not remove kernel permission checks.
- The example UID/GID maps preserve the host account's identity for `coder` and require 9,899,999 subordinate UIDs and GIDs. Allocations for different host users must not overlap. The runtime tests need their host mapping to cover container IDs through 999998; their launcher checks this explicitly.
- All bind sources and devices must exist. `/dev/fuse` is required for the tested overlay configuration. KVM and TUN may be omitted when not needed. KVM access requires permissions for the **running coder process**, not only group membership recorded after it started. `coder` is created in `root,sudo`; device GID mappings must make that membership useful. `--group-add=keep-groups` preserves existing access when launching a nested container, but does not create missing access.
- Do not set `XDG_RUNTIME_DIR=/run/user/1000` or the coder session-bus address globally for root. They belong to coder sessions and services.
- Published ports in this example are local-only. Nested `--publish` exposes a port in the outer coding container; exposing it on the physical host requires an outer port mapping too.

## Persistent runtime configuration

The image enables cgroups with private PID/cgroup namespaces and the systemd cgroup manager. Coder's default graphroot is on its declared data volume and retains native overlay behavior, avoiding an implicit backend change for existing XFS/ext4 stores. The isolated runtime suite explicitly exercises fuse-overlayfs as well. A custom graphroot inside another overlay filesystem may require an explicit mount program; storage-backend changes need a planned migration, not an automatic reset. System-wide Podman API, restart, cleanup and auto-update units are masked: this profile uses coder's engine, not an automatically started rootful engine. User units and direct `podman system service` remain available. `libpam-systemd`, `dbus-user-session` and linger start `user@1000.service`. `catatonit` provides `--init`, `aardvark-dns` provides named-network DNS, and pasta provides rootless connectivity. The rootless range for `coder` and the outer UID/GID maps must agree; changes to mappings require planned engine migration, not changes while other agents are using it.

`/etc/profile.d/coder-runtime.sh` sets the runtime directory and session-bus address only for UID 1000 in login shells. System services with `User=coder` do not source shell profiles. They can use the supplied `/etc/coding/coder-runtime.env`, for example in `/etc/systemd/system/pi-web-sessiond.service.d/coding-runtime.conf`:

```ini
[Service]
EnvironmentFile=/etc/coding/coder-runtime.env
```

The file contains `XDG_CONFIG_HOME`, `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`; agent-specific PATH, Go variables and credentials still belong to the agent unit or its own environment file. The outer Quadlet's environment is not automatically inherited by inner system services.

The image declares `/home/coder`, the actual graphroot `/srv/data/podman/coder` and the host identity directory `/var/lib/host-identity` as volumes. Explicit named volumes or bind mounts are still required to reuse the same data after removing and recreating a container; newly allocated anonymous volumes are not automatically reused.

The machine ID and SSH host keys are not part of the image: the build removes `/etc/machine-id`, `/var/lib/dbus/machine-id` and `/etc/ssh/ssh_host_*` in the same layer that creates them, so no image layer ships them. They live in the flat `/var/lib/host-identity` directory as `machine-id`, `ssh_host_ed25519_key`, `ssh_host_ecdsa_key`, `ssh_host_rsa_key` and their `.pub` files. Before systemd starts, the init wrapper copies a valid stored machine ID to `/etc/machine-id` or generates a new one and stores it there, so systemd neither runs its first boot nor derives a per-container ID. `ssh-host-keys.service` generates missing or empty keys and restores missing or empty public keys before `ssh.service` and every `sshd@.service` instance, which `ssh.socket` starts on demand and which waits for it through the `/etc/systemd/system/sshd@.service.d/10-host-identity.conf` drop-in, and `/etc/ssh/sshd_config.d/10-host-identity.conf` points `HostKey` to them. The host directory, `%h/volumes/vibecoding-main/identity` in the example above, must exist before the container starts. The machine ID and keys are created on the first start and survive container re-creation. On the host the files belong to a subordinate UID of the account, so they are removed with `podman unshare`, for example `podman unshare rm -f ~/volumes/vibecoding-main/identity/*`; the next start then creates a new identity. The directory must not be mounted read-only: on a read-only mount `ssh-host-keys.service` fails and SSH works only with valid keys already stored there, and without a valid stored machine ID the wrapper also prints a warning and systemd starts with its own machine ID.

The image diverts the `systemd-sysv` package's init executable to `init.distrib` and installs the journal wrapper in its place. Package upgrades therefore preserve forwarding. Replacing the wrapper with the package symlink starts systemd but silently loses `podman logs` journal forwarding.

Nested rootless containers can run UID 0 without a rootful engine. Ordinary nested containers default to the outer network namespace. Services such as SSH should use their own network, for example `--network=pasta`: a shared port can already be occupied, and a capability in a nested user namespace does not grant a privileged-port bind in an ancestor network namespace. True rootful nested Podman without outer `SYS_ADMIN` is not part of this profile.

## Shell access and checks

```bash
podman exec --user coder -it vibecoding-main bash -l
podman exec vibecoding-main systemctl --failed
podman logs --tail 100 vibecoding-main
journalctl --user -o cat -u vibecoding-main -f
```

A non-login `podman exec` does not source `/etc/profile`. For a direct nested command, supply coder's runtime environment explicitly:

```bash
podman exec --user coder \
  --env XDG_CONFIG_HOME=/workspace/coder/config \
  --env XDG_RUNTIME_DIR=/run/user/1000 \
  --env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  vibecoding-main podman run --rm --memory=128m --pids-limit=64 \
  mirror.gcr.io/library/alpine:3 \
  sh -ec 'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/pids.max'
```

The expected limits are `134217728` and `64`, not limits inherited from an ancestor.

## Automated tests

`vibeco-debian13` uses `_shared/test/coding/test.sh` as its `IMAGE_TEST`; `_shared/_all/build.sh` sources it after building the image. Its outer launcher `outer.sh` first saves the image and checks that no layer contains `etc/ssh/ssh_host_*_key` or a non-empty `etc/machine-id` or `var/lib/dbus/machine-id`, because later layers only hide such files, then in a disposable container that `systemd-analyze verify` finds no ordering cycle at a boot with `ssh.socket` enabled, that the image ships no `/etc/machine-id`, `/var/lib/dbus/machine-id` or `/etc/ssh/ssh_host_*`, that the `systemd-sysv` init executable stays diverted to `init.distrib` and that `/sbin/init` equals the repository's journal wrapper both before and after `apt-get install --reinstall systemd-sysv`. It then generates seccomp with the helper **installed in the built image** and starts that image without the two admin capabilities or a host socket, with named home, nested-image and host identity volumes and SSH published on `127.0.0.1`. On the outer container it checks user-manager boot, the hostname, systemd as PID 1, zero failed units, that `ssh.service` and an `sshd@.service` instance want and wait for `ssh-host-keys.service`, journal forwarding before and after `journalctl --rotate`, the SSH banner, the machine ID and SSH host keys stored in the identity volume and served by `sshd` (`ssh-keyscan`), the coder runtime environment and the installed default storage/configuration. It makes two stored private keys readable by others and removes or empties their public keys, recreates the container with the same volumes and checks the home, the nested images, the machine ID, the repaired key permissions and public keys and the key fingerprints, starts it once more with a new empty identity volume that must yield a different machine ID and different keys, and runs the installed runtime suite as `coder`.

The host-side launcher requires rootless Podman, crun, jq, `ssh-keyscan`, a working user systemd manager, delegated cgroup v2, sufficiently large subordinate UID/GID maps and `/dev/fuse`; it checks them and fails with an explanatory message instead of changing the host. `test.sh` passes `XDG_RUNTIME_DIR`, by default `/run/user/<UID>`, and the matching `DBUS_SESSION_BUS_ADDRESS` only to its child scripts, not to the sourcing `build.sh`. Only under GitHub Actions (`GITHUB_ACTIONS=true`) it first runs `_shared/test/coding/ci-host.sh` with the same two variables, which installs crun, jq and openssh-client, adds a non-overlapping two-million-ID subordinate range, enables linger, starts the user manager and then runs `podman system migrate` because the runner's rootless engine already started during the build with the old ID map. Unavailable mandatory prerequisites fail rather than skipping the whole suite. The launcher uses a private outer IPC namespace to avoid collisions with its own Podman locks. AppArmor is disabled for this integration container to avoid host-specific nesting restrictions; seccomp remains enabled with only the documented two-syscall adjustment.

The outer container checks report `PASS outer N: name` in their own series. The installed suite reports `PASS runtime N: name`, `SKIP runtime N: name` or `FAIL runtime N: name` in a separate series of **20 runtime cases** of nested rootless Podman:

1. Own procfs and correct PID 1 / `ps`.
2. Private hostname.
3. `--init` / catatonit.
4. No-network namespace.
5. Actual memory and PID limits.
6. Pasta DNS and outbound HTTPS.
7. Named bridge creation.
8. Bridge server startup.
9. Published HTTP port.
10. Peer DNS, peer HTTP and outbound HTTPS.
11. Bind-mount writes.
12. Subordinate UID/GID ownership.
13. OCI build with `RUN`, `chown` and `USER`.
14. Execution of the built image.
15. KVM API access.
16. TUN creation in a private network.
17. Rootless image mount/unmount inside `unshare`.
18. Local Docker-compatible API.
19. Rejection of host PID with disabled cgroups.
20. Rejection of hostname with host UTS.

KVM/TUN cases report explicit `SKIP` when their device is absent. `CODING_TEST_REQUIRE_DEVICES=1` makes missing devices fail instead. Existing but unusable devices always fail. `CODING_TEST_KEEP_LOGS=1` retains logs; the outer launcher copies runtime logs out before deleting its test container. Graphroot/runroot are isolated and cleaned without global reset/prune/migrate. Public base images use `mirror.gcr.io`.

For the full live-container suite:

```bash
podman exec --user coder \
  --env XDG_CONFIG_HOME=/workspace/coder/config \
  --env XDG_RUNTIME_DIR=/run/user/1000 \
  --env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  --env CODING_TEST_REQUIRE_DEVICES=1 \
  vibecoding-main /usr/local/libexec/coding-tests/runtime.sh
```

Standalone generator regression tests run as `_shared/test/coding/seccomp.sh`; `_shared/test/coding/metadata.sh` covers the Podman 5/6 storage-info schema difference without relaxing effective-storage checks, plus the default root user and declared home, storage and host identity volumes. Both are wired into CI. Hardware skips and the generator/outer-launcher checks are reported separately from the 20 runtime cases.
