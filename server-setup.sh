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

readonly SCRIPT_VERSION="0.6.4"
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
  less vim-tiny nano htop jq rsync lsof iproute2 dnsutils netcat-openbsd bash-completion tmux bsdextrautils
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
REPO_NPM="" REPO_PYPI="" REPO_GO="" REPO_GODL="" REPO_GITHUB=""
# Tools (app role) and backups
TOOLS="" NODE_MAJOR="" BACKUP_REPO="" BACKUP_PATHS="" BACKUP_TIME="" BACKUP_KEEP=""
# Monitoring (monitor role)
MONITOR="" MONITOR_RETENTION="" LOG_RETENTION="" MONITOR_USER="" MONITOR_METRICS_URL="" MONITOR_LOGS_URL=""
MONITOR_HUB_ADDR="" MONITOR_ALLOW="" MONITOR_INSECURE_TLS="" GRAFANA_PUBLIC=""
ALERT_TELEGRAM_CHAT="" ALERT_EMAIL_TO="" ALERT_EMAIL_FROM="" ALERT_SMTP="" ALERT_SMTP_USER="" ALERT_WEBHOOK=""
IMG_VM="" IMG_VMALERT="" IMG_LOKI="" IMG_GRAFANA="" IMG_ALERTMANAGER="" IMG_KUMA="" IMG_CADDY=""
# Dokploy node (dokploy-node role)
DOKPLOY_NODE="" DOKPLOY_USER="" DOKPLOY_KEY="" DOKPLOY_PANEL_IP="" DOKPLOY_ADVERTISE_ADDR="" DOKPLOY_SWARM_PEERS=""
TRAEFIK_VERSION="" NIXPACKS_VERSION="" RAILPACK_VERSION="" PACK_VERSION=""
# Fleet (member side: the manager allowed to run the fleet agent here)
FLEET_MANAGER=""
# Per source: SRC_<name> = auto|direct|mirror|none (what the admin wants),
#             ROUTE_<name> = direct|mirror|none (what is in use now)
readonly SOURCES="apt ntp dockerhub ghcr dockerapt grafanaapt nodesource npm pypi go godl github"
SRC_apt="" SRC_ntp="" SRC_dockerhub="" SRC_ghcr="" SRC_dockerapt="" SRC_grafanaapt="" SRC_nodesource=""
SRC_npm="" SRC_pypi="" SRC_go="" SRC_godl="" SRC_github=""
ROUTE_apt="" ROUTE_ntp="" ROUTE_dockerhub="" ROUTE_ghcr="" ROUTE_dockerapt="" ROUTE_grafanaapt=""
ROUTE_nodesource="" ROUTE_npm="" ROUTE_pypi="" ROUTE_go="" ROUTE_godl="" ROUTE_github=""

CONF_KEYS="ADMIN_USER DEPLOY_USER SSH_PORTS SSH_ALLOW TRUSTED_IPS OPEN_PORTS AUTO_REBOOT REBOOT_TIME
  TIMEZONE NTP_SERVERS JOURNAL_MAX AUDITD LYNIS ROLES SETUP_DONE MIRROR_URL MIRROR_USER
  REPO_UBUNTU REPO_UBUNTU_SECURITY REPO_UBUNTU_PORTS REPO_DEBIAN REPO_DEBIAN_SECURITY
  REPO_DOCKER_APT REPO_GRAFANA_APT REPO_NODESOURCE_APT MIRROR_DOCKER_REGISTRY
  REPO_NPM REPO_PYPI REPO_GO REPO_GODL REPO_GITHUB TOOLS NODE_MAJOR BACKUP_REPO BACKUP_PATHS BACKUP_TIME BACKUP_KEEP
  MONITOR MONITOR_RETENTION LOG_RETENTION MONITOR_USER MONITOR_METRICS_URL MONITOR_LOGS_URL MONITOR_HUB_ADDR
  MONITOR_ALLOW MONITOR_INSECURE_TLS GRAFANA_PUBLIC ALERT_TELEGRAM_CHAT ALERT_EMAIL_TO ALERT_EMAIL_FROM ALERT_SMTP
  ALERT_SMTP_USER ALERT_WEBHOOK IMG_VM IMG_VMALERT IMG_LOKI IMG_GRAFANA IMG_ALERTMANAGER IMG_KUMA IMG_CADDY
  DOKPLOY_NODE DOKPLOY_USER DOKPLOY_KEY DOKPLOY_PANEL_IP DOKPLOY_ADVERTISE_ADDR DOKPLOY_SWARM_PEERS
  TRAEFIK_VERSION NIXPACKS_VERSION RAILPACK_VERSION PACK_VERSION FLEET_MANAGER"
for _s in $SOURCES; do CONF_KEYS+=" SRC_$_s ROUTE_$_s"; done; unset _s

# Answers of this run that are not saved
ADMIN_KEYS="" ADMIN_PASSWORD="" ADMIN_PW_GENERATED=n DEPLOY_KEYS="" NEW_HOSTNAME="" UFW_RESET=n
MIRROR_PASSWORD_NEW="" PRO_TOKEN="" NEW_TOOLS=""
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
  : "${REPO_NPM:=npm-proxy}" "${REPO_PYPI:=pypi-proxy}" "${REPO_GO:=go-proxy}" "${REPO_GODL:=go-dl}" "${REPO_GITHUB:=github-proxy}"
  [[ -n $MIRROR_DOCKER_REGISTRY ]] || MIRROR_DOCKER_REGISTRY=$(mirror_host)
  local s v
  for s in $SOURCES; do v="SRC_$s"; [[ -n ${!v} ]] || printf -v "$v" auto; done
  mon_defaults
  dokploy_defaults
  : "${DOKPLOY_NODE:=n}"
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
    go) printf 'Go modules' ;; godl) printf 'Go toolchain downloads' ;; github) printf 'GitHub downloads' ;; *) printf '%s' "$1" ;;
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
    godl) printf 'https://dl.google.com/go/go1.22.0.linux-amd64.tar.gz.sha256' ;;
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
    godl) printf '%s/repository/%s/go/go1.22.0.linux-amd64.tar.gz.sha256' "$b" "$REPO_GODL" ;;
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
  printf '              docker-apt %s, grafana-apt %s, nodesource %s, npm %s, pypi %s, go %s, go-dl %s, github %s\n' \
    "$REPO_DOCKER_APT" "$REPO_GRAFANA_APT" "$REPO_NODESOURCE_APT" "$REPO_NPM" "$REPO_PYPI" "$REPO_GO" "$REPO_GODL" "$REPO_GITHUB"
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
           REPO_GRAFANA_APT REPO_NODESOURCE_APT REPO_NPM REPO_PYPI REPO_GO REPO_GODL REPO_GITHUB; do
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
  local s
  step "Package sources"
  resolve_apt
  run "Refreshing package lists" apt_get update
  if [[ -f /etc/chrony/chrony.conf ]]; then step "Time sync"; apply_time_sync; fi
  step "Tool sources"
  # every source a tool already uses is decided again and re-written where it is read
  for s in dockerhub dockerapt grafanaapt nodesource npm pypi go godl github; do
    [[ $(route_of "$s") == unset ]] && continue
    RECHECK=y need_source "$s"
  done
  [[ -f /etc/apt/sources.list.d/server-setup-docker.sources ]] && apt_repo dockerapt docker "https://download.docker.com/linux/$OS_ID" "$OS_CODENAME" stable "https://download.docker.com/linux/$OS_ID/gpg"
  [[ -f /etc/apt/sources.list.d/server-setup-nodesource.sources ]] && apt_repo nodesource nodesource "https://deb.nodesource.com/node_${NODE_MAJOR:-24}.x" nodistro main https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
  [[ -f /etc/apt/sources.list.d/server-setup-grafana.sources ]] && apt_repo grafanaapt grafana https://apt.grafana.com stable main https://apt.grafana.com/gpg.key
  apt_auth_sync
  render_client_mirrors
  if os_installed docker-ce; then
    render_daemon_json "$(docker_swarm_active && echo y || echo n)" >/etc/docker/daemon.json
    docker_restart; docker_login_mirror
  fi
  local line=""; for s in $SOURCES; do [[ $(route_of "$s") != unset ]] && line+="$s $(route_of "$s"), "; done
  ok "Sources: ${line%, }"
}
docker_swarm_active() { [[ $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null) == active ]]; }

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
fw_allow_ssh_port() { # fw_allow_ssh_port <port> - open to SSH_ALLOW only (or to all when it is empty)
  local p=$1 src
  if [[ -n $SSH_ALLOW ]]; then
    for src in $SSH_ALLOW; do ufw allow from "$src" to any port "$p" proto tcp comment 'SSH' >>"$LOG_FILE"; done
    ufw delete allow "$p/tcp" >>"$LOG_FILE" 2>&1 || true
  else
    ufw allow "$p/tcp" comment 'SSH' >>"$LOG_FILE"
  fi
}
fw_close_ssh_port() { # every rule that opened <port> for SSH, restricted or not
  local p=$1 src
  ufw delete allow "$p/tcp" >>"$LOG_FILE" 2>&1 || true
  for src in $SSH_ALLOW; do ufw delete allow from "$src" to any port "$p" proto tcp >>"$LOG_FILE" 2>&1 || true; done
}
apply_firewall() { # apply_firewall <ssh port>...
  local p src spec
  if [[ ${UFW_RESET:-n} == y ]]; then ufw --force reset >>"$LOG_FILE" 2>&1; fi
  ufw default deny incoming >>"$LOG_FILE"
  ufw default allow outgoing >>"$LOG_FILE"
  ufw default deny routed >>"$LOG_FILE" 2>&1 || true
  for p in "$@"; do fw_allow_ssh_port "$p"; done
  for spec in $OPEN_PORTS; do
    [[ $spec == */* ]] || spec="$spec/tcp"
    ufw allow "$spec" comment 'server-setup open port' >>"$LOG_FILE"
    # (older versions also added a ufw route rule here - matched on the CONTAINER port, it let
    #  any container listening on that port through on any published port: removed)
    ufw route delete allow proto "${spec#*/}" from any to any port "${spec%/*}" >>"$LOG_FILE" 2>&1 || true
  done
  ufw logging low >>"$LOG_FILE" 2>&1 || true
  ufw --force enable >>"$LOG_FILE"
  # containers' published ports follow the same open ports (rules in Docker's DOCKER-USER chain)
  if os_installed docker-ce; then apply_ufw_docker; fi
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
  if [[ -n $(ssh_stale_listeners) ]]; then problems+=("an old sshd (pid $(ssh_stale_listeners | xargs)) still holds a port with its old configuration - run: sudo server-setup ssh"); fi
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
  local f d new=() old="" p
  mapfile -t new < <(awk '/^Port / {print $2}' "$(ssh_dropin)" 2>/dev/null)   # the rejected ports
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
    ssh_kill_stale_listeners
  fi
  rm -f "$ROLLBACK_DIR/applied_at"
  if [[ -f $ROLLBACK_DIR/old_ports ]]; then
    old=$(xargs <"$ROLLBACK_DIR/old_ports")
    apply_fail2ban $old || true
    # close what the rejected change opened, and remember the ports sshd really uses again
    for p in "${new[@]}"; do [[ " $old " == *" $p "* ]] || fw_close_ssh_port "$p"; done
    if [[ -n $old ]]; then SSH_PORTS=$old; save_config; fi
  fi
  log_file "SSH configuration rolled back"
}

# sshd listeners that are not ssh.service's current main process. ssh.service has
# KillMode=process, so a restart only replaces the main sshd: a listener left over from an
# earlier start (seen: one from the package upgrade during setup) keeps its port with the OLD
# configuration - e.g. root login - while the new sshd can't bind that port. Found on the
# test server: port 22 still allowed root after the hardening. Sessions are never listeners.
ssh_stale_listeners() {
  local main pid
  main=$(systemctl show ssh.service -p MainPID --value 2>/dev/null)
  for pid in $(ss -Htlnp 2>/dev/null | grep '"sshd"' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    [[ $pid != "$main" ]] && printf '%s\n' "$pid"
  done
  return 0
}
ssh_kill_stale_listeners() { # stop them, then let the real sshd bind every port
  local pids
  pids=$(ssh_stale_listeners | xargs)
  [[ -n $pids ]] || return 0
  warn "Stopping sshd listener(s) left over from an earlier start (old configuration): $pids"
  kill -TERM $pids 2>/dev/null || true
  sleep 1
  kill -KILL $pids 2>/dev/null || true
  systemctl restart ssh.service
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
  ssh_kill_stale_listeners
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
    if [[ " ${new[*]} " != *" $p "* ]]; then fw_close_ssh_port "$p"; fi
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

  for p in "${ports[@]}"; do fw_allow_ssh_port "$p"; done
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
# Sources in use by tools: decided the first time a tool needs one (direct first, then the
# mirror), then written where that ecosystem reads it.
# ----------------------------------------------------------------------------
source_direct_ok() { http_ok "$(http_code "$(direct_url "$1")")"; }
source_mirror_ok() { # does the mirror serve this source (with the login, if any)
  local u code netrc args=()
  u=$(mirror_url_of "$1"); [[ -n $u ]] || return 1
  netrc=$(mktemp); if mirror_netrc "$netrc"; then args=(--netrc-file "$netrc"); fi
  code=$(http_code "$u" "${args[@]}"); rm -f "$netrc"
  [[ $code =~ ^(2..|3..)$ ]] && return 0
  [[ $1 == dockerhub && $code == 401 ]]   # a registry always answers 401 before its token dance
}
# need_source <name> - make sure <name> has a route (direct|mirror), deciding it if needed
need_source() {
  local s=$1 v="SRC_$1" r="ROUTE_$1" cur
  cur=${!r}
  case ${!v} in
    direct|mirror) printf -v "$r" '%s' "${!v}" ;;
    none) die "$(source_label "$s") is set to 'none' - change it: server-setup mirror set" ;;
    *)
      if [[ -z $cur || ${RECHECK:-n} == y ]]; then
        if source_direct_ok "$s"; then printf -v "$r" direct
        elif source_mirror_ok "$s"; then printf -v "$r" mirror; note "$(source_label "$s"): not reachable directly - using the mirror."
        else die "$(source_label "$s") is reachable neither directly nor on the mirror ($(mirror_url_of "$s")). Check: server-setup mirror test"
        fi
      fi ;;
  esac
  save_config
}
is_mirror() { [[ $(route_of "$1") == mirror ]]; }

# fetch <source> <url-path-or-full-url> <out> - a download through the source's route.
# direct: the URL as given; mirror: the same path under the source's mirror repository.
fetch() {
  local s=$1 url=$2 out=$3 netrc args=() rc=0
  need_source "$s"
  if is_mirror "$s"; then
    url="$(mirror_base)/repository/$(mirror_repo_of "$s")/${url#*://*/}"
    netrc=$(mktemp); if mirror_netrc "$netrc"; then args=(--netrc-file "$netrc"); fi
  fi
  printf '\n$ fetch %s\n' "$url" >>"$LOG_FILE"
  curl -fsSL --retry 2 --connect-timeout 15 -o "$out" "${args[@]}" "$url" 2>>"$LOG_FILE" || rc=$?
  [[ -n ${netrc-} ]] && rm -f "$netrc"
  (( rc == 0 )) || die "Download failed: $url (see $LOG_FILE)"
}
mirror_repo_of() {
  case $1 in
    dockerapt) printf '%s' "$REPO_DOCKER_APT" ;; grafanaapt) printf '%s' "$REPO_GRAFANA_APT" ;;
    nodesource) printf '%s' "$REPO_NODESOURCE_APT" ;; npm) printf '%s' "$REPO_NPM" ;; pypi) printf '%s' "$REPO_PYPI" ;;
    go) printf '%s' "$REPO_GO" ;; github) printf '%s' "$REPO_GITHUB" ;; godl) printf '%s' "$REPO_GODL" ;;
  esac
}

