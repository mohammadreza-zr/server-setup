#!/usr/bin/env bash
# =============================================================================
# server-setup - turns a fresh Ubuntu/Debian server into a hardened server that runs for
# years (production backends, Dokploy nodes, monitoring), online or in an internal network,
# then manages it.
#
# First run (as root, from a saved file - not piped into bash):
#     sudo bash server-setup.sh
# It asks everything first, then does every step. A step that fails is reported and the rest
# still runs; a full report is printed at the end (and saved to /root/server-setup-report.txt,
# without secrets). Safe to re-run.
#
# Every download source (apt, NTP, later Docker/npm/PyPI/Go/GitHub) is tried DIRECTLY first;
# only a source that does not answer is switched to the mirror (a Nexus by default).
#
# Afterwards it is installed as /usr/local/sbin/server-setup:   sudo server-setup help
#
# Supported: Ubuntu 22.04 / 24.04 / 26.04 LTS and Debian 12 / 13 (amd64, arm64).
# Log (never contains secrets): /var/log/server-setup.log
# =============================================================================
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION="0.1.0"
readonly INSTALL_PATH="/usr/local/sbin/server-setup"
readonly LIB_DIR="/usr/local/lib/server-setup"
readonly STATE_DIR="/etc/server-setup"
readonly CONF_FILE="$STATE_DIR/config"
readonly SECRETS_DIR="$STATE_DIR/secrets"
readonly BACKUP_DIR="$STATE_DIR/backup"
readonly APT_ORIG_DIR="$STATE_DIR/backup/apt-original"
readonly ROLLBACK_DIR="$STATE_DIR/ssh-rollback"
readonly RUN_NOTES="$STATE_DIR/.run-notes"
readonly RUN_CREDS="$STATE_DIR/.run-creds"
readonly CRED_DIR="/root/server-setup-credentials"
readonly REPORT_FILE="/root/server-setup-report.txt"
readonly LAST_SETUP="$STATE_DIR/last-setup"
readonly LOG_FILE="/var/log/server-setup.log"
readonly SSH_DROPIN_NAME="00-server-setup.conf"
readonly ROLLBACK_UNIT="server-setup-ssh-rollback"
readonly ROLLBACK_MINUTES=10
readonly SSH_GROUP="ssh-users"   # only members may log in over SSH
readonly APT_MIRROR_FILE="/etc/apt/sources.list.d/server-setup-mirror.sources"
readonly APT_AUTH_FILE="/etc/apt/auth.conf.d/server-setup.conf"

SSH_DIR="/etc/ssh"               # a variable (not readonly) so tests can point it elsewhere

# Packages every server gets (all from the OS repositories, so they work through an apt mirror)
BASE_PKGS=(
  ca-certificates curl gnupg openssl sudo openssh-server
  ufw fail2ban python3-systemd chrony unattended-upgrades needrestart apt-listchanges
  apparmor apparmor-utils logrotate
  less vim-tiny nano htop jq rsync lsof iproute2 dnsutils netcat-openbsd bash-completion tmux
)

# ---- state (loaded from $CONF_FILE when it exists) -----------------------------------------
ADMIN_USER="" DEPLOY_USER="" SSH_PORTS="" SSH_ALLOW="" TRUSTED_IPS="" OPEN_PORTS=""
AUTO_REBOOT="" REBOOT_TIME="" TIMEZONE="" NTP_SERVERS="" JOURNAL_MAX="" AUDITD="" LYNIS=""
ROLES="" SETUP_DONE=""
# Mirror (a Nexus repository manager by default). Repo names are per ecosystem; any can be
# changed with: server-setup mirror set
MIRROR_URL="" MIRROR_USER=""
REPO_UBUNTU="" REPO_UBUNTU_SECURITY="" REPO_UBUNTU_PORTS="" REPO_DEBIAN="" REPO_DEBIAN_SECURITY=""
REPO_DOCKER_APT="" REPO_GRAFANA_APT="" REPO_NODESOURCE_APT="" MIRROR_DOCKER_REGISTRY=""
REPO_NPM="" REPO_PYPI="" REPO_GO="" REPO_GITHUB=""
# Per source: SRC_<name> = auto|direct|mirror|none (what the admin wants),
#             ROUTE_<name> = direct|mirror|none (what is in use now)
readonly SOURCES="apt ntp dockerhub ghcr dockerapt grafanaapt nodesource npm pypi go github"
SRC_apt="" SRC_ntp="" SRC_dockerhub="" SRC_ghcr="" SRC_dockerapt="" SRC_grafanaapt="" SRC_nodesource=""
SRC_npm="" SRC_pypi="" SRC_go="" SRC_github=""
ROUTE_apt="" ROUTE_ntp="" ROUTE_dockerhub="" ROUTE_ghcr="" ROUTE_dockerapt="" ROUTE_grafanaapt=""
ROUTE_nodesource="" ROUTE_npm="" ROUTE_pypi="" ROUTE_go="" ROUTE_github=""

CONF_KEYS="ADMIN_USER DEPLOY_USER SSH_PORTS SSH_ALLOW TRUSTED_IPS OPEN_PORTS AUTO_REBOOT REBOOT_TIME
  TIMEZONE NTP_SERVERS JOURNAL_MAX AUDITD LYNIS ROLES SETUP_DONE MIRROR_URL MIRROR_USER
  REPO_UBUNTU REPO_UBUNTU_SECURITY REPO_UBUNTU_PORTS REPO_DEBIAN REPO_DEBIAN_SECURITY
  REPO_DOCKER_APT REPO_GRAFANA_APT REPO_NODESOURCE_APT MIRROR_DOCKER_REGISTRY
  REPO_NPM REPO_PYPI REPO_GO REPO_GITHUB"
for _s in $SOURCES; do CONF_KEYS+=" SRC_$_s ROUTE_$_s"; done; unset _s

# Answers of this run that are not saved
ADMIN_KEYS="" ADMIN_PASSWORD="" ADMIN_PW_GENERATED=n DEPLOY_KEYS="" NEW_HOSTNAME="" UFW_RESET=n
MIRROR_PASSWORD_NEW="" PRO_TOKEN=""
PW_GENERATED=n
REFRESH_FOR=""
KEYS_OUT=""
RESULTS=()
IN_SETUP=n

