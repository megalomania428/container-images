<!-- cspell:ignore novnc websockify Xvfb xfce linger oneshot startxfce logind -->
# Obsidian desktop with systemd

Debian 13 with systemd as PID 1, XFCE on Xvfb display `:99`, x11vnc and noVNC on port 6080, and Obsidian 1.6.3 using `/vault`. The `/sbin/init` entry point is a journal wrapper, so Podman automatically enables systemd mode and the entire journal is visible in `podman logs`. Rootless Podman requires cgroup v2 with delegation; systemd runs as UID 0 inside the container.

## Run

```bash
podman run -d --name obsidian -p 127.0.0.1:6080:6080 \
  -v obsidian-vault:/vault -v obsidian-config:/config \
  ghcr.io/megalomania428/obsidian:latest
```

The desktop is available at `http://localhost:6080/vnc.html`.

x11vnc has no password. The port must be published only on a trusted interface, for example with `-p 127.0.0.1:6080:6080` instead of `-p 6080:6080`.

## Volumes

- `/vault` stores notes and is passed to Obsidian as an argument.
- `/config` is `XDG_CONFIG_HOME` for XFCE, GTK, and Obsidian. On the first start, `obsidian-config.service` copies defaults from `/etc/xdg-obsidian` without replacing existing files and creates `/config/.xdg-initialized`.

## Screen size

`SCREEN_WIDTH`, `SCREEN_HEIGHT`, and `SCREEN_DEPTH` are passed through `podman run -e`; the defaults are 1920, 1080, and 24. Example run flags: `-e SCREEN_WIDTH=1280 -e SCREEN_HEIGHT=800`. The former `env_xvfb_SCREEN_WIDTH` format is no longer supported.

## Units

System units run as root: `xvfb.service`, `x11vnc.service`, `novnc.service`, and the first-run `obsidian-config.service`. SSH is disabled.

The `obsidian` user (UID 1000) has linger enabled. At boot, logind starts `user@1000.service`; the standard `dbus.socket` provides the session D-Bus at `/run/user/1000/bus`. User units are `xfce-session.service`, which runs `startxfce4`, and `obsidian.service`, which restarts Obsidian and follows `graphical-session.target`.

Other settings use drop-in files mounted in `/etc/systemd/system/<unit>.d/` or `/etc/systemd/user/<unit>.d/`. Application status can be inspected with:

```bash
podman exec -it obsidian systemctl --user -M obsidian@.host status obsidian.service
```

## Logs

```bash
podman logs obsidian
```