# apt credentials for every apt-type source that uses the mirror (root-only file)
apt_auth_sync() {
  local s use=n
  for s in apt dockerapt grafanaapt nodesource; do is_mirror "$s" && use=y; done
  install -d -m 755 /etc/apt/auth.conf.d
  if [[ $use == y && -n $(apt_auth_render) ]]; then ( umask 077; apt_auth_render >"$APT_AUTH_FILE" ); else rm -f "$APT_AUTH_FILE"; fi
}

# apt_repo <source> <name> <direct-base-url> <suite> <components> <key-url>
# A third-party apt repository, from its own server or the mirror (a proxy of that server).
apt_repo() {
  local s=$1 name=$2 base=$3 suite=$4 comps=$5 keyurl=$6 uri key tmp
  need_source "$s"
  key="/etc/apt/keyrings/server-setup-$name.gpg"
  if is_mirror "$s"; then uri="$(mirror_base)/repository/$(mirror_repo_of "$s")/${base#*://*/}"; uri=${uri%/}; else uri=${base%/}; fi
  install -d -m 755 /etc/apt/keyrings
  tmp=$(mktemp)
  fetch "$s" "$keyurl" "$tmp"
  if grep -q 'BEGIN PGP' "$tmp"; then gpg --batch --yes --dearmor -o "$key" "$tmp"; else install -m 644 "$tmp" "$key"; fi
  chmod 644 "$key"; rm -f "$tmp"
  printf '# Managed by server-setup (%s)\nTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
    "$(route_of "$s")" "$uri" "$suite" "$comps" "$key" >"/etc/apt/sources.list.d/server-setup-$name.sources"
  apt_auth_sync
  run "Refreshing package lists" apt_get update
}

# Language package managers: written system-wide, only when that source uses the mirror
render_client_mirrors() {
  local b; b=$(mirror_base)
  if [[ $(route_of npm) == mirror ]]; then
    printf '# Managed by server-setup: npm through the mirror\nregistry=%s/repository/%s/\n' "$b" "$REPO_NPM" >/etc/npmrc
  elif [[ -f /etc/npmrc ]] && grep -q 'server-setup' /etc/npmrc; then rm -f /etc/npmrc; fi
  if [[ $(route_of pypi) == mirror ]]; then
    printf '# Managed by server-setup: PyPI through the mirror\n[global]\nindex-url = %s/repository/%s/simple\n' "$b" "$REPO_PYPI" >/etc/pip.conf
  elif [[ -f /etc/pip.conf ]] && grep -q 'server-setup' /etc/pip.conf; then rm -f /etc/pip.conf; fi
  {
    printf '# Managed by server-setup: download sources for language tools\n'
    if [[ $(route_of pypi) == mirror ]]; then printf 'export UV_DEFAULT_INDEX=%s/repository/%s/simple\nexport PIP_INDEX_URL=%s/repository/%s/simple\n' "$b" "$REPO_PYPI" "$b" "$REPO_PYPI"; fi
    if [[ $(route_of npm) == mirror ]]; then printf 'export NPM_CONFIG_REGISTRY=%s/repository/%s/\n' "$b" "$REPO_NPM"; fi
    if [[ $(route_of go) == mirror ]]; then
      # the checksum database (sum.golang.org) is not proxied: modules are trusted from the mirror
      printf 'export GOPROXY=%s/repository/%s/\nexport GOSUMDB=off\n' "$b" "$REPO_GO"
    fi
  } >/etc/profile.d/90-server-setup-sources.sh
  if [[ -n $MIRROR_USER && -n $(secret_get mirror-password || true) ]] && \
     [[ $(route_of npm) == mirror || $(route_of pypi) == mirror || $(route_of go) == mirror ]]; then
    note "Mirror login is NOT written into npm/pip/Go settings (they are readable by every user). Allow anonymous read on those Nexus proxies, or each app user logs in itself."
  fi
}

# ----------------------------------------------------------------------------
# Docker: Docker's own packages, logs capped, published ports filtered by ufw
# ----------------------------------------------------------------------------
render_daemon_json() { # render_daemon_json [swarm:y|n]
  local mirrors=""
  if [[ $(route_of dockerhub) == mirror ]]; then mirrors=$(printf '  "registry-mirrors": ["https://%s"],\n' "$MIRROR_DOCKER_REGISTRY"); fi
  cat <<EOF
{
${mirrors}  "cgroup-parent": "apps.slice",
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  $([[ ${1:-n} == y ]] && echo '"live-restore": false' || echo '"live-restore": true'),
  "userland-proxy": false,
  "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 1048576 } }
}
EOF
}

