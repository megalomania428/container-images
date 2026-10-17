#!/usr/bin/env bash

cleanup_python_packages() {
  local python_root="$1"
  echo "Cleaning up Python packages…"
  find "${python_root}" -depth \
    \( \
    \( -type d -a \( \
    -name test -o -name tests -o -name __pycache__ \
    \) -a -not -path '*/ansible/plugins/test' \) \
    -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name '*.a' \) \) \
    -o \( -type f -a -name 'wininst-*.exe' \) \
    \) -exec rm -rf '{}' +
}

apply_flush_line_patch() {
  local python_root="$1"
  local patch_file="$2"
  local ansible_version="$3"
  # ansible-06 doesn't use flush-line.patch
  if [[ "${ansible_version}" == "06" ]]; then
    echo "Skipping flush-line.patch for ansible-06 (not needed)"
    return
  fi
  if [[ ! -f "${patch_file}" ]]; then
    echo "Warning: flush-line.patch not found at ${patch_file}, skipping"
    return
  fi
  echo "Applying flush-line.patch patch…"
  # patch paths start with lib/python3.X/site-packages/, strip them for any Python
  # shellcheck disable=2164
  cd "${python_root}"/lib/python*/site-packages
  # newer ansible-core keeps the flush block commented with OSError instead of IOError
  if grep -q '^ *# except OSError as e:$' ansible/utils/display.py; then
    sed 's/except IOError as e:/except OSError as e:/' "${patch_file}" | patch -p3
  else
    patch -p3 <"${patch_file}"
  fi
}

apply_recipe_patches() {
  local python_root="$1"
  local patch_dir="$2"
  local site_packages
  local patch_file
  site_packages="$(echo "${python_root}"/lib/python*/site-packages)"
  # recipe patches keep upstream lib/ansible/ paths, pip installs them without lib/
  for patch_file in "${patch_dir}/"*.patch; do
    [[ -f "${patch_file}" ]] || continue
    echo "Applying ${patch_file}…"
    sed -E '/^(---|\+\+\+) [ab]\/lib\/ansible\//s@/lib/ansible/@/ansible/@' \
      "${patch_file}" | patch --batch --forward --fuzz=0 -d "${site_packages}" -p1
  done
}

copy_system_libs() {
  local appdir="$1"
  shift
  local packages=("$@")
  echo "Copying system libraries from packages: ${packages[*]}"
  local lib_dir="${appdir}/lib"
  mkdir -p "${lib_dir}"
  for pkg in "${packages[@]}"; do
    # dpkg may not know about meta-packages or virtual ones — skip silently
    dpkg -L "${pkg}" 2>/dev/null || continue
  done | grep -E '\.so(\.[0-9]+)*$' | grep -v '/liblzma\.so' | while read -r src; do
    [[ -e "${src}" || -L "${src}" ]] || continue
    dst="${lib_dir}/$(basename "${src}")"
    if [[ -L "${src}" ]]; then
      # Preserve symlinks as-is (relative target kept)
      ln -sf "$(readlink "${src}")" "${dst}"
    else
      cp -a "${src}" "${dst}"
    fi
  done
}

find_package() {
  apt-cache search --names-only "$1" 2>/dev/null |
    awk '{printf "%s ", $1}'
}

python_runtime_packages() {
  find_package '^libreadline[_\.0-9\-]+$'
  find_package '^libsqlite[_\.0-9\-]+$'
  find_package '^libbz[_\.0-9\-]+$'
  find_package '^zlib[\.0-9\-]+[a-z]$'
  find_package '^libssl[0-9]'
  find_package '^libffi[0-9]+$'
  find_package '^liblzma[0-9]+$'
}

mkosi_system_packages() {
  printf '%s ' \
    debootstrap systemd-container xfsprogs e2fsprogs dosfstools \
    btrfs-progs squashfs-tools debian-archive-keyring ubuntu-keyring \
    fdisk util-linux udev kmod zstd xz-utils cpio curl \
    grub-pc-bin grub-common qemu-utils
}

