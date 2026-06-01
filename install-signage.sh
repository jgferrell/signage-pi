#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_SRC="${PROJECT_DIR}/signage.conf"
STATE_DIR="/var/lib/signage/state"
STATE_FILE="${STATE_DIR}/install.state"

REQUIRED_PACKAGES=(feh ca-certificates python3)

log() { printf '[install-signage] %s\n' "$*"; }
die() { printf '[install-signage] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this installer as root, for example: sudo ./install-signage.sh"
  fi
}

load_config() {
  if [[ ! -f "${CONF_SRC}" ]]; then
    die "Missing ${CONF_SRC}. Copy signage.conf.example to signage.conf and edit SLIDES_URL first."
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

write_state() {
  local packages="$1"
  local user_created="$2"
  install -d -m 0755 "${STATE_DIR}"
  cat > "${STATE_FILE}" <<STATE
# Created by digital-signage install-signage.sh
SIGNAGE_USER="signage-user"
SIGNAGE_SESSION="signage-session"
SIGNAGE_USER_CREATED="${user_created}"
PACKAGES_INSTALLED_BY_SIGNAGE="${packages}"
STATE
  chmod 0644 "${STATE_FILE}"
}

install_packages() {
  local missing=()
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! package_is_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  write_state "${missing[*]}" "0"

  log "Installing required packages: ${REQUIRED_PACKAGES[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}"
}

create_signage_user() {
  if id -u "${SIGNAGE_USER}" >/dev/null 2>&1; then
    die "User ${SIGNAGE_USER} already exists. Remove it or run uninstall-signage.sh before reinstalling."
  fi

  log "Creating user ${SIGNAGE_USER}"
  useradd --create-home --shell /bin/bash --user-group "${SIGNAGE_USER}"
  passwd -l "${SIGNAGE_USER}" >/dev/null 2>&1 || true

  local group
  for group in video audio render input tty; do
    if getent group "${group}" >/dev/null 2>&1; then
      usermod -aG "${group}" "${SIGNAGE_USER}"
    fi
  done
  if getent group autologin >/dev/null 2>&1; then
    usermod -aG autologin "${SIGNAGE_USER}"
  fi

  # Preserve the package state already written by install_packages.
  local packages=""
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    packages="${PACKAGES_INSTALLED_BY_SIGNAGE:-}"
  fi
  write_state "${packages}" "1"
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

  install -m 0644 "${CONF_SRC}" /etc/signage/signage.conf
  install -m 0755 "${PROJECT_DIR}/files/lib/signage-fetch.py" /usr/local/lib/signage/signage-fetch.py
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-sync" /usr/local/sbin/signage-sync
  install -m 0755 "${PROJECT_DIR}/files/bin/start-signage" /usr/local/bin/start-signage
  install -m 0755 "${PROJECT_DIR}/files/bin/signage-session" /usr/local/bin/signage-session
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.service" /etc/systemd/system/signage-sync.service
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.timer" /etc/systemd/system/signage-sync.timer
  install -m 0644 "${PROJECT_DIR}/files/wayland-sessions/signage-session.desktop" /usr/share/wayland-sessions/signage-session.desktop

  cat > /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf <<'LIGHTDM'
[Seat:*]
autologin-user=signage-user
autologin-user-timeout=0
user-session=signage-session
autologin-session=signage-session
LIGHTDM
  chmod 0644 /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf

  chown -R root:root /etc/signage /usr/local/lib/signage /var/lib/signage
  chmod 0755 /var/lib/signage /var/lib/signage/releases /var/lib/signage/staging /var/lib/signage/state
}

run_initial_sync() {
  log "Running initial slide download and validation"
  if ! /usr/local/sbin/signage-sync --initial --no-restart; then
    die "Initial sync failed. The web directory must be reachable and contain at least one feh-readable image. Run ./uninstall-signage.sh to remove partial install state."
  fi
}

enable_services() {
  log "Enabling signage sync timer"
  systemctl daemon-reload
  systemctl enable --now signage-sync.timer

  if [[ "${RESTART_LIGHTDM_AFTER_INSTALL}" == "1" ]]; then
    log "Restarting LightDM because RESTART_LIGHTDM_AFTER_INSTALL=1"
    systemctl restart lightdm
  else
    log "LightDM was not restarted. Reboot or restart LightDM when ready to enter signage-session."
  fi
}

main() {
  require_root
  load_config

  if [[ -f "${STATE_FILE}" ]]; then
    die "Existing installer state found at ${STATE_FILE}. Run ./uninstall-signage.sh before reinstalling."
  fi

  install_packages
  create_signage_user
  install_files
  run_initial_sync
  enable_services

  log "Install complete. Current local slideshow: /var/lib/signage/current"
}

main "$@"