# Docker publishes ports with its own iptables rules, past ufw. These rules (in DOCKER-USER)
# let containers talk out and to each other, and let in from outside only the HOST ports that
# `server-setup firewall allow` opened - everything else is dropped. Docker has already
# rewritten the destination to the container's port when these rules run, so they match the
# port the client originally asked for (conntrack --ctorigdstport): "-p 8080:80" is reachable
# only if 8080 is open, whatever port the container listens on inside.
render_ufw_docker() {
  local spec src
  cat <<'EOF'
# BEGIN server-setup docker
*filter
:server-setup-docker-deny - [0:0]
:DOCKER-USER - [0:0]
-F DOCKER-USER
-F server-setup-docker-deny
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -i docker_gwbridge -j RETURN
EOF
  for spec in $OPEN_PORTS; do
    [[ $spec == */* ]] || spec="$spec/tcp"
    printf -- '-A DOCKER-USER -p %s -m conntrack --ctorigdstport %s -j RETURN\n' "${spec#*/}" "${spec%/*}"
  done
  if [[ ${MONITOR-} == hub ]]; then
    if [[ -n ${MONITOR_ALLOW-} ]]; then
      for src in $MONITOR_ALLOW; do printf -- '-A DOCKER-USER -s %s -p tcp -m conntrack --ctorigdstport %s -j RETURN\n' "$src" "$HUB_PORT"; done
    else
      printf -- '-A DOCKER-USER -p tcp -m conntrack --ctorigdstport %s -j RETURN\n' "$HUB_PORT"
    fi
  fi
  cat <<'EOF'
-A DOCKER-USER -m conntrack --ctstate NEW -j server-setup-docker-deny
-A DOCKER-USER -j RETURN
-A server-setup-docker-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A server-setup-docker-deny -j DROP
COMMIT
# END server-setup docker
EOF
}
apply_ufw_docker() {
  local f=/etc/ufw/after.rules tmp
  [[ -f $f ]] || return 0
  backup_file "$f"
  tmp=$(mktemp)
  awk '/^# BEGIN server-setup docker$/ {skip = 1} !skip {print} /^# END server-setup docker$/ {skip = 0}' "$f" >"$tmp"
  render_ufw_docker >>"$tmp"
  install -m 640 "$tmp" "$f"; rm -f "$tmp"
  ufw reload >>"$LOG_FILE" 2>&1 || die "ufw did not accept the Docker rules (see $LOG_FILE)."
}

# docker_restart - restart Docker and bring back every container that should be running.
# (Tested: switching live-restore off for Swarm stopped all containers, and their
# 'unless-stopped' policy did not start them again.)
docker_restart() {
  local c pol
  systemctl restart docker
  sleep 3
  for c in $(docker ps -aq --filter status=exited --filter status=created 2>/dev/null); do
    pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
    if [[ $pol == always || $pol == unless-stopped ]]; then docker start "$c" >>"$LOG_FILE" 2>&1 || warn "Container $c did not start again after the Docker restart."; fi
  done
  if [[ -f $MON_DIR/compose.yaml ]] && mon_stack_here; then
    docker compose -f "$MON_DIR/compose.yaml" up -d >>"$LOG_FILE" 2>&1 || warn "The monitoring stack did not come back after the Docker restart."
  fi
}

install_docker() { # install_docker [swarm:y|n]
  local p
  if ! os_installed docker-ce; then
    apt_repo dockerapt docker "https://download.docker.com/linux/$OS_ID" "$OS_CODENAME" stable "https://download.docker.com/linux/$OS_ID/gpg"
    # Ubuntu's own docker.io would conflict
    for p in docker.io docker-doc docker-compose podman-docker containerd runc; do os_installed "$p" && run "Removing $p" apt_get remove "$p"; done
    os_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  need_source dockerhub
  install -d /etc/docker
  render_daemon_json "${1:-n}" >/etc/docker/daemon.json.new
  if ! cmp -s /etc/docker/daemon.json.new /etc/docker/daemon.json 2>/dev/null; then
    mv -f /etc/docker/daemon.json.new /etc/docker/daemon.json
    systemctl enable docker >>"$LOG_FILE" 2>&1; docker_restart
  else rm -f /etc/docker/daemon.json.new; fi
  docker_login_mirror
  apply_ufw_docker
  if [[ -n $ADMIN_USER ]] && id "$ADMIN_USER" &>/dev/null; then usermod -aG docker "$ADMIN_USER"; fi
  note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null): logs capped (20 MB x 5 per container), images $(route_of dockerhub)$([[ $(route_of dockerhub) == mirror ]] && echo " via $MIRROR_DOCKER_REGISTRY"); published ports pass only what 'server-setup firewall allow' opens."
  note "  The docker group is root-equivalent: only $ADMIN_USER is in it."
}
docker_login_mirror() {
  [[ $(route_of dockerhub) == mirror ]] || return 0
  local pw; pw=$(secret_get mirror-password || true)
  if [[ -n $MIRROR_USER && -n $pw ]]; then
    printf '%s' "$pw" | docker login --username "$MIRROR_USER" --password-stdin "$MIRROR_DOCKER_REGISTRY" >>"$LOG_FILE" 2>&1 \
      || warn "docker login to $MIRROR_DOCKER_REGISTRY failed (see $LOG_FILE)."
    note "Docker: Docker Hub goes through $MIRROR_DOCKER_REGISTRY. 'registry-mirrors' can't send a login: if the Nexus proxy needs one, pull as $MIRROR_DOCKER_REGISTRY/library/<image> (logged in), or allow anonymous pull on it."
  fi
}

# ----------------------------------------------------------------------------
# Tools catalog (app role): nothing is installed unless asked for
# ----------------------------------------------------------------------------
readonly TOOL_CATALOG="docker|Docker CE + compose + buildx (Docker's apt repo)
node|Node.js LTS from NodeSource (--version 22|24...)
python|Python 3 + venv + pip + pipx + uv
go|Go toolchain in /usr/local/go (--version 1.x.y)
nginx|nginx web server / reverse proxy
caddy|Caddy web server with automatic HTTPS
certbot|Let's Encrypt certificates (certbot + nginx plugin)
postgresql|PostgreSQL server (the OS's version)
postgresql-client|PostgreSQL client tools only
redis|Redis server (localhost only)
restic|restic backups (then: server-setup backup init)
apt:<pkg>|any package from the OS repositories
url:<https://...tar.gz>|a tarball, unpacked into --prefix (default /opt/<name>)"

TOOL_VERSION="" TOOL_PREFIX="" TOOL_SHA256=""
cmd_tools() {
  local action=${1-} names=() a; if (( $# > 0 )); then shift; fi
  TOOL_VERSION="" TOOL_PREFIX="" TOOL_SHA256=""
  while (( $# > 0 )); do
    case $1 in
      --version) TOOL_VERSION=${2-}; shift ;; --version=*) TOOL_VERSION=${1#*=} ;;
      --prefix) TOOL_PREFIX=${2-}; shift ;; --prefix=*) TOOL_PREFIX=${1#*=} ;;
      --sha256) TOOL_SHA256=${2-}; shift ;; --sha256=*) TOOL_SHA256=${1#*=} ;;
      -*) die "Unknown option $1" ;;
      *) names+=("$1") ;;
    esac
    shift
  done
  case $action in
    list|"") tools_list ;;
    install)
      (( ${#names[@]} > 0 )) || die "usage: server-setup tools install <tool>... [--version V] [--prefix DIR]   (list: server-setup tools list)"
      local failed=()
      for a in "${names[@]}"; do ( install_tool "$a" ) || failed+=("$a"); done
      (( ${#failed[@]} == 0 )) || die "Not installed: ${failed[*]} (details above and in $LOG_FILE)"
      ok "Installed: ${names[*]}" ;;
    remove)
      (( ${#names[@]} > 0 )) || die "usage: server-setup tools remove <tool>..."
      for a in "${names[@]}"; do remove_tool "$a"; done ;;
    *) die "usage: server-setup tools list | install <tool>... [--version V] [--prefix DIR] [--sha256 H] | remove <tool>..." ;;
  esac
}
tools_list() {
  local name desc state
  printf '    %-26s %-10s %s\n' TOOL STATE ""
  while IFS='|' read -r name desc; do
    state=-; if tool_installed "$name"; then state=installed; fi
    printf '    %-26s %-10s %s\n' "$name" "$state" "$desc"
  done <<<"$TOOL_CATALOG"
  [[ -z $TOOLS ]] || info "Installed with server-setup: $TOOLS"
}
tool_installed() {
  case $1 in
    docker) os_installed docker-ce ;; node) command -v node >/dev/null ;; python) command -v uv >/dev/null || os_installed python3-venv ;;
    go) [[ -x /usr/local/go/bin/go ]] ;; postgresql) os_installed postgresql ;; redis) os_installed redis-server ;;
    *:*) return 1 ;; *) os_installed "$1" ;;
  esac
}
tool_record() { TOOLS=$(uniq_words $TOOLS "$1"); save_config; }

install_tool() {
  local t=$1
  case $t in
    docker) install_docker n ;;
    node)
      local major=${TOOL_VERSION:-${NODE_MAJOR:-24}}; major=${major%%.*}
      [[ $major =~ ^[0-9]{2}$ ]] || die "Node --version must be a major version such as 22 or 24."
      apt_repo nodesource nodesource "https://deb.nodesource.com/node_$major.x" nodistro main https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
      os_install nodejs
      NODE_MAJOR=$major
      need_source npm; render_client_mirrors
      note "Node.js $(node --version 2>/dev/null) (NodeSource, $(route_of nodesource)); npm registry: $(route_of npm)." ;;
    python)
      os_install python3 python3-venv python3-pip pipx
      need_source pypi; render_client_mirrors
      if ! command -v uv >/dev/null; then
        # uv for everyone, installed once into /usr/local (from PyPI - direct or the mirror)
        local idx=()
        if is_mirror pypi; then idx=(--index-url "$(mirror_base)/repository/$REPO_PYPI/simple"); fi
        run "Installing uv" env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install uv --pip-args="${idx[*]}"
      fi
      note "Python $(python3 --version 2>/dev/null | awk '{print $2}'), pipx, uv $(uv --version 2>/dev/null | awk '{print $2}'); PyPI: $(route_of pypi)." ;;
    go) install_go ;;
    nginx)
      os_install nginx
      printf '# Managed by server-setup\nserver_tokens off;\n' >/etc/nginx/conf.d/00-server-setup.conf
      nginx -t >>"$LOG_FILE" 2>&1 && systemctl reload nginx
      note "nginx $(nginx -v 2>&1 | awk -F/ '{print $2}'): version hidden. Open the ports: server-setup firewall allow 80 443" ;;
    caddy)
      pkg_available caddy || die "Caddy is not in this OS's repositories ($OS_ID $OS_VERSION)."
      os_install caddy; note "Caddy $(caddy version 2>/dev/null | awk '{print $1}'). Open the ports: server-setup firewall allow 80 443" ;;
    certbot)
      os_install certbot
      if os_installed nginx; then os_install python3-certbot-nginx; fi
      note "certbot: certificates renew by themselves (certbot.timer). Needs internet to Let's Encrypt - not usable inside an internal network." ;;
    postgresql)
      os_install postgresql
      note "PostgreSQL $(psql --version 2>/dev/null | awk '{print $3}'): listens on localhost only. Reach it from your PC with: ssh -L 5432:127.0.0.1:5432 <server>" ;;
    postgresql-client) os_install postgresql-client ;;
    redis)
      os_install redis-server
      sed -i -E 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
      grep -qE '^bind 127\.0\.0\.1' /etc/redis/redis.conf || note "redis: check 'bind' in /etc/redis/redis.conf - it should stay on localhost."
      systemctl restart redis-server
      note "Redis $(redis-server --version 2>/dev/null | grep -oE 'v=[0-9.]+' | cut -d= -f2): localhost only." ;;
    restic) os_install restic; note "restic $(restic version 2>/dev/null | awk '{print $2}'). Set up backups: server-setup backup init" ;;
    apt:*)
      local p=${t#apt:}
      [[ $p =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || die "'$p' is not a package name."
      pkg_available "$p" || die "No package '$p' in the configured repositories."
      os_install "$p" ;;
    url:*) install_tarball "${t#url:}" ;;
    *) die "Unknown tool '$t' (see: server-setup tools list)." ;;
  esac
  tool_record "$t"
}
remove_tool() {
  local t=$1
  case $t in
    docker) die "Removing Docker deletes every container's runtime - do it by hand if you mean it: apt purge docker-ce docker-ce-cli containerd.io" ;;
    node) run "Removing Node.js" apt_get purge nodejs; rm -f /etc/apt/sources.list.d/server-setup-nodesource.sources ;;
    go) rm -rf /usr/local/go; rm -f /etc/profile.d/90-server-setup-go.sh ;;
    python) run "Removing uv" env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx uninstall uv || true ;;
    redis) run "Removing Redis" apt_get purge redis-server ;;
    postgresql) die "Removing PostgreSQL can delete databases - do it by hand: apt purge postgresql" ;;
    apt:*) run "Removing ${t#apt:}" apt_get purge "${t#apt:}" ;;
    url:*) die "Remove the unpacked directory by hand." ;;
    *) run "Removing $t" apt_get purge "$t" ;;
  esac
  TOOLS=$(printf '%s\n' $TOOLS | awk -v x="$t" '$0 != x' | xargs); save_config
  ok "Removed $t."
}

install_go() {
  local ver=${TOOL_VERSION-} arch file tmp want
  arch=$OS_ARCH; [[ $arch == amd64 || $arch == arm64 ]] || die "No Go build for $arch."
  if [[ -z $ver ]]; then
    ver=$(curl -fsS -m 15 'https://go.dev/VERSION?m=text' 2>/dev/null | head -n1 || true)
    [[ -n $ver ]] || die "go.dev is not reachable - give the version: server-setup tools install go --version 1.25.4"
  fi
  ver=go${ver#go}
  [[ $ver =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "'$ver' is not a Go version."
  if [[ -x /usr/local/go/bin/go && $(/usr/local/go/bin/go version | awk '{print $3}') == "$ver" ]]; then note "Go $ver already installed."; return 0; fi
  file="$ver.linux-$arch.tar.gz"
  tmp=$(mktemp -d)
  fetch godl "https://dl.google.com/go/$file" "$tmp/$file"
  fetch godl "https://dl.google.com/go/$file.sha256" "$tmp/sum"
  want=$(tr -d ' \n' <"$tmp/sum")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "No checksum published for $file."
  printf '%s  %s\n' "$want" "$tmp/$file" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "Checksum mismatch for $file - not installed."; }
  rm -rf /usr/local/go; tar -C /usr/local -xzf "$tmp/$file"; rm -rf "$tmp"
  printf '# Managed by server-setup\ncase ":$PATH:" in *:/usr/local/go/bin:*) ;; *) PATH="/usr/local/go/bin:$PATH" ;; esac\n' >/etc/profile.d/90-server-setup-go.sh
  need_source go; render_client_mirrors
  note "Go $ver in /usr/local/go (checksum verified; download $(route_of godl), modules $(route_of go))."
}

install_tarball() { # a release tarball: github.com URLs go through the GitHub source's route
  local url=$1 name prefix tmp file
  [[ $url =~ ^https://[A-Za-z0-9.-]+/[^[:space:]]+\.(tar\.gz|tgz|tar\.xz|tar\.zst|zip)$ ]] || die "Give an https URL of a .tar.gz/.tgz/.tar.xz/.zip file."
  file=${url##*/}; name=${file%%[-_.][0-9v]*}; name=${name%%.*}
  prefix=${TOOL_PREFIX:-/opt/$name}
  [[ $prefix == /* && $prefix != / && $prefix != *..* ]] || die "--prefix must be an absolute directory."
  tmp=$(mktemp -d)
  if [[ $url == https://github.com/* || $url == https://objects.githubusercontent.com/* ]]; then fetch github "$url" "$tmp/$file"
  else
    printf '\n$ download %s\n' "$url" >>"$LOG_FILE"
    curl -fsSL --retry 2 -o "$tmp/$file" "$url" 2>>"$LOG_FILE" || die "Download failed: $url"
  fi
  if [[ -n $TOOL_SHA256 ]]; then printf '%s  %s\n' "$TOOL_SHA256" "$tmp/$file" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "Checksum mismatch."; }
  else warn "No --sha256 given: $file is not verified."; fi
  install -d -m 755 "$prefix"
  case $file in
    *.zip) command -v unzip >/dev/null || os_install unzip; unzip -oq "$tmp/$file" -d "$prefix" ;;
    *) tar -C "$prefix" -xf "$tmp/$file" ;;
  esac
  rm -rf "$tmp"
  note "Unpacked $file into $prefix."
}

# ----------------------------------------------------------------------------
# Backups (restic): any restic repository - a local disk, SFTP, S3 / MinIO
# ----------------------------------------------------------------------------
cmd_backup() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  case $action in
    init)
      need_tty
      command -v restic >/dev/null || install_tool restic
      prompt BACKUP_REPO "restic repository (e.g. /mnt/backup, sftp:user@host:/backups, s3:https://minio.local/bucket)" "${BACKUP_REPO:-}" accept_any
      prompt BACKUP_PATHS "Paths to back up (space-separated)" "${BACKUP_PATHS:-/etc /srv /var/lib/postgresql /root}" accept_any
      prompt BACKUP_TIME "Daily backup time (HH:MM)" "${BACKUP_TIME:-02:30}" valid_time
      prompt BACKUP_KEEP "Keep (restic forget policy)" "${BACKUP_KEEP:---keep-daily 7 --keep-weekly 5 --keep-monthly 12}" accept_any
      local pw env=""
      pw=$(secret_get restic-password || true)
      if [[ -z $pw ]]; then pw=$(gen_password 32); secret_set restic-password "$pw"; note_cred root "restic password" "$pw"; fi
      if [[ $BACKUP_REPO == s3:* ]]; then
        local ak sk
        prompt ak "S3 access key" "" accept_any
        printf '%s?%s S3 secret key: ' "$C_C" "$C_0" >/dev/tty; IFS= read -rs sk </dev/tty; printf '\n' >/dev/tty
        env=$(printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$ak" "$sk")
      fi
      ( umask 077; printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD_FILE=%s\n%s\n' "$BACKUP_REPO" "$SECRETS_DIR/restic-password" "$env" >"$SECRETS_DIR/restic.env" )
      save_config
      backup_units
      if ! backup_restic cat config >/dev/null 2>&1; then run "Creating the restic repository" backup_restic init; fi
      ok "Backups: daily at $BACKUP_TIME to $BACKUP_REPO (paths: $BACKUP_PATHS)."
      warn "Keep the restic password somewhere safe outside this server - without it the backups can't be read: $CRED_DIR/root.txt" ;;
    run) run "Backing up" systemctl start --wait server-setup-backup.service; backup_restic snapshots --latest 3 ;;
    status|"") [[ -n $BACKUP_REPO ]] || { info "No backups configured: server-setup backup init"; return 0; }
      info "Repository: $BACKUP_REPO   paths: $BACKUP_PATHS   daily at $BACKUP_TIME"
      systemctl list-timers server-setup-backup.timer --no-pager 2>/dev/null | sed 's/^/    /' | head -3
      backup_restic snapshots --latest 5 2>&1 | sed 's/^/    /' ;;
    list) backup_restic snapshots ;;
    *) die "usage: server-setup backup init|run|status|list   (restore: restic with the env in $SECRETS_DIR/restic.env)" ;;
  esac
}
backup_restic() { ( set -a; . "$SECRETS_DIR/restic.env"; set +a; restic "$@" ); }
backup_units() {
  install -d -m 755 "$LIB_DIR"
  cat >"$LIB_DIR/backup" <<EOF
#!/bin/bash
# Managed by server-setup: daily restic backup, then forget/prune by the policy
set -euo pipefail
set -a; . $SECRETS_DIR/restic.env; set +a
restic backup --one-file-system --exclude-caches $BACKUP_PATHS
restic forget --prune $BACKUP_KEEP
restic check --read-data-subset=1%
EOF
  chmod 700 "$LIB_DIR/backup"
  cat >/etc/systemd/system/server-setup-backup.service <<EOF
# Managed by server-setup
[Unit]
Description=Backup with restic (server-setup)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=$LIB_DIR/backup
EOF
  cat >/etc/systemd/system/server-setup-backup.timer <<EOF
# Managed by server-setup
[Unit]
Description=Daily backup (server-setup)
[Timer]
OnCalendar=*-*-* $BACKUP_TIME:00
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now server-setup-backup.timer >>"$LOG_FILE" 2>&1
}

# ----------------------------------------------------------------------------
# App services: every app runs as its own system user, in /srv/<name>, under systemd
# with a hardened sandbox; logs go to the journal (capped).
# ----------------------------------------------------------------------------
render_app_unit() { # render_app_unit <name> <exec> <dir> <port>
  cat <<EOF
# Managed by server-setup (server-setup apps ...)
[Unit]
Description=App $1 (server-setup)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Slice=apps.slice
User=$1
Group=$1
WorkingDirectory=$3
EnvironmentFile=-/etc/server-setup/apps/$1.env
ExecStart=$2
Restart=always
RestartSec=3
LimitNOFILE=65536
# sandbox: the app sees the system read-only, writes only its own directory
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$3
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
$([[ ${4:-0} -gt 0 && ${4:-0} -lt 1024 ]] && printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\n')
[Install]
WantedBy=multi-user.target
EOF
}
cmd_apps() {
  local action=${1-} name="" exec="" port=0 a; if (( $# > 0 )); then shift; fi
  while (( $# > 0 )); do
    case $1 in --exec) exec=${2-}; shift ;; --port) port=${2-0}; shift ;; -*) die "Unknown option $1" ;; *) name=$1 ;; esac
    shift
  done
  case $action in
    list|"")
      systemctl list-units --all --plain --no-legend 'app-*.service' 2>/dev/null | awk '{printf "    %-30s %s %s\n", $1, $3, $4}'
      [[ -n $(systemctl list-units --all --plain --no-legend 'app-*.service' 2>/dev/null) ]] || info "No apps yet: server-setup apps add <name> --exec \"<command>\"" ;;
    add)
      [[ $name =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "usage: server-setup apps add <name> --exec \"/srv/<name>/bin/app --flag\" [--port N]"
      [[ -n $exec && $exec == /* ]] || die "--exec needs the full command, starting with an absolute path."
      [[ $port =~ ^[0-9]{1,5}$ ]] || die "--port must be a number."
      id "$name" &>/dev/null || useradd --system --home-dir "/srv/$name" --shell /usr/sbin/nologin --user-group "$name"
      install -d -m 750 -o "$name" -g "$name" "/srv/$name"
      install -d -m 750 /etc/server-setup/apps
      [[ -f /etc/server-setup/apps/$name.env ]] || install -m 640 -g "$name" /dev/null "/etc/server-setup/apps/$name.env"
      render_app_unit "$name" "$exec" "/srv/$name" "$port" >"/etc/systemd/system/app-$name.service"
      systemctl daemon-reload; systemctl enable "app-$name.service" >>"$LOG_FILE" 2>&1
      ok "App $name: user $name, files in /srv/$name, settings (KEY=value) in /etc/server-setup/apps/$name.env"
      info "Start it: sudo systemctl start app-$name   logs: journalctl -u app-$name -f"
 ;;
    remove)
      [[ -n $name && -f /etc/systemd/system/app-$name.service ]] || die "No app '$name'."
      systemctl disable --now "app-$name.service" >>"$LOG_FILE" 2>&1 || true
      rm -f "/etc/systemd/system/app-$name.service"; systemctl daemon-reload
      ok "App $name stopped and removed. Its files stay in /srv/$name and its user stays (userdel $name to remove)." ;;
    *) die "usage: server-setup apps list | add <name> --exec CMD [--port N] | remove <name>" ;;
  esac
}

# ----------------------------------------------------------------------------
# Monitoring (monitor role). One design for every size:
#   agent  - Grafana Alloy on every server: host + container metrics, journal + container
#            logs, pushed (remote_write / Loki push) - works through NAT and firewalls.
#   none     no monitoring
#   external the agent pushes to a Prometheus-compatible + Loki you already run
#   local    the whole stack on this server (a startup's single server)
#   hub      the stack here, and other servers push to it (server-setup monitor join)
#   Stack: VictoriaMetrics, Loki, Grafana, vmalert + Alertmanager, Uptime Kuma (compose).
#   Grow: server-setup monitor move-to <hub> - re-points the agent and copies the history.
# ----------------------------------------------------------------------------
readonly MON_DIR="/opt/server-setup/monitoring"
readonly TEXTFILE_DIR="/var/lib/server-setup/textfile"
readonly HUB_PORT=8430

mon_defaults() {
  : "${MONITOR:=none}" "${MONITOR_RETENTION:=90d}" "${LOG_RETENTION:=30d}" "${MONITOR_USER:=agent}"
  : "${IMG_VM:=victoriametrics/victoria-metrics:v1.157.0}" "${IMG_VMALERT:=victoriametrics/vmalert:v1.157.0}"
  : "${IMG_LOKI:=grafana/loki:3.7.10}"
  : "${IMG_GRAFANA:=grafana/grafana:13.3.1}" "${IMG_ALERTMANAGER:=prom/alertmanager:v0.35.0}"
  : "${IMG_KUMA:=louislam/uptime-kuma:2.5.12}" "${IMG_CADDY:=caddy:2.11.9}"
}
mon_stack_here() { [[ $MONITOR == local || $MONITOR == hub ]]; }
mon_metrics_url() {
  case $MONITOR in
    local|hub) printf 'http://127.0.0.1:8428/api/v1/write' ;;
    external) printf '%s' "$MONITOR_METRICS_URL" ;;
  esac
}
mon_logs_url() {
  case $MONITOR in
    local|hub) printf 'http://127.0.0.1:3100/loki/api/v1/push' ;;
    external) printf '%s' "$MONITOR_LOGS_URL" ;;
  esac
}

# ---- the agent -------------------------------------------------------------
render_alloy() { # render_alloy <docker:y|n> <auth:y|n> <insecure-tls:y|n>
  local host docker=$1 auth=$2 insecure=$3 ba="" tls=""
  host=$(hostname -s)
  if [[ $auth == y ]]; then ba=$(printf '    basic_auth {\n      username      = "%s"\n      password_file = "/etc/alloy/monitor-password"\n    }\n' "$MONITOR_USER"); fi
  # a hub's own certificate (Caddy's internal CA): encrypted, but not verified against a public CA
  if [[ $insecure == y ]]; then tls=$(printf '    tls_config {\n      insecure_skip_verify = true\n    }\n'); fi
  cat <<EOF
// Managed by server-setup - rewritten by: server-setup monitor apply
logging {
  level = "warn"
}

// ---- host metrics (node exporter) + server-setup's own facts (reboot needed, updates)
prometheus.exporter.unix "host" {
  enable_collectors = ["systemd"]
  textfile {
    directory = "$TEXTFILE_DIR"
  }
}

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  job_name        = "node"
  scrape_interval = "30s"
}
EOF
  if [[ $docker == y ]]; then cat <<EOF

// ---- container metrics (cAdvisor) and container logs
prometheus.exporter.cadvisor "containers" {
  docker_host      = "unix:///var/run/docker.sock"
  docker_only      = true
  storage_duration = "5m"
}

prometheus.scrape "containers" {
  targets         = prometheus.exporter.cadvisor.containers.targets
  forward_to      = [prometheus.relabel.instance.receiver]
  job_name        = "containers"
  scrape_interval = "30s"
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers" {
  targets = discovery.docker.containers.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}

loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers.output
  forward_to = [loki.write.out.receiver]
  labels     = { host = "$host", job = "docker" }
}
EOF
  fi
  cat <<EOF

// ---- every series carries this server's name
prometheus.relabel "instance" {
  forward_to = [prometheus.remote_write.out.receiver]
  rule {
    target_label = "instance"
    replacement  = "$host"
  }
}

prometheus.remote_write "out" {
  endpoint {
    url = "$(mon_metrics_url)"
$ba
$tls
  }
}

// ---- system journal
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "journal" {
  forward_to    = [loki.write.out.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels        = { host = "$host", job = "journal" }
  max_age       = "12h"
}

loki.write "out" {
  endpoint {
    url = "$(mon_logs_url)"
$ba
$tls
  }
}
EOF
}

render_textfile_script() {
  cat <<EOF
#!/bin/bash
# Managed by server-setup: facts for the monitoring agent (every 15 min)
set -u
out=$TEXTFILE_DIR/server_setup.prom
reboot=0
if [[ -f /var/run/reboot-required ]]; then reboot=1
elif command -v needrestart >/dev/null && [[ \$(needrestart -b -k 2>/dev/null | awk -F': ' '/NEEDRESTART-KSTA/ {print \$2}') =~ ^[23]\$ ]]; then reboot=1; fi
sec=\$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst .*-security' || true)
{
  echo '# HELP server_setup_reboot_required 1 when the server needs a reboot to finish updates.'
  echo '# TYPE server_setup_reboot_required gauge'
  echo "server_setup_reboot_required \$reboot"
  echo '# HELP server_setup_security_updates Security updates waiting to be installed.'
  echo '# TYPE server_setup_security_updates gauge'
  echo "server_setup_security_updates \${sec:-0}"
} >"\$out.tmp" && mv -f "\$out.tmp" "\$out"
EOF
}

install_agent() {
  local docker=n auth=n insecure=n
  apt_repo grafanaapt grafana https://apt.grafana.com stable main https://apt.grafana.com/gpg.key
  os_install alloy
  install -d -m 755 "$TEXTFILE_DIR"
  render_textfile_script >"$LIB_DIR/textfile"; chmod 755 "$LIB_DIR/textfile"
  cat >/etc/systemd/system/server-setup-textfile.service <<EOF
# Managed by server-setup
[Unit]
Description=Facts for the monitoring agent (server-setup)
[Service]
Type=oneshot
Nice=10
ExecStart=$LIB_DIR/textfile
EOF
  cat >/etc/systemd/system/server-setup-textfile.timer <<'EOF'
# Managed by server-setup
[Unit]
Description=Facts for the monitoring agent, every 15 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload; systemctl enable --now server-setup-textfile.timer >>"$LOG_FILE" 2>&1
  "$LIB_DIR/textfile" || true
  # what the agent may read: the journal; Docker's socket (= root on this host) only for containers
  usermod -aG systemd-journal,adm alloy 2>/dev/null || true
  # Container stats (cAdvisor) need root to read Docker's state - tested: as the 'alloy' user
  # only the host's root cgroup is seen. The docker socket it needs is root-equivalent anyway,
  # so with Docker the agent runs as root; without Docker it stays an unprivileged user.
  install -d /etc/systemd/system/alloy.service.d
  if os_installed docker-ce; then
    docker=y
    printf '# Managed by server-setup: container metrics need root (see install_agent)\n[Service]\nUser=root\nGroup=root\n' \
      >/etc/systemd/system/alloy.service.d/90-server-setup.conf
  else
    rm -f /etc/systemd/system/alloy.service.d/90-server-setup.conf
  fi
  systemctl daemon-reload
  local pw; pw=$(secret_get monitor-password || true)
  # local/hub push to this server's own stack on 127.0.0.1 (no login); external may need one
  if [[ $MONITOR == external && -n $pw && -n $MONITOR_USER ]]; then auth=y; fi
  if [[ $auth == y ]]; then ( umask 077; printf '%s' "$pw" >/etc/alloy/monitor-password ); chown root:alloy /etc/alloy/monitor-password; chmod 640 /etc/alloy/monitor-password; fi
  [[ ${MONITOR_INSECURE_TLS:-n} == y ]] && insecure=y
  render_alloy "$docker" "$auth" "$insecure" >/etc/alloy/config.alloy
  # no usage reporting to Grafana Labs
  if [[ -f /etc/default/alloy ]] && ! grep -q 'disable-reporting' /etc/default/alloy; then
    sed -i -E 's/^CUSTOM_ARGS="?([^"]*)"?/CUSTOM_ARGS="\1 --disable-reporting"/' /etc/default/alloy
  fi
  systemctl enable alloy >>"$LOG_FILE" 2>&1; systemctl restart alloy
  sleep 3
  systemctl is-active --quiet alloy || { journalctl -u alloy -n 20 --no-pager >&2; die "The monitoring agent (alloy) did not start - see above."; }
  note "Monitoring agent: Grafana Alloy -> $(mon_metrics_url) (metrics) and $(mon_logs_url) (logs)$([[ $docker == y ]] && echo ', containers included')."
  if [[ $docker == y ]]; then note "  With Docker the agent runs as root: container stats need it (and Docker's socket is root-equivalent anyway)."; fi
}

# ---- the stack ---------------------------------------------------------------
render_compose() { # render_compose <hub:y|n>
  local hub=$1
  cat <<EOF
# Managed by server-setup - rewritten by: server-setup monitor apply
name: monitoring
services:
  victoriametrics:
    image: $IMG_VM
    command: ["-storageDataPath=/storage", "-retentionPeriod=$MONITOR_RETENTION", "-httpListenAddr=:8428", "-selfScrapeInterval=30s"]
    volumes: ["vmdata:/storage"]
    ports: ["127.0.0.1:8428:8428"]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
  vmalert:
    image: $IMG_VMALERT
    command: ["-rule=/etc/alerts/*.yml", "-datasource.url=http://victoriametrics:8428", "-notifier.url=http://alertmanager:9093",
              "-remoteWrite.url=http://victoriametrics:8428", "-remoteRead.url=http://victoriametrics:8428", "-evaluationInterval=1m"]
    volumes: ["./alerts:/etc/alerts:ro"]
    depends_on: [victoriametrics, alertmanager]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
  alertmanager:
    image: $IMG_ALERTMANAGER
    command: ["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager"]
    volumes: ["./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro", "amdata:/alertmanager"]
    ports: ["127.0.0.1:9093:9093"]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
  loki:
    image: $IMG_LOKI
    command: ["-config.file=/etc/loki/loki.yaml"]
    volumes: ["./loki.yaml:/etc/loki/loki.yaml:ro", "lokidata:/loki"]
    ports: ["127.0.0.1:3100:3100"]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
  grafana:
    image: $IMG_GRAFANA
    env_file: [./grafana.env]
    volumes: ["grafanadata:/var/lib/grafana", "./grafana/provisioning:/etc/grafana/provisioning:ro", "./grafana/dashboards:/var/lib/grafana/dashboards:ro"]
    ports: ["$([[ ${GRAFANA_PUBLIC:-n} == y ]] && echo '' || echo '127.0.0.1:')3000:3000"]
    depends_on: [victoriametrics, loki]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
  uptime-kuma:
    image: $IMG_KUMA
    volumes: ["kumadata:/app/data"]
    ports: ["127.0.0.1:3001:3001"]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
EOF
  if [[ $hub == y ]]; then cat <<EOF
  gateway:
    image: $IMG_CADDY
    volumes: ["./Caddyfile:/etc/caddy/Caddyfile:ro", "caddydata:/data"]
    ports: ["$HUB_PORT:$HUB_PORT"]
    depends_on: [victoriametrics, loki]
    restart: unless-stopped
    cgroup_parent: monitoring.slice
EOF
  fi
  cat <<EOF
volumes:
  vmdata: {}
  amdata: {}
  lokidata: {}
  grafanadata: {}
  kumadata: {}
$([[ $hub == y ]] && echo '  caddydata: {}')
EOF
}

render_loki() {
  cat <<EOF
# Managed by server-setup
auth_enabled: false
server:
  http_listen_port: 3100
  log_level: warn
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  retention_period: $LOG_RETENTION
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 16
  ingestion_burst_size_mb: 32
  allow_structured_metadata: true
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
analytics:
  reporting_enabled: false
EOF
}

render_alert_rules() {
  cat <<'EOF'
# Managed by server-setup: alerts for every server that pushes to this stack
groups:
  - name: server-setup
    rules:
      - alert: ServerSilent
        expr: lag(node_time_seconds[3d]) > 300
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.instance }} has sent no metrics for {{ $value | humanizeDuration }} (down, or its agent stopped)" }
      - alert: DiskAlmostFull
        expr: 100 * node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} < 10
        for: 10m
        labels: { severity: critical }
        annotations: { summary: "{{ $labels.instance }}: {{ $labels.mountpoint }} has only {{ $value | printf \"%.1f\" }}% free" }
      - alert: DiskFillsIn24h
        expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}[6h], 86400) < 0
        for: 30m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: {{ $labels.mountpoint }} will be full within a day at this rate" }
      - alert: MemoryLow
        expr: 100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 10
        for: 10m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: only {{ $value | printf \"%.1f\" }}% memory available" }
      - alert: SwapAlmostFull
        expr: node_memory_SwapTotal_bytes > 0 and (1 - node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes) > 0.8
        for: 15m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: swap is {{ $value | humanizePercentage }} full" }
      - alert: OOMKill
        expr: increase(node_vmstat_oom_kill[30m]) > 0
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: the kernel killed a process for lack of memory" }
      - alert: HighLoad
        expr: node_load15 / count by (instance) (node_cpu_seconds_total{mode="idle"}) > 2
        for: 30m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: load is {{ $value | printf \"%.1f\" }}x the CPU count for 30 min" }
      - alert: ServiceFailed
        expr: node_systemd_unit_state{state="failed"} == 1
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: {{ $labels.name }} has failed" }
      - alert: ClockNotSynced
        expr: node_timex_sync_status == 0 or abs(node_timex_offset_seconds) > 0.1
        for: 30m
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: the clock is not synchronized" }
      - alert: RebootNeeded
        expr: server_setup_reboot_required == 1
        for: 24h
        labels: { severity: info }
        annotations: { summary: "{{ $labels.instance }} needs a reboot to finish updates (for a day now)" }
      - alert: SecurityUpdatesWaiting
        expr: server_setup_security_updates > 0
        for: 48h
        labels: { severity: info }
        annotations: { summary: "{{ $labels.instance }}: {{ $value }} security updates waiting for 2 days (server-setup update)" }
      - alert: ContainerRestarting
        expr: changes(container_start_time_seconds{name!=""}[30m]) > 3
        labels: { severity: warning }
        annotations: { summary: "{{ $labels.instance }}: container {{ $labels.name }} restarted more than 3 times in 30 min" }
EOF
}

render_alertmanager() {
  local pw
  printf '# Managed by server-setup: where alerts go (server-setup monitor alerts)\n'
  printf 'route:\n  receiver: default\n  group_by: [alertname, instance]\n  group_wait: 30s\n  group_interval: 5m\n  repeat_interval: 6h\n'
  printf 'receivers:\n  - name: default\n'
  if [[ -n ${ALERT_TELEGRAM_CHAT-} ]]; then
    pw=$(secret_get telegram-token || true)
    printf '    telegram_configs:\n      - bot_token: "%s"\n        chat_id: %s\n        send_resolved: true\n' "$pw" "$ALERT_TELEGRAM_CHAT"
  fi
  if [[ -n ${ALERT_EMAIL_TO-} ]]; then
    pw=$(secret_get smtp-password || true)
    printf '    email_configs:\n      - to: "%s"\n        from: "%s"\n        smarthost: "%s"\n        auth_username: "%s"\n        auth_password: "%s"\n        send_resolved: true\n' \
      "$ALERT_EMAIL_TO" "$ALERT_EMAIL_FROM" "$ALERT_SMTP" "${ALERT_SMTP_USER-}" "$pw"
  fi
  if [[ -n ${ALERT_WEBHOOK-} ]]; then
    printf '    webhook_configs:\n      - url: "%s"\n        send_resolved: true\n' "$ALERT_WEBHOOK"
  fi
}

render_grafana_provisioning() { # writes the datasource and dashboard provisioning into <dir>
  local d=$1
  install -d -m 755 "$d/datasources" "$d/dashboards" "$d/plugins" "$d/alerting"   # the last two empty: Grafana expects them
  cat >"$d/datasources/server-setup.yaml" <<'EOF'
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    uid: vm
    type: prometheus
    access: proxy
    url: http://victoriametrics:8428
    isDefault: true
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
EOF
  cat >"$d/dashboards/server-setup.yaml" <<'EOF'
apiVersion: 1
providers:
  - name: server-setup
    folder: server-setup
    type: file
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
EOF
}

render_dashboard() { # one overview dashboard: every server, its containers and its logs
  python3 -I - <<'PYEOF'
import json
def ts(title, expr, unit, x, y, w=12, h=8, legend="{{instance}}"):
    return {"type": "timeseries", "title": title, "datasource": {"type": "prometheus", "uid": "vm"},
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
            "targets": [{"refId": "A", "expr": expr, "legendFormat": legend}]}
def stat(title, expr, unit, x, y, w=4, h=4, thresholds=None):
    p = {"type": "stat", "title": title, "datasource": {"type": "prometheus", "uid": "vm"},
         "gridPos": {"x": x, "y": y, "w": w, "h": h},
         "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
         "targets": [{"refId": "A", "expr": expr, "legendFormat": "{{instance}}"}]}
    if thresholds:
        p["fieldConfig"]["defaults"]["thresholds"] = {"mode": "absolute", "steps": thresholds}
    return p
I = 'instance=~"$instance"'
panels = [
  stat("Up for", f'time() - node_boot_time_seconds{{{I}}}', "s", 0, 0),
  stat("Reboot needed", f'server_setup_reboot_required{{{I}}}', "none", 4, 0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}]),
  stat("Security updates", f'server_setup_security_updates{{{I}}}', "none", 8, 0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1}]),
  stat("Failed services", f'sum by (instance) (node_systemd_unit_state{{{I},state="failed"}})', "none", 12, 0, thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
  stat("Disk used (fullest)", f'max by (instance) (100 - 100 * node_filesystem_avail_bytes{{{I},fstype!~"tmpfs|overlay|squashfs|ramfs"}} / node_filesystem_size_bytes{{{I},fstype!~"tmpfs|overlay|squashfs|ramfs"}})', "percent", 16, 0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]),
  stat("Memory used", f'100 - 100 * node_memory_MemAvailable_bytes{{{I}}} / node_memory_MemTotal_bytes{{{I}}}', "percent", 20, 0, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]),
  ts("CPU used", f'100 - 100 * avg by (instance) (rate(node_cpu_seconds_total{{{I},mode="idle"}}[2m]))', "percent", 0, 4),
  ts("Load (15 min) per CPU", f'node_load15{{{I}}} / count by (instance) (node_cpu_seconds_total{{{I},mode="idle"}})', "none", 12, 4),
  ts("Memory used", f'node_memory_MemTotal_bytes{{{I}}} - node_memory_MemAvailable_bytes{{{I}}}', "bytes", 0, 12),
  ts("Disk free", f'node_filesystem_avail_bytes{{{I},fstype!~"tmpfs|overlay|squashfs|ramfs"}}', "bytes", 12, 12, legend="{{instance}} {{mountpoint}}"),
  ts("Network in", f'sum by (instance) (rate(node_network_receive_bytes_total{{{I},device!~"lo|veth.*|docker.*|br-.*"}}[2m]))', "Bps", 0, 20),
  ts("Network out", f'sum by (instance) (rate(node_network_transmit_bytes_total{{{I},device!~"lo|veth.*|docker.*|br-.*"}}[2m]))', "Bps", 12, 20),
  ts("Disk I/O time", f'rate(node_disk_io_time_seconds_total{{{I}}}[2m])', "percentunit", 0, 28, legend="{{instance}} {{device}}"),
  ts("Containers: CPU", f'sum by (instance, name) (rate(container_cpu_usage_seconds_total{{{I},name!=""}}[2m]))', "none", 12, 28, legend="{{instance}} {{name}}"),
  ts("Containers: memory", f'sum by (instance, name) (container_memory_working_set_bytes{{{I},name!=""}})', "bytes", 0, 36, legend="{{instance}} {{name}}"),
  {"type": "logs", "title": "Logs (errors and warnings)", "datasource": {"type": "loki", "uid": "loki"},
   "gridPos": {"x": 12, "y": 36, "w": 12, "h": 16},
   "targets": [{"refId": "A", "expr": '{host=~"$instance"} |~ "(?i)(error|fail|warn|denied|panic)"'}],
   "options": {"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending"}},
]
for i, p in enumerate(panels, 1):
    p["id"] = i
dash = {"uid": "server-setup-overview", "title": "Servers (server-setup)", "schemaVersion": 39, "version": 1,
        "editable": False, "refresh": "1m", "time": {"from": "now-24h", "to": "now"},
        "tags": ["server-setup"],
        "templating": {"list": [{"name": "instance", "label": "Server", "type": "query",
            "datasource": {"type": "prometheus", "uid": "vm"},
            "query": {"query": "label_values(node_uname_info, instance)", "refId": "q"},
            "definition": "label_values(node_uname_info, instance)",
            "includeAll": True, "multi": True, "allValue": ".*", "refresh": 2,
            "current": {"text": "All", "value": "$__all"}}]},
        "panels": panels}
print(json.dumps(dash, indent=1))
PYEOF
}

render_caddyfile() { # the hub's gateway: TLS (Caddy's own CA) + one login for every agent
  local hash=$1
  cat <<EOF
# Managed by server-setup: agents push here (metrics, logs, history imports)
{
  admin off
  default_sni $MONITOR_HUB_ADDR
}
https://$MONITOR_HUB_ADDR:$HUB_PORT {
  tls internal
  basic_auth {
    $MONITOR_USER $hash
  }
  handle /api/v1/write {
    reverse_proxy victoriametrics:8428
  }
  handle /api/v1/import/native {
    reverse_proxy victoriametrics:8428
  }
  handle /loki/api/v1/push {
    reverse_proxy loki:3100
  }
  handle {
    respond 404
  }
}
EOF
}

apply_stack() {
  local hub=n pw hash gpw
  [[ $MONITOR == hub ]] && hub=y
  os_installed docker-ce || install_tool docker
  install -d -m 700 "$MON_DIR"
  install -d -m 755 "$MON_DIR/alerts" "$MON_DIR/grafana" "$MON_DIR/grafana/dashboards"   # read by the containers' own users
  render_compose "$hub" >"$MON_DIR/compose.yaml"
  render_loki >"$MON_DIR/loki.yaml"
  render_alert_rules >"$MON_DIR/alerts/server-setup.yml"
  ( umask 077; render_alertmanager >"$MON_DIR/alertmanager.yml" ); chmod 644 "$MON_DIR/alertmanager.yml"
  render_grafana_provisioning "$MON_DIR/grafana/provisioning"
  render_dashboard >"$MON_DIR/grafana/dashboards/server-setup-overview.json"
  gpw=$(secret_get grafana-admin || true)
  if [[ -z $gpw ]]; then gpw=$(gen_password 20); secret_set grafana-admin "$gpw"; note_cred grafana "admin password" "$gpw"; fi
  ( umask 077; cat >"$MON_DIR/grafana.env" <<EOF
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$gpw
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
GF_NEWS_NEWS_FEED_ENABLED=false
GF_PLUGINS_PREINSTALL_DISABLED=true
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
EOF
  )
  if [[ $hub == y ]]; then
    [[ -n ${MONITOR_HUB_ADDR-} ]] || MONITOR_HUB_ADDR=$(server_ip)
    pw=$(secret_get monitor-password || true)
    if [[ -z $pw ]]; then pw=$(gen_password 24); secret_set monitor-password "$pw"; fi
    command -v htpasswd >/dev/null || os_install apache2-utils
    # bcrypt from stdin (never on a command line); Caddy reads the 2a form
    hash=$(printf '%s' "$pw" | htpasswd -niB "$MONITOR_USER" | cut -d: -f2- | sed 's/^\$2y\$/$2a$/')
    ( umask 077; render_caddyfile "$hash" >"$MON_DIR/Caddyfile" ); chmod 644 "$MON_DIR/Caddyfile"
  fi
  chmod 700 "$MON_DIR"
  run "Pulling the monitoring images" docker compose -f "$MON_DIR/compose.yaml" pull
  run "Starting the monitoring stack" docker compose -f "$MON_DIR/compose.yaml" up -d --remove-orphans
  if [[ $hub == y ]]; then
    apply_ufw_docker   # the hub's port, for the allowed agents (MONITOR_ALLOW) only
    if [[ -z ${MONITOR_ALLOW-} ]]; then
      warn "The hub's port $HUB_PORT is open to everyone (it needs the agent login). Limit it: MONITOR_ALLOW in $CONF_FILE, then server-setup monitor apply"
    fi
  fi
  save_config
  note "Monitoring stack ($MONITOR) in $MON_DIR: VictoriaMetrics ($MONITOR_RETENTION), Loki ($LOG_RETENTION), Grafana, vmalert + Alertmanager, Uptime Kuma."
  note "  Grafana: ssh -L 3000:127.0.0.1:3000 $(hostname -s) -> http://localhost:3000 (admin / see credentials). Uptime Kuma: ssh -L 3001:127.0.0.1:3001 -> http://localhost:3001"
  if [[ $hub == y ]]; then note "  Hub: agents push to https://$MONITOR_HUB_ADDR:$HUB_PORT - on each server: sudo server-setup monitor join https://$MONITOR_HUB_ADDR:$HUB_PORT"; fi
}

monitor_apply() {
  case $MONITOR in
    none) monitor_stop_agent; return 0 ;;
    external) [[ -n ${MONITOR_METRICS_URL-} && -n ${MONITOR_LOGS_URL-} ]] || die "external needs MONITOR_METRICS_URL and MONITOR_LOGS_URL (server-setup monitor setup)." ;;
    local|hub) apply_stack ;;
    *) die "MONITOR must be none, external, local or hub." ;;
  esac
  install_agent
}
monitor_stop_agent() { systemctl disable --now alloy >>"$LOG_FILE" 2>&1 || true; }

cmd_monitor() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  mon_defaults
  case $action in
    status|"")
      info "Mode: $MONITOR$([[ $MONITOR == external ]] && echo " -> $MONITOR_METRICS_URL")"
      if systemctl is-active --quiet alloy; then ok "Agent (alloy) running."; else warn "Agent (alloy) not running."; fi
      if mon_stack_here; then docker compose -f "$MON_DIR/compose.yaml" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null | sed 's/^/    /'; fi ;;
    setup) need_tty; monitor_prompt; save_config; monitor_apply ;;
    apply) monitor_apply ;;
    join)  # this server's agent pushes to a hub
      need_tty
      local url=${1-}
      [[ $url =~ ^https?://[^/]+$ ]] || die "usage: server-setup monitor join https://<hub>:$HUB_PORT"
      MONITOR=external MONITOR_METRICS_URL="$url/api/v1/write" MONITOR_LOGS_URL="$url/loki/api/v1/push"
      prompt MONITOR_USER "Agent login on the hub" "$MONITOR_USER" accept_any
      local pw; printf '%s?%s Agent password (sudo server-setup monitor token, on the hub): ' "$C_C" "$C_0" >/dev/tty
      IFS= read -rs pw </dev/tty; printf '\n' >/dev/tty
      [[ -n $pw ]] || die "The password is needed."
      secret_set monitor-password "$pw"
      MONITOR_INSECURE_TLS=y   # the hub's certificate comes from its own (Caddy) CA
      save_config; install_agent; ok "This server now reports to $url." ;;
    move-to) monitor_move_to "$@" ;;
    token)
      [[ $MONITOR == hub ]] || die "This server is not a monitoring hub."
      info "On each server: sudo server-setup monitor join https://$MONITOR_HUB_ADDR:$HUB_PORT"
      info "Login: $MONITOR_USER   password: $(secret_get monitor-password)" ;;
    alerts) need_tty; alerts_prompt; save_config; mon_stack_here && { ( umask 077; render_alertmanager >"$MON_DIR/alertmanager.yml" ); chmod 644 "$MON_DIR/alertmanager.yml"; docker compose -f "$MON_DIR/compose.yaml" restart alertmanager >>"$LOG_FILE" 2>&1; }; ok "Alert receivers saved." ;;
    *) die "usage: server-setup monitor status|setup|apply|join <hub-url>|move-to <hub-url>|token|alerts" ;;
  esac
}

monitor_prompt() {
  info "none: no monitoring. local: everything on this server. hub: everything here, other servers"
  info "push to it. external: only the agent, pushing to a Prometheus-compatible + Loki you already run."
  prompt MONITOR "Monitoring mode (none|local|hub|external)" "$MONITOR" valid_monitor_mode
  case $MONITOR in
    external)
      prompt MONITOR_METRICS_URL "Prometheus remote_write URL (e.g. https://vm.example.com/api/v1/write)" "${MONITOR_METRICS_URL-}" valid_url
      prompt MONITOR_LOGS_URL "Loki push URL (e.g. https://loki.example.com/loki/api/v1/push)" "${MONITOR_LOGS_URL-}" valid_url
      prompt MONITOR_USER "Login (empty = none)" "${MONITOR_USER-}" accept_any
      if [[ -n $MONITOR_USER ]]; then local pw; printf '%s?%s Password: ' "$C_C" "$C_0" >/dev/tty; IFS= read -rs pw </dev/tty; printf '\n' >/dev/tty; [[ -z $pw ]] || secret_set monitor-password "$pw"; fi ;;
    hub)
      prompt MONITOR_HUB_ADDR "Address the other servers use to reach this one (IP or DNS name)" "${MONITOR_HUB_ADDR:-$(server_ip)}" valid_host_list
      prompt MONITOR_ALLOW "Servers allowed to push (IPs/CIDRs, empty = any with the login)" "${MONITOR_ALLOW-}" valid_ip_list ;;
  esac
  if mon_stack_here; then
    prompt MONITOR_RETENTION "Keep metrics for (e.g. 90d, 1y)" "$MONITOR_RETENTION" valid_retention
    prompt LOG_RETENTION "Keep logs for (e.g. 30d)" "$LOG_RETENTION" valid_retention
    alerts_prompt
  fi
}
valid_chat_id() { [[ -z $1 || $1 =~ ^-?[0-9]{1,20}$ ]] || { warn "A Telegram chat id is a number."; return 1; }; }
valid_monitor_mode() { [[ $1 =~ ^(none|local|hub|external)$ ]] || { warn "Use none, local, hub or external."; return 1; }; }
valid_retention() { [[ $1 =~ ^[0-9]{1,4}[dwy]$ ]] || { warn "Use e.g. 30d, 12w or 1y."; return 1; }; }

alerts_prompt() {
  info "Alerts go to any of: Telegram (needs internet), e-mail (SMTP), a webhook. Empty = skip."
  prompt ALERT_TELEGRAM_CHAT "Telegram chat id (a number, e.g. -1001234567890)" "${ALERT_TELEGRAM_CHAT-}" valid_chat_id
  if [[ -n $ALERT_TELEGRAM_CHAT ]]; then local t; printf '%s?%s Telegram bot token (empty = keep): ' "$C_C" "$C_0" >/dev/tty; IFS= read -rs t </dev/tty; printf '\n' >/dev/tty; [[ -z $t ]] || secret_set telegram-token "$t"; fi
  prompt ALERT_EMAIL_TO "Alert e-mail to" "${ALERT_EMAIL_TO-}" accept_any
  if [[ -n $ALERT_EMAIL_TO ]]; then
    prompt ALERT_EMAIL_FROM "From address" "${ALERT_EMAIL_FROM:-alerts@$(hostname -f 2>/dev/null || hostname)}" accept_any
    prompt ALERT_SMTP "SMTP server host:port" "${ALERT_SMTP-}" accept_any
    prompt ALERT_SMTP_USER "SMTP login (empty = none)" "${ALERT_SMTP_USER-}" accept_any
    if [[ -n $ALERT_SMTP_USER ]]; then local sp; printf '%s?%s SMTP password (empty = keep): ' "$C_C" "$C_0" >/dev/tty; IFS= read -rs sp </dev/tty; printf '\n' >/dev/tty; [[ -z $sp ]] || secret_set smtp-password "$sp"; fi
  fi
  prompt ALERT_WEBHOOK "Webhook URL (Slack/Mattermost/n8n...)" "${ALERT_WEBHOOK-}" valid_url_or_empty
}

monitor_move_to() { # a single server grows: its agent pushes to a hub, its history goes along
  need_tty
  local url=${1-} pw keep=y
  [[ $url =~ ^https?://[^/]+$ ]] || die "usage: server-setup monitor move-to https://<hub>:$HUB_PORT"
  [[ $MONITOR == local ]] || die "move-to is for a server that runs its own stack (mode local); this one is '$MONITOR'."
  prompt MONITOR_USER "Agent login on the hub" "agent" accept_any
  printf '%s?%s Agent password (on the hub: sudo server-setup monitor token): ' "$C_C" "$C_0" >/dev/tty
  IFS= read -rs pw </dev/tty; printf '\n' >/dev/tty
  prompt_yn keep "Copy this server's metric history to the hub first (logs stay here until the stack is removed)?" y
  if [[ $keep == y ]]; then
    # VictoriaMetrics' native export, streamed straight into the hub's native import; the
    # login is in a private netrc file, never on a command line
    local n; n=$(mktemp)
    ( umask 077; printf 'machine %s\nlogin %s\npassword %s\n' "$(sed -E 's#^https?://##; s#:[0-9]+$##' <<<"$url")" "$MONITOR_USER" "$pw" >"$n" )
    run "Copying metric history to $url (can take a while)" bash -c \
      'set -o pipefail; curl -fsS -G "http://127.0.0.1:8428/api/v1/export/native" --data-urlencode "match[]={__name__!=\"\"}" \
         | curl -fsS -k --netrc-file "$1" -X POST -T - "$2/api/v1/import/native"' _ "$n" "$url"
    rm -f "$n"
  fi
  secret_set monitor-password "$pw"
  MONITOR=external MONITOR_METRICS_URL="$url/api/v1/write" MONITOR_LOGS_URL="$url/loki/api/v1/push" MONITOR_INSECURE_TLS=y
  save_config
  install_agent
  local stop=n; prompt_yn stop "Stop the local monitoring stack now? (its data volumes are kept)" y
  if [[ $stop == y ]]; then run "Stopping the local stack" docker compose -f "$MON_DIR/compose.yaml" down; fi
  ok "This server now reports to $url."
}

# ----------------------------------------------------------------------------
# dokploy-node role: this server is a REMOTE SERVER of a Dokploy panel that runs elsewhere
# (the panel is not installed here). The panel connects over SSH and runs its "Setup Server"
# script (Dokploy packages/server/src/setup/server-setup.ts); every step of it is skipped when
# its result already exists. This role creates those results ahead of time through the chosen
# sources - so "Setup Server" also works on a server without internet:
#   utilities + rclone (apt) | Docker (Docker's apt repo, not get.docker.com) | Swarm (advertise
#   address from the routes, not ifconfig.io) | dokploy-network | the Traefik image, pulled |
#   nixpacks, railpack, pack (GitHub releases, direct or mirror) | a 'dokploy' user for the panel
# The panel itself still writes Traefik's config and starts it (no internet needed for that).
# ----------------------------------------------------------------------------
dokploy_defaults() {
  : "${DOKPLOY_USER:=dokploy}" "${TRAEFIK_VERSION:=3.7.19}" "${NIXPACKS_VERSION:=1.41.0}"
  : "${RAILPACK_VERSION:=0.15.4}" "${PACK_VERSION:=0.39.1}"
}

# docker_pull <image> - a Docker Hub image through the dockerhub source. With the mirror:
# registry-mirrors first (anonymous), then the mirror's own name (logged in) + the usual tag.
docker_pull() {
  local img=$1 path
  if docker image inspect "$img" >/dev/null 2>&1; then return 0; fi
  if run_soft "Pulling $img" docker pull "$img"; then return 0; fi
  [[ $(route_of dockerhub) == mirror ]] || die "Could not pull $img."
  path=$img; [[ $path == */* ]] || path="library/$path"
  run "Pulling $img as $MIRROR_DOCKER_REGISTRY/$path" docker pull "$MIRROR_DOCKER_REGISTRY/$path"
  docker tag "$MIRROR_DOCKER_REGISTRY/$path" "$img"
}

# install_release_binary <name> <url> <binary-in-archive> [sha256-url]
install_release_binary() {
  local name=$1 url=$2 bin=$3 sumurl=${4-} tmp want
  tmp=$(mktemp -d)
  fetch github "$url" "$tmp/archive"
  if [[ -n $sumurl ]]; then
    fetch github "$sumurl" "$tmp/sum"
    want=$(awk '{print $1}' "$tmp/sum")
    printf '%s  %s\n' "$want" "$tmp/archive" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "Checksum mismatch for $name."; }
  fi
  tar -C "$tmp" -xzf "$tmp/archive"
  local f; f=$(find "$tmp" -type f -name "$bin" | head -n1)
  [[ -n $f ]] || { rm -rf "$tmp"; die "$bin not found in the $name archive."; }
  install -m 755 "$f" "/usr/local/bin/$bin"
  rm -rf "$tmp"
}