defaults() { # fill every setting that is still empty
  : "${SSH_PORTS:=22}" "${AUTO_REBOOT:=n}" "${REBOOT_TIME:=04:00}" "${JOURNAL_MAX:=1G}"
  : "${AUDITD:=n}" "${LYNIS:=n}" "${ROLES:=base}"
  : "${MIRROR_URL:=https://nexus.mrzdev.ir}"
  : "${REPO_UBUNTU:=ubuntu}" "${REPO_UBUNTU_SECURITY:=ubuntu-security}" "${REPO_UBUNTU_PORTS:=ubuntu-ports}"
  : "${REPO_DEBIAN:=debian}" "${REPO_DEBIAN_SECURITY:=debian-security}"
  : "${REPO_DOCKER_APT:=docker-apt}" "${REPO_GRAFANA_APT:=grafana-apt}" "${REPO_NODESOURCE_APT:=nodesource-apt}"
  : "${REPO_NPM:=npm-proxy}" "${REPO_PYPI:=pypi-proxy}" "${REPO_GO:=go-proxy}" "${REPO_GITHUB:=github-proxy}"
  [[ -n $MIRROR_DOCKER_REGISTRY ]] || MIRROR_DOCKER_REGISTRY=$(mirror_host)
  local s v
  for s in $SOURCES; do v="SRC_$s"; [[ -n ${!v} ]] || printf -v "$v" auto; done
}
# Output
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_C=$'\e[36m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_0=""
fi
log_file() { if [[ -w ${LOG_FILE%/*} ]]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; fi; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0"; log_file "==> $*"; }
info() { printf '    %s\n' "$*"; log_file "    $*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*"; log_file "ok  $*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; log_file "WARN $*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; log_file "FAIL $*"; exit 1; }
note() { info "$*"; if [[ -d $STATE_DIR ]]; then printf '%s\n' "$*" >>"$RUN_NOTES"; fi; }   # goes into the final report

on_error() {
  local rc=$? line=$1
  printf '%s[x]%s Failed (exit %s) at line %s: %s\n' "$C_R" "$C_0" "$rc" "$line" "$BASH_COMMAND" >&2
  log_file "FAIL line $line: $BASH_COMMAND (exit $rc)"
  exit "$rc"
}

# run <description> <command...> - command output goes to the log; while it runs a progress
# line is shown every 30 s; on failure the tail of the log is shown and the step stops.
run() { run_soft "$@" || exit 1; }

# run_soft - the same, but returns the failure instead of stopping (to continue with others)
run_soft() {
  local desc=$1 pid waited=0 last; shift
  info "$desc"
  printf '\n$ %s\n' "$*" >>"$LOG_FILE"
  "$@" >>"$LOG_FILE" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if (( waited % 30 == 0 )) && kill -0 "$pid" 2>/dev/null; then
      last=$(tail -n 1 "$LOG_FILE" 2>/dev/null | tr -d '\r' | cut -c1-100 || true)
      if [[ $last == *"lock"* ]]; then
        last="waiting for another apt/dpkg run to finish (usually Ubuntu's automatic updates after first boot)"
      fi
      printf '      ... %dm%02ds  %s\n' $((waited / 60)) $((waited % 60)) "$last"
    fi
  done
  if wait "$pid"; then return 0; fi
  printf '%s[x]%s %s failed. Last lines of %s:\n' "$C_R" "$C_0" "$desc" "$LOG_FILE" >&2
  tail -n 30 "$LOG_FILE" >&2
  return 1
}

# try_step <title> <function> [args...] - runs a setup step in a subshell; a failure is
# recorded for the report and the setup continues with the next step.
try_step() {
  local title=$1 rc; shift
  step "$title"
  trap - ERR; set +e
  ( set -Eeuo pipefail; trap 'on_error $LINENO' ERR; "$@" )
  rc=$?
  set -e; trap 'on_error $LINENO' ERR
  if (( rc == 0 )); then
    RESULTS+=("ok"$'\t'"$title")
  else
    RESULTS+=("FAILED"$'\t'"$title")
    warn "'$title' failed - continuing with the next step (details: $LOG_FILE)."
  fi
  load_config
}
skip_step() { RESULTS+=("skipped"$'\t'"$1 - $2"); warn "Skipped '$1': $2"; }
step_ok() { local r; for r in "${RESULTS[@]}"; do [[ $r == "ok"$'\t'"$1" ]] && return 0; done; return 1; }

apt_get() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -y -q -o DPkg::Lock::Timeout=1800 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
in_group() { [[ " $(id -nG "$1" 2>/dev/null) " == *" $2 "* ]]; }
home_of() { local e; e=$(getent passwd "$1") || return 1; cut -d: -f6 <<<"$e"; }
is_human_uid() { (( $1 >= 1000 && $1 < 60000 )); }
user_has_password() { local h; h=$(getent shadow "$1" | cut -d: -f2) || return 1; [[ $h == \$* ]]; }   # a real hash ($y$, $6$...)
port_listening() { [[ -n $(ss -Htln "( sport = :$1 )" 2>/dev/null) ]]; }
wait_port() { local i; for i in $(seq 1 20); do if port_listening "$1"; then return 0; fi; sleep 0.5; done; return 1; }
pkg_available() { [[ -n $(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)"') ]]; }
uniq_words() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | xargs; }
ssh_main_port() { local a=(); read -ra a <<<"${SSH_PORTS:-22}"; printf '%s' "${a[0]:-22}"; }
server_users() { # admin + developers (members of the SSH group), one per line
  local name uid
  while IFS=: read -r name _ uid _; do
    if is_human_uid "$uid" && in_group "$name" "$SSH_GROUP"; then printf '%s\n' "$name"; fi
  done < <(getent passwd)
}

gen_password() { # gen_password <length> - letters and digits only (safe to type and paste)
  local len=${1:-20} p="" r
  while (( ${#p} < len )); do r=$(openssl rand -base64 48); r=${r//[^A-Za-z0-9]/}; p+=$r; done
  printf '%s' "${p:0:len}"
}

server_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}') || true
  [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  printf '%s' "${ip:-<server-ip>}"
}

backup_file() {
  install -d -m 700 "$BACKUP_DIR"
  cp -a "$1" "$BACKUP_DIR/$(basename "$1").$(date +%Y%m%d-%H%M%S)"
}

need_tty() { { : >/dev/tty; } 2>/dev/null || die "This command is interactive: run it from a terminal."; }

# ----------------------------------------------------------------------------
# Prompts (always read from the terminal)
# ----------------------------------------------------------------------------
accept_any() { return 0; }

# prompt <var> <question> [default] [validator]
prompt() {
  local __var=$1 __q=$2 __def=${3-} __check=${4-} __ans
  while :; do
    if [[ -n $__def ]]; then printf '%s?%s %s [%s]: ' "$C_C" "$C_0" "$__q" "$__def" >/dev/tty
    else printf '%s?%s %s: ' "$C_C" "$C_0" "$__q" >/dev/tty; fi
    IFS= read -r __ans </dev/tty || die "No input."
    __ans=$(trim "${__ans//$'\r'/}")
    __ans=${__ans:-$__def}
    if [[ $__ans == "-" ]]; then __ans=""; fi   # "-" clears a default
    if [[ -n $__check ]]; then
      if "$__check" "$__ans"; then break; fi
    elif [[ -n $__ans ]]; then
      break
    fi
  done
  printf -v "$__var" '%s' "$__ans"
}

# prompt_yn <var> <question> <y|n>
prompt_yn() {
  local __var=$1 __q=$2 __def=${3:-n} __ans __hint="y/N"
  [[ $__def == y ]] && __hint="Y/n"
  while :; do
    printf '%s?%s %s [%s]: ' "$C_C" "$C_0" "$__q" "$__hint" >/dev/tty
    IFS= read -r __ans </dev/tty || die "No input."
    __ans=$(trim "${__ans:-$__def}"); __ans=${__ans,,}
    case $__ans in
      y|yes) printf -v "$__var" y; return 0 ;;
      n|no)  printf -v "$__var" n; return 0 ;;
    esac
  done
}

# prompt_password <var> <question> - empty input generates one; sets PW_GENERATED=y|n
prompt_password() {
  local __var=$1 __q=$2 __a __b
  while :; do
    printf '%s?%s %s (min 12 chars, empty = generate one): ' "$C_C" "$C_0" "$__q" >/dev/tty
    IFS= read -rs __a </dev/tty || die "No input."; printf '\n' >/dev/tty
    if [[ -z $__a ]]; then printf -v "$__var" '%s' "$(gen_password 20)"; PW_GENERATED=y; return 0; fi
    if (( ${#__a} < 12 )); then warn "Too short."; continue; fi
    printf '%s?%s Repeat it: ' "$C_C" "$C_0" >/dev/tty
    IFS= read -rs __b </dev/tty || die "No input."; printf '\n' >/dev/tty
    if [[ $__a != "$__b" ]]; then warn "The two entries differ."; continue; fi
    printf -v "$__var" '%s' "$__a"; PW_GENERATED=n; return 0
  done
}

# ----------------------------------------------------------------------------
# Validators (print why on failure)
# ----------------------------------------------------------------------------
valid_username() {
  local u=$1 uid
  if [[ ! $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    warn "Use lowercase letters, digits, '-' or '_' (start with a letter, max 32)."; return 1
  fi
  if uid=$(id -u "$u" 2>/dev/null) && ! is_human_uid "$uid"; then warn "'$u' is a system account."; return 1; fi
  return 0
}
valid_port_number() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || { warn "'$1' is not a port (1-65535)."; return 1; }
}
valid_port() { # a port sshd may use: free, or already used by sshd itself
  valid_port_number "$1" || return 1
  local used line
  used=$(ss -Htlnp "( sport = :$((10#$1)) )" 2>/dev/null || true)
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    # sshd itself, systemd's ssh.socket, or our GitLab gateway (it lets go of SSH ports)
    [[ $line == *'"sshd"'* || $line == *'"systemd"'* || $line == *" $GITLAB_IP:"* ]] && continue
    warn "Port $1 is already used by another program."; return 1
  done <<<"$used"
  return 0
}
valid_ssh_ports() {
  local p seen=" "
  [[ -n $1 ]] || { warn "Enter at least one port."; return 1; }
  for p in $1; do
    valid_port "$p" || return 1
    p=$((10#$p))
    [[ $seen != *" $p "* ]] || { warn "Port $p is listed twice."; return 1; }
    seen+="$p "
  done
  return 0
}
valid_port_list_or_empty() { local p; for p in $1; do valid_port_number "$p" || return 1; done; return 0; }
valid_hostname() { [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { warn "Use letters, digits and '-' (one label, e.g. api-1)."; return 1; }; }
valid_timezone() { [[ -n $1 && $1 != *..* && -f /usr/share/zoneinfo/$1 ]] || { warn "Unknown timezone (examples: UTC, Europe/Berlin, Asia/Tehran)."; return 1; }; }
valid_ip_list() {
  local t
  for t in $1; do [[ $t =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || { warn "'$t' is not an IP or CIDR."; return 1; }; done
  return 0
}
valid_url() { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] || { warn "'$1' is not a URL like https://nexus.example.com"; return 1; }; }
valid_url_or_empty() { [[ -z $1 ]] || valid_url "$1"; }
valid_host_list() {
  local h
  for h in $1; do [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || { warn "'$h' is not a hostname or IP."; return 1; }; done
  return 0
}
valid_repo_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || { warn "'$1' is not a repository name."; return 1; }; }
valid_open_ports() { # "80 443 8080/udp" - ports opened to everyone
  local p
  for p in $1; do
    [[ $p =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]] && (( 10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 65535 )) \
      || { warn "'$p' is not a port (e.g. 443 or 51820/udp)."; return 1; }
  done
  return 0
}
valid_size() { [[ $1 =~ ^[0-9]{1,5}[MG]$ ]] || { warn "Use a size such as 500M or 2G."; return 1; }; }
valid_time() { [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { warn "Use HH:MM (24 h), e.g. 04:00."; return 1; }; }
normalize_pubkey() {
  local line re key tmp fp bits
  line=$(trim "${1//$'\r'/}")
  [[ -n $line && $line != \#* && $line != *"PRIVATE KEY"* ]] || return 1
  re='((sk-)?(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))(@openssh\.com)?[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]]+[^[:space:]].*)?)$'
  [[ $line =~ $re ]] || return 1
  key=${BASH_REMATCH[1]}
  tmp=$(mktemp)
  printf '%s\n' "$key" >"$tmp"
  if ! fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null); then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  bits=${fp%% *}
  if [[ $key == ssh-rsa* ]] && (( bits < 2048 )); then warn "RSA keys must be at least 2048 bits."; return 1; fi
  printf '%s\n' "$key"
}

# resolve_keys <spec> - a pasted public key, or copy:<user> (that user's authorized_keys).
resolve_keys() {
  local spec=$1 line key home out=()
  if [[ $spec == copy:* ]]; then
    home=$(home_of "${spec#copy:}") || { warn "No user '${spec#copy:}'."; return 1; }
    [[ -r $home/.ssh/authorized_keys ]] || { warn "$home/.ssh/authorized_keys not found."; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
      if key=$(normalize_pubkey "$line"); then out+=("$key"); fi
    done <"$home/.ssh/authorized_keys"
  elif key=$(normalize_pubkey "$spec"); then
    out+=("$key")
  fi
  (( ${#out[@]} > 0 )) || return 1
  printf '%s\n' "${out[@]}"
}

# collect_keys <user> [require-new] - sets KEYS_OUT to key lines, "generate", or "" (keep existing)
collect_keys() {
  local u=$1 require_new=${2:-n} spec has_keys=n home
  if home=$(home_of "$u") && [[ -s $home/.ssh/authorized_keys ]]; then has_keys=y; fi
  local hint="paste a public key, 'generate', or 'copy:<user>'"
  [[ $has_keys == y && $require_new == n ]] && hint+=", empty = keep existing keys"
  while :; do
    prompt spec "SSH key for $u ($hint)" "" accept_any
    if [[ -z $spec ]]; then
      if [[ $has_keys == y && $require_new == n ]]; then KEYS_OUT=""; return 0; fi
      warn "A key is required (password login over SSH is disabled)."; continue
    fi
    if [[ $spec == generate ]]; then KEYS_OUT=generate; return 0; fi
    if KEYS_OUT=$(resolve_keys "$spec"); then return 0; fi
    warn "That is not a valid SSH public key (expected 'ssh-ed25519 AAAA... comment')."
  done
}

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
load_config() {
  if [[ -f $CONF_FILE ]]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
  fi
  defaults
}

init_state() {
  install -d -m 700 "$STATE_DIR" "$SECRETS_DIR" "$BACKUP_DIR"
  [[ -f $LOG_FILE ]] || install -m 600 /dev/null "$LOG_FILE"
  load_config
}

save_config() {
  local tmp k
  tmp=$(mktemp "$STATE_DIR/.config.XXXXXX")
  {
    printf '# server-setup %s state - written by the script, edit with care\n' "$SCRIPT_VERSION"
    for k in $CONF_KEYS; do printf '%s=%q\n' "$k" "${!k-}"; done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONF_FILE"
}

secret_get() { [[ -s $SECRETS_DIR/$1 ]] && cat "$SECRETS_DIR/$1"; }
secret_set() { # secret_set <name> <value> - empty value removes it
  if [[ -z $2 ]]; then rm -f "$SECRETS_DIR/$1"; return 0; fi
  install -d -m 700 "$SECRETS_DIR"
  ( umask 077; printf '%s' "$2" >"$SECRETS_DIR/$1" )
}

begin_run() { install -m 600 /dev/null "$RUN_NOTES"; install -m 600 /dev/null "$RUN_CREDS"; }
end_run() {
  local rc=$?
  if [[ -n $REFRESH_FOR && $SETUP_DONE == y ]]; then
    if ( write_report "$REFRESH_FOR" ) >>"$LOG_FILE" 2>&1; then
      if (( rc == 0 )); then info "Updated: $REPORT_FILE"; fi
    else
      warn "Could not update $REPORT_FILE (see $LOG_FILE)."
    fi
  fi
  rm -f "$RUN_CREDS"
}

note_cred() { # note_cred <user> <what> <value>
  install -d -m 700 "$CRED_DIR"
  local f="$CRED_DIR/$1.txt"
  printf '%s  %-16s %s\n' "$(date '+%F %T')" "$2" "$3" >>"$f"
  chmod 600 "$f"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RUN_CREDS"
}

print_credentials() {
  [[ -s $RUN_CREDS ]] || return 0
  step "Credentials created now (also in $CRED_DIR - hand them over privately, then delete that folder)"
  local u w v
  while IFS=$'\t' read -r u w v; do printf '    %-16s %-16s %s\n' "$u" "$w" "$v"; done <"$RUN_CREDS"
}

install_self() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}")
  [[ -f $src ]] || die "Save the script to a file and run it from there (sudo bash server-setup.sh)."
  if [[ $src != "$INSTALL_PATH" ]]; then
    install -m 0755 -o root -g root "$src" "$INSTALL_PATH"
    info "Installed management command: $INSTALL_PATH (use it as: sudo server-setup ...)"
  fi
  chmod 0755 "$INSTALL_PATH"
  ln -sfn "$INSTALL_PATH" /usr/local/bin/server-setup
}

# ----------------------------------------------------------------------------
# OS layer - everything that differs between distributions lives here. Only apt-based
# systems are implemented (Ubuntu, Debian); a dnf-based one would add its own branch.
# ----------------------------------------------------------------------------
OS_ID="" OS_VERSION="" OS_CODENAME="" OS_ARCH=""
os_detect() {
  OS_ID=$(. /etc/os-release && printf '%s' "${ID-}")
  OS_VERSION=$(. /etc/os-release && printf '%s' "${VERSION_ID-}")
  OS_CODENAME=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME-}")
  OS_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
}

check_os() {
  os_detect
  case $OS_ID in
    ubuntu) case $OS_VERSION in 22.04|24.04|26.04) ;; *) warn "Ubuntu $OS_VERSION has not been tested with this script." ;; esac ;;
    debian) case $OS_VERSION in 12|13) ;; *) warn "Debian $OS_VERSION has not been tested with this script." ;; esac ;;
    *) die "This script supports Ubuntu and Debian (found '$OS_ID'). Other distributions are not implemented yet." ;;
  esac
  [[ -n $OS_CODENAME ]] || die "Could not read the release codename from /etc/os-release."
  command -v systemctl >/dev/null || die "systemd is required."
  command -v apt-get >/dev/null || die "apt-get is required."
}

os_install() { run "Installing $*" apt_get install "$@"; }
os_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }

# The OS's own package repositories, as deb822 (used to probe "direct" and as the mirror's layout)
os_keyring() { case $OS_ID in ubuntu) printf '/usr/share/keyrings/ubuntu-archive-keyring.gpg' ;; debian) printf '/usr/share/keyrings/debian-archive-keyring.gpg' ;; esac; }
os_components() {
  case $OS_ID in
    ubuntu) printf 'main restricted universe multiverse' ;;
    debian) if [[ $OS_VERSION == 11 ]]; then printf 'main contrib non-free'; else printf 'main contrib non-free non-free-firmware'; fi ;;
  esac
}
# render_os_sources <main-uri> <security-uri> - the OS repositories in deb822 form
render_os_sources() {
  local main=$1 sec=$2 key comps suites
  key=$(os_keyring); comps=$(os_components)
  case $OS_ID in
    ubuntu) suites="$OS_CODENAME $OS_CODENAME-updates $OS_CODENAME-backports" ;;
    debian) suites="$OS_CODENAME $OS_CODENAME-updates" ;;
  esac
  printf '# Managed by server-setup\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' "$main" "$suites" "$comps" "$key"
  printf 'Types: deb\nURIs: %s\nSuites: %s-security\nComponents: %s\nSigned-By: %s\n' "$sec" "$OS_CODENAME" "$comps" "$key"
}
os_default_uris() { # prints "<main> <security>" - the OS's public repositories
  case $OS_ID in
    ubuntu) if [[ $OS_ARCH == amd64 || $OS_ARCH == i386 ]]; then printf 'http://archive.ubuntu.com/ubuntu http://security.ubuntu.com/ubuntu'
            else printf 'http://ports.ubuntu.com/ubuntu-ports http://ports.ubuntu.com/ubuntu-ports'; fi ;;
    debian) printf 'http://deb.debian.org/debian http://deb.debian.org/debian-security' ;;
  esac
}
os_mirror_uris() { # prints "<main> <security>" on the mirror
  local b; b=$(mirror_base)
  case $OS_ID in
    ubuntu) if [[ $OS_ARCH == amd64 || $OS_ARCH == i386 ]]; then printf '%s/repository/%s/ %s/repository/%s/' "$b" "$REPO_UBUNTU" "$b" "$REPO_UBUNTU_SECURITY"
            else printf '%s/repository/%s/ %s/repository/%s/' "$b" "$REPO_UBUNTU_PORTS" "$b" "$REPO_UBUNTU_PORTS"; fi ;;
    debian) printf '%s/repository/%s/ %s/repository/%s/' "$b" "$REPO_DEBIAN" "$b" "$REPO_DEBIAN_SECURITY" ;;
  esac
}
os_reboot_reason() { # empty when no reboot is needed
  local k
  if [[ -f /var/run/reboot-required ]]; then
    printf 'updates installed (%s)' "$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | xargs | cut -c1-80)"; return 0
  fi
  if command -v needrestart >/dev/null; then
    k=$(needrestart -b -k 2>/dev/null | awk -F': ' '/NEEDRESTART-KSTA/ {print $2}')
    if [[ $k == 2 || $k == 3 ]]; then printf 'a newer kernel is installed (running %s)' "$(uname -r)"; fi
  fi
}
ensure_swap() {
  if [[ -n $(swapon --noheadings --show 2>/dev/null) ]]; then info "Swap already active."; return 0; fi
  if [[ -e /swapfile ]]; then warn "/swapfile exists but is not active - leaving it alone."; return 0; fi
  local mem_mb size_mb avail_mb
  mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  size_mb=$(( mem_mb < 2048 ? 2048 : (mem_mb > 4096 ? 4096 : mem_mb) ))
  avail_mb=$(df -Pm / | awk 'NR == 2 {print $4}')
  if (( avail_mb < size_mb + 4096 )); then warn "Not enough free disk for a ${size_mb} MB swap file - skipped."; return 0; fi
  if ! { fallocate -l "${size_mb}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; }; then
    rm -f /swapfile; warn "Could not create /swapfile - skipped."; return 0
  fi
  chmod 600 /swapfile
  mkswap /swapfile >>"$LOG_FILE" 2>&1
  if ! swapon /swapfile 2>>"$LOG_FILE"; then rm -f /swapfile; warn "This VPS does not allow swap - skipped."; return 0; fi
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  note "Created a ${size_mb} MB swap file."
}
render_fail2ban() { # render_fail2ban <ports csv>
  cat <<EOF
# Managed by server-setup
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 $TRUSTED_IPS

[sshd]
enabled = true
port = $1
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session + _COMM=sshd-auth
maxretry = 4
EOF
}
apply_fail2ban() { # apply_fail2ban <port>...
  local ports f=/etc/fail2ban/jail.d/zz-server-setup.local
  ports=$(uniq_words "$@" | tr ' ' ',')
  render_fail2ban "${ports:-22}" >"$f"
  if fail2ban-client -t >>"$LOG_FILE" 2>&1; then
    systemctl enable fail2ban >>"$LOG_FILE" 2>&1
    systemctl restart fail2ban
  else
    rm -f "$f"; die "fail2ban rejected the generated jail (see log) - fail2ban left on its defaults."
  fi
}
render_zswap() {
  cat <<'EOF'
#!/bin/bash
# zswap - managed by server-setup; run at boot by server-setup-zswap.service.
p=/sys/module/zswap/parameters
[[ -d $p ]] || { echo "zswap: not in this kernel - skipped" >&2; exit 0; }
for z in zsmalloc z3fold zbud; do echo "$z" >"$p/zpool" 2>/dev/null && break; done
for c in zstd lz4 lzo; do echo "$c" >"$p/compressor" 2>/dev/null && break; done
echo 20 >"$p/max_pool_percent"
echo Y >"$p/enabled"
echo "zswap on: $(cat "$p/compressor")/$(cat "$p/zpool"), up to $(cat "$p/max_pool_percent")% of RAM"
EOF
}

# ----------------------------------------------------------------------------
# Download sources: each one is tried DIRECTLY first; only a source that does not answer
# goes through the mirror. SRC_<name> = auto|direct|mirror|none (the admin's choice),
# ROUTE_<name> = direct|mirror|none (in use now).
# ----------------------------------------------------------------------------
mirror_base() { local u=${MIRROR_URL%/}; [[ $u == *://* ]] || u="https://$u"; printf '%s' "$u"; }
mirror_host() { local u; u=$(mirror_base); u=${u#*://}; printf '%s' "${u%%/*}"; }
mirror_netrc() { # mirror_netrc <file> - writes the mirror login as a netrc file (0600); fails without one
  local pw; pw=$(secret_get mirror-password || true)
  [[ -n $MIRROR_USER && -n $pw ]] || return 1
  ( umask 077; printf 'machine %s\nlogin %s\npassword %s\n' "$(mirror_host)" "$MIRROR_USER" "$pw" >"$1" )
}
source_label() {
  case $1 in
    apt) printf 'OS packages (apt)' ;; ntp) printf 'time (NTP)' ;; dockerhub) printf 'Docker Hub images' ;;
    ghcr) printf 'ghcr.io images' ;; dockerapt) printf "Docker's apt repo" ;; grafanaapt) printf "Grafana's apt repo" ;;
    nodesource) printf 'NodeSource apt repo' ;; npm) printf 'npm registry' ;; pypi) printf 'PyPI' ;;
    go) printf 'Go modules' ;; github) printf 'GitHub downloads' ;; *) printf '%s' "$1" ;;
  esac
}
route_of() { local v="ROUTE_$1"; printf '%s' "${!v:-unset}"; }

# http_code <url> [curl args...] - the HTTP status, 000 when nothing answered
http_code() { local u=$1; shift; curl -sS -o /dev/null -m 12 --connect-timeout 6 -w '%{http_code}' "$@" "$u" 2>/dev/null || true; }
http_ok() { [[ $1 =~ ^(2..|3..|401)$ ]]; }   # 401: a registry that answered (needs a token)

direct_url() { # the public address a source is checked against
  case $1 in
    dockerhub) printf 'https://registry-1.docker.io/v2/' ;; ghcr) printf 'https://ghcr.io/v2/' ;;
    dockerapt) printf 'https://download.docker.com/linux/' ;; grafanaapt) printf 'https://apt.grafana.com/' ;;
    nodesource) printf 'https://deb.nodesource.com/' ;; npm) printf 'https://registry.npmjs.org/' ;;
    pypi) printf 'https://pypi.org/simple/pip/' ;; go) printf 'https://proxy.golang.org/golang.org/x/text/@v/list' ;;
    github) printf 'https://github.com/' ;;
  esac
}
mirror_url_of() { # where a source lives on the mirror
  local b; b=$(mirror_base)
  case $1 in
    apt) printf '%s' "$(os_mirror_uris | cut -d' ' -f1)" ;;
    dockerhub) printf 'https://%s/v2/' "$MIRROR_DOCKER_REGISTRY" ;;
    ghcr) printf '' ;;   # needs its own registry host on the mirror - not configured yet
    dockerapt) printf '%s/repository/%s/' "$b" "$REPO_DOCKER_APT" ;;
    grafanaapt) printf '%s/repository/%s/' "$b" "$REPO_GRAFANA_APT" ;;
    nodesource) printf '%s/repository/%s/' "$b" "$REPO_NODESOURCE_APT" ;;
    npm) printf '%s/repository/%s/' "$b" "$REPO_NPM" ;;
    pypi) printf '%s/repository/%s/simple/pip/' "$b" "$REPO_PYPI" ;;
    go) printf '%s/repository/%s/golang.org/x/text/@v/list' "$b" "$REPO_GO" ;;
    github) printf '%s/repository/%s/' "$b" "$REPO_GITHUB" ;;
  esac
}

# ---- apt -------------------------------------------------------------------
# apt_probe <dir with .sources/.list files> [netrc dir] - an `apt-get update` that only uses
# those files and a private lists directory: the real apt state is never touched.
apt_probe() {
  local parts=$1 netrc=${2:-/dev/null} tmp out rc
  tmp=$(mktemp -d); mkdir -p "$tmp/lists/partial"
  out=$(timeout 120 apt-get -q -o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts="$parts" \
    -o Dir::Etc::netrcparts="$netrc" -o Dir::State::lists="$tmp/lists" -o Dir::Cache::pkgcache= \
    -o Dir::Cache::srcpkgcache= -o Debug::NoLocking=1 -o Acquire::http::Timeout=15 \
    -o Acquire::https::Timeout=15 -o Acquire::Retries=0 update 2>&1); rc=$?
  rm -rf "$tmp"
  printf '\n$ apt probe (%s)\n%s\n' "$parts" "$out" >>"$LOG_FILE"
  (( rc == 0 )) && ! grep -qE '^(Err:|E: |W: (Failed|Some index))' <<<"$out"
}

# The original apt sources (as the server came) - kept so "direct" can always be restored
apt_save_originals() {
  [[ -d $APT_ORIG_DIR ]] && return 0
  install -d -m 700 "$APT_ORIG_DIR/sources.list.d"
  [[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$APT_ORIG_DIR/"
  local f
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $f && $(basename "$f") != server-setup-* ]] && cp -a "$f" "$APT_ORIG_DIR/sources.list.d/"
  done
  return 0
}
# is_os_source <file> - one of the distribution's own repositories (signed with its archive key,
# or the classic sources.list) - not a third-party repo such as Docker's or a PPA
is_os_source() {
  local f=$1 key; key=$(os_keyring)
  case $(basename "$f") in sources.list|00-original.list|ubuntu.sources|debian.sources) return 0 ;; esac
  grep -qsF "$key" "$f" && return 0
  # one-line format without signed-by: the codename's main component on a non-PPA host
  grep -qsE "^[[:space:]]*deb[[:space:]]+[^#]*[[:space:]]$OS_CODENAME(-updates|-security)?[[:space:]]+main" "$f" \
    && ! grep -qsE 'ppa\.launchpad(content)?\.net' "$f"
}
# the original OS sources in a probe directory (what "direct" means on this server). Only the
# distribution's own repositories decide - a broken third-party repo must not move the OS to
# the mirror.
apt_direct_parts() {
  local d=$1 f n=0
  if [[ -f $APT_ORIG_DIR/sources.list ]] && grep -qE '^[[:space:]]*deb[[:space:]]' "$APT_ORIG_DIR/sources.list"; then
    cp "$APT_ORIG_DIR/sources.list" "$d/00-original.list"; n=1
  fi
  for f in "$APT_ORIG_DIR"/sources.list.d/*; do
    if [[ -f $f ]] && is_os_source "$f"; then cp "$f" "$d/"; n=1; fi
  done
  # nothing saved: the distribution's public repositories
  if (( n == 0 )); then
    local uris; read -ra uris <<<"$(os_default_uris)"
    render_os_sources "${uris[0]}" "${uris[1]}" >"$d/os.sources"
  fi
}
apt_mirror_parts() { local d=$1 uris; read -ra uris <<<"$(os_mirror_uris)"; render_os_sources "${uris[0]}" "${uris[1]}" >"$d/mirror.sources"; }
apt_auth_render() { # netrc lines for the mirror (apt's auth.conf format)
  local pw; pw=$(secret_get mirror-password || true)
  [[ -n $MIRROR_USER && -n $pw ]] || return 0
  printf 'machine %s/repository/\nlogin %s\npassword %s\n' "$(mirror_host)" "$MIRROR_USER" "$pw"
}
apt_probe_direct() { local d rc=0; d=$(mktemp -d); apt_save_originals; apt_direct_parts "$d"; apt_probe "$d" || rc=1; rm -rf "$d"; return $rc; }
apt_probe_mirror() {
  local d n rc=0; d=$(mktemp -d); n=$(mktemp -d)
  apt_mirror_parts "$d"; ( umask 077; apt_auth_render >"$n/mirror.conf" )
  apt_probe "$d" "$n" || rc=1
  rm -rf "$d" "$n"; return $rc
}

apt_use_direct() {
  [[ -f $APT_MIRROR_FILE ]] || return 0
  rm -f "$APT_MIRROR_FILE" "$APT_AUTH_FILE"
  if [[ -d $APT_ORIG_DIR ]]; then
    if [[ -f $APT_ORIG_DIR/sources.list ]]; then cp -a "$APT_ORIG_DIR/sources.list" /etc/apt/sources.list; fi
    local f; for f in "$APT_ORIG_DIR"/sources.list.d/*; do [[ -f $f ]] && cp -a "$f" /etc/apt/sources.list.d/; done
  fi
  note "apt: back to the original package sources."
}
apt_use_mirror() {
  local f disabled=()
  apt_save_originals
  # every other source would fail without internet (and make apt-get update fail): set aside
  if [[ -f /etc/apt/sources.list ]] && grep -qE '^[[:space:]]*deb' /etc/apt/sources.list; then
    printf '# Managed by server-setup: the package sources are in %s\n# (originals: %s)\n' "$APT_MIRROR_FILE" "$APT_ORIG_DIR" >/etc/apt/sources.list
    disabled+=(sources.list)
  fi
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f $f && $(basename "$f") != server-setup-* ]] || continue
    rm -f "$f"; disabled+=("$(basename "$f")")
  done
  local uris; read -ra uris <<<"$(os_mirror_uris)"
  render_os_sources "${uris[0]}" "${uris[1]}" >"$APT_MIRROR_FILE"; chmod 644 "$APT_MIRROR_FILE"
  install -d -m 755 /etc/apt/auth.conf.d
  if [[ -n $(apt_auth_render) ]]; then ( umask 077; apt_auth_render >"$APT_AUTH_FILE" ); else rm -f "$APT_AUTH_FILE"; fi
  note "apt: using the mirror $(mirror_base) (repos $(os_mirror_uris | tr ' ' '\n' | sed 's#.*/repository/##; s#/$##' | uniq | xargs))."
  if (( ${#disabled[@]} > 0 )); then note "apt: set aside (they need internet): ${disabled[*]} - originals kept in $APT_ORIG_DIR"; fi
}

# resolve_apt - choose direct or mirror for apt and apply it
resolve_apt() {
  local want=$SRC_apt
  case $want in
    direct) apt_use_direct; ROUTE_apt=direct ;;
    mirror) apt_use_mirror; ROUTE_apt=mirror ;;
    none) die "apt is set to 'none' - nothing can be installed. Change it: server-setup mirror set" ;;
    *)
      info "Checking the package sources directly (up to 2 minutes when there is no internet)..."
      if apt_probe_direct; then
        apt_use_direct; ROUTE_apt=direct; note "apt: the normal package sources work - used directly."
      else
        warn "The normal package sources do not answer - trying the mirror $(mirror_base)."
        apt_probe_mirror || die "The mirror's apt repositories do not work either ($(os_mirror_uris)). Check the URL, repository names and login: server-setup mirror set   (details: $LOG_FILE)"
        apt_use_mirror; ROUTE_apt=mirror
      fi ;;
  esac
  save_config
}

# ---- NTP -------------------------------------------------------------------
ntp_probe() { # ntp_probe <server>... - does any of them answer (chronyd -Q only measures)
  local s
  command -v chronyd >/dev/null || return 1
  for s in "$@"; do
    if timeout 25 chronyd -Q -t 20 "server $s iburst maxsamples 2" >>"$LOG_FILE" 2>&1; then return 0; fi
  done
  return 1
}
ntp_public() { case $OS_ID in ubuntu) printf 'ntp.ubuntu.com pool.ntp.org' ;; *) printf 'deb.pool.ntp.org pool.ntp.org' ;; esac; }
apply_time_sync() {
  local d=/etc/chrony/sources.d f conf=/etc/chrony/chrony.conf servers=() s want=$SRC_ntp
  [[ -f $conf ]] || die "chrony is not installed."
  timedatectl set-timezone "$TIMEZONE"
  if [[ $want == auto ]]; then
    # shellcheck disable=SC2046
    if ntp_probe $(ntp_public); then want=direct; elif [[ -n $NTP_SERVERS ]]; then want=mirror; else want=direct; fi
  fi
  install -d -m 755 "$d"
  f="$d/server-setup.sources"
  if [[ $want == mirror ]]; then
    for s in $NTP_SERVERS; do servers+=("server $s iburst"); done
    (( ${#servers[@]} > 0 )) || die "Internal NTP is chosen but no NTP servers are set (server-setup mirror set)."
    printf '# Managed by server-setup: internal time servers\n%s\n' "$(printf '%s\n' "${servers[@]}")" >"$f"
    # the public pools in chrony.conf can't be reached here - only the internal servers count
    sed -i -E 's/^(pool[[:space:]].*)$/# disabled by server-setup (no internet): \1/' "$conf"
    ROUTE_ntp=mirror
  else
    rm -f "$f"
    sed -i -E 's/^# disabled by server-setup \(no internet\): //' "$conf"
    for s in $NTP_SERVERS; do servers+=("server $s iburst"); done
    if (( ${#servers[@]} > 0 )); then printf '# Managed by server-setup: extra time servers\n%s\n' "$(printf '%s\n' "${servers[@]}")" >"$f"; fi
    ROUTE_ntp=direct
  fi
  grep -qE '^[[:space:]]*sourcedir[[:space:]]+/etc/chrony/sources.d' "$conf" || printf '\n# Added by server-setup\nsourcedir /etc/chrony/sources.d\n' >>"$conf"
  # chrony replaces systemd-timesyncd; make sure only one of them runs
  systemctl disable --now systemd-timesyncd >>"$LOG_FILE" 2>&1 || true
  systemctl enable chrony >>"$LOG_FILE" 2>&1 || systemctl enable chronyd >>"$LOG_FILE" 2>&1 || true
  systemctl restart chrony >>"$LOG_FILE" 2>&1 || systemctl restart chronyd >>"$LOG_FILE" 2>&1
  save_config
  note "Time: chrony, $([[ $ROUTE_ntp == mirror ]] && echo "internal servers $NTP_SERVERS" || echo "public pools${NTP_SERVERS:+ + $NTP_SERVERS}"); timezone $TIMEZONE"
}

# ---- every source: test / recheck ------------------------------------------
# source_check <name> - prints "direct=<ok|fail|-> mirror=<code|->"
source_check() {
  local s=$1 d m code auth=() netrc
  # the login goes in a private file, never on the command line (where `ps` shows it)
  netrc=$(mktemp); if mirror_netrc "$netrc"; then auth=(--netrc-file "$netrc"); fi
  case $s in
    apt) if apt_probe_direct; then d=ok; else d=fail; fi
         if apt_probe_mirror; then m=ok; else m=fail; fi ;;
    ntp) # shellcheck disable=SC2046
         if ntp_probe $(ntp_public); then d=ok; else d=fail; fi
         if [[ -z $NTP_SERVERS ]]; then m=-; elif ntp_probe $NTP_SERVERS; then m=ok; else m=fail; fi ;;
    *) code=$(http_code "$(direct_url "$s")"); if http_ok "$code"; then d=ok; else d="fail($code)"; fi
       if [[ -z $(mirror_url_of "$s") ]]; then m=-
       else code=$(http_code "$(mirror_url_of "$s")" "${auth[@]}")
            case $code in 2??|3??) m=ok ;; 401) m="401(login)" ;; 404) m="404(no repo)" ;; 000) m=unreachable ;; *) m=$code ;; esac
       fi ;;
  esac
  rm -f "$netrc"
  printf 'direct=%s mirror=%s' "$d" "$m"
}

