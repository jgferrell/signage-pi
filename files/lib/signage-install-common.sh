# Shared install/update helpers for digital-signage scripts.
# This file is sourced by install-signage.sh and update-signage.sh.

as_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

require_project_file() {
  [[ -f "${PROJECT_DIR}/$1" ]] || die "Missing required repo file: $1"
}

load_shared_defaults() {
  require_project_file "files/lib/signage-defaults.sh"
  # shellcheck source=files/lib/signage-defaults.sh
  source "${PROJECT_DIR}/files/lib/signage-defaults.sh"
}

apply_config_defaults() {
  SIGNAGE_USER="${SIGNAGE_USER_DEFAULT}"
  SIGNAGE_SESSION="${SIGNAGE_SESSION_DEFAULT}"
  SLIDES_CA_CERT_URL="${SLIDES_CA_CERT_URL:-}"
  SLIDESHOW_DELAY_SECONDS="${SLIDESHOW_DELAY_SECONDS:-${SLIDESHOW_DELAY_SECONDS_DEFAULT}}"
  RESTART_THROTTLE_SECONDS="${RESTART_THROTTLE_SECONDS:-${RESTART_THROTTLE_SECONDS_DEFAULT}}"
  HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-${HTTP_TIMEOUT_SECONDS_DEFAULT}}"
  KEEP_RELEASES="${KEEP_RELEASES:-${KEEP_RELEASES_DEFAULT}}"
  IMAGE_EXTENSIONS="${IMAGE_EXTENSIONS:-${IMAGE_EXTENSIONS_DEFAULT}}"
  SIGNAGE_AUTO_UPDATE_ENABLED="${SIGNAGE_AUTO_UPDATE_ENABLED:-${SIGNAGE_AUTO_UPDATE_ENABLED_DEFAULT}}"
  SIGNAGE_AUTO_UPDATE_ONCALENDAR="${SIGNAGE_AUTO_UPDATE_ONCALENDAR:-${SIGNAGE_AUTO_UPDATE_ONCALENDAR_DEFAULT}}"
  SIGNAGE_AUTO_UPDATE_REPO_URL="${SIGNAGE_AUTO_UPDATE_REPO_URL:-}"
  SIGNAGE_AUTO_UPDATE_REF="${SIGNAGE_AUTO_UPDATE_REF:-${SIGNAGE_AUTO_UPDATE_REF_DEFAULT}}"
  SIGNAGE_CONFIG_PRESERVE_KEYS="${SIGNAGE_CONFIG_PRESERVE_KEYS:-${SIGNAGE_CONFIG_PRESERVE_KEYS_DEFAULT}}"
  CA_CERT_PATH="${CA_CERT_PATH:-${CA_CERT_PATH_DEFAULT}}"
}

validate_runtime_numbers() {
  is_uint "${SLIDESHOW_DELAY_SECONDS}" || die "SLIDESHOW_DELAY_SECONDS must be a non-negative integer"
  is_uint "${RESTART_THROTTLE_SECONDS}" || die "RESTART_THROTTLE_SECONDS must be a non-negative integer"
  is_uint "${HTTP_TIMEOUT_SECONDS}" || die "HTTP_TIMEOUT_SECONDS must be a non-negative integer"
  is_uint "${KEEP_RELEASES}" || die "KEEP_RELEASES must be a non-negative integer"
}

validate_update_config() {
  [[ -n "${SIGNAGE_AUTO_UPDATE_REF:-}" ]] || die "SIGNAGE_AUTO_UPDATE_REF must not be empty"

  if as_bool "${SIGNAGE_AUTO_UPDATE_ENABLED:-false}" && [[ -z "${SIGNAGE_AUTO_UPDATE_REPO_URL:-}" ]]; then
    die "SIGNAGE_AUTO_UPDATE_ENABLED is true but SIGNAGE_AUTO_UPDATE_REPO_URL is empty"
  fi
}

preflight_display_stack() {
  if ! command -v lightdm >/dev/null 2>&1 && [[ ! -x /usr/sbin/lightdm ]]; then
    die "LightDM is required but was not found. Use Raspberry Pi OS Desktop with LightDM."
  fi

  if ! command -v labwc-pi >/dev/null 2>&1 && ! command -v labwc >/dev/null 2>&1; then
    die "No supported Wayland compositor found. Expected labwc-pi or labwc. Use Raspberry Pi OS Desktop with Wayland support."
  fi
}

write_update_timer() {
  cat > /etc/systemd/system/signage-update.timer <<EOF_TIMER
[Unit]
Description=Run Digital Signage software update check
Documentation=man:systemd.timer(5)

[Timer]
OnCalendar=${SIGNAGE_AUTO_UPDATE_ONCALENDAR}
Persistent=true
Unit=signage-update.service

[Install]
WantedBy=timers.target
EOF_TIMER
  chmod 0644 /etc/systemd/system/signage-update.timer
}

managed_dirs() {
  cat <<'EOF_DIRS'
/etc/signage
/usr/local/lib/signage
/usr/local/bin
/usr/local/sbin
/etc/systemd/system
/usr/share/wayland-sessions
/var/lib/signage/releases
/var/lib/signage/staging
/var/lib/signage/state
/var/lib/signage/update
/var/log/signage
EOF_DIRS
}

managed_files() {
  cat <<'EOF_FILES'
0755 files/lib/signage-fetch.py /usr/local/lib/signage/signage-fetch.py
0644 files/lib/signage-defaults.sh /usr/local/lib/signage/signage-defaults.sh
0644 files/lib/signage-install-common.sh /usr/local/lib/signage/signage-install-common.sh
0755 files/sbin/signage-install-ca /usr/local/sbin/signage-install-ca
0755 files/sbin/signage-mode /usr/local/sbin/signage-mode
0755 files/sbin/signage-sync /usr/local/sbin/signage-sync
0755 files/sbin/signage-update /usr/local/sbin/signage-update
0755 files/bin/start-signage /usr/local/bin/start-signage
0755 files/bin/signage-session /usr/local/bin/signage-session
0755 files/bin/signagectl /usr/local/bin/signagectl
0644 files/systemd/signage.service /etc/systemd/system/signage.service
0644 files/systemd/signage-sync.service /etc/systemd/system/signage-sync.service
0644 files/systemd/signage-sync.timer /etc/systemd/system/signage-sync.timer
0644 files/systemd/signage-update.service /etc/systemd/system/signage-update.service
0644 files/wayland-sessions/signage-session.desktop /usr/share/wayland-sessions/signage-session.desktop
EOF_FILES
}

install_managed_files() {
  local dir mode src dest

  while IFS= read -r dir; do
    [[ -n "${dir}" ]] || continue
    install -d -m 0755 "${dir}"
  done < <(managed_dirs)

  while read -r mode src dest; do
    [[ -n "${mode:-}" ]] || continue
    require_project_file "${src}"
    install -m "${mode}" "${PROJECT_DIR}/${src}" "${dest}"
  done < <(managed_files)

  chown -R root:root /etc/signage /usr/local/lib/signage /var/lib/signage /var/log/signage
  chmod 0755 /var/lib/signage /var/lib/signage/releases /var/lib/signage/staging /var/lib/signage/state /var/lib/signage/update /var/log/signage
}