dokploy_advertise_addr() { # the address Swarm advertises: asked, or the one routing to the world
  [[ -n ${DOKPLOY_ADVERTISE_ADDR-} ]] && { printf '%s' "$DOKPLOY_ADVERTISE_ADDR"; return 0; }
  local ip; ip=$(server_ip)
  [[ $ip != "<server-ip>" ]] || die "Could not find this server's address - set DOKPLOY_ADVERTISE_ADDR (server-setup dokploy-node prepare)."
  printf '%s' "$ip"
}

dokploy_prepare() {
  local a arch
  dokploy_defaults
  arch=$OS_ARCH; [[ $arch == amd64 || $arch == arm64 ]] || die "Dokploy's build tools have no $arch build."
  # 1. utilities the panel's script installs (from apt - direct or mirror)
  os_install curl wget git git-lfs jq openssl unzip tar rclone
  # 2. Docker (Swarm-ready: no live-restore), logs capped, ports filtered by ufw
  OPEN_PORTS=$(uniq_words $OPEN_PORTS 80 443 443/udp)
  install_docker y
  # Docker and containerd are not restarted by automatic updates (that would restart every app)
  if [[ -d /etc/needrestart/conf.d ]]; then
    printf "# Managed by server-setup: never restart Docker by itself (all apps would restart)\n\$nrconf{override_rc}{qr(^docker)} = 0;\n\$nrconf{override_rc}{qr(^containerd)} = 0;\n" \
      >/etc/needrestart/conf.d/91-server-setup-docker.conf
  fi
  # 3. Swarm + the overlay network the panel expects
  if ! docker_swarm_active; then
    run "Starting Docker Swarm" docker swarm init --advertise-addr "$(dokploy_advertise_addr)"
  fi
  if ! docker network inspect dokploy-network >/dev/null 2>&1; then
    run "Creating dokploy-network" docker network create --driver overlay --attachable dokploy-network
  fi
  # 4. Traefik's image, so the panel's `docker run traefik:v...` needs no internet
  need_source dockerhub
  docker_pull "traefik:v$TRAEFIK_VERSION"
  # 5. the build tools (the panel skips each one that exists)
  local nx rp
  nx="x86_64-unknown-linux-musl"; [[ $arch == arm64 ]] && nx="aarch64-unknown-linux-musl"
  rp="x86_64-unknown-linux-musl"; [[ $arch == arm64 ]] && rp="arm64-unknown-linux-musl"
  command -v nixpacks >/dev/null || install_release_binary nixpacks \
    "https://github.com/railwayapp/nixpacks/releases/download/v$NIXPACKS_VERSION/nixpacks-v$NIXPACKS_VERSION-$nx.tar.gz" nixpacks
  command -v railpack >/dev/null || install_release_binary railpack \
    "https://github.com/railwayapp/railpack/releases/download/v$RAILPACK_VERSION/railpack-v$RAILPACK_VERSION-$rp.tar.gz" railpack
  local pk="linux"; [[ $arch == arm64 ]] && pk="linux-arm64"
  command -v pack >/dev/null || install_release_binary pack \
    "https://github.com/buildpacks/pack/releases/download/v$PACK_VERSION/pack-v$PACK_VERSION-$pk.tgz" pack \
    "https://github.com/buildpacks/pack/releases/download/v$PACK_VERSION/pack-v$PACK_VERSION-$pk.tgz.sha256"
  # 6. the user the panel logs in as
  dokploy_user
  # 7. Swarm ports between this server and its peers only
  for a in ${DOKPLOY_SWARM_PEERS-}; do
    ufw allow from "$a" to any port 2377 proto tcp comment 'swarm' >>"$LOG_FILE"
    ufw allow from "$a" to any port 7946 comment 'swarm' >>"$LOG_FILE"
    ufw allow from "$a" to any port 4789 proto udp comment 'swarm overlay' >>"$LOG_FILE"
  done
  step_firewall
  ROLES=$(uniq_words $ROLES dokploy-node); save_config
  note "Dokploy node ready: Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) in Swarm mode, dokploy-network, traefik:v$TRAEFIK_VERSION pulled, nixpacks $NIXPACKS_VERSION, railpack $RAILPACK_VERSION, pack $PACK_VERSION."
  note "  In the panel: Servers -> Create: IP $(dokploy_advertise_addr), port $(ssh_main_port), user $DOKPLOY_USER, the panel's SSH key -> Setup Server."
  note "  Ports 80/443 open (Traefik); the panel's address: ${DOKPLOY_PANEL_IP:-any (no restriction set)}."
  if [[ $(route_of dockerhub) == mirror || $(route_of github) == mirror ]]; then
    note "  Without internet: Dockerfile builds work (Docker Hub images through the mirror). Nixpacks/Railpack builds also need"
    note "  ghcr.io images - Docker can't mirror ghcr.io; add a ghcr.io proxy to Nexus and pre-pull them, or use Dockerfiles."
    note "  App builds that run npm/pip/go need the mirror too: set NPM_CONFIG_REGISTRY / PIP_INDEX_URL / GOPROXY as build"
    note "  variables in Dokploy (values: $(mirror_base)/repository/$REPO_NPM/, .../$REPO_PYPI/simple, .../$REPO_GO/)."
  fi
}