# Returns all recursive dependencies of given packages (installed only)
get_package_deps() {
  local packages=("$@")
  apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    "${packages[@]}" 2>/dev/null | awk '
      /^[[:space:]]*(Depends|PreDepends):/ {
        sub(/^[[:space:]]*(Depends|PreDepends):[[:space:]]*/, "")
        n = split($0, parts, /\|/)
        for (i = 1; i <= n; i++) {
          pkg = parts[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", pkg)
          if (pkg ~ /^</) {
            continue
          }
          if (pkg ~ /^[a-z0-9][a-z0-9.+-]*$/) {
            print pkg
          }
        }
      }
    ' | sort -u
}

# Copies system package files into AppDir preserving paths.
# Filter: bin/*, sbin/*, *.so*, grub modules, debootstrap scripts, keyrings.
# Also processes all recursive deps of given packages.
copy_system_files() {
  local appdir="$1"
  shift
  local packages=("$@")
  echo "Resolving dependencies for: ${packages[*]}"
  local dep_str
  dep_str="$(get_package_deps "${packages[@]}")"
  local all_pkgs=("${packages[@]}")
  if [[ -n "$dep_str" ]]; then
    mapfile -t dep_arr <<<"$dep_str"
    all_pkgs+=("${dep_arr[@]}")
  fi
  echo "Copying files from ${#all_pkgs[@]} packages (including deps)…"
  for pkg in "${all_pkgs[@]}"; do
    [[ -z "$pkg" ]] && continue
    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii' || continue
    dpkg -L "$pkg" 2>/dev/null | while IFS= read -r src; do
      [[ -f "$src" || -L "$src" ]] || continue
      case "$src" in
      */bin/* | */sbin/* | */*.so | */*.so.[0-9]* | */lib/grub/* | \
        */share/debootstrap/* | */share/keyrings/* | */share/ubuntu-keyring/* | \
        */share/grub/* | /etc/*)
        # Never bundle glibc and core system libs — they are always
        # present on the host and are tied to the kernel ABI.
        # Bundling an older glibc breaks host binaries like /usr/bin/env.
        case "$(basename "$src")" in
        libc.so* | libc-[0-9]*.so* | libpthread.so* | libpthread-[0-9]*.so* | \
          libdl.so* | libdl-[0-9]*.so* | librt.so* | librt-[0-9]*.so* | libm.so* | \
          libm-[0-9]*.so* | libgcc_s.so* | libstdc++.so* | ld-linux*.so* | \
          ld-[0-9]*.so*)
          continue
          ;;
        esac
        dst="${appdir}${src}"
        mkdir -p "$(dirname "$dst")"
        if [[ -L "$src" ]]; then
          target="$(readlink "$src")"
          if [[ "$target" = /* ]]; then
            # Absolute symlink: resolve to real file and copy it to dst
            real_target="$(realpath "$src" 2>/dev/null)"
            if [[ -f "$real_target" ]]; then
              cp -a "$real_target" "$dst"
            fi
          else
            ln -sf "$target" "$dst"
          fi
        else
          cp -a "$src" "$dst"
        fi
        ;;
      esac
    done
  done
}

apply_async_check_patch() {
  local python_root="$1"
  local patch_file="$2"
  local ansible_version="$3"
  # async-check.patch only for ansible-06, 07, 08, 09
  case "${ansible_version}" in
  06 | 07 | 08 | 09)
    if [[ ! -f "${patch_file}" ]]; then
      echo "Warning: async-check.patch not found at ${patch_file}, skipping"
      return
    fi
    echo "Applying async-check.patch patch for ansible-${ansible_version}…"
    # shellcheck disable=2164
    cd "${python_root}"
    if [[ "${ansible_version}" == "06" ]]; then
      # ansible-06: modified version (only first part, without __init__.py)
      awk \
        '/^--- .+site-packages\/ansible\/plugins\/action\/__init__/ { exit } { print }' \
        "${patch_file}" | patch -p0
      # Additional sed fix for ansible-06
      sed -ri '/^\s+elif self._task.async_val and self\..+$/d;
/^.+check mode and async cannot be used on same task.+$/d' \
        lib/python*/site-packages/ansible/plugins/action/__init__.py
    else
      # ansible-07, 08, 09: full patch
      patch -p0 <"${patch_file}"
    fi
    ;;
  *)
    echo "Skipping async-check.patch for ansible-${ansible_version} (not needed)"
    ;;
  esac
}
