#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${PROJECT_DIR}/signage.conf"
STATE_DIR="/var/lib/signage/state"
STATE_FILE="${STATE_DIR}/install.state"
SSH_PASSWORD_AUTH_DROPIN="/etc/ssh/sshd_config.d/99-signage-password-auth.conf"
REPAIR_MODE="0"

REQUIRED_PACKAGES=(feh ca-certificates python3 openssh-server)

SIGNAGE_USER="signage-user"
SIGNAGE_SESSION="signage-session"
RESTART_LIGHTDM_AFTER_INSTALL="0"
PACKAGES_INSTALLED_BY_SIGNAGE=""
SIGNAGE_USER_CREATED="0"
SSH_PASSWORD_AUTH_DROPIN_CREATED="0"

log() { printf '[install-signage] %s\n' "$*"; }
die() { printf '[install-signage] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: sudo ./install-signage.sh [--repair]

Options:
  --repair   Reinstall/repair program files and service configuration when a
             previous complete or partial install is detected.
  -h, --help Show this help.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repair) REPAIR_MODE="1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this installer as root, for example: sudo ./install-signage.sh"
  fi
}

load_existing_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    SIGNAGE_USER="${SIGNAGE_USER:-signage-user}"
    SIGNAGE_SESSION="${SIGNAGE_SESSION:-signage-session}"
    PACKAGES_INSTALLED_BY_SIGNAGE="${PACKAGES_INSTALLED_BY_SIGNAGE:-}"
    SIGNAGE_USER_CREATED="${SIGNAGE_USER_CREATED:-0}"
    SSH_PASSWORD_AUTH_DROPIN_CREATED="${SSH_PASSWORD_AUTH_DROPIN_CREATED:-0}"
  fi
}

load_config() {
  if [[ ! -f "${CONF_SRC}" ]]; then
    if [[ "${REPAIR_MODE}" == "1" && -f /etc/signage/signage.conf ]]; then
      log "Using existing /etc/signage/signage.conf because ./signage.conf is missing and --repair was requested"
      CONF_SRC="/etc/signage/signage.conf"
    else
      die "Missing ${CONF_SRC}. Copy signage.conf.example to signage.conf and edit SLIDES_URL first."
    fi
  fi

  # shellcheck source=/dev/null
  source "${CONF_SRC}"

  : "${SLIDES_URL:?SLIDES_URL must be set in signage.conf}"
  SIGNAGE_USER="${SIGNAGE_USER:-signage-user}"
  SIGNAGE_SESSION="${SIGNAGE_SESSION:-signage-session}"
  RESTART_LIGHTDM_AFTER_INSTALL="${RESTART_LIGHTDM_AFTER_INSTALL:-0}"

  if [[ "${SIGNAGE_USER}" != "signage-user" ]]; then
    die "This installer currently requires SIGNAGE_USER=\"signage-user\"."
  fi
  if [[ "${SIGNAGE_SESSION}" != "signage-session" ]]; then
    die "This installer currently requires SIGNAGE_SESSION=\"signage-session\"."
  fi
}

package_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

append_unique_package() {
  local pkg="$1"
  if [[ " ${PACKAGES_INSTALLED_BY_SIGNAGE} " != *" ${pkg} "* ]]; then
    PACKAGES_INSTALLED_BY_SIGNAGE="${PACKAGES_INSTALLED_BY_SIGNAGE:+${PACKAGES_INSTALLED_BY_SIGNAGE} }${pkg}"
  fi
}

write_state() {
  install -d -m 0755 "${STATE_DIR}"
  cat > "${STATE_FILE}" <<STATE
# Created by digital-signage install-signage.sh
SIGNAGE_INSTALLED="1"
INSTALL_VERSION="2026-06-01"
SIGNAGE_USER="${SIGNAGE_USER}"
SIGNAGE_SESSION="${SIGNAGE_SESSION}"
SIGNAGE_USER_CREATED="${SIGNAGE_USER_CREATED}"
PACKAGES_INSTALLED_BY_SIGNAGE="${PACKAGES_INSTALLED_BY_SIGNAGE}"
SSH_PASSWORD_AUTH_DROPIN_CREATED="${SSH_PASSWORD_AUTH_DROPIN_CREATED}"
STATE
  chmod 0644 "${STATE_FILE}"
}