dokploy_user() {
  local u=$DOKPLOY_USER home key opts=""
  ensure_group "$SSH_GROUP"
  ensure_user "$u" deploy
  usermod -aG docker "$u"
  # Dokploy runs its setup with `sudo` (it requires passwordless sudo) - so this user IS root.
  printf '# Managed by server-setup: the Dokploy panel runs its server setup with sudo\n%s ALL=(ALL) NOPASSWD:ALL\n' "$u" >/etc/sudoers.d/60-server-setup-dokploy
  chmod 440 /etc/sudoers.d/60-server-setup-dokploy
  visudo -cq || { rm -f /etc/sudoers.d/60-server-setup-dokploy; die "sudoers check failed for the dokploy user."; }
  install -d -m 755 /etc/dokploy; chown -R "$u:$u" /etc/dokploy
  if [[ -n ${DOKPLOY_KEY-} ]]; then
    key=$(normalize_pubkey "$DOKPLOY_KEY") || die "The Dokploy panel's key is not a valid SSH public key."
    # only from the panel, and only as a command shell (no forwarding of any kind)
    [[ -n ${DOKPLOY_PANEL_IP-} ]] && opts="from=\"$DOKPLOY_PANEL_IP\","
    opts+="no-port-forwarding,no-agent-forwarding,no-X11-forwarding"
    home=$(home_of "$u")
    runuser -u "$u" -- sh -c 'umask 077; mkdir -p "$1/.ssh"; : >"$1/.ssh/authorized_keys"' sh "$home"
    printf '%s %s\n' "$opts" "$key" | runuser -u "$u" -- tee "$home/.ssh/authorized_keys" >/dev/null
  fi
  if [[ -n $SSH_ALLOW && -n ${DOKPLOY_PANEL_IP-} ]]; then SSH_ALLOW=$(uniq_words $SSH_ALLOW "$DOKPLOY_PANEL_IP"); fi
  note "Dokploy panel user '$u': key-only${DOKPLOY_PANEL_IP:+, only from $DOKPLOY_PANEL_IP}; passwordless sudo + docker group (Dokploy requires it - this user is effectively root)."
}

