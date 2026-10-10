#!/usr/bin/env bash
# cspell:ignore obsidian novnc websockify xvfb x11vnc xfce xfwm xfconf xfdesktop gtkrc
# cspell:ignore nologin libasound dbus xfce4 thunar metacity libpam logind
# cspell:ignore fastfetch awf nopasswd sudoers passwordless whiskermenu notifyd libxfce
# cspell:ignore xkb libxklavier xdg initialized clipman rgba xsettings redmochi hintstyle
# cspell:ignore hintslight xfconfd dconf ccd mateconf pastel greymond gawk gdir gname
# cspell:ignore Metatheme tdir themerc tname vaio sysv startxfce
set -xueo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
# keep the journal wrapper of the systemd installer as init: systemd-sysv (pulled by
# dbus-user-session via libpam-systemd) gets its init symlink diverted aside
dpkg-divert --local --no-rename --divert /usr/sbin/init.systemd-sysv --add /usr/sbin/init
apt-get install -y --no-install-recommends xvfb x11vnc novnc websockify bc gawk xfce4 \
  mate-terminal xfwm4 xfconf xfce4-session xfdesktop4 xfce4-panel dbus dbus-user-session \
  at-spi2-core fastfetch awf-gtk3 awf-gtk4 sudo wget ca-certificates libasound2t64 \
  libdbus-1-3 xfce4-whiskermenu-plugin xfce4-eyes-plugin xfce4-xkb-plugin xfce4-notifyd \
  xfce4-clipman-plugin gtk2-engines dconf-cli xfce4-terminal
if [[ -L /usr/sbin/init || ! -x /usr/sbin/init ]]; then
  echo 'journal wrapper /usr/sbin/init was replaced' >&2
  exit 1
fi
_obsidian_ver='1.6.3'
_obsidian_url="https://github.com/obsidianmd/obsidian-releases/releases/download/\
v${_obsidian_ver}/obsidian_${_obsidian_ver}_amd64.deb"
_deb='/tmp/obsidian.deb'
wget -qO "${_deb}" "${_obsidian_url}"
dpkg -i "${_deb}" || apt-get install -fy --no-install-recommends
rm -f "${_deb}"
# install Redmond97 Rainy Day xfwm4+gtk theme from upstream checkout
install -d -m 755 '/usr/share/themes/Redmond97 Rainy Day'
cp -r '/files/shared/redmond97/Theme/no-csd/Redmond97 Rainy Day/.' \
  '/usr/share/themes/Redmond97 Rainy Day/'
# patch base_color: upstream uses #FFFFFF, we want a slightly darkened window bg
sed -i 's/^base_color:#FFFFFF/base_color:#c1ccd9/' \
  '/usr/share/themes/Redmond97 Rainy Day/gtk-2.0/gtkrc'
sed -i 's/@define-color base_color #FFFFFF;/@define-color base_color #c1ccd9;/' \
  '/usr/share/themes/Redmond97 Rainy Day/gtk-3.0/gtk.css'
# install Chicago95 Rainy Day theme: base from upstream Chicago95, colors from
# Windows 98 Rainy Day palette (converted via ChicagoPlus.py, base_color patched)
install -d -m 755 '/usr/share/themes/Chicago95 Rainy Day'
cp -r /files/shared/chicago95/Theme/Chicago95/. '/usr/share/themes/Chicago95 Rainy Day/'
# overlay Rainy Day-colored gtk.css and xfwm4/themerc over the Chicago95 base
cp /files/conf/chicago95-rainy-day/gtk-3.0/gtk.css \
  '/usr/share/themes/Chicago95 Rainy Day/gtk-3.0/gtk.css'
cp /files/conf/chicago95-rainy-day/xfwm4/themerc \
  '/usr/share/themes/Chicago95 Rainy Day/xfwm4/themerc'
# patch GTK2 gtkrc: bg_color and base_color to match GTK3
sed -i 's/bg_color:#c0c0c0/bg_color:#8399b1/; s/base_color:#ffffff/base_color:#c1ccd9/;
s/selected_bg_color:#000080/selected_bg_color:#4f657d/' \
  '/usr/share/themes/Chicago95 Rainy Day/gtk-2.0/gtkrc'
# install Greymond themes: each variant has its own gtk-2.0/gtk-3.0 with shared
# widgets via symlinks; cp -rL resolves symlinks at copy time
for _gdir in /files/shared/greymond/src/Greymond-*/; do
  _gname="$(basename "${_gdir}")"
  install -d -m 755 "/usr/share/themes/${_gname}"
  cp -rL "${_gdir}." "/usr/share/themes/${_gname}/"
  # generate index.theme for each variant
  cat >"/usr/share/themes/${_gname}/index.theme" <<EOF
[Desktop Entry]
Name=${_gname}
Type=X-GNOME-Metatheme
Comment=Greymond GTK theme
Encoding=UTF-8

[X-GNOME-Metatheme]
GtkTheme=${_gname}
MetacityTheme=
IconTheme=
BackgroundImage=
EOF
done
# copy shared xfwm4 from Greymond base (neutral grey, used by all variants)
for _gdir in /usr/share/themes/Greymond-*/; do
  cp -r /files/shared/greymond/src/Greymond/xfwm4/. "${_gdir}xfwm4/"
