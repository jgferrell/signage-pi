#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/var/lib/signage/state/install.state"
SIGNAGE_USER="signage-user"
PACKAGES_INSTALLED_BY_SIGNAGE=""
SIGNAGE_USER_CREATED="1"
RESTART_LIGHTDM_AFTER_UNINSTALL="0"

log() { printf '[uninstall-signage] %s\n' "$*"; }
die() { printf '[uninstall-signage] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this uninstaller as root, for example: sudo ./uninstall-signage.sh"
  fi
}

load_state_and_config() {
  if [[ -f /etc/signage/signage.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/signage/signage.conf || true
    SIGNAGE_USER="${SIGNAGE_USER:-signage-user}"
    RESTART_LIGHTDM_AFTER_UNINSTALL="${RESTART_LIGHTDM_AFTER_UNINSTALL:-0}"
  fi

  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    SIGNAGE_USER="${SIGNAGE_USER:-signage-user}"
    PACKAGES_INSTALLED_BY_SIGNAGE="${PACKAGES_INSTALLED_BY_SIGNAGE:-}"
    SIGNAGE_USER_CREATED="${SIGNAGE_USER_CREATED:-1}"
  else
    log "No install state file found. Proceeding with best-effort cleanup."
  fi
}

stop_services_and_sessions() {
  log "Stopping signage services and user session"
  systemctl disable --now signage-sync.timer >/dev/null 2>&1 || true
  systemctl stop signage-sync.service >/dev/null 2>&1 || true
  systemctl disable signage.service >/dev/null 2>&1 || true
  systemctl stop signage.service >/dev/null 2>&1 || true

  if id -u "${SIGNAGE_USER}" >/dev/null 2>&1; then
    loginctl terminate-user "${SIGNAGE_USER}" >/dev/null 2>&1 || true
    pkill -u "${SIGNAGE_USER}" >/dev/null 2>&1 || true
  fi
}

restore_lightdm_config() {
  log "Restoring LightDM configuration"

  local backup_file="/var/lib/signage/state/lightdm.conf.pre-signage"
  local missing_marker="/var/lib/signage/state/lightdm.conf.was-missing"

  # Remove stale drop-in from earlier development iterations.
  rm -f /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf

  if [[ -f "${backup_file}" ]]; then
    cp -a "${backup_file}" /etc/lightdm/lightdm.conf
  elif [[ -f "${missing_marker}" ]]; then
    rm -f /etc/lightdm/lightdm.conf
  else
    log "No LightDM backup marker found; leaving /etc/lightdm/lightdm.conf unchanged."
  fi
}

remove_files() {
  log "Removing signage files"
  rm -f /etc/systemd/system/signage.service
  rm -f /etc/systemd/system/signage-sync.service
  rm -f /etc/systemd/system/signage-sync.timer
  rm -f /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf
  rm -f /usr/share/wayland-sessions/signage-session.desktop
  rm -f /usr/local/lib/signage/signage-fetch.py
  rmdir /usr/local/lib/signage >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/signage-sync
  rm -f /usr/local/sbin/signage-kiosk-mode
  rm -f /usr/local/sbin/signage-admin-mode
  rm -f /usr/local/bin/start-signage
  rm -f /usr/local/bin/signage-session
  rm -rf /etc/signage
  rm -rf /var/lib/signage

  systemctl daemon-reload
}

remove_user() {
  if [[ "${SIGNAGE_USER_CREATED}" != "1" ]]; then
    log "Installer state says ${SIGNAGE_USER} was not created by installer; leaving user in place."
    return 0
  fi

  if id -u "${SIGNAGE_USER}" >/dev/null 2>&1; then
    log "Removing user ${SIGNAGE_USER}"
    userdel -r "${SIGNAGE_USER}" >/dev/null 2>&1 || userdel "${SIGNAGE_USER}" >/dev/null 2>&1 || true
  fi
}

remove_packages() {
  local packages_to_remove=()

  # Development expectation: remove feh. Also remove other packages only if the installer recorded
  # that they were not present before install.
  packages_to_remove+=(feh)

  local pkg
  for pkg in ${PACKAGES_INSTALLED_BY_SIGNAGE}; do
    if [[ " ${packages_to_remove[*]} " != *" ${pkg} "* ]]; then
      packages_to_remove+=("${pkg}")
    fi
  done

  if [[ "${#packages_to_remove[@]}" -gt 0 ]]; then
    log "Removing packages: ${packages_to_remove[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  fi
}

maybe_restart_lightdm() {
  if [[ "${RESTART_LIGHTDM_AFTER_UNINSTALL}" == "1" ]]; then
    log "Restarting LightDM because RESTART_LIGHTDM_AFTER_UNINSTALL=1"
    systemctl restart lightdm || true
  else
    log "LightDM was not restarted. Reboot or restart LightDM manually if needed."
  fi
}

main() {
  require_root
  load_state_and_config
  stop_services_and_sessions
  restore_lightdm_config
  remove_files
  remove_user
  remove_packages
  maybe_restart_lightdm
  log "Uninstall complete."
}

main "$@"