dokploy_prompt() {
  dokploy_defaults
  info "The Dokploy panel (installed elsewhere) manages this server over SSH. In the panel: Settings ->"
  info "SSH Keys -> create a key and copy its public part; you paste it here."
  prompt DOKPLOY_KEY "The panel's SSH public key" "${DOKPLOY_KEY-}" valid_pubkey_or_empty
  prompt DOKPLOY_PANEL_IP "The panel's IP address (only it may log in as $DOKPLOY_USER; empty = any)" "${DOKPLOY_PANEL_IP-}" valid_ip_list
  prompt DOKPLOY_ADVERTISE_ADDR "This server's address for Swarm" "${DOKPLOY_ADVERTISE_ADDR:-$(server_ip)}" valid_host_list
  prompt DOKPLOY_SWARM_PEERS "Other Swarm nodes (IPs, empty = this server alone)" "${DOKPLOY_SWARM_PEERS-}" valid_ip_list
}
valid_pubkey_or_empty() { [[ -z $1 ]] || normalize_pubkey "$1" >/dev/null || { warn "Not an SSH public key."; return 1; }; }

cmd_dokploy_node() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  dokploy_defaults
  case $action in
    prepare) need_tty; dokploy_prompt; save_config; dokploy_prepare; print_credentials ;;
    status|"")
      info "Versions: traefik $TRAEFIK_VERSION, nixpacks $NIXPACKS_VERSION, railpack $RAILPACK_VERSION, pack $PACK_VERSION"
      if docker_swarm_active; then ok "Swarm active."; else warn "Swarm not active."; fi
      if docker network inspect dokploy-network >/dev/null 2>&1; then ok "dokploy-network exists."; else warn "dokploy-network missing."; fi
      if docker inspect dokploy-traefik >/dev/null 2>&1; then ok "Traefik running (set up by the panel)."; else info "Traefik not started yet - the panel's 'Setup Server' does that."; fi
      local b; for b in nixpacks railpack pack rclone; do command -v "$b" >/dev/null && ok "$b: $("$b" --version 2>/dev/null | head -n1)" || warn "$b missing"; done ;;
    sync) dokploy_sync "$@" ;;
    *) die "usage: server-setup dokploy-node prepare | status | sync [<dokploy-version>] [--traefik V --nixpacks V --railpack V --pack V]" ;;
  esac
}

# dokploy_sync - match the versions a newer panel expects (read from Dokploy's own source, or given)
dokploy_sync() {
  local tag="" t src tmp
  while (( $# > 0 )); do
    case $1 in
      --traefik) TRAEFIK_VERSION=${2-}; shift ;; --nixpacks) NIXPACKS_VERSION=${2-}; shift ;;
      --railpack) RAILPACK_VERSION=${2-}; shift ;; --pack) PACK_VERSION=${2-}; shift ;;
      -*) die "Unknown option $1" ;; *) tag=$1 ;;
    esac
    shift
  done
  if [[ -n $tag ]]; then
    [[ $tag =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|canary|main)$ ]] || die "Give a Dokploy release such as v0.25.0."
    src="https://raw.githubusercontent.com/Dokploy/dokploy/$tag/packages/server/src/setup"
    tmp=$(mktemp -d)
    curl -fsSL -m 30 -o "$tmp/s.ts" "$src/server-setup.ts" && curl -fsSL -m 30 -o "$tmp/t.ts" "$src/traefik-setup.ts" \
      || { rm -rf "$tmp"; die "Dokploy's source for $tag is not reachable - give the versions: --traefik V --nixpacks V --railpack V --pack V"; }
    t=$(grep -oE 'TRAEFIK_VERSION \|\| "[0-9.]+"' "$tmp/t.ts" | grep -oE '[0-9.]+' | head -n1); [[ -n $t ]] && TRAEFIK_VERSION=$t
    t=$(grep -oE 'NIXPACKS_VERSION=[0-9.]+' "$tmp/s.ts" | cut -d= -f2 | head -n1); [[ -n $t ]] && NIXPACKS_VERSION=$t
    t=$(grep -oE 'RAILPACK_VERSION=[0-9.]+' "$tmp/s.ts" | cut -d= -f2 | head -n1); [[ -n $t ]] && RAILPACK_VERSION=$t
    t=$(grep -oE 'BUILDPACKS_VERSION=[0-9.]+' "$tmp/s.ts" | cut -d= -f2 | head -n1); [[ -n $t ]] && PACK_VERSION=$t
    rm -rf "$tmp"
  fi
  save_config
  ok "Versions: traefik $TRAEFIK_VERSION, nixpacks $NIXPACKS_VERSION, railpack $RAILPACK_VERSION, pack $PACK_VERSION"
  # replace the build tools that changed, pull the new Traefik image
  local b want
  for b in nixpacks railpack pack; do
    case $b in nixpacks) want=$NIXPACKS_VERSION ;; railpack) want=$RAILPACK_VERSION ;; pack) want=$PACK_VERSION ;; esac
    if command -v "$b" >/dev/null && ! "$b" --version 2>/dev/null | grep -qF "$want"; then rm -f "/usr/local/bin/$b"; fi
  done
  dokploy_prepare
}

