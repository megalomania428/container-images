#!/usr/bin/env bash
set -euo pipefail
# Builds AppImage for ansible-NN or mkosi-NN tags.
# Runs inside the builder stage of the ansible image built with APPIMAGE_TARGET.
# Usage: TAG=ansible-11 IMAGE_VER=001 build-appimage.sh
# Requires pyenv with Python, downloads appimagetool to /usr/local/bin if missing
: "${TAG:?TAG environment variable must be set (e.g., ansible-11)}"
: "${IMAGE_VER:?IMAGE_VER environment variable must be set (e.g., 001)}"
APPIMAGETOOL='/usr/local/bin/appimagetool.AppImage'
if [[ ! -x "${APPIMAGETOOL}" ]]; then
  echo 'Downloading appimagetool…'
  curl -fsSLm 111 -o "${APPIMAGETOOL}" "https://github.com/AppImage/appimagetool/\
releases/latest/download/appimagetool-$(uname -m).AppImage"
  chmod +x "${APPIMAGETOOL}"
fi
# Source common functions from mounted workspace so changes take effect
# without rebuilding the builder image
# shellcheck disable=SC1091
source /workspace/_shared/install/ansible/common.sh
# Install runtime packages inside the running container so dpkg -L works.
# This avoids rebuilding the builder image when package list changes.
export DEBIAN_FRONTEND=noninteractive
echo "Installing runtime packages…"
apt-get update -q
read -ra _rt_pkgs <<<"$(python_runtime_packages)"
_add_pkgs=()
case "${TAG}" in
mkosi-*)
  read -ra _add_pkgs <<<"$(mkosi_system_packages)"
  ;;