cmd_mirror() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  case $action in
    show|"") mirror_show ;;
    test)
      step "Testing every source directly and on the mirror $(mirror_base)"
      local s r
      printf '    %-22s %-8s %-8s %-14s %s\n' SOURCE WANTED IN-USE DIRECT MIRROR
      for s in $SOURCES; do
        r=$(source_check "$s"); local v="SRC_$s"
        printf '    %-22s %-8s %-8s %-14s %s\n' "$(source_label "$s")" "${!v}" "$(route_of "$s")" "$(sed 's/direct=//; s/ mirror=.*//' <<<"$r")" "${r#* mirror=}"
      done
      info "MIRROR: ok = works; 401 = needs a login (server-setup mirror set); 404 = no repository with that name."
      ;;
    set) need_tty; mirror_prompt; save_config; mirror_apply_all ;;
    recheck) mirror_apply_all ;;
    *) die "usage: server-setup mirror show|test|set|recheck" ;;
  esac
}

mirror_show() {
  local s v
  printf '    Mirror:   %s   login: %s\n' "$(mirror_base)" "${MIRROR_USER:-(none)}"
  printf '    Repos:    apt %s/%s (ports: %s), debian %s/%s\n' "$REPO_UBUNTU" "$REPO_UBUNTU_SECURITY" "$REPO_UBUNTU_PORTS" "$REPO_DEBIAN" "$REPO_DEBIAN_SECURITY"
  printf '              docker-apt %s, grafana-apt %s, nodesource %s, npm %s, pypi %s, go %s, github %s\n' \
    "$REPO_DOCKER_APT" "$REPO_GRAFANA_APT" "$REPO_NODESOURCE_APT" "$REPO_NPM" "$REPO_PYPI" "$REPO_GO" "$REPO_GITHUB"
  printf '              docker registry %s\n' "$MIRROR_DOCKER_REGISTRY"
  printf '    NTP:      %s\n' "${NTP_SERVERS:-(public pools only)}"
  printf '    %-22s %-8s %s\n' SOURCE WANTED IN-USE
  for s in $SOURCES; do v="SRC_$s"; printf '    %-22s %-8s %s\n' "$(source_label "$s")" "${!v}" "$(route_of "$s")"; done
}