# ----------------------------------------------------------------------------
# Fleet: one server (usually the monitoring hub) manages many over SSH.
#   manager: server-setup fleet init | add | remove | list | status | show | update
#   member:  server-setup fleet join <manager's key> --from <manager IP>
# On a member, the manager's key may run ONE program: `server-setup fleet-agent`, which
# accepts only: brief, status, update, update-all, version. Nothing else - no shell, no
# forwarding, only from the manager's address.
# ----------------------------------------------------------------------------
readonly FLEET_DIR="$STATE_DIR/fleet"
readonly FLEET_KEY="$STATE_DIR/fleet/id_ed25519"
readonly FLEET_HOSTS="$STATE_DIR/fleet/servers"
readonly FLEET_USER="fleet"

fleet_brief() { # one line about this server, for the manager's table (tab-separated)
  local mem disk why sec failed
  os_detect
  mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d", 100 - 100 * a / t}' /proc/meminfo)
  disk=$(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR > 1 {gsub("%", "", $5); if ($5 > m) m = $5} END {print m + 0}')
  why=$(os_reboot_reason)
  sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst .*-security' || true)
  failed=$(systemctl --failed --plain --no-legend 2>/dev/null | wc -l)
  printf '%s\t%s %s\t%s\t%s\t%s%%\t%s%%\t%s\t%s\t%s\t%s\n' "$(hostname -s)" "$OS_ID" "$OS_VERSION" "$(uptime -p | sed 's/^up //; s/ years\?/y/; s/ weeks\?/w/; s/ days\?/d/; s/ hours\?/h/; s/ minutes\?/m/g; s/,//g')" \
    "$(cut -d' ' -f3 /proc/loadavg)" "$mem" "$disk" "$([[ -n $why ]] && echo yes || echo no)" "${sec:-0}" "$failed" "$SCRIPT_VERSION"
}

# the forced command on a member (runs as root through sudo)
cmd_fleet_agent() {
  local req=${SSH_ORIGINAL_COMMAND-}
  case $req in
    brief) fleet_brief ;;
    status) cmd_status 2>&1 | sed 's/\x1b\[[0-9;]*m//g' ;;
    update|update-all)
      exec 9>"$STATE_DIR/.lock"
      flock -w 900 9 || { echo "fleet-agent: another server-setup run is still going" >&2; exit 3; }
      if [[ $req == update ]]; then cmd_update 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; else cmd_update --all 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; fi ;;
    version) printf 'server-setup %s\n' "$SCRIPT_VERSION" ;;
    *) printf 'fleet-agent: not allowed: %s (allowed: brief status update update-all version)\n' "${req:-(nothing)}" >&2; exit 2 ;;
  esac
}

fleet_join() { # make this server a member: the manager's key may run fleet-agent only
  local key="" from="" home opts a
  while (( $# > 0 )); do
    case $1 in --from) from=${2-}; shift ;; -*) die "Unknown option $1" ;; *) key+="${key:+ }$1" ;; esac
    shift
  done
  key=$(normalize_pubkey "$key") || die "usage: server-setup fleet join \"ssh-ed25519 AAAA... server-setup-fleet@hub\" --from <manager IP>"
  [[ -n $from ]] || die "--from <manager IP> is required: the key only works from there."
  valid_ip_list "$from" || exit 1
  ensure_group "$SSH_GROUP"
  id "$FLEET_USER" &>/dev/null || useradd --create-home --user-group --shell /bin/sh "$FLEET_USER"
  usermod -p '*' "$FLEET_USER"; usermod -aG "$SSH_GROUP" "$FLEET_USER"
  home=$(home_of "$FLEET_USER"); chmod 750 "$home"
  opts="from=\"$from\",command=\"sudo -n $INSTALL_PATH fleet-agent\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,no-user-rc"
  runuser -u "$FLEET_USER" -- sh -c 'umask 077; mkdir -p "$1/.ssh"' sh "$home"
  printf '%s %s\n' "$opts" "$key" | runuser -u "$FLEET_USER" -- tee "$home/.ssh/authorized_keys" >/dev/null
  # sudo for exactly that program (no arguments), keeping the request the manager sent
  cat >/etc/sudoers.d/70-server-setup-fleet <<EOF
# Managed by server-setup: the fleet manager may run the fleet agent, nothing else
Defaults:$FLEET_USER env_keep += "SSH_ORIGINAL_COMMAND"
$FLEET_USER ALL=(root) NOPASSWD: $INSTALL_PATH fleet-agent
EOF
  chmod 440 /etc/sudoers.d/70-server-setup-fleet
  visudo -cq || { rm -f /etc/sudoers.d/70-server-setup-fleet; die "sudoers check failed - not joined."; }
  if [[ -n $SSH_ALLOW ]]; then SSH_ALLOW=$(uniq_words $SSH_ALLOW $from); save_config; step_firewall; fi
  FLEET_MANAGER=$from; save_config
  ok "This server can now be managed by the fleet manager at $from (status and updates only)."
}

