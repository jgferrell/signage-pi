#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/var/lib/signage/state/install.state"
SSH_PASSWORD_AUTH_DROPIN="/etc/ssh/sshd_config.d/99-signage-password-auth.conf"
CA_CERT_PATH="/usr/local/share/ca-certificates/signage-slides-ca.crt"
SIGNAGE_USER="signage-user"
PACKAGES_INSTALLED_BY_SIGNAGE=""
SIGNAGE_USER_CREATED="1"
SSH_PASSWORD_AUTH_DROPIN_CREATED="0"
CA_CERT_INSTALLED="0"
RESTART_LIGHTDM_AFTER_UNINSTALL="0"
PURGE_MODE="0"
KNOWN_INSTALL="0"
MANUAL_CONFIRM_STEPS="0"

log() { printf '[uninstall-signage] %s\n' "$*"; }
die() { printf '[uninstall-signage] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: sudo ./uninstall-signage.sh [--purge]

Options:
  --purge   Remove all signage-owned config, cache, state, logs, and installer-created files.
  -h, --help
            Show this help.

When install state is missing, each cleanup step is confirmed individually:
  y = run the described step
  n = skip the described step
  a = abort uninstall immediately
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) PURGE_MODE="1" ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

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
    KNOWN_INSTALL="1"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    SIGNAGE_USER="${SIGNAGE_USER:-signage-user}"
    PACKAGES_INSTALLED_BY_SIGNAGE="${PACKAGES_INSTALLED_BY_SIGNAGE:-}"
    SIGNAGE_USER_CREATED="${SIGNAGE_USER_CREATED:-1}"
    SSH_PASSWORD_AUTH_DROPIN_CREATED="${SSH_PASSWORD_AUTH_DROPIN_CREATED:-0}"
    CA_CERT_INSTALLED="${CA_CERT_INSTALLED:-0}"
    CA_CERT_PATH="${CA_CERT_PATH:-/usr/local/share/ca-certificates/signage-slides-ca.crt}"
  else
    MANUAL_CONFIRM_STEPS="1"
    log "No install state file found. Signage may not be installed, or the install may be partial/corrupt."
    log "Each cleanup step will require confirmation. Enter y to run, n to skip, or a to abort."
  fi
}

confirm_step() {
  local description="$1"
  local reply=""

  if [[ "${MANUAL_CONFIRM_STEPS}" != "1" ]]; then
    return 0
  fi

  while true; do
    printf '\n[uninstall-signage] Step: %s\n' "${description}"
    read -r -p "Run this step? [y/n/a] " reply
    case "${reply}" in
      y|Y) return 0 ;;
      n|N) log "Skipped: ${description}"; return 1 ;;
      a|A) die "Uninstall aborted by user" ;;
      *) printf 'Enter y, n, or a.\n' ;;
    esac
  done
}

run_step() {
  local description="$1"
  shift
  if confirm_step "${description}"; then
    "$@"
  fi
}

