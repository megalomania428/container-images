<!-- cspell:ignore journalctl msmtp msmtpq msmtprc transmail -->
# Transmission 4.1.4 on Debian 13

`transmission-cli`, `transmission-common` and `transmission-daemon` 4.1.4 together with `msmtp` 1.8.28 are rebuilt in a builder stage from the Debian trixie packaging with the patches from `patches/`; the final `debian:trixie-slim` stage receives only the resulting `.deb` files.

A finished torrent sends mail through `/usr/local/bin/transmail.sh` → `mutt` → `/usr/bin/msmtpq` → `msmtp`.

The `msmtpq` queue lives in the named volume `transmission-msmtpq` mounted to `/var/spool/msmtpq`, so queued mail survives a service restart and `--rm` (only anonymous volumes are removed with a container).

## Podman Quadlet

`/etc/containers/systemd/transmission.container`:

```ini
[Unit]
Description=transmission
Wants=network-online.target
After=network-online.target

[Container]
Image=ghcr.io/megalomania428/transmission-debian13:latest
EnvironmentFile=/etc/default/transmission
ContainerName=transmission
HostName=transmission
RunInit=true
PublishPort=9091:9091
PublishPort=11000-11110:11000-11110/tcp
PublishPort=11000-11110:11000-11110/udp
Volume=/home/podman/.config/transmission:/etc/transmission-daemon
Volume=/home/lib/t:/home/lib/t
Volume=transmission-msmtpq:/var/spool/msmtpq
PodmanArgs=--cidfile=%t/user/888/%N.cid --runtime runc

[Service]
User=podman
Group=podman
ExecStop=/usr/bin/podman rm -v -f -i --cidfile=%t/user/888/%N.cid
ExecStopPost=-/usr/bin/podman rm -v -f -i --cidfile=%t/user/888/%N.cid
RestartSec=1
Restart=always
StartLimitInterval=0
SyslogIdentifier=transmission
TimeoutStopSec=22s
TimeoutStartSec=11m
```

`PodmanArgs` moves the container ID file to `%t/user/888/%N.cid` (`888` is the UID of `podman`, `%t` of the system manager is `/run`), so the extra `ExecStop` and `ExecStopPost` remove the container through that file; they run before the Quadlet generated ones, which then find no file and do nothing.

## Environment

`/etc/default/transmission`:

```bash
TRANSMAIL_FROM=transmission@example.org
TRANSMAIL_TO=admin@example.org
MSMTPQ_PERIOD=555
TRANSMISSION_RPC_PASSWORD=
```

Without `TRANSMAIL_FROM` or `TRANSMAIL_TO` no mail is sent; `TRANSMAIL_FROM` may include a display name, for example `Transmission <transmission@example.org>`, and is passed to `mutt` as `EMAIL`; `MSMTPQ_PERIOD=0` turns the background queue flush off; `TRANSMISSION_RPC_PASSWORD` is read only when `settings.json` does not exist yet, and when it is empty or missing a random password is printed to the container log (`journalctl -t transmission`); a value that starts with `{` and is at least 41 characters long is treated by Transmission as an already salted hash, the same as in `settings.json`.

## Config directory

The host directory `/home/podman/.config/transmission` is mounted to `/etc/transmission-daemon` and holds `settings.json` (when it is missing it is created from the image default with the RPC password from `TRANSMISSION_RPC_PASSWORD` or a random one, and the daemon rewrites the file on start), the daemon state (`torrents/`, `resume/`, `stats.json`) and `msmtprc` (without it the queue flush does not start); `/home/lib/t` holds the downloads (`download_dir` is `/home/lib/t/files`).