fleet_ssh() { # fleet_ssh <host> <port> <request>
  ssh -n -i "$FLEET_KEY" -p "$2" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$FLEET_DIR/known_hosts" \
    -o IdentitiesOnly=yes "$FLEET_USER@$1" "$3"
}
fleet_each() { # fleet_each [names...] - prints "name host port" lines (all, or those named)
  [[ -s $FLEET_HOSTS ]] || die "No servers yet: server-setup fleet add <name> <host> [--port P]"
  if (( $# == 0 )); then grep -vE '^[[:space:]]*(#|$)' "$FLEET_HOSTS"; return 0; fi
  local n line found
  for n in "$@"; do
    found=$(awk -v n="$n" '$1 == n' "$FLEET_HOSTS")
    [[ -n $found ]] || die "No server '$n' (server-setup fleet list)."
    printf '%s\n' "$found"
  done
}

cmd_fleet() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  case $action in
    join) fleet_join "$@"; return ;;
  esac
  install -d -m 700 "$FLEET_DIR"
  case $action in
    init)
      if [[ ! -f $FLEET_KEY ]]; then ssh-keygen -q -t ed25519 -N '' -C "server-setup-fleet@$(hostname -s)" -f "$FLEET_KEY"; fi
      touch "$FLEET_HOSTS"; chmod 600 "$FLEET_HOSTS"
      ok "This server is a fleet manager. On every server to manage, run:"
      printf '\n    sudo server-setup fleet join "%s" --from %s\n\n' "$(cat "$FLEET_KEY.pub")" "$(server_ip)" ;;
    add)
      [[ -f $FLEET_KEY ]] || die "Run 'server-setup fleet init' first."
      local name=${1-} host=${2-} port=22; shift 2 2>/dev/null || true
      [[ ${1-} == --port ]] && port=${2-22}
      [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ && -n $host ]] || die "usage: server-setup fleet add <name> <host> [--port P]"
      valid_host_list "$host" || exit 1; valid_port_number "$port" || exit 1
      if awk -v n="$name" '$1 == n {f=1} END {exit !f}' "$FLEET_HOSTS" 2>/dev/null; then die "'$name' is already in the fleet."; fi
      local v; v=$(fleet_ssh "$host" "$port" version 2>&1) || die "Could not reach $name ($host:$port) as '$FLEET_USER': $v
  On $name: sudo server-setup fleet join \"$(cat "$FLEET_KEY.pub")\" --from $(server_ip)"
      printf '%s %s %s\n' "$name" "$host" "$port" >>"$FLEET_HOSTS"
      ok "Added $name ($host:$port) - $v" ;;
    remove)
      [[ -n ${1-} ]] || die "usage: server-setup fleet remove <name>"
      awk -v n="$1" '$1 != n' "$FLEET_HOSTS" >"$FLEET_HOSTS.new" && mv -f "$FLEET_HOSTS.new" "$FLEET_HOSTS"; chmod 600 "$FLEET_HOSTS"
      ok "Removed $1 from the fleet (on it: sudo userdel -r $FLEET_USER; sudo rm /etc/sudoers.d/70-server-setup-fleet)." ;;
    list|"") [[ -s $FLEET_HOSTS ]] && column -t "$FLEET_HOSTS" | sed 's/^/    /' || info "No servers yet: server-setup fleet add <name> <host>" ;;
    status)
      local out; out=$(mktemp -d)
      local name host port
      while read -r name host port _; do
        # rows go to <name>.row, errors to <name>.err - only rows are shown
        # the inventory name leads the row (not the server's own hostname)
        ( fleet_ssh "$host" "$port" brief 2>"$out/$name.err" | awk -v n="$name" 'BEGIN {FS = OFS = "\t"} {$1 = n; print}' >"$out/$name.row" \
          && [[ -s $out/$name.row ]] \
          || printf '%s\tUNREACHABLE\t%s\n' "$name" "$(grep -v '^Warning: Permanently added' "$out/$name.err" | tr '\n' ' ' | cut -c1-70)" >"$out/$name.row" ) &
      done < <(fleet_each "$@")
      wait
      { printf 'SERVER\tOS\tUP\tLOAD\tMEM\tDISK\tREBOOT\tSEC-UPD\tFAILED\tVERSION\n'; cat "$out"/*.row 2>/dev/null | grep -v '^$'; } | column -t -s $'\t' | sed 's/^/    /'
      rm -rf "$out" ;;
    show)
      [[ -n ${1-} ]] || die "usage: server-setup fleet show <name>"
      local name host port; read -r name host port _ < <(fleet_each "$1")
      fleet_ssh "$host" "$port" status ;;
    update)
      local req=update names=() a
      for a in "$@"; do case $a in --all) req=update-all ;; *) names+=("$a") ;; esac; done
      local name host port
      while read -r name host port _; do
        step "$name ($host)"
        fleet_ssh "$host" "$port" "$req" 2>&1 | sed 's/^/    /' || warn "$name: update failed or unreachable."
      done < <(fleet_each "${names[@]}") ;;
    *) die "usage: server-setup fleet init | add <name> <host> [--port P] | remove <name> | list | status [names] | show <name> | update [--all] [names]   (member: fleet join <key> --from <IP>)" ;;
  esac
}

# ----------------------------------------------------------------------------
# Under pressure: the admin can always get in and fix it
#   apps.slice        every workload: app-* services and every Docker container (cgroup-parent)
#                     - memory capped below the RAM (MemoryHigh, then MemoryMax), low CPU/IO weight
#   monitoring.slice  the monitoring stack - keeps reporting while apps misbehave
#   ssh + user.slice  sshd and admin sessions: 10x the CPU/IO weight, memory protected (MemoryMin)
#   systemd-oomd      kills the heaviest thing in apps.slice when it thrashes or swap runs out -
#                     never sshd, admin sessions or system services
#   ballast file      disk space held in reserve: `server-setup rescue free-space` frees it at once
#   rescue            diagnose / freeze / thaw / stop-apps / free-space / kill
# ----------------------------------------------------------------------------
readonly BALLAST="/var/lib/server-setup/ballast"

pressure_reserve_mb() { # memory kept free for the system and the admin: 5% of RAM, 256 MB..1 GB
  local mb; mb=$(awk '/^MemTotal:/ {print int($2 / 1024 / 20)}' /proc/meminfo)
  (( mb < 256 )) && mb=256; (( mb > 1024 )) && mb=1024
  printf '%s' "$mb"
}

render_apps_slice() {
  local total reserve high max
  total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  reserve=$(pressure_reserve_mb)
  max=$(( total - reserve )); high=$(( total - 2 * reserve ))
  cat <<EOF
# Managed by server-setup: every workload (app-* services, Docker containers) lives here.
# Above MemoryHigh it is slowed down and reclaimed; it can never take the last ${reserve} MB
# of RAM (MemoryMax), which stay for sshd, the admin and the system.
[Unit]
Description=Applications (server-setup: capped so the server stays manageable)
Before=slices.target

[Slice]
MemoryHigh=${high}M
MemoryMax=${max}M
CPUWeight=100
IOWeight=100
TasksMax=16384
ManagedOOMMemoryPressure=kill
ManagedOOMMemoryPressureLimit=80%
ManagedOOMSwap=kill
EOF
}

apply_pressure_guard() {
  local reserve mf
  reserve=$(pressure_reserve_mb)
  render_apps_slice >/etc/systemd/system/apps.slice
  cat >/etc/systemd/system/monitoring.slice <<'EOF'
# Managed by server-setup: the monitoring stack - apart from the apps, so it keeps reporting
[Unit]
Description=Monitoring (server-setup)
Before=slices.target

[Slice]
CPUWeight=200
IOWeight=200
MemoryMin=256M
EOF
  # sshd and every login session: far ahead of the apps for CPU and disk, memory protected
  install -d /etc/systemd/system/ssh.service.d /etc/systemd/system/user.slice.d
  cat >/etc/systemd/system/ssh.service.d/91-server-setup-pressure.conf <<'EOF'
# Managed by server-setup: SSH answers even when the apps use every CPU and disk
[Service]
CPUWeight=1000
IOWeight=1000
MemoryMin=64M
EOF
  cat >/etc/systemd/system/user.slice.d/91-server-setup-pressure.conf <<'EOF'
# Managed by server-setup: admin sessions (SSH logins) stay usable under load
[Slice]
CPUWeight=1000
IOWeight=1000
MemoryMin=256M
EOF
  # the kernel keeps this much RAM free for urgent allocations (1% of RAM, 64..256 MB)
  mf=$(awk '/^MemTotal:/ {v = int($2 / 100); if (v < 65536) v = 65536; if (v > 262144) v = 262144; print v}' /proc/meminfo)
  printf '# Managed by server-setup: headroom for urgent allocations under memory pressure\nvm.min_free_kbytes = %s\n' "$mf" \
    >/etc/sysctl.d/94-server-setup-pressure.conf
  sysctl -q -p /etc/sysctl.d/94-server-setup-pressure.conf >>"$LOG_FILE" 2>&1 || true
  # systemd-oomd acts on apps.slice only (the slice's ManagedOOM* settings above)
  if ! command -v oomctl >/dev/null && pkg_available systemd-oomd; then os_install systemd-oomd; fi
  if command -v oomctl >/dev/null; then
    install -d /etc/systemd/oomd.conf.d
    printf '# Managed by server-setup\n[OOM]\nSwapUsedLimit=90%%\nDefaultMemoryPressureDurationSec=20s\n' >/etc/systemd/oomd.conf.d/90-server-setup.conf
    systemctl enable systemd-oomd >>"$LOG_FILE" 2>&1 || true
  fi
  systemctl daemon-reload
  systemctl start apps.slice monitoring.slice >>"$LOG_FILE" 2>&1 || true
  if command -v oomctl >/dev/null; then systemctl restart systemd-oomd >>"$LOG_FILE" 2>&1 || true; fi
  ballast_ensure
  # Docker's containers belong in apps.slice too (cgroup-parent) - also on a re-run, when Docker
  # was installed earlier. live-restore keeps running containers up; they move when re-created.
  if os_installed docker-ce; then
    render_daemon_json "$(docker_swarm_active && echo y || echo n)" >/etc/docker/daemon.json.new
    if ! cmp -s /etc/docker/daemon.json.new /etc/docker/daemon.json; then
      mv -f /etc/docker/daemon.json.new /etc/docker/daemon.json; docker_restart
      note "Docker: new containers start in apps.slice (running ones move there when they are re-created)."
    else rm -f /etc/docker/daemon.json.new; fi
  fi
  note "Under pressure: apps (services + containers) capped at RAM - ${reserve} MB in apps.slice, slowed from RAM - $((2 * reserve)) MB;"
  note "  SSH and admin sessions get 10x their CPU/disk priority and protected memory; systemd-oomd ends a"
  note "  thrashing app, never SSH. Ballast $(ballast_size_mb) MB in $BALLAST. When it's bad: sudo server-setup rescue"
}

ballast_size_mb() { # 2% of the root filesystem, 256 MB..2 GB
  df -Pm / | awk 'NR == 2 {v = int($2 / 50); if (v < 256) v = 256; if (v > 2048) v = 2048; print v}'
}
ballast_ensure() {
  local want avail
  want=$(ballast_size_mb)
  [[ -f $BALLAST && $(stat -c %s "$BALLAST") -ge $(( want * 1048576 )) ]] && return 0
  avail=$(df -Pm / | awk 'NR == 2 {print $4}')
  if (( avail < want * 4 )); then warn "Not enough free disk to keep a ${want} MB ballast file now - skipped."; return 0; fi
  install -d -m 700 "${BALLAST%/*}"
  fallocate -l "${want}M" "$BALLAST" 2>/dev/null || dd if=/dev/zero of="$BALLAST" bs=1M count="$want" status=none
  chmod 600 "$BALLAST"
}

# ---- rescue ------------------------------------------------------------------
psi() { [[ -r /proc/pressure/$1 ]] && awk -v r="$1" '/^some/ {split($2, a, "="); printf "%s %s%% ", r, a[2]}' "/proc/pressure/$1"; }

rescue_diagnose() {
  local apps_mem
  step "Pressure (share of time something waited, last 10 s)"
  info "$(psi cpu)$(psi memory)$(psi io)  load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPU"
  free -m | awk '/^Mem:/ {printf "    RAM  %d MB used of %d MB, %d MB available\n", $3, $2, $7} /^Swap:/ {printf "    swap %d MB used of %d MB\n", $3, $2}'
  apps_mem=$(systemctl show apps.slice -p MemoryCurrent --value 2>/dev/null)
  [[ $apps_mem =~ ^[0-9]+$ ]] && info "apps.slice uses $(( apps_mem / 1048576 )) MB (limit $(systemctl show apps.slice -p MemoryMax --value | awk '{printf "%d", $1 / 1048576}') MB)$([[ $(systemctl show apps.slice -p FreezerState --value 2>/dev/null) == frozen ]] && echo ' - FROZEN')"
  step "Top memory"
  ps -eo pid,user,rss,comm --sort=-rss --no-headers | head -6 | awk '{printf "    %-8s %-12s %7d MB  %s\n", $1, $2, $3 / 1024, $4}'
  step "Top CPU (now)"
  top -b -n 2 -d 1 -o %CPU -w 120 2>/dev/null | awk '/^top - / {n++} n == 2 && /^ *PID / {p = 1; next} p && c++ < 6 {printf "    %-8s %-12s %5s%%  %s\n", $1, $2, $9, $12}'
  step "Disks"
  df -h -x tmpfs -x devtmpfs -x overlay -x squashfs | awk 'NR > 1 {printf "    %-22s %5s used of %5s (%s)\n", $6, $3, $2, $5}'
  df -i / | awk 'NR == 2 {printf "    inodes on /: %s used\n", $5}'
  [[ -f $BALLAST ]] && info "ballast: $(( $(stat -c %s "$BALLAST") / 1048576 )) MB ready to free (server-setup rescue free-space)"
  info "biggest under /var: $(timeout 20 du -xsh /var/* 2>/dev/null | sort -rh | head -4 | awk '{printf "%s %s, ", $2, $1}')"
  step "Recent out-of-memory kills"
  journalctl -k --since -6h --no-pager -q 2>/dev/null | grep -E 'Out of memory|oom-kill|Killed process' | tail -3 | cut -c1-150 | sed 's/^/    /'
  journalctl -u systemd-oomd --since -6h --no-pager -q 2>/dev/null | grep -i 'killed' | tail -3 | cut -c1-150 | sed 's/^/    /'
  info "Actions: rescue freeze | thaw | stop-apps | free-space | kill <pid>"
}

rescue_free_space() {
  local before after
  before=$(df -Pm / | awk 'NR == 2 {print $4}')
  if [[ -f $BALLAST ]]; then rm -f "$BALLAST"; ok "Ballast freed."; fi
  journalctl --vacuum-size=200M >>"$LOG_FILE" 2>&1 || true
  apt-get clean >>"$LOG_FILE" 2>&1 || true
  if command -v docker >/dev/null; then
    # dangling images and build cache only - never volumes or images in use
    timeout 120 docker image prune -f >>"$LOG_FILE" 2>&1 || true
    timeout 120 docker builder prune -f >>"$LOG_FILE" 2>&1 || true
  fi
  find /tmp /var/tmp -xdev -type f -atime +7 -delete 2>/dev/null || true
  after=$(df -Pm / | awk 'NR == 2 {print $4}')
  ok "Freed $(( after - before )) MB on / (now $after MB free). Find the cause: sudo server-setup rescue"
  info "When it's fixed, re-create the ballast: sudo server-setup rescue restore"
}

cmd_rescue() {
  local action=${1-}; if (( $# > 0 )); then shift; fi
  # the rescue itself goes ahead of everything else
  renice -n -15 -p $$ >/dev/null 2>&1 || true
  ionice -c 1 -n 0 -p $$ >/dev/null 2>&1 || true
  case $action in
    ""|diagnose) rescue_diagnose ;;
    freeze)
      systemctl freeze apps.slice || die "Could not freeze apps.slice (needs cgroup v2 and systemd 246+)."
      ok "All apps and containers are PAUSED (nothing killed). Look around: sudo server-setup rescue   Resume: sudo server-setup rescue thaw" ;;
    thaw) systemctl thaw apps.slice; ok "Apps resumed." ;;
    stop-apps)
      need_tty
      local go; prompt_yn go "Stop every app service and every Docker container now?" n
      [[ $go == y ]] || exit 0
      systemctl thaw apps.slice 2>/dev/null || true
      systemctl stop 'app-*.service' 2>/dev/null || true
      if command -v docker >/dev/null; then timeout 120 docker ps -q | xargs -r timeout 120 docker stop -t 10 >/dev/null || true; fi
      ok "Apps stopped. Start them again: systemctl start app-<name> / docker start <container>" ;;
    free-space) rescue_free_space ;;
    restore) ballast_ensure; systemctl thaw apps.slice 2>/dev/null || true; ok "Ballast back, apps not frozen." ;;
    kill)
      local pid=${1-}
      [[ $pid =~ ^[0-9]+$ ]] || die "usage: server-setup rescue kill <pid>   (see: server-setup rescue)"
      [[ $(ps -o comm= -p "$pid") != sshd ]] || die "That is sshd - not killed."
      kill -TERM "$pid"; sleep 3; kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
      ok "Process $pid ended." ;;
    *) die "usage: server-setup rescue [diagnose] | freeze | thaw | stop-apps | free-space | restore | kill <pid>" ;;
  esac
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
  # rules this script made carry its comments ('SSH', 'server-setup ...') - only others count
  rules=$(ufw show added 2>/dev/null | grep '^ufw ' | grep -vE "allow ($allowed)/tcp" | grep -vE "comment '(SSH|server-setup|swarm|monitoring)" || true)
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
  info "Nothing is installed beyond hardening unless you list it. Tools: docker node python go nginx"
  info "caddy certbot postgresql postgresql-client redis restic, apt:<package> (later: server-setup tools install)."
  prompt NEW_TOOLS "Tools to install now (space-separated, empty = none)" "" valid_tool_list
  prompt_yn DOKPLOY_NODE "Prepare this server as a remote server for a Dokploy panel (Docker Swarm, Traefik, build tools)?" "$DOKPLOY_NODE"
  if [[ $DOKPLOY_NODE == y ]]; then dokploy_prompt; fi
  monitor_prompt

  step "Plan"
  info "OS:                  $OS_ID $OS_VERSION ($OS_CODENAME, $OS_ARCH)"
  info "Admin (sudo):        $ADMIN_USER${DEPLOY_USER:+   Deploy (no sudo): $DEPLOY_USER}"
  info "SSH:                 ports $SSH_PORTS, keys only, no root login${SSH_ALLOW:+, only from $SSH_ALLOW}"
  info "Firewall:            SSH${OPEN_PORTS:+ + $OPEN_PORTS} inbound, everything else blocked"
  info "Hostname/timezone:   $NEW_HOSTNAME / $TIMEZONE"
  info "Sources:             direct first, mirror $(mirror_base) as fallback${NTP_SERVERS:+; NTP $NTP_SERVERS}"
  info "Reboots:             $([[ $AUTO_REBOOT == y ]] && echo "automatic at $REBOOT_TIME when needed" || echo 'never automatic')"
  info "Extras:              auditd $AUDITD, Lynis $LYNIS${PRO_TOKEN:+, Ubuntu Pro + Livepatch}"
  info "Tools:               ${NEW_TOOLS:-(none - hardening only)}"
  info "Dokploy node:        $DOKPLOY_NODE${DOKPLOY_PANEL_IP:+ (panel $DOKPLOY_PANEL_IP)}"
  info "Monitoring:          $MONITOR$([[ $MONITOR == external ]] && echo " -> $MONITOR_METRICS_URL")$([[ $MONITOR == hub ]] && echo " (agents push to https://$MONITOR_HUB_ADDR:$HUB_PORT)")"
}
valid_tool_list() {
  local t
  for t in $1; do
    case $t in
      docker|node|python|go|nginx|caddy|certbot|postgresql|postgresql-client|redis|restic) ;;
      apt:*) [[ ${t#apt:} =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { warn "'$t' is not apt:<package>."; return 1; } ;;
      *) warn "Unknown tool '$t'."; return 1 ;;
    esac
  done
  return 0
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
  UFW_RESET=n   # here in the parent shell: later steps re-apply the firewall without resetting it
  try_step "fail2ban" step_fail2ban
  try_step "Kernel and system hardening" apply_hardening
  try_step "Long-uptime tuning (limits, network, swap, zswap)" apply_uptime_tuning
  try_step "Staying reachable under pressure (app slice, protected SSH, OOM guard, ballast)" apply_pressure_guard
  try_step "Logs (journal, logrotate)" apply_logs
  try_step "Automatic security updates" apply_auto_updates
  if [[ -n $PRO_TOKEN ]]; then try_step "Ubuntu Pro and Livepatch" apply_ubuntu_pro; fi
  if [[ $AUDITD == y ]]; then try_step "auditd" apply_auditd; fi
  local t
  for t in $NEW_TOOLS; do try_step "Tool: $t" install_tool "$t"; done
  if [[ $DOKPLOY_NODE == y ]]; then try_step "Dokploy node (Docker Swarm, Traefik image, build tools, panel user)" dokploy_prepare; fi
  if [[ $MONITOR != none ]]; then try_step "Monitoring ($MONITOR)" monitor_apply; fi
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
        ufw route delete allow proto "${spec#*/}" from any to any port "${spec%/*}" >>"$LOG_FILE" 2>&1 || true
      done
      save_config
      if os_installed docker-ce; then apply_ufw_docker; fi
      ok "Open to everyone now: ${OPEN_PORTS:-(nothing but SSH)}" ;;
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
  info "pressure (10 s): $(psi cpu)$(psi memory)$(psi io)$([[ $(systemctl show apps.slice -p FreezerState --value 2>/dev/null) == frozen ]] && echo ' - APPS FROZEN (rescue thaw)')"
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
  if [[ $MONITOR != none ]]; then step "Monitoring"; cmd_monitor status; fi
  if [[ $DOKPLOY_NODE == y ]]; then step "Dokploy node"; cmd_dokploy_node status; fi
  if [[ -s $FLEET_HOSTS ]]; then step "Fleet"; info "Manager of $(grep -cvE '^[[:space:]]*(#|$)' "$FLEET_HOSTS") server(s): server-setup fleet status"; fi
  if [[ -n $FLEET_MANAGER ]]; then step "Fleet"; info "Managed by the fleet manager at $FLEET_MANAGER (status and updates only)."; fi
  [[ -n $TOOLS ]] && { step "Tools"; info "$TOOLS"; }
  return 0
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

  tools list | install <tool>... [--version V] [--prefix DIR] [--sha256 H] | remove <tool>...
                               Opt-in tools: docker, node, python, go, nginx, caddy, certbot,
                               postgresql, redis, restic, apt:<pkg>, url:<tarball> - each
                               downloaded directly or through the mirror.
  apps list | add <name> --exec CMD [--port N] | remove <name>
                               An app as a sandboxed systemd service with its own user (/srv/<name>).
  backup init|run|status|list  Daily restic backups (local disk, SFTP, S3/MinIO).
  dokploy-node prepare|status|sync [<dokploy-version>]
                               Make this server a remote server of a Dokploy panel elsewhere: every
                               internet-dependent step of the panel's "Setup Server" is done here
                               ahead of time (through the mirror when needed). sync: match a newer
                               panel's Traefik/nixpacks/railpack/pack versions.
  monitor status|setup|apply|join <hub>|move-to <hub>|token|alerts
  fleet init | add <name> <host> [--port P] | remove <name> | list | status [names]
        | show <name> | update [--all] [names]
                               Manage many servers from this one (usually the monitoring hub).
  fleet join "<manager key>" --from <manager IP>
                               On each managed server: the manager's key may only run the fleet
                               agent (status and updates), only from the manager's address.
                               Grafana Alloy agent on every server; the stack (VictoriaMetrics,
                               Loki, Grafana, Alertmanager, Uptime Kuma) here (local), as a hub
                               for many servers, or an existing one (external). move-to: a
                               single server grows into a hub setup, with its history.

  rescue [diagnose] | freeze | thaw | stop-apps | free-space | restore | kill <pid>
                               When the server is under pressure (full disk, RAM or CPU): what is
                               eating it; pause every app at once (freeze, nothing killed) to get
                               control back; free the disk ballast + caches; stop or kill apps.
                               SSH and admin sessions keep priority all the time (apps.slice).

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
  # read-only requests: no lock, no report rewrite, and a running setup's notes and
  # credential list are left alone
  case $cmd in
    fleet-agent) cmd_fleet_agent; return 0 ;;
    status) cmd_status; return 0 ;;
    rescue) cmd_rescue "$@"; return 0 ;;
  esac
  case $cmd in
    fleet) [[ ${1-} == join ]] && { exec 9>"$STATE_DIR/.lock"; flock -n 9 || die "Another server-setup run is still going."; } ;;
      # the manager's fleet commands work on OTHER servers: holding this server's lock would
      # deadlock when the manager is also a member of its own fleet (its agent waits for it)
    *)
      exec 9>"$STATE_DIR/.lock"
      flock -n 9 || die "Another server-setup run is still going. If it runs in tmux: sudo tmux attach -t server-setup"
      ;;
  esac
  # only commands that change something rewrite the report (not list/show/status/test views)
  case $cmd in
    setup|status|help|report) ;;
    *) case ${1-} in ""|list|show|status|test|token) [[ $cmd == firewall || $cmd == users || $cmd == tools || $cmd == apps || $cmd == fleet || $cmd == mirror || $cmd == monitor || $cmd == backup || $cmd == dokploy-node ]] || REFRESH_FOR="$cmd $*" ;;
         *) REFRESH_FOR="$cmd $*" ;; esac ;;
  esac
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
    tools)    cmd_tools "$@" ;;
    apps)     cmd_apps "$@" ;;
    backup)   cmd_backup "$@" ;;
    monitor)  cmd_monitor "$@" ;;
    dokploy-node) cmd_dokploy_node "$@" ;;
    fleet)    cmd_fleet "$@" ;;
    fleet-agent) cmd_fleet_agent ;;
    confirm)  ssh_change_pending || die "No SSH change is pending."; ssh_finalize; ok "SSH change kept (ports $SSH_PORTS)." ;;
    *) usage >&2; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