mirror_prompt() {
  local pw="" k s v
  prompt MIRROR_URL "Mirror base URL (a Nexus)" "$(mirror_base)" valid_url
  prompt MIRROR_USER "Mirror username (empty = anonymous)" "${MIRROR_USER:-}" accept_any
  if [[ -n $MIRROR_USER ]]; then
    printf '%s?%s Mirror password (empty = keep the current one): ' "$C_C" "$C_0" >/dev/tty
    IFS= read -rs pw </dev/tty || true; printf '\n' >/dev/tty
    if [[ -n $pw ]]; then MIRROR_PASSWORD_NEW=$pw; secret_set mirror-password "$pw"; fi
  else
    secret_set mirror-password ""
  fi
  info "Repository names on the mirror ('-' keeps nothing; Enter keeps the shown value):"
  for k in REPO_UBUNTU REPO_UBUNTU_SECURITY REPO_UBUNTU_PORTS REPO_DEBIAN REPO_DEBIAN_SECURITY REPO_DOCKER_APT \
           REPO_GRAFANA_APT REPO_NODESOURCE_APT REPO_NPM REPO_PYPI REPO_GO REPO_GITHUB; do
    prompt "$k" "  $k" "${!k}" valid_repo_name
  done
  prompt MIRROR_DOCKER_REGISTRY "  Docker registry host on the mirror" "$MIRROR_DOCKER_REGISTRY" valid_host_list
  prompt NTP_SERVERS "Internal NTP servers (space-separated, empty = public pools only)" "${NTP_SERVERS:-}" valid_host_list
  info "Per source: auto = direct first, mirror if direct fails; direct; mirror; none."
  for s in $SOURCES; do
    v="SRC_$s"
    prompt "$v" "  $(source_label "$s")" "${!v}" valid_src_mode
  done
}
valid_src_mode() { [[ $1 =~ ^(auto|direct|mirror|none)$ ]] || { warn "Use auto, direct, mirror or none."; return 1; }; }

# Re-apply every source in use (apt and NTP now; the tools add theirs in later versions)
mirror_apply_all() {
  step "Package sources"
  resolve_apt
  run "Refreshing package lists" apt_get update
  if [[ -f /etc/chrony/chrony.conf ]]; then step "Time sync"; apply_time_sync; fi
  ok "Sources: apt $(route_of apt), ntp $(route_of ntp)"
}

# ----------------------------------------------------------------------------
# Base role: update, users, firewall, hardening, long-uptime tuning
# ----------------------------------------------------------------------------
step_packages() {
  run "Checking for an interrupted earlier upgrade" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  run "Refreshing package lists" apt_get update
  run "Repairing broken dependencies (if any)" apt_get -f install
  run "Upgrading installed packages" apt_get dist-upgrade
  local pkgs=() p
  for p in "${BASE_PKGS[@]}"; do if pkg_available "$p"; then pkgs+=("$p"); else warn "Package $p is not available here - skipped."; fi; done
  run "Installing base packages" apt_get install "${pkgs[@]}"
  run "Removing packages nothing needs any more" apt_get autoremove --purge
}

apply_hostname() {
  [[ -n $NEW_HOSTNAME ]] || return 0
  [[ $(hostname) == "$NEW_HOSTNAME" ]] || hostnamectl set-hostname "$NEW_HOSTNAME"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$NEW_HOSTNAME" >>/etc/hosts
  fi
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then printf 'preserve_hostname: true\n' >/etc/cloud/cloud.cfg.d/99-server-setup.cfg; fi
  note "Hostname $NEW_HOSTNAME"
}

# ---- users ---------------------------------------------------------------------------------
ensure_group() { getent group "$1" >/dev/null || groupadd --system "$1"; }