find_install_footprints() {
  local paths=(
    "${STATE_FILE}"
    "/etc/signage/signage.conf"
    "/var/lib/signage"
    "/var/log/signage"
    "/usr/local/lib/signage/signage-fetch.py"
    "/usr/local/sbin/signage-sync"
    "/usr/local/sbin/signage-kiosk-mode"
    "/usr/local/sbin/signage-admin-mode"
    "/usr/local/bin/start-signage"
    "/usr/local/bin/signage-session"
    "/etc/systemd/system/signage.service"
    "/etc/systemd/system/signage-sync.service"
    "/etc/systemd/system/signage-sync.timer"
    "/usr/share/wayland-sessions/signage-session.desktop"
    "${SSH_PASSWORD_AUTH_DROPIN}"
  )

  local path
  for path in "${paths[@]}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      printf '%s\n' "${path}"
    fi
  done

  if id -u "${SIGNAGE_USER}" >/dev/null 2>&1; then
    printf 'user:%s\n' "${SIGNAGE_USER}"
  fi
}

refuse_if_existing_install_without_repair() {
  local footprints
  footprints="$(find_install_footprints || true)"

  if [[ -n "${footprints}" && "${REPAIR_MODE}" != "1" ]]; then
    cat >&2 <<EOF2
[install-signage] ERROR: Digital signage appears to be already installed or partially installed.

Detected existing install footprint(s):
${footprints}

Refusing to continue because a normal install could overwrite existing state.
Run this command to repair/reinstall program files and service configuration:

  sudo ./install-signage.sh --repair
EOF2
    exit 1
  fi

  if [[ -n "${footprints}" && "${REPAIR_MODE}" == "1" ]]; then
    log "Existing install footprint detected; continuing because --repair was requested"
  fi
}

install_packages() {
  local missing=()
  local pkg

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! package_is_installed "${pkg}"; then
      missing+=("${pkg}")
      append_unique_package "${pkg}"
    fi
  done

  write_state

  log "Installing required packages: ${REQUIRED_PACKAGES[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}"
}

print_sshd_auth_debug() {
  local sshd_bin="$1"

  printf '[install-signage] Effective sshd auth settings:\n' >&2
  "${sshd_bin}" -T 2>/dev/null | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|usepam|permitrootlogin)[[:space:]]+' >&2 || true

  printf '[install-signage] Configured sshd auth lines:\n' >&2
  grep -RInE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|UsePAM|PermitRootLogin)[[:space:]]+' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null >&2 || true
}

require_sshd_effective_yes() {
  local sshd_bin="$1"
  local key="$2"
  local label="$3"
  local effective_config=""

  effective_config="$("${sshd_bin}" -T 2>/dev/null)"

  if ! awk -v key="${key}" '
    BEGIN { wanted = tolower(key) }
    tolower($1) == wanted && tolower($2) == "yes" { ok = 1 }
    END { exit ok ? 0 : 1 }
  ' <<<"${effective_config}"; then
    print_sshd_auth_debug "${sshd_bin}"
    die "Effective sshd configuration does not permit ${label}"
  fi
}

configure_ssh() {
  log "Ensuring OpenSSH Server is enabled, running, and permits password authentication"

  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > "${SSH_PASSWORD_AUTH_DROPIN}" <<'SSHD_CONFIG'
# Created by digital-signage install-signage.sh.
# The signage installer is run locally, but future maintenance is expected to be done via SSH.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
SSHD_CONFIG
  chmod 0644 "${SSH_PASSWORD_AUTH_DROPIN}"
  SSH_PASSWORD_AUTH_DROPIN_CREATED="1"
  write_state

  local sshd_bin=""
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "${sshd_bin}" && -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  fi
  if [[ -z "${sshd_bin}" ]]; then
    die "sshd was not found after installing openssh-server"
  fi

  "${sshd_bin}" -t
  systemctl enable --now ssh.service
  systemctl reload ssh.service || systemctl restart ssh.service
  systemctl is-enabled --quiet ssh.service || die "ssh.service is not enabled"
  systemctl is-active --quiet ssh.service || die "ssh.service is not running"

  require_sshd_effective_yes "${sshd_bin}" "passwordauthentication" "PasswordAuthentication"
  require_sshd_effective_yes "${sshd_bin}" "kbdinteractiveauthentication" "KbdInteractiveAuthentication"
  require_sshd_effective_yes "${sshd_bin}" "usepam" "UsePAM"
}

