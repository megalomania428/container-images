#!/usr/bin/env bash
# cspell:ignore conffile envfile MANAGERPID MANAGERPIDFDID readenv runuser
# Session environment hook checks of the coding image: outer.sh runs the fixture and
# stable steps on the host and the others as root inside its disposable outer container.
set -ueo pipefail
export DEBIAN_FRONTEND=noninteractive
dir=/run/coding-session-env
loopback=127.0.0.1 # DevSkim: ignore DS162092
profile=/usr/share/pam-configs/coding-env
hook_args='readenv=1 user_readenv=0 conffile=/dev/null envfile=/etc/coding/session.env'
hook_line="session optional pam_env.so ${hook_args}"
# Names whose values differ between two otherwise identical logins or containers.
volatile_names=(_ container_uuid INVOCATION_ID JOURNAL_STREAM MANAGERPID MANAGERPIDFDID
  MEMORY_PRESSURE_WATCH MEMORY_PRESSURE_WRITE MOTD_SHOWN SSH_CLIENT SSH_CONNECTION SSH_TTY
  SYSTEMD_EXEC_PID XDG_SESSION_ID)
ssh_opts=(-i "${dir}/key" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
fail() {
  echo "session hook: $*" >&2
  exit 1
}
fixture() {
  cat <<'EOF'
# fixture of the coding session hook test
CODING_HOOK_DOLLAR=a$b${HOME}$(id)
CODING_HOOK_BACKSLASH=c\d\\e\n
CODING_HOOK_QUOTE=say "hi" x
CODING_HOOK_PERCENT=100%s%%
CODING_HOOK_AT=u@{PAM_USER}@host
CODING_HOOK_QUOTED="outer quoted"
CODING_HOOK_ENV=hook
CODING_HOOK_LOCALE=hook
EOF
}
# Lines every covered session must get literally from the fixture.
expected() {
  cat <<'EOF'
CODING_HOOK_DOLLAR=a$b${HOME}$(id)
CODING_HOOK_BACKSLASH=c\d\\e\n
CODING_HOOK_QUOTE=say "hi" x
CODING_HOOK_PERCENT=100%s%%
CODING_HOOK_AT=u@{PAM_USER}@host
CODING_HOOK_QUOTED=outer quoted
EOF
}
stable() {
  local names
  names="$(IFS='|' && echo "${volatile_names[*]}")"
  awk -v re="^(${names})=" '$0 !~ re' | LC_ALL=C sort
}
# Counts the lines of file $2 equal to line $1 after collapsing blanks.
hook_count() {
  awk -v line="$1" '{ $1 = $1 } $0 == line { n++ } END { print n + 0 }' "$2"
}
hook_lines() {
  local file
  for file in common-session common-session-noninteractive; do
    [[ $(hook_count "$1" "/etc/pam.d/${file}") -eq $2 ]] ||
      fail "/etc/pam.d/${file} must contain $2 line(s): $1"
  done
}
wait_manager() {
  for _ in {1..60}; do
    if systemctl is-active --quiet "user@$1.service" &&
      [[ -S /run/user/$1/bus ]]; then
      return 0
    fi
    sleep 1
  done
  fail "user@$1.service did not start"
}
restart_managers() {
  local uid
  for uid in "$@"; do
    systemctl reset-failed "user@${uid}.service" 2>/dev/null || true
    systemctl restart "user@${uid}.service"
    wait_manager "${uid}"
  done
}
# Runs a command as user $1 against the user manager of that user.
as_user() {
  local user="$1" uid
  shift
  uid="$(id -u "${user}")"
  runuser -u "${user}" -- env XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
}
# Prints the environment of the interactive login shell that the given command starts.
tty_env() {
  rm -f "${dir}/tty/env"
  timeout 60 "$@" <<<"env >${dir}/tty/env; exit" >/dev/null 2>&1 || true
  [[ -s ${dir}/tty/env ]] || fail "no environment from: $*"
  cat "${dir}/tty/env"
}
# Starts login as its own session leader on a pty and sends the command only after
# the shell prompt appears, because login flushes input that arrives earlier.
login_env() {
  rm -f "${dir}/tty/env"
  # shellcheck disable=SC2016
  ENV_FILE="${dir}/tty/env" timeout 60 expect -c '
set timeout 30
spawn login -f coder
expect -re {[$#] $}
send "env >$env(ENV_FILE); exit\r"
expect eof' >/dev/null 2>&1 || true
  [[ -s ${dir}/tty/env ]] || fail 'no environment from: login -f coder'
  cat "${dir}/tty/env"
}
ssh_env() {
  ssh -n "${ssh_opts[@]}" "coder@${loopback}" env
}
su_env() {
  su - coder -c env </dev/null
}
sudo_env() {
  runuser -u coder -- sudo env </dev/null
}
capture() {
  local out="$1"
  mkdir -p "${out}"
  tty_env ssh -tt "${ssh_opts[@]}" "coder@${loopback}" | stable >"${out}/ssh-tty"
  ssh_env | stable >"${out}/ssh-cmd"
  su_env | stable >"${out}/su"
  sudo_env | stable >"${out}/sudo"
  as_user coder systemctl --user show-environment | stable >"${out}/user-coder"
  as_user root systemctl --user show-environment | stable >"${out}/user-root"
  tr '\0' '\n' </proc/1/environ | stable >"${out}/pid1"
  systemd-run --wait --pipe --quiet env </dev/null | stable >"${out}/unit"
}
cursor() {
  journalctl -q -n 1 -o cat --show-cursor | sed -n 's/^-- cursor: //p'
}
# Prints the PAM warnings and errors logged after cursor $1.
pam_messages() {
  local out rc=0
  journalctl --sync
  journalctl -q --no-pager -n 1 --after-cursor="$1" -o cat >/dev/null ||
    fail 'cannot read the journal after the cursor'
  out="$(journalctl -q --no-pager -p warning --after-cursor="$1" -o cat)" || rc=$?
  # journalctl may exit with 1 when no entry matches the priority filter
  [[ ${rc} -eq 0 || (${rc} -eq 1 && -z ${out}) ]] ||
    fail "journalctl failed with code ${rc}"
  awk '/pam_|PAM/' <<<"${out}" | LC_ALL=C sort
}
prepare() {
  local keys=/home/coder/.ssh/authorized_keys
  rm -rf "${dir}"
  install -d -m 755 "${dir}"
  install -d -m 1777 "${dir}/tty"
  ssh-keygen -q -t ed25519 -N '' -C coding-session-env-test -f "${dir}/key"
  install -d -m 700 -o coder -g coder /home/coder/.ssh
  [[ -e ${keys} ]] || install -m 600 -o coder -g coder /dev/null "${keys}"
  cat "${dir}/key.pub" >>"${keys}"
}
finish() {
  sed -i '/ coding-session-env-test$/d' /home/coder/.ssh/authorized_keys
}
snapshot() {
  local out="${dir}/snapshots/$1" start
  rm -rf "${out}"
  start="$(cursor)"
  [[ -n ${start} ]] || fail 'no journal cursor'
  restart_managers 1000 0
  capture "${out}"
  pam_messages "${start}" >"${out}/journal"
}
remove_hook() {
  local file
  hook_lines "${hook_line}" 1
  rm -rf "${dir}/pam.d"
  cp -a /etc/pam.d "${dir}/pam.d"
  pam-auth-update --remove coding-env
  hook_lines "${hook_line}" 0
  for file in common-session common-session-noninteractive; do
    awk -v line="${hook_line}" '{ text = $0; $1 = $1 } $0 != line { print text }' \
      "${dir}/pam.d/${file}" | cmp - "/etc/pam.d/${file}" ||
      fail "/etc/pam.d/${file} differs by more than the hook line"
  done
  diff -r -x common-session -x common-session-noninteractive "${dir}/pam.d" \
    /etc/pam.d || fail 'removing the hook changed other /etc/pam.d files'
}
restore_hook() {
  pam-auth-update --package
  hook_lines "${hook_line}" 1
}
entries=(ssh-tty ssh-cmd su sudo sudo-podman user-coder user-root)
# Saves the environments of every covered entry point of state $1 under ${dir}/$1,
# running image $2 with sudo podman.
collect() {
  local out="${dir}/$1" user
  rm -rf "${out}"
  mkdir -p "${out}"
  restart_managers 1000 0
  tty_env ssh -tt "${ssh_opts[@]}" "coder@${loopback}" >"${out}/ssh-tty"
  ssh_env >"${out}/ssh-cmd"
  su_env >"${out}/su"
  sudo_env >"${out}/sudo"
  runuser -u coder -- sudo podman run --rm --pull=never --env-host "$2" env \
    </dev/null >"${out}/sudo-podman"
  for user in coder root; do
    as_user "${user}" systemctl --user show-environment >"${out}/user-${user}.show"
    as_user "${user}" systemd-run --user --wait --pipe --quiet env </dev/null \
      >"${out}/user-${user}"
  done
}
# Succeeds when environment file $1 has every expected line.
delivered() {
  local line
  while IFS= read -r line; do
    grep -Fxq -- "${line}" "$1" || return 1
  done < <(expected)
}
# Sets decoded to the value of the systemd quoting $'...' body $1; fails on anything else.
unquote() {
  local rest="$1" ch digits
  decoded=''
  while [[ -n ${rest} ]]; do
    ch="${rest:0:1}"
    rest="${rest:1}"
    if [[ ${ch} != \\ ]]; then
      decoded+="${ch}"
      continue
    fi
    ch="${rest:0:1}"
    rest="${rest:1}"
    case "${ch}" in
    \\ | "'" | '"') decoded+="${ch}" ;;
    a) decoded+=$'\a' ;;
    b) decoded+=$'\b' ;;
    e) decoded+=$'\e' ;;
    f) decoded+=$'\f' ;;
    n) decoded+=$'\n' ;;
    r) decoded+=$'\r' ;;
    t) decoded+=$'\t' ;;
    v) decoded+=$'\v' ;;
    [0-7])
      digits="${ch}"
      while [[ ${#digits} -lt 3 && ${rest:0:1} == [0-7] ]]; do
        digits+="${rest:0:1}"
        rest="${rest:1}"
      done
      printf -v ch '%b' "\\0${digits}"
      decoded+="${ch}"
      ;;
    x)
      [[ ${rest:0:2} =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
      printf -v ch '%b' "\\x${rest:0:2}"
      decoded+="${ch}"
      rest="${rest:2}"
      ;;
    *) return 1 ;;
    esac
  done
}
# Succeeds when show-environment output $1 has, for every expected line, a line of the
# same name whose value, after undoing the quoting of systemd, equals the expected one.
listed() {
  local line name value shown
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    shown="$(grep -m 1 -- "^${name}=" "$1")" || return 1
    shown="${shown#*=}"
    if [[ ${shown} == "\$'"*"'" ]]; then
      unquote "${shown:2:${#shown}-3}" || return 1
      shown="${decoded}"
    fi
    [[ ${shown} == "${value}" ]] || return 1
  done < <(expected)
}
check_delivered() {
  local name user
  collect "$1" "$2"
  for name in "${entries[@]}"; do
    delivered "${dir}/$1/${name}" || fail "$1: ${name} lacks session file values"
  done
  for user in coder root; do
    listed "${dir}/$1/user-${user}.show" ||
      fail "$1: show-environment of ${user} lacks session file variables"
  done
}
check_undelivered() {
  local name user
  collect "$1" "$2"
  for name in "${entries[@]}" user-coder.show user-root.show; do
    grep -q '^HOME=' "${dir}/$1/${name}" || fail "$1: no environment from ${name}"
  done
  for name in "${entries[@]}"; do
    if delivered "${dir}/$1/${name}"; then
      fail "$1: the delivery check passes for ${name}"
    fi
  done
  for user in coder root; do
    if listed "${dir}/$1/user-${user}.show"; then
      fail "$1: the delivery check passes for show-environment of ${user}"
    fi
  done
}
side_effects() {
  local pid1 unit
  pid1="$(tr '\0' '\n' </proc/1/environ)"
  unit="$(systemd-run --wait --pipe --quiet env </dev/null)"
  [[ ${pid1} != *CODING_HOOK_* ]] || fail 'PID 1 has session file variables'
  [[ ${unit} != *CODING_HOOK_* ]] || fail 'a system unit has session file variables'
}
persist() {
  local update out
  pam-auth-update --package
  hook_lines "${hook_line}" 1
  # An unrelated failing source must not hide a possible reinstall.
  update="$(apt-get update -qq 2>&1)" || true
  out="$(apt-get install -y --no-install-recommends --reinstall libpam-runtime 2>&1)" ||
    fail "libpam-runtime reinstall failed: ${update} ${out}"
  grep -q '^Setting up libpam-runtime ' <<<"${out}" ||
    fail "libpam-runtime was not reinstalled: ${update} ${out}"
  hook_lines "${hook_line}" 1
  check_delivered reinstalled "$1"
}
mutate() {
  local broken="${hook_line/readenv=1/readenv=0}"
  cp -a "${profile}" "${dir}/profile"
  sed -i 's/ readenv=1 / readenv=0 /' "${profile}"
  pam-auth-update --package
  hook_lines "${broken}" 1
  check_undelivered readenv0 "$1"
  cp -a "${dir}/profile" "${profile}"
  pam-auth-update --package
  hook_lines "${hook_line}" 1
  check_delivered readenv1 "$1"
  pam-auth-update --remove coding-env
  hook_lines "${hook_line}" 0
  check_undelivered removed "$1"
  restore_hook
  check_delivered restored "$1"
}
# Fails unless environment $1 of entry point $2 has CODING_HOOK_ENV=$3 and
# CODING_HOOK_LOCALE=$4.
winner() {
  if ! grep -Fxq "CODING_HOOK_ENV=$3" <<<"$1" ||
    ! grep -Fxq "CODING_HOOK_LOCALE=$4" <<<"$1"; then
    fail "$2: expected CODING_HOOK_ENV=$3 and CODING_HOOK_LOCALE=$4"
  fi
}
priority() {
  local out user
  printf 'CODING_HOOK_ENV=etc-environment\n' >>/etc/environment
  printf 'CODING_HOOK_LOCALE=default-locale\n' >>/etc/default/locale
  out="$(ssh_env)"
  winner "${out}" sshd etc-environment default-locale
  out="$(login_env)"
  winner "${out}" login hook hook
  out="$(su_env)"
  winner "${out}" su hook hook
  out="$(sudo_env)"
  winner "${out}" sudo hook hook
  restart_managers 1000 0
  for user in coder root; do
    out="$(as_user "${user}" systemctl --user show-environment)"
    winner "${out}" "systemd-user ${user}" etc-environment hook
  done
}
step="${1-}"
[[ $# -eq 0 ]] || shift
case "${step}" in
fixture) fixture ;;
stable) stable ;;
prepare) prepare ;;
snapshot) snapshot "$1" ;;
remove-hook) remove_hook ;;
restore-hook) restore_hook ;;
deliver) check_delivered deliver "$1" ;;
side-effects) side_effects ;;
persist) persist "$1" ;;
mutate) mutate "$1" ;;
priority) priority ;;
finish) finish ;;
*)
  echo "usage: $0 STEP [ARGUMENT]" >&2
  exit 2
  ;;
esac