stop_services_and_sessions() {
  log "Stopping signage services and user session"
  systemctl disable --now signage-update.timer >/dev/null 2>&1 || true
  systemctl stop signage-update.service >/dev/null 2>&1 || true
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

remove_ssh_config() {
  log "Removing signage SSH password-authentication drop-in"
  rm -f "${SSH_PASSWORD_AUTH_DROPIN}"

  if command -v sshd >/dev/null 2>&1; then
    sshd -t || die "sshd configuration is invalid after removing ${SSH_PASSWORD_AUTH_DROPIN}"
  elif [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -t || die "sshd configuration is invalid after removing ${SSH_PASSWORD_AUTH_DROPIN}"
  fi

  systemctl reload ssh.service >/dev/null 2>&1 || true
}

remove_ca_certificate() {
  if [[ "${CA_CERT_INSTALLED}" != "1" && ! -e "${CA_CERT_PATH}" ]]; then
    log "No installer-managed CA certificate found."
    return 0
  fi

  log "Removing signage slide-server CA certificate"
  rm -f "${CA_CERT_PATH}"
  update-ca-certificates >/dev/null 2>&1 || true
}

remove_program_files() {
  log "Removing signage program files and systemd units"
  rm -f /etc/systemd/system/signage.service
  rm -f /etc/systemd/system/signage-sync.service
  rm -f /etc/systemd/system/signage-sync.timer
  rm -f /etc/systemd/system/signage-update.service
  rm -f /etc/systemd/system/signage-update.timer
  rm -f /etc/lightdm/lightdm.conf.d/50-signage-autologin.conf
  rm -f /usr/share/wayland-sessions/signage-session.desktop
  rm -f /usr/local/lib/signage/signage-fetch.py
  rmdir /usr/local/lib/signage >/dev/null 2>&1 || true
  rm -f /usr/local/sbin/signage-sync
  rm -f /usr/local/sbin/signage-update
  rm -f /usr/local/sbin/update-signage
  rm -f /usr/local/sbin/signage-kiosk-mode
  rm -f /usr/local/sbin/signage-admin-mode
  rm -f /usr/local/bin/start-signage
  rm -f /usr/local/bin/signage-session
  rm -f /usr/local/bin/signagectl

  systemctl daemon-reload
}

remove_state_for_normal_uninstall() {
  log "Removing installer state while preserving local config/cache"
  rm -f "${STATE_FILE}"
  rm -f /var/lib/signage/state/lightdm.conf.pre-signage
  rm -f /var/lib/signage/state/lightdm.conf.was-missing
  rm -f /var/lib/signage/state/installed-commit
  rm -f /var/lib/signage/state/update.lock
  rmdir /var/lib/signage/state >/dev/null 2>&1 || true
}

purge_config_state_and_cache() {
  log "Purging signage config, cache, state, and logs"
  rm -rf /etc/signage
  rm -rf /var/lib/signage
  rm -rf /var/log/signage
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

  # Development expectation: remove feh. It is the only package the signage runtime
  # unambiguously owns after install.
  packages_to_remove+=(feh)

  local pkg
  for pkg in ${PACKAGES_INSTALLED_BY_SIGNAGE}; do
    case "${pkg}" in
      openssh-server)
        # Do not automatically remove SSH. It may be the current maintenance path.
        continue
        ;;
    esac

    if [[ " ${packages_to_remove[*]} " != *" ${pkg} "* ]]; then
      packages_to_remove+=("${pkg}")
    fi
  done

  if [[ "${#packages_to_remove[@]}" -gt 0 ]]; then
    log "Removing packages: ${packages_to_remove[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  fi

  if [[ " ${PACKAGES_INSTALLED_BY_SIGNAGE} " == *" openssh-server "* ]]; then
    log "Leaving openssh-server installed even though signage installed it; remove it manually if SSH access is no longer needed."
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
  parse_args "$@"
  require_root
  load_state_and_config

  run_step "disable signage services and stop the signage user session" stop_services_and_sessions
  run_step "restore the pre-signage LightDM configuration if a backup exists" restore_lightdm_config
  run_step "remove signage's SSH password-authentication drop-in and reload ssh" remove_ssh_config
  run_step "remove signage's optional slide-server CA certificate and update trust store" remove_ca_certificate
  run_step "remove signage program files, systemd units, and session files" remove_program_files
  run_step "remove the signage-user account if installer state says it was created by signage" remove_user
  run_step "purge feh and other non-SSH packages recorded as installed by signage" remove_packages

  if [[ "${PURGE_MODE}" == "1" ]]; then
    run_step "purge all signage-owned config, cache, state, and logs" purge_config_state_and_cache
  else
    run_step "remove installer state while preserving /etc/signage and /var/lib/signage slideshow cache" remove_state_for_normal_uninstall
  fi

  maybe_restart_lightdm
  if [[ "${PURGE_MODE}" == "1" ]]; then
    log "Purge uninstall complete."
  else
    log "Uninstall complete. Local config/cache may remain; use --purge to remove them."
  fi
}

main "$@"