ensure_user() { # ensure_user <user> <admin|deploy>
  local u=$1 role=$2 home
  if id "$u" &>/dev/null; then info "User $u exists - updating it."
  else useradd --create-home --user-group --shell /bin/bash "$u"; ok "Created user $u"; fi
  home=$(home_of "$u")
  [[ -d $home && ! -L $home ]] || die "Home directory of $u ($home) is missing or a symlink."
  chmod 750 "$home"
  # useradd leaves the password "!" (locked) - with it sshd refuses even keys. "*" = no password.
  if [[ $(getent shadow "$u" | cut -d: -f2) =~ ^!+\*?$ ]]; then usermod -p '*' "$u"; fi
  usermod -aG "$SSH_GROUP" "$u"
  if [[ $role == admin ]]; then
    usermod -aG sudo "$u"
  else
    if in_group "$u" sudo; then gpasswd -d "$u" sudo >/dev/null; warn "Removed $u from the sudo group (a deploy user has no sudo)."; fi
  fi
  runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.ssh"; chmod 700 "$1/.ssh"' sh "$home"
}

add_authorized_keys() { # add_authorized_keys <user> <key>... - written AS the user (no symlink tricks)
  local u=$1 home ak k; shift
  home=$(home_of "$u"); ak="$home/.ssh/authorized_keys"
  runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.ssh"; chmod 700 "$1/.ssh"; touch "$1/.ssh/authorized_keys"; chmod 600 "$1/.ssh/authorized_keys"' sh "$home"
  for k in "$@"; do
    [[ -n $k ]] || continue
    if ! runuser -u "$u" -- grep -qxF -- "$k" "$ak"; then printf '%s\n' "$k" | runuser -u "$u" -- tee -a "$ak" >/dev/null; fi
  done
}
generate_key_for() { # the private key goes to $CRED_DIR only
  local u=$1 tmp
  tmp=$(mktemp -d)
  ssh-keygen -q -t ed25519 -N '' -C "$u@$(hostname -s)" -f "$tmp/key"
  add_authorized_keys "$u" "$(cat "$tmp/key.pub")"
  install -d -m 700 "$CRED_DIR"; install -m 600 "$tmp/key" "$CRED_DIR/$u.id_ed25519"
  rm -rf "$tmp"
  note_cred "$u" "ssh private key" "$CRED_DIR/$u.id_ed25519"
}
apply_keys() { # apply_keys <user> <key lines | generate | "">
  local keys=()
  case $2 in "") ;; generate) generate_key_for "$1" ;; *) mapfile -t keys <<<"$2"; add_authorized_keys "$1" "${keys[@]}" ;; esac
}
set_password() { chpasswd <<<"$1:$2"; if [[ $3 == y ]]; then note_cred "$1" "password" "$2"; fi; }

step_users() {
  ensure_group "$SSH_GROUP"
  ensure_user "$ADMIN_USER" admin
  apply_keys "$ADMIN_USER" "$ADMIN_KEYS"
  if [[ -n $ADMIN_PASSWORD ]]; then set_password "$ADMIN_USER" "$ADMIN_PASSWORD" "$ADMIN_PW_GENERATED"; fi
  user_has_password "$ADMIN_USER" || die "$ADMIN_USER needs a password for sudo."
  if [[ -n $DEPLOY_USER ]]; then ensure_user "$DEPLOY_USER" deploy; apply_keys "$DEPLOY_USER" "$DEPLOY_KEYS"; fi
  # sudo asks again after 5 minutes, and every sudo use is logged
  printf '# Managed by server-setup\nDefaults timestamp_timeout=5\nDefaults logfile=/var/log/sudo.log\nDefaults use_pty\n' >/etc/sudoers.d/50-server-setup
  chmod 440 /etc/sudoers.d/50-server-setup
  visudo -cq || { rm -f /etc/sudoers.d/50-server-setup; die "sudoers check failed - the sudo defaults were not applied."; }
  note "Users: admin $ADMIN_USER (sudo)${DEPLOY_USER:+; deploy $DEPLOY_USER (no sudo)}"
}