esac
apt-get install -y --no-install-recommends "${_rt_pkgs[@]}" "${_add_pkgs[@]}"
rm -rf /var/lib/apt/lists/*
APP_NAME="${TAG}-${IMAGE_VER}"
APPDIR="${PYENV_ROOT}/versions/${PYENV_VERSION_PYTHON}"
echo "Building AppImage for ${TAG} with Python ${PYENV_VERSION_PYTHON}"
cd "$APPDIR"
# Create sitecustomize.py for portable shebangs
echo "Creating sitecustomize.py…"
SITE_PACKAGES_DIR="$(find lib -type d -name site-packages | head -n1)"
cat >"${SITE_PACKAGES_DIR}/sitecustomize.py" <<'SITECUSTOMIZE_EOF'
from pip._vendor.distlib.scripts import ScriptMaker
ScriptMaker._build_shebang = lambda self, exe, post: b'#!/usr/bin/env python3' + post + b'\n'
SITECUSTOMIZE_EOF
echo "Upgrading pip, setuptools, wheel…"
bin/python -m pip install --upgrade --force-reinstall pip setuptools wheel
case "${TAG}" in
ansible-*)
  REQUIREMENTS="/workspace/sources/${TAG}/requirements.txt"
  if [[ ! -f "${REQUIREMENTS}" ]]; then
    echo "Error: requirements.txt not found at ${REQUIREMENTS}"
    exit 1
  fi
  echo "Installing ansible packages from requirements.txt…"
  bin/python -m pip install -r "${REQUIREMENTS}"
  ;;
mkosi-*)
  echo "Installing mkosi…"
  bin/python -m pip install 'mkosi @ git+https://github.com/systemd/mkosi.git@v26'
  ;;
*)
  echo "Error: unknown TAG format: ${TAG}"
  exit 1
  ;;
esac
# Bundle Python runtime libraries
echo "Bundling Python runtime libraries…"
read -ra _pkg_array <<<"$(python_runtime_packages)"
copy_system_libs "$APPDIR" "${_pkg_array[@]}"
PATCH_DIR="/workspace/_shared/install/ansible"
echo "Creating AppRun…"
cat >AppRun <<'APPRUN_HEADER'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
CMD="$(basename "$0")"
_APP_PATH="${HERE}/bin:${HERE}/usr/bin:${HERE}/usr/sbin:${HERE}/sbin"
APPRUN_HEADER
case "${TAG}" in
mkosi-*)
  # Bundle system tool binaries, libs and data from mkosi dependencies
  echo "Bundling system tools…"
  read -ra _sys_arr <<<"$(mkosi_system_packages)"
  copy_system_files "$APPDIR" "${_sys_arr[@]}"
  # shellcheck disable=2016
  _DEFAULT_BIN='${HERE}/bin/mkosi'
  cat >>AppRun <<'EOF'
_TRIPLET="$(uname -m)-linux-gnu"
export LD_LIBRARY_PATH="${HERE}/lib:${HERE}/usr/lib:${HERE}/lib/${_TRIPLET}:\
${HERE}/usr/lib/${_TRIPLET}:${LD_LIBRARY_PATH:-}"
export PATH="${HERE}/bin:${HERE}/usr/bin:${HERE}/usr/sbin:${HERE}/sbin:${PATH}"
export PYTHONHOME="${HERE}"
EOF
  ;;
ansible-*)
  ANSIBLE_VERSION="${TAG#ansible-}"
  apply_flush_line_patch \
    "$APPDIR" "${PATCH_DIR}/flush-line.patch" "${ANSIBLE_VERSION}"
  apply_async_check_patch \
    "$APPDIR" "${PATCH_DIR}/async-check.patch" "${ANSIBLE_VERSION}"
  apply_recipe_patches "$APPDIR" "/workspace/sources/${TAG}/patches"
  cd "$APPDIR"
  # shellcheck disable=2016
  _DEFAULT_BIN='${HERE}/bin/python'
  cat >>AppRun <<'EOF'
export LD_LIBRARY_PATH="${HERE}/lib:${HERE}/lib64:${LD_LIBRARY_PATH:-}"
export PATH="${HERE}/bin:${HERE}/usr/bin:${PATH}"
export PYTHONHOME="${HERE}"
export PYTHONPATH="${HERE}/lib/python"
_SITE_PKG="$(echo "${HERE}"/lib/python*/site-packages)"
export ANSIBLE_COLLECTIONS_PATH="${HOME}/.ansible/collections:\
${_SITE_PKG}/ansible_collections"
: "${ANSIBLE_USERDIR:="${HOME}/.ansible"}"
/usr/bin/env mkdir -vp "${ANSIBLE_USERDIR}"/{ssh,tmp}
/usr/bin/env cat >"${ANSIBLE_USERDIR}/ssh/config" <<SSHCONFIG
# ssh config for Ansible
SendEnv=LC_*
SendEnv=LANG
SendEnv=ANSIBLE_*
SendEnv=RSYNC_RSH
ForwardAgent=yes
ControlMaster=auto
ControlPersist=111m
HostKeyAlgorithms=ssh-ed25519
StrictHostKeyChecking=accept-new
PreferredAuthentications=publickey
ControlPath=${ANSIBLE_USERDIR}/ssh/host-%r@%h:%p
UserKnownHostsFile=${ANSIBLE_USERDIR}/ssh/known_hosts
Include ${ANSIBLE_USERDIR}/ssh/conf.d/*
SSHCONFIG
export ANSIBLE_SSH_ARGS="-F ${ANSIBLE_USERDIR}/ssh/config"
EOF
  ;;
esac
cleanup_python_packages "$APPDIR"
cat >>AppRun <<EOF
if [[ "\${CMD}" != "AppRun" ]] &&
  _BIN="\$(PATH="\${_APP_PATH}" command -v "\${CMD}" 2>/dev/null)"; then
  exec "\${_BIN}" "\$@"
fi
if [[ \$# -gt 0 ]] && _BIN="\$(PATH="\${_APP_PATH}" command -v "\$1" 2>/dev/null)"; then
  shift
  exec "\${_BIN}" "\$@"
fi
exec "${_DEFAULT_BIN}" "\$@"
EOF
chmod +x AppRun
echo "Creating desktop file…"
cat >"${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=${APP_NAME}
Icon=${APP_NAME}
Categories=Development;
Terminal=true
EOF
echo "Creating icon…"
printf '\x89PNG\r\n\x1a\n' >"${APP_NAME}.png"
echo "Building AppImage…"
"${APPIMAGETOOL}" "${APPDIR}" "${APP_NAME}.AppImage"
mkdir -p /output
cp "${APP_NAME}.AppImage" /output/
echo "Build finished successfully!"
echo "  /output/${APP_NAME}.AppImage"