create_signage_user() {
  if id -u "${SIGNAGE_USER}" >/dev/null 2>&1; then
    if [[ "${REPAIR_MODE}" == "1" ]]; then
      log "User ${SIGNAGE_USER} already exists; reusing it for --repair"
      write_state
      return 0
    fi
    die "User ${SIGNAGE_USER} already exists. Remove it or run ./install-signage.sh --repair."
  fi

  log "Creating user ${SIGNAGE_USER}"
  useradd --create-home --shell /bin/bash --user-group "${SIGNAGE_USER}"
  passwd -l "${SIGNAGE_USER}" >/dev/null 2>&1 || true
  SIGNAGE_USER_CREATED="1"

  local group
  for group in video audio render input tty; do
    if getent group "${group}" >/dev/null 2>&1; then
      usermod -aG "${group}" "${SIGNAGE_USER}"
    fi
  done
  if getent group autologin >/dev/null 2>&1; then
    usermod -aG autologin "${SIGNAGE_USER}"
  fi

  write_state
}

install_files() {
  log "Installing signage files"

  install -d -m 0755 /etc/signage
  install -d -m 0755 /usr/local/lib/signage
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/systemd/system
  install -d -m 0755 /usr/share/wayland-sessions
  install -d -m 0755 /etc/lightdm/lightdm.conf.d
  install -d -m 0755 /var/lib/signage/releases
  install -d -m 0755 /var/lib/signage/staging
  install -d -m 0755 /var/lib/signage/state
  install -d -m 0755 /var/log/signage

  install -m 0644 "${CONF_SRC}" /etc/signage/signage.conf
  install -m 0755 "${PROJECT_DIR}/files/lib/signage-fetch.py" /usr/local/lib/signage/signage-fetch.py
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-sync" /usr/local/sbin/signage-sync
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-kiosk-mode" /usr/local/sbin/signage-kiosk-mode
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-admin-mode" /usr/local/sbin/signage-admin-mode
  install -m 0755 "${PROJECT_DIR}/files/bin/start-signage" /usr/local/bin/start-signage
  install -m 0755 "${PROJECT_DIR}/files/bin/signage-session" /usr/local/bin/signage-session
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage.service" /etc/systemd/system/signage.service
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.service" /etc/systemd/system/signage-sync.service
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.timer" /etc/systemd/system/signage-sync.timer
  install -m 0644 "${PROJECT_DIR}/files/wayland-sessions/signage-session.desktop" /usr/share/wayland-sessions/signage-session.desktop

  chown -R root:root /etc/signage /usr/local/lib/signage /var/lib/signage /var/log/signage
  chmod 0755 /var/lib/signage /var/lib/signage/releases /var/lib/signage/staging /var/lib/signage/state /var/log/signage
  write_state
}

configure_lightdm() {
  log "Configuring LightDM autologin for signage-user/signage-session"

  local lightdm_conf="/etc/lightdm/lightdm.conf"
  local backup_file="${STATE_DIR}/lightdm.conf.pre-signage"
  local missing_marker="${STATE_DIR}/lightdm.conf.was-missing"

  # Back up the real LightDM configuration file, because Raspberry Pi OS can set
  # autologin-user/user-session there. /etc/lightdm/lightdm.conf is read after
  # many drop-in files, so a drop-in alone may be overridden by the stock config.
  if [[ ! -e "${backup_file}" && ! -e "${missing_marker}" ]]; then
    if [[ -f "${lightdm_conf}" ]]; then
      cp -a "${lightdm_conf}" "${backup_file}"
    else
      : > "${missing_marker}"
    fi
  fi

  /usr/local/sbin/signage-kiosk-mode --no-restart

  # Remove stale copies from earlier development iterations. The canonical
  # installer-owned LightDM change is now the backed-up edit to lightdm.conf.
  rm -f /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf
}

run_initial_sync() {
  log "Running initial slide download and validation"
  if ! /usr/local/sbin/signage-sync --initial --no-restart; then
    die "Initial sync failed. The web directory must be reachable and contain at least one feh-readable image. Run ./uninstall-signage.sh to remove partial install state."
  fi
}

enable_services() {
  log "Enabling signage services"
  systemctl daemon-reload
  systemctl enable signage.service
  systemctl enable --now signage-sync.timer

  if [[ "${RESTART_LIGHTDM_AFTER_INSTALL}" == "1" ]]; then
    log "Starting signage.service because RESTART_LIGHTDM_AFTER_INSTALL=1"
    systemctl start signage.service
  else
    log "signage.service is enabled but not started. Reboot or run: sudo systemctl start signage"
  fi
}

main() {
  parse_args "$@"
  require_root
  load_existing_state
  refuse_if_existing_install_without_repair
  load_config

  install_packages
  configure_ssh
  create_signage_user
  install_files
  configure_lightdm
  run_initial_sync
  enable_services
  write_state

  log "Install complete. Current local slideshow: /var/lib/signage/current"
}

main "$@"