# ---- firewall ------------------------------------------------------------------------------
apply_firewall() { # apply_firewall <ssh port>...
  local p src spec
  if [[ ${UFW_RESET:-n} == y ]]; then ufw --force reset >>"$LOG_FILE" 2>&1; fi
  ufw default deny incoming >>"$LOG_FILE"
  ufw default allow outgoing >>"$LOG_FILE"
  ufw default deny routed >>"$LOG_FILE" 2>&1 || true
  for p in "$@"; do
    if [[ -n $SSH_ALLOW ]]; then
      for src in $SSH_ALLOW; do ufw allow from "$src" to any port "$p" proto tcp comment 'SSH' >>"$LOG_FILE"; done
      ufw delete allow "$p/tcp" >>"$LOG_FILE" 2>&1 || true
    else
      ufw allow "$p/tcp" comment 'SSH' >>"$LOG_FILE"
    fi
  done
  for spec in $OPEN_PORTS; do
    [[ $spec == */* ]] || spec="$spec/tcp"
    ufw allow "$spec" comment 'server-setup open port' >>"$LOG_FILE"
  done
  ufw logging low >>"$LOG_FILE" 2>&1 || true
  ufw --force enable >>"$LOG_FILE"
  note "Firewall: incoming blocked except SSH ($*${SSH_ALLOW:+ from $SSH_ALLOW})${OPEN_PORTS:+ and $OPEN_PORTS for everyone}."
}
step_firewall() { apply_firewall $(uniq_words $(current_ssh_ports) $SSH_PORTS); }
step_fail2ban() { apply_fail2ban $(current_ssh_ports) $SSH_PORTS; note "fail2ban guards SSH ports: $(uniq_words $(current_ssh_ports) $SSH_PORTS)"; }

# ---- hardening -----------------------------------------------------------------------------
apply_hardening() {
  cat >/etc/sysctl.d/90-server-setup-hardening.conf <<'EOF'
# Managed by server-setup: kernel and network hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# loose reverse-path filter: drops spoofed packets, still works with Docker and several NICs
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.perf_event_paranoid = 3
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2
fs.protected_fifos = 1
fs.suid_dumpable = 0
EOF
  # no core dumps: they can hold secrets (keys, passwords in memory) and fill the disk
  install -d /etc/systemd/coredump.conf.d /etc/systemd/system.conf.d /etc/security/limits.d
  printf '# Managed by server-setup\n[Coredump]\nStorage=none\nProcessSizeMax=0\n' >/etc/systemd/coredump.conf.d/90-server-setup.conf
  printf '# Managed by server-setup: no core dumps\n* hard core 0\n' >/etc/security/limits.d/90-server-setup-core.conf
  # AppArmor on
  if command -v aa-status >/dev/null; then
    systemctl enable --now apparmor >>"$LOG_FILE" 2>&1 || true
    if aa-status --enabled 2>/dev/null; then note "AppArmor: enabled ($(aa-status 2>/dev/null | awk '/profiles are in enforce mode/ {print $1}') profiles enforced)."
    else warn "AppArmor is installed but not enabled in this kernel (check the boot parameters)."; fi
  fi
  # shared memory and /tmp stay as they are: noexec on /tmp breaks many installers and apps
  # the login banner says nothing about the system
  : >/etc/issue.net
  sysctl --system >>"$LOG_FILE" 2>&1 || warn "Some sysctl settings were not accepted (see log)."
  ok "Kernel/network hardening, no core dumps, AppArmor"
}

# ---- long uptime -----------------------------------------------------------------------------
apply_uptime_tuning() {
  local ports reserved="" p
  # ports this server listens on (SSH) never handed out as outgoing ports
  for p in $SSH_PORTS; do (( p >= 16384 )) && reserved+="${reserved:+,}$p"; done
  cat >/etc/sysctl.d/91-server-setup-capacity.conf <<EOF
# Managed by server-setup: capacity for long-running, busy servers
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 16384 65535
${reserved:+net.ipv4.ip_local_reserved_ports = $reserved}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
vm.swappiness = 10
vm.max_map_count = 262144
EOF
  # BBR congestion control (better throughput and latency) when the kernel has it
  if modprobe tcp_bbr 2>/dev/null; then
    printf 'tcp_bbr\n' >/etc/modules-load.d/server-setup-bbr.conf
    printf '# Managed by server-setup\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >/etc/sysctl.d/92-server-setup-bbr.conf
  fi
  # connection tracking: the firewall and Docker keep a table of every connection
  if modprobe nf_conntrack 2>/dev/null; then
    printf 'nf_conntrack\n' >/etc/modules-load.d/server-setup-conntrack.conf
    printf '# Managed by server-setup\nnet.netfilter.nf_conntrack_max = 262144\n' >/etc/sysctl.d/93-server-setup-conntrack.conf
  fi
  sysctl --system >>"$LOG_FILE" 2>&1 || warn "Some sysctl settings were not accepted (see log)."
  # open files: high hard limit for everything, a sane soft default (services raise their own)
  printf '# Managed by server-setup\n* soft nofile 65536\n* hard nofile 1048576\nroot soft nofile 65536\nroot hard nofile 1048576\n' \
    >/etc/security/limits.d/90-server-setup-nofile.conf
  printf '# Managed by server-setup\n[Manager]\nDefaultLimitNOFILE=65536:1048576\nDefaultLimitCORE=0\n' >/etc/systemd/system.conf.d/90-server-setup.conf
  systemctl daemon-reexec >>"$LOG_FILE" 2>&1 || true
  ensure_swap
  apply_zswap
  # when memory runs out, the kernel's OOM killer must never pick sshd - you'd lose the server
  install -d /etc/systemd/system/ssh.service.d
  printf '# Managed by server-setup: keep SSH alive under memory pressure\n[Service]\nOOMScoreAdjust=-900\nRestart=always\nRestartSec=3\n' \
    >/etc/systemd/system/ssh.service.d/90-server-setup.conf
  systemctl daemon-reload
  # SSD/virtual disks: give freed blocks back weekly
  systemctl enable --now fstrim.timer >>"$LOG_FILE" 2>&1 || true
  ok "Limits, network buffers$([[ -f /etc/sysctl.d/92-server-setup-bbr.conf ]] && echo ', BBR'), swap + zswap, SSH protected from the OOM killer"
}

apply_zswap() {
  install -d -m 755 "$LIB_DIR"
  render_zswap >"$LIB_DIR/zswap"; chmod 755 "$LIB_DIR/zswap"
  cat >/etc/systemd/system/server-setup-zswap.service <<EOF
# Managed by server-setup
[Unit]
Description=Compressed RAM cache in front of swap (zswap)
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB_DIR/zswap

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl enable server-setup-zswap.service >>"$LOG_FILE" 2>&1
  systemctl restart server-setup-zswap.service >>"$LOG_FILE" 2>&1 || warn "zswap could not be switched on (see $LOG_FILE)."
}

# ---- logs ------------------------------------------------------------------------------------
apply_logs() {
  install -d /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/90-server-setup.conf <<EOF
# Managed by server-setup: the journal never fills the disk and keeps 3 months at most
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=$JOURNAL_MAX
SystemKeepFree=2G
SystemMaxFileSize=128M
MaxRetentionSec=3month
EOF
  install -d -m 2755 -g systemd-journal /var/log/journal 2>/dev/null || install -d /var/log/journal
  systemctl restart systemd-journald
  # text logs: rotated daily, compressed, never larger than 500 MB before rotating
  cat >/etc/logrotate.d/server-setup <<EOF
# Managed by server-setup
$LOG_FILE /var/log/sudo.log {
    weekly
    rotate 12
    maxsize 100M
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
EOF
  if [[ -f /etc/logrotate.d/rsyslog ]] && ! grep -q 'maxsize' /etc/logrotate.d/rsyslog; then
    backup_file /etc/logrotate.d/rsyslog
    sed -i -E 's/^([[:space:]]*)(rotate[[:space:]]+[0-9]+)/\1\2\n\1maxsize 500M/' /etc/logrotate.d/rsyslog
  fi
  systemctl enable --now logrotate.timer >>"$LOG_FILE" 2>&1 || true
  note "Logs: journal capped at $JOURNAL_MAX / 3 months (compressed); text logs rotate before 500 MB."
}

# ---- automatic security updates ----------------------------------------------------------
apply_auto_updates() {
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >/etc/apt/apt.conf.d/52server-setup-unattended <<EOF
// Managed by server-setup: security updates only; services restart by themselves (needrestart)
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Automatic-Reboot "$([[ $AUTO_REBOOT == y ]] && echo true || echo false)";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::SyslogEnable "true";
EOF
  systemctl enable --now unattended-upgrades >>"$LOG_FILE" 2>&1 || true
  if [[ -d /etc/needrestart ]]; then
    install -d /etc/needrestart/conf.d
    printf "# Managed by server-setup: restart services after updates without asking\n\$nrconf{restart} = 'a';\n\$nrconf{kernelhints} = -1;\n" \
      >/etc/needrestart/conf.d/90-server-setup.conf
  fi
  note "Updates: security updates install daily; services restart by themselves. Reboot: $([[ $AUTO_REBOOT == y ]] && echo "automatic at $REBOOT_TIME when needed" || echo 'never automatic - status shows when one is needed')."
}

apply_ubuntu_pro() { # Livepatch: kernel security fixes without a reboot (needs Canonical's servers)
  [[ $OS_ID == ubuntu && -n $PRO_TOKEN ]] || return 0
  command -v pro >/dev/null || os_install ubuntu-pro-client
  run "Attaching Ubuntu Pro" pro attach "$PRO_TOKEN"
  run "Enabling Livepatch" pro enable livepatch --assume-yes
  note "Ubuntu Pro attached; Livepatch on (kernel fixes without a reboot - needs internet to Canonical)."
}

apply_auditd() {
  os_install auditd
  cat >/etc/audit/rules.d/90-server-setup.rules <<'EOF'
# Managed by server-setup: who changed accounts, sudo, SSH and the firewall
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/ufw/ -p wa -k firewall
-w /usr/bin/sudo -p x -k sudo_use
EOF
  sed -i -E 's/^max_log_file_action.*/max_log_file_action = ROTATE/; s/^num_logs.*/num_logs = 8/' /etc/audit/auditd.conf
  augenrules --load >>"$LOG_FILE" 2>&1 || true
  systemctl enable --now auditd >>"$LOG_FILE" 2>&1
  note "auditd: changes to accounts, sudo, SSH and the firewall are recorded (ausearch -k identity|sudo|sshd|firewall)."
}

apply_lynis() {
  os_install lynis
  run_soft "Running a Lynis security audit (a few minutes)" lynis audit system --quick --no-colors --report-file /var/log/lynis-report.dat || true
  local score; score=$(awk -F= '/^hardening_index=/ {print $2}' /var/log/lynis-report.dat 2>/dev/null || true)
  note "Lynis audit: hardening index ${score:-?}/100 - suggestions: grep suggestion /var/log/lynis-report.dat"
}
sshd_cmd() { [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd; sshd "$@"; }
sshd_effective() { sshd_cmd -T; }
sshd_check() { sshd_cmd -t; }
ssh_dropin() { printf '%s' "$SSH_DIR/sshd_config.d/$SSH_DROPIN_NAME"; }
ssh_socket_enabled() { systemctl is-enabled --quiet ssh.socket 2>/dev/null; }

render_ssh_dropin() { # render_ssh_dropin <port>...
  local p
  cat <<EOF
# Managed by server-setup - rewritten on every run. Change ports: sudo server-setup ssh --ports "22 9011"
# sshd keeps the FIRST value it reads and this file sorts first in sshd_config.d,
# so these settings win over 50-cloud-init.conf and any other drop-in.
# Several ports: if one can't be opened, sshd keeps serving the others.
EOF
  for p in "$@"; do printf 'Port %s\n' "$p"; done
  cat <<EOF
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
AllowGroups $SSH_GROUP
MaxAuthTries 4
MaxSessions 10
LoginGraceTime 30
ClientAliveInterval 120
ClientAliveCountMax 3
# A server, not a workstation: admins may open LOCAL forwards (ssh -L to reach a database
# on 127.0.0.1); nothing may listen on this server through SSH (remote forwards, sockets),
# no agent forwarding (a root on this server could use your key), no X11, no tunnels.
AllowTcpForwarding local
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
UseDNS no
EOF
}

current_ssh_ports() {
  {
    sshd_cmd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
    ss -Htlnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}' || true
    if ssh_socket_enabled; then systemctl show ssh.socket -p Listen --value 2>/dev/null | grep -oE ':[0-9]+ ' | tr -d ': ' || true; fi
  } | grep -E '^[0-9]+$' | sort -un || true
}

ssh_ensure_include() {
  local cfg="$SSH_DIR/sshd_config"
  if ! grep -qE "^[[:space:]]*Include[[:space:]]+$SSH_DIR/sshd_config\.d/\*\.conf" "$cfg"; then
    sed -i "1i Include $SSH_DIR/sshd_config.d/*.conf" "$cfg"
    info "Added the sshd_config.d Include line to $cfg."
  fi
}

# Port/ListenAddress/AllowUsers/AllowGroups ADD UP across files instead of first-wins,
# so a leftover line elsewhere would open another port or lock our users out.
ssh_neutralize_conflicts() {
  local f changed=()
  for f in "$SSH_DIR/sshd_config" "$SSH_DIR"/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$(ssh_dropin)" ]] || continue
    if grep -qiE '^[[:space:]]*(Port|ListenAddress|AllowUsers|AllowGroups)[[:space:]]' "$f"; then
      sed -i -E 's/^([[:space:]]*)(Port|ListenAddress|AllowUsers|AllowGroups)([[:space:]])/\1# disabled by server-setup: \2\3/I' "$f"
      changed+=("$f")
    fi
  done
  if (( ${#changed[@]} > 0 )); then info "Disabled conflicting Port/ListenAddress/AllowUsers/AllowGroups lines in: ${changed[*]}"; fi
}

ssh_verify() { # ssh_verify <port>... - checks the EFFECTIVE config, not just our file
  local want_ports eff ports want line p okp problems=()
  want_ports=$(printf '%s\n' "$@" | sort -un | xargs)
  if ! eff=$(sshd_effective 2>&1); then warn "sshd -T failed: $eff"; return 1; fi
  ports=$(awk '$1 == "port" {print $2}' <<<"$eff" | sort -un | xargs)
  [[ $ports == "$want_ports" ]] || problems+=("sshd would listen on port(s) '$ports' instead of '$want_ports'")
  while read -r line; do
    [[ -n $line ]] || continue
    okp=n; for p in "$@"; do [[ $line == *":$p" ]] && okp=y; done
    [[ $okp == y ]] || problems+=("listen address $line is not on one of the ports $want_ports")
  done < <(awk '$1 == "listenaddress" {print $2}' <<<"$eff")
  for want in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
              "pubkeyauthentication yes" "authenticationmethods publickey" "gatewayports no" "usepam yes" \
              "allowtcpforwarding local" "allowstreamlocalforwarding no" "allowagentforwarding no" "x11forwarding no"; do
    grep -qxF "$want" <<<"$eff" || problems+=("expected '$want', effective: '$(grep -E "^${want%% *} " <<<"$eff" || echo unset)'")
  done
  grep -qE "^allowgroups( .*)? $SSH_GROUP( |\$)" <<<"$eff" || problems+=("AllowGroups does not include $SSH_GROUP")
  if grep -qE '^allowusers ' <<<"$eff"; then problems+=("an AllowUsers line is still active"); fi
  if (( ${#problems[@]} > 0 )); then
    for line in "${problems[@]}"; do warn "sshd: $line"; done
    return 1
  fi
  return 0
}

ssh_snapshot() {
  local f
  rm -rf "$ROLLBACK_DIR"
  install -d -m 700 "$ROLLBACK_DIR"
  tar -C "$SSH_DIR" -cpf "$ROLLBACK_DIR/ssh.tar" sshd_config sshd_config.d
  if ssh_socket_enabled; then echo socket; else echo service; fi >"$ROLLBACK_DIR/mode"
  for f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do
    if [[ -f $f ]]; then cp -p "$f" "$ROLLBACK_DIR/$(basename "$(dirname "$f")")--$(basename "$f")"; fi
  done
}

ssh_restore_files() {
  [[ -f $ROLLBACK_DIR/ssh.tar ]] || { warn "No SSH snapshot to restore."; return 1; }
  rm -rf "$SSH_DIR/sshd_config.d"
  tar -C "$SSH_DIR" -xpf "$ROLLBACK_DIR/ssh.tar"
}

ssh_restore() { # restore the snapshot and run sshd the way it ran before
  local f d
  ssh_restore_files || return 1
  for f in "$ROLLBACK_DIR"/*--*.conf; do
    [[ -f $f ]] || continue
    d=$(basename "$f"); d=${d%%--*}
    install -d "/etc/systemd/system/$d"
    cp -p "$f" "/etc/systemd/system/$d/$(basename "$f" | sed 's/.*--//')"
  done
  systemctl daemon-reload
  if [[ $(cat "$ROLLBACK_DIR/mode" 2>/dev/null) == socket ]]; then
    systemctl stop ssh.service || true
    systemctl disable ssh.service >/dev/null 2>&1 || true
    systemctl enable --now ssh.socket
  else
    systemctl restart ssh.service
  fi
  rm -f "$ROLLBACK_DIR/applied_at"
  if [[ -f $ROLLBACK_DIR/old_ports ]]; then apply_fail2ban $(cat "$ROLLBACK_DIR/old_ports") || true; fi
  log_file "SSH configuration rolled back"
}

ssh_use_service_mode() {
  local f
  if ssh_socket_enabled || systemctl is-active --quiet ssh.socket; then
    info "Switching sshd from socket activation to a normal service (so its Port settings are authoritative)."
    systemctl disable --now ssh.socket >>"$LOG_FILE" 2>&1
    for f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do rm -f "$f"; done
    systemctl daemon-reload
  fi
  systemctl enable ssh.service >>"$LOG_FILE" 2>&1
  systemctl restart ssh.service
}

schedule_rollback() {
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_MINUTES}min" "$INSTALL_PATH" _ssh-rollback
}
cancel_rollback() { systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true; }
ssh_change_pending() { [[ -f $ROLLBACK_DIR/applied_at ]]; }

# A public-key login by the admin through the NEW sshd (not from the server itself) proves
# the change works - then it is kept automatically.
ssh_login_seen() {
  local since out hits
  since=$(cat "$ROLLBACK_DIR/applied_at" 2>/dev/null) || return 1
  out=$(journalctl -q --no-pager -o cat -u ssh.service --since "@$since" 2>/dev/null || true)
  hits=$(grep -E "^Accepted publickey for $ADMIN_USER from " <<<"$out" | grep -vE ' from (127\.|::1 )' || true)
  [[ -n $hits ]]
}

ssh_finalize() { # keep the new SSH setup: close the old ports, update fail2ban, save
  local new=() old=() p
  cancel_rollback
  mapfile -t new < <(awk '/^Port / {print $2}' "$(ssh_dropin)")
  if [[ -f $ROLLBACK_DIR/old_ports ]]; then mapfile -t old <"$ROLLBACK_DIR/old_ports"; fi
  for p in "${old[@]}"; do
    if [[ " ${new[*]} " != *" $p "* ]]; then ufw delete allow "$p/tcp" >>"$LOG_FILE" 2>&1 || true; fi
  done
  apply_fail2ban "${new[@]}"
  SSH_PORTS="${new[*]}"; save_config
  rm -f "$ROLLBACK_DIR/applied_at"
  log_file "SSH change confirmed (ports ${new[*]})"
}

ssh_wait_for_login() {
  local ip ports=("$@") ans deadline left keyopt=""
  ip=$(server_ip)
  [[ -f $CRED_DIR/$ADMIN_USER.id_ed25519 ]] && keyopt="-i <saved private key> "
  printf '\n%s' "$C_Y"
  printf '  ---------------------------------------------------------------------------\n'
  printf '   SSH is now key-only, root login off, ports %s, group %s only.\n' "${ports[*]}" "$SSH_GROUP"
  printf '   KEEP THIS TERMINAL OPEN. From your computer, log in as %s on any of them:\n\n' "$ADMIN_USER"
  printf '       ssh %s-p %s %s@%s\n\n' "$keyopt" "${ports[0]}" "$ADMIN_USER" "$ip"
  printf '   The setup continues by itself as soon as that login arrives.\n'
  printf '   Your provider'"'"'s cloud firewall (if any) must allow these TCP ports.\n'
  printf '   No login within %s minutes -> SSH is rolled back automatically.\n' "$ROLLBACK_MINUTES"
  printf '  ---------------------------------------------------------------------------%s\n' "$C_0"
  if [[ -n $keyopt ]]; then
    printf '\n  Private key for %s (save it on your computer, chmod 600):\n\n' "$ADMIN_USER"
    cat "$CRED_DIR/$ADMIN_USER.id_ed25519"
  fi
  printf "  Waiting for the login... (type 'skip' to stop waiting - it is still kept as soon as\n"
  printf "  %s logs in; 'no' rolls back now)\n" "$ADMIN_USER"
  deadline=$(( $(date +%s) + ROLLBACK_MINUTES * 60 - 20 ))
  while left=$(( deadline - $(date +%s) )); (( left > 0 )); do
    if ssh_login_seen; then ssh_finalize; note "SSH: login by $ADMIN_USER confirmed - hardening kept on ports ${ports[*]}."; return 0; fi
    if IFS= read -r -t 5 ans </dev/tty; then
      case $(trim "${ans,,}") in
        skip) note "SSH: not confirmed yet - kept automatically once $ADMIN_USER logs in, else rolled back after $ROLLBACK_MINUTES min."; return 0 ;;
        no)   cancel_rollback; ssh_restore; die "Rolled back on request - SSH runs as before." ;;
      esac
    fi
  done
  if ssh_login_seen; then ssh_finalize; note "SSH: login by $ADMIN_USER confirmed - hardening kept."; return 0; fi
  cancel_rollback; ssh_restore
  die "No login by $ADMIN_USER through the new SSH setup - rolled back. Fix it, then run: sudo server-setup ssh"
}

ssh_apply() { # ssh_apply <port>...
  local ports=("$@") old_ports=() p up=() down=()
  mapfile -t old_ports < <(current_ssh_ports)

  if [[ -f $(ssh_dropin) ]] && cmp -s <(render_ssh_dropin "${ports[@]}") "$(ssh_dropin)" \
     && ! ssh_socket_enabled && ! ssh_change_pending && ssh_verify "${ports[@]}" >/dev/null 2>&1; then
    for p in "${ports[@]}"; do if port_listening "$p"; then up+=("$p"); fi; done
    if (( ${#up[@]} > 0 )); then note "SSH: already hardened, listening on ${up[*]} - unchanged."; return 0; fi
  fi

  for p in "${ports[@]}"; do ufw allow "$p/tcp" comment 'SSH' >>"$LOG_FILE"; done
  ssh_snapshot
  printf '%s\n' "${old_ports[@]}" >"$ROLLBACK_DIR/old_ports"
  ssh_ensure_include
  ssh_neutralize_conflicts
  render_ssh_dropin "${ports[@]}" >"$(ssh_dropin).new"
  chmod 644 "$(ssh_dropin).new"
  mv -f "$(ssh_dropin).new" "$(ssh_dropin)"
  if ! sshd_check >>"$LOG_FILE" 2>&1 || ! ssh_verify "${ports[@]}"; then
    ssh_restore_files
    die "The SSH configuration did not validate - nothing was changed (see the messages above)."
  fi

  schedule_rollback
  ssh_use_service_mode
  date +%s >"$ROLLBACK_DIR/applied_at"
  for p in "${ports[@]}"; do if wait_port "$p"; then up+=("$p"); else down+=("$p"); fi; done
  if (( ${#up[@]} == 0 )); then
    cancel_rollback; ssh_restore
    die "sshd could not open any of the ports ${ports[*]} - rolled back to the previous SSH setup."
  fi
  if (( ${#down[@]} > 0 )); then
    note "SSH: port(s) ${down[*]} could not be opened on the server - continuing with ${up[*]} (see: journalctl -u ssh)."
  fi
  note "SSH listening on: ${up[*]}"
  apply_fail2ban "${ports[@]}" "${old_ports[@]}"
  ssh_wait_for_login "${up[@]}"
}

maybe_use_tmux() {
  local use src cmd
  if [[ -n ${TMUX-} || -n ${STY-} ]] || ! command -v tmux >/dev/null; then return 0; fi
  info "If your SSH connection drops, a setup running directly in it is stopped half-way."
  prompt_yn use "Run the setup inside tmux so it keeps going if the connection drops?" y
  [[ $use == y ]] || return 0
  src=$(readlink -f "${BASH_SOURCE[0]}")
  cmd="bash $(printf '%q' "$src") setup; printf '\nSetup finished - the report is in $REPORT_FILE. Press Enter to close. '; read -r _"
  info "Starting tmux session 'server-setup'. If you get disconnected, log in again and run:"
  info "    sudo tmux attach -t server-setup"
  sleep 3
  exec 9>&-   # don't hand the run lock to tmux
  exec tmux new-session -A -s server-setup "$cmd"
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
collect_answers() {
  local existing rules allowed
  step "1/5  Admin account (full sudo)"
  prompt ADMIN_USER "Admin username" "${ADMIN_USER:-${SUDO_USER:-}}" valid_username
  [[ $ADMIN_USER != root ]] || die "The admin must be a normal user (root login over SSH is turned off)."
  collect_keys "$ADMIN_USER"; ADMIN_KEYS=$KEYS_OUT
  ADMIN_PASSWORD=""; ADMIN_PW_GENERATED=n
  local replace=y
  if user_has_password "$ADMIN_USER"; then prompt_yn replace "$ADMIN_USER already has a password. Replace it?" n; fi
  if [[ $replace == y ]]; then prompt_password ADMIN_PASSWORD "Password for $ADMIN_USER (used for sudo)"; ADMIN_PW_GENERATED=$PW_GENERATED; fi
  info "A deploy user logs in with a key for CI/CD (git pull, docker compose up...) - it has no sudo."
  prompt DEPLOY_USER "Deploy username (empty = none)" "${DEPLOY_USER:-}" valid_username_or_empty
  DEPLOY_KEYS=""
  if [[ -n $DEPLOY_USER ]]; then
    [[ $DEPLOY_USER != "$ADMIN_USER" ]] || die "The deploy user must differ from the admin."
    collect_keys "$DEPLOY_USER"; DEPLOY_KEYS=$KEYS_OUT
  fi

  step "2/5  SSH and firewall"
  existing=$(current_ssh_ports | xargs)
  info "Several SSH ports are allowed: if one is blocked on a network, clients use the next one."
  prompt SSH_PORTS "SSH ports (space-separated)" "${SSH_PORTS:-${existing:-22}}" valid_ssh_ports
  SSH_PORTS=$(for p in $SSH_PORTS; do echo $((10#$p)); done | xargs)
  prompt SSH_ALLOW "Allow SSH only from these IPs/CIDRs (space-separated, empty = from anywhere)" "${SSH_ALLOW:-}" valid_ip_list
  prompt TRUSTED_IPS "IPs/CIDRs fail2ban must never ban (empty = none)" "${TRUSTED_IPS:-}" valid_ip_list
  prompt OPEN_PORTS "Ports open to everyone (e.g. 80 443; empty = none)" "${OPEN_PORTS:-}" valid_open_ports
  UFW_RESET=n
  allowed=$(printf '%s|' $SSH_PORTS 22); allowed=${allowed%|}
  rules=$(ufw show added 2>/dev/null | grep '^ufw ' | grep -vE "allow ($allowed)/tcp" || true)
  if [[ -n $rules ]]; then
    warn "The firewall already has other rules:"; printf '        %s\n' "$rules" >&2
    prompt_yn UFW_RESET "Remove them and keep only what this setup manages?" n
  fi

  step "3/5  Server"
  prompt NEW_HOSTNAME "Hostname" "$(hostname -s)" valid_hostname
  prompt TIMEZONE "Timezone" "${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}" valid_timezone
  prompt JOURNAL_MAX "Maximum disk space for the system journal" "$JOURNAL_MAX" valid_size
  prompt_yn AUTO_REBOOT "Reboot automatically when a security update needs it? (No = it's reported; you choose the time)" "$AUTO_REBOOT"
  if [[ $AUTO_REBOOT == y ]]; then prompt REBOOT_TIME "Reboot time (HH:MM)" "$REBOOT_TIME" valid_time; fi

  step "4/5  Download sources"
  info "Every source (apt, time, later Docker/npm/PyPI/Go/GitHub) is tried directly first. Only a"
  info "source that does not answer goes through the mirror - a Nexus repository manager."
  prompt MIRROR_URL "Mirror base URL" "$(mirror_base)" valid_url
  prompt MIRROR_USER "Mirror username (empty = anonymous)" "${MIRROR_USER:-}" accept_any
  if [[ -n $MIRROR_USER ]]; then
    local pw=""
    printf '%s?%s Mirror password (empty = keep the current one): ' "$C_C" "$C_0" >/dev/tty
    IFS= read -rs pw </dev/tty || true; printf '\n' >/dev/tty
    [[ -z $pw ]] || MIRROR_PASSWORD_NEW=$pw
  fi
  info "Repository names on the mirror can be changed any time: server-setup mirror set"
  prompt NTP_SERVERS "Internal NTP servers (space-separated, empty = public pools only)" "${NTP_SERVERS:-}" valid_host_list
  PRO_TOKEN=""
  if [[ $OS_ID == ubuntu ]]; then
    info "Ubuntu Pro (free for 5 machines) adds Livepatch: kernel security fixes without a reboot."
    info "It needs internet access to Canonical. Token from https://ubuntu.com/pro/dashboard"
    prompt PRO_TOKEN "Ubuntu Pro token (empty = skip)" "" accept_any
  fi

  step "5/5  Extras"
  prompt_yn AUDITD "Record changes to accounts, sudo, SSH and the firewall (auditd)?" "$AUDITD"
  prompt_yn LYNIS "Run a Lynis security audit at the end (report only)?" "$LYNIS"
  info "Roles available in this version: base (hardening). Tools, monitoring and Dokploy nodes come next."
  ROLES=base

  step "Plan"
  info "OS:                  $OS_ID $OS_VERSION ($OS_CODENAME, $OS_ARCH)"
  info "Admin (sudo):        $ADMIN_USER${DEPLOY_USER:+   Deploy (no sudo): $DEPLOY_USER}"
  info "SSH:                 ports $SSH_PORTS, keys only, no root login${SSH_ALLOW:+, only from $SSH_ALLOW}"
  info "Firewall:            SSH${OPEN_PORTS:+ + $OPEN_PORTS} inbound, everything else blocked"
  info "Hostname/timezone:   $NEW_HOSTNAME / $TIMEZONE"
  info "Sources:             direct first, mirror $(mirror_base) as fallback${NTP_SERVERS:+; NTP $NTP_SERVERS}"
  info "Reboots:             $([[ $AUTO_REBOOT == y ]] && echo "automatic at $REBOOT_TIME when needed" || echo 'never automatic')"
  info "Extras:              auditd $AUDITD, Lynis $LYNIS${PRO_TOKEN:+, Ubuntu Pro + Livepatch}"
}
valid_username_or_empty() { [[ -z $1 ]] || valid_username "$1"; }

cmd_setup() {
  need_tty
  check_os
  maybe_use_tmux
  install_self
  printf '\n%sServer setup - server-setup %s%s\n' "$C_B" "$SCRIPT_VERSION" "$C_0"
  info "$OS_ID $OS_VERSION, $(nproc) CPU, $(awk '/^MemTotal:/ {printf "%.1f GB RAM", $2/1048576}' /proc/meminfo), $(df -h / | awk 'NR == 2 {print $2 " disk"}')"
  if [[ $SETUP_DONE == y ]]; then
    local again; prompt_yn again "This server is already set up (admin: $ADMIN_USER). Run the setup again and update everything in place?" n
    [[ $again == y ]] || exit 0
  fi
  collect_answers
  local go; prompt_yn go "Apply this now? (every step runs; failures are reported at the end)" y
  [[ $go == y ]] || die "Aborted - nothing was changed."
  log_file "setup started by ${SUDO_USER:-root}"
  IN_SETUP=y
  if [[ -n $MIRROR_PASSWORD_NEW ]]; then secret_set mirror-password "$MIRROR_PASSWORD_NEW"; fi
  [[ -n $MIRROR_USER ]] || secret_set mirror-password ""
  save_config

  try_step "Package sources (direct first, mirror if needed)" resolve_apt
  if step_ok "Package sources (direct first, mirror if needed)"; then
    try_step "System update and base packages" step_packages
  else
    skip_step "System update and base packages" "no working package source"
  fi
  try_step "Hostname" apply_hostname
  try_step "Time sync (chrony)" apply_time_sync
  try_step "Users and SSH keys" step_users
  try_step "Firewall" step_firewall
  try_step "fail2ban" step_fail2ban
  try_step "Kernel and system hardening" apply_hardening
  try_step "Long-uptime tuning (limits, network, swap, zswap)" apply_uptime_tuning
  try_step "Logs (journal, logrotate)" apply_logs
  try_step "Automatic security updates" apply_auto_updates
  if [[ -n $PRO_TOKEN ]]; then try_step "Ubuntu Pro and Livepatch" apply_ubuntu_pro; fi
  if [[ $AUDITD == y ]]; then try_step "auditd" apply_auditd; fi
  if step_ok "Users and SSH keys" && step_ok "Firewall"; then
    try_step "SSH hardening (ports $SSH_PORTS, auto-rollback)" ssh_apply $SSH_PORTS
  else
    skip_step "SSH hardening" "users or firewall step failed - SSH left unchanged so you can't be locked out"
  fi
  if [[ $LYNIS == y ]]; then try_step "Lynis audit" apply_lynis; fi
  SETUP_DONE=y; save_config
  print_report
}

# ----------------------------------------------------------------------------
# Day-2 commands
# ----------------------------------------------------------------------------
cmd_users() {
  local action=${1-} u="" role=deploy a; if (( $# > 0 )); then shift; fi
  for a in "$@"; do case $a in --admin) role=admin ;; --deploy) role=deploy ;; -*) die "Unknown option $a" ;; *) u=$a ;; esac; done
  case $action in
    list|"") users_table ;;
    add)
      need_tty
      [[ -n $u ]] || prompt u "Username" "" valid_username
      valid_username "$u" || exit 1
      ensure_group "$SSH_GROUP"
      collect_keys "$u"; local keys=$KEYS_OUT pw="" gen=n
      if [[ $role == admin ]] && ! user_has_password "$u"; then prompt_password pw "Password for $u (used for sudo)"; gen=$PW_GENERATED; fi
      ensure_user "$u" "$role"; apply_keys "$u" "$keys"
      if [[ -n $pw ]]; then set_password "$u" "$pw" "$gen"; fi
      ok "$u added ($role)."; print_credentials ;;
    remove)
      need_tty
      [[ -n $u ]] && id "$u" &>/dev/null || die "usage: server-setup users remove <user>"
      is_human_uid "$(id -u "$u")" || die "'$u' is a system account."
      [[ $u != "$ADMIN_USER" ]] || die "$u is the primary admin of this setup."
      [[ $u != "${SUDO_USER-}" ]] || die "You can't remove yourself."
      local confirm; prompt confirm "Type '$u' again to delete this user (home archived to /root first)" "" accept_any
      [[ $confirm == "$u" ]] || die "Aborted."
      loginctl terminate-user "$u" 2>/dev/null || true; pkill -KILL -u "$u" 2>/dev/null || true; sleep 1
      local home; home=$(home_of "$u")
      if [[ -d $home ]]; then
        install -d -m 700 /root/server-setup-archive
        tar -C "$(dirname "$home")" -czf "/root/server-setup-archive/$u-$(date +%Y%m%d-%H%M%S).tar.gz" "$(basename "$home")"
      fi
      userdel -r "$u" >>"$LOG_FILE" 2>&1 || userdel "$u"
      rm -f "$CRED_DIR/$u".*
      [[ $u != "$DEPLOY_USER" ]] || { DEPLOY_USER=""; save_config; }
      ok "Removed $u." ;;
    key)
      need_tty
      [[ -n $u ]] && id "$u" &>/dev/null || die "usage: server-setup users key <user>"
      collect_keys "$u" y; apply_keys "$u" "$KEYS_OUT"; ok "Key added for $u."; print_credentials ;;
    password)
      need_tty
      [[ -n $u ]] && id "$u" &>/dev/null || die "usage: server-setup users password <user>"
      local pw; prompt_password pw "New password for $u"; set_password "$u" "$pw" "$PW_GENERATED"
      ok "Password set for $u (sudo only - SSH stays key-only)."; print_credentials ;;
    *) die "usage: server-setup users list|add|remove|key|password <user> [--admin|--deploy]" ;;
  esac
}

cmd_firewall() {
  local action=${1-} spec; if (( $# > 0 )); then shift; fi
  case $action in
    list|"") ufw status verbose | sed 's/^/    /' ;;
    allow)
      (( $# > 0 )) || die "usage: server-setup firewall allow <port>[/udp]...   (opens to everyone)"
      valid_open_ports "$*" || exit 1
      OPEN_PORTS=$(uniq_words $OPEN_PORTS "$@"); save_config; step_firewall; ok "Open to everyone: $OPEN_PORTS" ;;
    deny)
      (( $# > 0 )) || die "usage: server-setup firewall deny <port>[/udp]..."
      for spec in "$@"; do
        OPEN_PORTS=$(printf '%s\n' $OPEN_PORTS | awk -v x="$spec" '$0 != x && $0 != x"/tcp"' | xargs)
        [[ $spec == */* ]] || spec="$spec/tcp"
        ufw delete allow "$spec" >>"$LOG_FILE" 2>&1 || true
      done
      save_config; ok "Open to everyone now: ${OPEN_PORTS:-(nothing but SSH)}" ;;
    ssh-from)
      valid_ip_list "$*" || exit 1
      SSH_ALLOW="$*"; save_config
      ufw delete allow "$(ssh_main_port)/tcp" >>"$LOG_FILE" 2>&1 || true
      step_firewall; ok "SSH allowed from: ${SSH_ALLOW:-anywhere}" ;;
    *) die "usage: server-setup firewall list | allow <port>... | deny <port>... | ssh-from [<cidr>...]" ;;
  esac
}

cmd_update() {
  local all=n; [[ ${1-} == --all ]] && all=y
  run "Refreshing package lists" apt_get update
  if [[ $all == y ]]; then run "Installing all updates" apt_get dist-upgrade
  else run "Installing security updates" unattended-upgrade -v; fi
  if command -v needrestart >/dev/null; then run_soft "Restarting services that use updated libraries" needrestart -r a -q || true; fi
  local why; why=$(os_reboot_reason)
  if [[ -n $why ]]; then warn "A reboot is needed: $why. Choose a quiet moment: sudo reboot"; else ok "Up to date - no reboot needed."; fi
}

# ----------------------------------------------------------------------------
# Status and report
# ----------------------------------------------------------------------------
users_table() {
  local name uid role pw keys home
  printf '%-16s %-7s %-5s %-9s %s\n' USER ROLE SSH PASSWORD KEYS
  while IFS=: read -r name _ uid _ _ home _; do
    is_human_uid "$uid" || continue
    role=-; if in_group "$name" sudo; then role=admin; elif [[ $name == "$DEPLOY_USER" ]]; then role=deploy; fi
    pw=none; if user_has_password "$name"; then pw=set; fi
    keys=$(grep -cE '^(sk-)?(ssh-|ecdsa-)' "$home/.ssh/authorized_keys" 2>/dev/null || true)
    printf '%-16s %-7s %-5s %-9s %s\n' "$name" "$role" "$(in_group "$name" "$SSH_GROUP" && echo yes || echo no)" "$pw" "${keys:-0}"
  done < <(getent passwd)
}

cmd_status() {
  local eff why failed sec p
  os_detect
  step "System"
  info "$(hostname -f 2>/dev/null || hostname) - $OS_ID $OS_VERSION, kernel $(uname -r), up $(uptime -p | sed 's/^up //')"
  info "load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPU; $(free -h | awk '/^Mem:/ {print "RAM " $3 " used of " $2} /^Swap:/ {print ", swap " $3 " of " $2}' | xargs)"
  df -h -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR > 1 {printf "    disk %-20s %5s used of %5s (%s)\n", $6, $3, $2, $5}'
  why=$(os_reboot_reason); if [[ -n $why ]]; then warn "Reboot needed: $why"; else ok "No reboot needed."; fi
  failed=$(systemctl --failed --plain --no-legend 2>/dev/null | awk '{print $1}' | xargs)
  if [[ -n $failed ]]; then warn "Failed services: $failed"; else ok "No failed services."; fi
  sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst .*-security' || true)
  if (( sec > 0 )); then warn "$sec security update(s) waiting: sudo server-setup update"; else ok "No security updates waiting."; fi

  step "Sources"
  local s line=""; for s in $SOURCES; do [[ $(route_of "$s") != unset ]] && line+="$s: $(route_of "$s")  "; done
  info "${line:-not checked yet}   (mirror $(mirror_base); details: server-setup mirror test)"

  step "Users"; users_table | sed 's/^/    /'

  step "SSH"
  if ssh_verify ${SSH_PORTS:-22} 2>/dev/null; then ok "Effective sshd config matches the hardening."; else warn "sshd config differs from the hardening - run: sudo server-setup ssh"; fi
  for p in ${SSH_PORTS:-22}; do if port_listening "$p"; then info "port $p: listening"; else warn "port $p: NOT listening"; fi; done
  if ssh_change_pending; then warn "An SSH change is waiting for $ADMIN_USER's first login (auto-rollback pending)."; fi

  step "Firewall"; ufw status 2>/dev/null | sed 's/^/    /' || true
  step "fail2ban"
  fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' | sed 's/^[|` -]*/    /' || info "not running"
  step "Time"; info "$(timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/yes/clock synchronized/; s/no/clock NOT synchronized/'), $(chronyc -n tracking 2>/dev/null | awk -F': ' '/^Reference ID/ {print "source " $2}')"
  step "Logs"; info "journal $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1) of $JOURNAL_MAX"
}

write_report() { # write_report [what changed] - the whole report, from the current state
  {
    printf 'server-setup %s - %s, updated %s' "$SCRIPT_VERSION" "$(hostname -s)" "$(date '+%F %T')"
    if [[ -n ${1-} ]]; then printf ' (after: %s)' "$1"; fi
    printf '\n'
    if [[ -s $LAST_SETUP ]]; then printf '\n'; cat "$LAST_SETUP"; fi
    printf '\n'; cmd_status 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    printf '\nManage: sudo server-setup help\n'
  } >"$REPORT_FILE.new"
  chmod 600 "$REPORT_FILE.new"; mv -f "$REPORT_FILE.new" "$REPORT_FILE"
}

print_report() {
  local row s t failed=0 color
  {
    printf 'Last full setup: %s\n' "$(date '+%F %T')"
    printf '\nSteps:\n'
    for row in "${RESULTS[@]}"; do IFS=$'\t' read -r s t <<<"$row"; printf '  %-8s %s\n' "${s^^}" "$t"; done
    if [[ -s $RUN_NOTES ]]; then printf '\nDetails:\n'; sed 's/^/  - /' "$RUN_NOTES"; fi
  } >"$LAST_SETUP"
  chmod 600 "$LAST_SETUP"
  write_report "setup"
  step "Result"
  for row in "${RESULTS[@]}"; do
    IFS=$'\t' read -r s t <<<"$row"
    case $s in ok) color=$C_G ;; FAILED) color=$C_R; failed=$((failed + 1)) ;; *) color=$C_Y ;; esac
    printf '    %s%-8s%s %s\n' "$color" "${s^^}" "$C_0" "$t"
  done
  if [[ -s $RUN_NOTES ]]; then printf '\n'; sed 's/^/    - /' "$RUN_NOTES"; fi
  print_credentials
  printf '\n'
  info "Report (no secrets): $REPORT_FILE     Full log: $LOG_FILE     Status any time: sudo server-setup status"
  if (( failed > 0 )); then
    warn "$failed step(s) failed - fix the cause and run 'sudo server-setup setup' again (it is safe to re-run)."
    exit 1
  fi
}

cmd_ssh() {
  need_tty
  local ports=""
  while (( $# > 0 )); do
    case $1 in --ports|--port) ports=${2-}; shift 2 || die "$1 needs a value" ;; *) die "usage: server-setup ssh [--ports \"22 9011\"]" ;; esac
  done
  [[ -n $ADMIN_USER ]] || die "Run the setup first."
  if [[ -z $ports ]]; then prompt ports "SSH ports (space-separated)" "${SSH_PORTS:-22}" valid_ssh_ports; fi
  valid_ssh_ports "$ports" || exit 1
  ports=$(for p in $ports; do echo $((10#$p)); done | xargs)
  SSH_PORTS=$ports; save_config
  apply_firewall $(uniq_words $(current_ssh_ports) $ports)
  ssh_apply $ports
  print_credentials
}

usage() {
  cat <<EOF
server-setup $SCRIPT_VERSION - hardened Ubuntu/Debian servers, online or internal

  setup                        First-time setup (interactive). Safe to re-run.
  status                       System, reboot needed, sources, users, SSH, firewall, time, logs.
  report                       Rewrite $REPORT_FILE.
  update [--all]               Install security updates now (--all: every update), restart
                               the services that need it, and say whether a reboot is needed.

  users list|add|remove|key|password <name> [--admin|--deploy]
                               Admins have sudo; deploy users only log in with a key (CI/CD).
  firewall list | allow <port>[/udp]... | deny <port>... | ssh-from [<cidr>...]
  mirror show|test|set|recheck Download sources: each one is tried directly first and only
                               goes through the mirror (a Nexus) when direct does not answer.
                               test: what works, directly and on the mirror. set: URL, login,
                               repository names, NTP servers, per-source mode. recheck: decide
                               again (e.g. after the server got or lost internet access).

  ssh [--ports "22 9011"]      Re-apply the SSH hardening or change its ports (auto-rollback).
  confirm                      Keep a pending SSH change now (otherwise it is kept on the
                               admin's first login, or rolled back after $ROLLBACK_MINUTES minutes).
  help                         This text.

Config: $CONF_FILE   Log: $LOG_FILE   Credentials made by the script: $CRED_DIR
EOF
}

main() {
  local cmd=${1-}
  if (( $# > 0 )); then shift; fi
  case $cmd in help|-h|--help) usage; return 0 ;; esac
  [[ $EUID -eq 0 ]] || die "This needs root: sudo server-setup ${cmd:-status} $*"
  init_state
  os_detect
  trap 'on_error $LINENO' ERR
  if [[ -z $cmd ]]; then if [[ $SETUP_DONE == y ]]; then cmd=status; else cmd=setup; fi; fi
  if [[ $cmd == _ssh-rollback ]]; then
    if ssh_change_pending; then
      if ssh_login_seen; then ssh_finalize
      else
        ssh_restore || true
        wall "server-setup: an SSH change saw no login by $ADMIN_USER within $ROLLBACK_MINUTES minutes and was rolled back." 2>/dev/null || true
      fi
    fi
    return 0
  fi
  case $cmd in
    status) ;;
    *)
      exec 9>"$STATE_DIR/.lock"
      flock -n 9 || die "Another server-setup run is still going. If it runs in tmux: sudo tmux attach -t server-setup"
      ;;
  esac
  case $cmd in setup|status|help|report) ;; *) REFRESH_FOR="$cmd $*" ;; esac
  begin_run
  trap end_run EXIT
  case $cmd in
    setup)    cmd_setup "$@" ;;
    status)   cmd_status ;;
    report)   write_report "report"; ok "Updated: $REPORT_FILE" ;;
    update)   cmd_update "$@" ;;
    users)    cmd_users "$@" ;;
    firewall) cmd_firewall "$@" ;;
    mirror)   cmd_mirror "$@" ;;
    ssh)      cmd_ssh "$@" ;;
    confirm)  ssh_change_pending || die "No SSH change is pending."; ssh_finalize; ok "SSH change kept (ports $SSH_PORTS)." ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