done
# install Pastel2K themes: run gen_theme.sh for each conf, output to /usr/share/themes
_pastel_tools='/files/shared/pastel2k/tools'
for _conf in /files/shared/pastel2k/conf/*.conf \
  /files/shared/pastel2k/conf/vaio/*.conf; do
  _workdir="$(mktemp -d)"
  cp "${_pastel_tools}/base.tar.gz" "${_pastel_tools}/gen_theme.sh" \
    "${_pastel_tools}/theme_default" "${_conf}" "${_workdir}/"
  cp "${_workdir}/$(basename "${_conf}")" "${_workdir}/theme.conf"
  HOME="${_workdir}/.home" mkdir -p "${_workdir}/.home/.themes"
  # gen_theme.sh exits 1 due to a typo in its cleanup; ignore non-zero exit
  (cd "${_workdir}" && HOME="${_workdir}/.home" bash gen_theme.sh 2>/dev/null) || true
  # move generated theme to system themes
  for _tdir in "${_workdir}/.home/.themes"/*/; do
    _tname="$(basename "${_tdir}")"
    install -d -m 755 "/usr/share/themes/${_tname}"
    cp -r "${_tdir}." "/usr/share/themes/${_tname}/"
  done
  rm -rf "${_workdir}"
done
unset _gdir _gname _pastel_tools _conf _workdir _tdir _tname
# install Redmond97 icon set (bundled in Redmond97 repo under Extras/Icons/)
install -d -m 755 /usr/share/icons/Redmond97
cp -r /files/shared/user-config/.icons/Redmond97/. /usr/share/icons/Redmond97/
gtk-update-icon-cache -f -t /usr/share/icons/Redmond97 || true
useradd -m -u 1000 -s /bin/bash obsidian
install -d -m 755 /vault /config
chown obsidian:obsidian /vault /config
# passwordless sudo for the obsidian user
echo 'obsidian ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/obsidian
chmod 440 /etc/sudoers.d/obsidian
# store default xfce4/gtk configs in /etc/xdg-obsidian/ — obsidian-config.service
# copies them to /config/ (XDG_CONFIG_HOME) on first container start
_xdg='/etc/xdg-obsidian'
install -d -m 755 "${_xdg}/xfce4/xfconf/xfce-perchannel-xml"
install -d -m 755 "${_xdg}/xfce4/panel"
install -d -m 755 "${_xdg}/autostart"
install -d -m 755 "${_xdg}/gtk-3.0"
# copy xfconf channel configs: theme, panel, desktop, keybindings, wm, session
# (xfce4-session: no save-on-exit, no screensaver, no first-run dialog)
# also install as system-wide xfce4 defaults — xfwm4 reads these directly
# at startup before connecting to xfconfd (it may run with empty environ)
for _xml in xsettings xfwm4 xfce4-panel xfce4-desktop \
  xfce4-keyboard-shortcuts xfce4-notifyd xfce4-session; do
  install -m 644 "/files/conf/xfconf/${_xml}.xml" \
    "${_xdg}/xfce4/xfconf/xfce-perchannel-xml/${_xml}.xml"
done
# panel plugin configs (whiskermenu, eyes)
install -m 644 /files/conf/panel/whiskermenu-8.rc \
  "${_xdg}/xfce4/panel/whiskermenu-8.rc"
install -m 644 /files/conf/panel/eyes-2.rc \
  "${_xdg}/xfce4/panel/eyes-2.rc"
install -m 644 /files/conf/autostart/xfce4-clipman.desktop \
  "${_xdg}/autostart/xfce4-clipman.desktop"
# gtk-3.0 settings: Greymond-Rainy-Day theme + Redmond97 icons
install -m 644 /files/conf/gtk-3.0/settings.ini "${_xdg}/gtk-3.0/settings.ini"
# gtk-2.0 settings (lives in home dir, not XDG_CONFIG_HOME)
install -m 644 /files/conf/gtkrc-2.0 /home/obsidian/.gtkrc-2.0
install -d -m 755 /home/obsidian/.local/share/applications
chown -R obsidian:obsidian /home/obsidian/.local /home/obsidian/.gtkrc-2.0
# configure mate-terminal profile via dconf compile (no dbus required at build time)
# result into xdg template — obsidian-config.service copies it to /config/dconf/user
install -d -m 755 "${_xdg}/dconf"
dconf compile "${_xdg}/dconf/user" /files/conf/dconf
# set mate-terminal as preferred terminal emulator for exo-open
# XDG_CONFIG_HOME=/config in container, so helpers.rc goes into the xdg template
cat >"${_xdg}/xfce4/helpers.rc" <<'EOF'
TerminalEmulator=mate-terminal
EOF
# system units: virtual display, VNC, noVNC and first-run /config seeding
install -m 644 -t /etc/systemd/system /files/systemd/system/*.service
install -d -m 755 /etc/systemd/system/user@1000.service.d
install -m 644 /files/systemd/system/user@1000.service.d/obsidian.conf \
  /etc/systemd/system/user@1000.service.d/obsidian.conf
# user units: XFCE session and Obsidian, started by the lingering user manager
install -d -m 755 /etc/systemd/user
install -m 644 -t /etc/systemd/user /files/systemd/user/*.service
install -d -m 755 /etc/environment.d
install -m 644 /files/environment.d/60-obsidian.conf /etc/environment.d/60-obsidian.conf
systemctl enable xvfb.service x11vnc.service novnc.service
systemctl --global enable xfce-session.service obsidian.service
systemctl disable ssh.service
# logind starts user@1000.service with the user bus at boot for lingering users
install -d -m 755 /var/lib/systemd/linger
touch /var/lib/systemd/linger/obsidian
# cleanup
apt-get clean
rm -Rf /usr/share/doc /usr/share/man /var/lib/apt/lists/* /root/.cache /files \
  '/usr/share/themes/Chicago95 Rainy Day/xfce-notify-4.0' \
  '/usr/share/themes/Chicago95 Rainy Day/gnome-shell' \
  '/usr/share/themes/Chicago95 Rainy Day/cinnamon' \
  '/usr/share/themes/Chicago95 Rainy Day/metacity-1' \
  '/usr/share/themes/Redmond97 Rainy Day/metacity-1'
