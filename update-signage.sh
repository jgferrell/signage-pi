#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/signage/signage.conf"
CONFIG_EXAMPLE="${PROJECT_DIR}/signage.conf.example"
STATE_DIR="/var/lib/signage/state"
CA_CERT_PATH="/usr/local/share/ca-certificates/signage-slides-ca.crt"

SIGNAGE_AUTO_UPDATE_ENABLED="false"
SIGNAGE_AUTO_UPDATE_ONCALENDAR="Tue *-*-* 03:00:00"
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
SLIDES_CA_CERT_URL=""
HTTP_TIMEOUT_SECONDS="30"
CA_CERT_INSTALLED="0"

log() { printf '[update-signage] %s\n' "$*"; }
die() { printf '[update-signage] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this updater as root."
  fi
}

as_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

require_project_file() {
  [[ -f "${PROJECT_DIR}/$1" ]] || die "Missing required repo file: $1"
}

load_current_config_defaults() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
  fi

  SIGNAGE_AUTO_UPDATE_ENABLED="${SIGNAGE_AUTO_UPDATE_ENABLED:-false}"
  SIGNAGE_AUTO_UPDATE_ONCALENDAR="${SIGNAGE_AUTO_UPDATE_ONCALENDAR:-Tue *-*-* 03:00:00}"
  SIGNAGE_CONFIG_PRESERVE_KEYS="${SIGNAGE_CONFIG_PRESERVE_KEYS:-SLIDES_URL}"
  SLIDES_CA_CERT_URL="${SLIDES_CA_CERT_URL:-}"
  HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-30}"
}

merge_config() {
  require_project_file "signage.conf.example"
  install -d -m 0755 /etc/signage

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log "No existing ${CONFIG_FILE}; installing repo default config."
    install -m 0644 "${CONFIG_EXAMPLE}" "${CONFIG_FILE}"
    return 0
  fi

  local tmp
  tmp="$(mktemp /etc/signage/signage.conf.XXXXXX)"

  PRESERVE_KEYS="${SIGNAGE_CONFIG_PRESERVE_KEYS}" \
  OLD_CONF="${CONFIG_FILE}" \
  NEW_CONF="${CONFIG_EXAMPLE}" \
  OUT_CONF="${tmp}" \
  python3 <<'PY'
import os
import re
from pathlib import Path

preserve = [key for key in os.environ["PRESERVE_KEYS"].split() if key]
old_conf = Path(os.environ["OLD_CONF"])
new_conf = Path(os.environ["NEW_CONF"])
out_conf = Path(os.environ["OUT_CONF"])
assign_re = re.compile(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)(\s*=.*)$")

old_assignments = {}
for line in old_conf.read_text().splitlines():
    match = assign_re.match(line)
    if match:
        old_assignments[match.group(2)] = line

used = set()
out_lines = []
for line in new_conf.read_text().splitlines():
    match = assign_re.match(line)
    if match and match.group(2) in preserve and match.group(2) in old_assignments:
        key = match.group(2)
        out_lines.append(old_assignments[key])
        used.add(key)
    else:
        out_lines.append(line)

append_lines = []
for key in preserve:
    if key in old_assignments and key not in used:
        append_lines.append(old_assignments[key])

if append_lines:
    if out_lines and out_lines[-1] != "":
        out_lines.append("")
    out_lines.append("# Preserved local values not present in signage.conf.example.")
    out_lines.extend(append_lines)

out_conf.write_text("\n".join(out_lines) + "\n")
PY

  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${CONFIG_FILE}"
}

reload_config_after_merge() {
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  SIGNAGE_AUTO_UPDATE_ENABLED="${SIGNAGE_AUTO_UPDATE_ENABLED:-false}"
  SIGNAGE_AUTO_UPDATE_ONCALENDAR="${SIGNAGE_AUTO_UPDATE_ONCALENDAR:-Tue *-*-* 03:00:00}"
  SLIDES_CA_CERT_URL="${SLIDES_CA_CERT_URL:-}"
  HTTP_TIMEOUT_SECONDS="${HTTP_TIMEOUT_SECONDS:-30}"
}

install_files() {
  log "Updating managed signage files"

  install -d -m 0755 /usr/local/lib/signage
  install -d -m 0755 /usr/local/bin
  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/systemd/system
  install -d -m 0755 /usr/share/wayland-sessions
  install -d -m 0755 /var/lib/signage/releases
  install -d -m 0755 /var/lib/signage/staging
  install -d -m 0755 /var/lib/signage/state
  install -d -m 0755 /var/lib/signage/update
  install -d -m 0755 /var/log/signage

  require_project_file "files/lib/signage-fetch.py"
  require_project_file "files/sbin/signage-sync"
  require_project_file "files/sbin/signage-kiosk-mode"
  require_project_file "files/sbin/signage-admin-mode"
  require_project_file "files/sbin/signage-update"
  require_project_file "files/bin/start-signage"
  require_project_file "files/bin/signage-session"
  require_project_file "files/bin/signagectl"
  require_project_file "files/systemd/signage.service"
  require_project_file "files/systemd/signage-sync.service"
  require_project_file "files/systemd/signage-sync.timer"
  require_project_file "files/systemd/signage-update.service"
  require_project_file "files/wayland-sessions/signage-session.desktop"

  install -m 0755 "${PROJECT_DIR}/files/lib/signage-fetch.py" /usr/local/lib/signage/signage-fetch.py
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-sync" /usr/local/sbin/signage-sync
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-kiosk-mode" /usr/local/sbin/signage-kiosk-mode
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-admin-mode" /usr/local/sbin/signage-admin-mode
  install -m 0755 "${PROJECT_DIR}/files/sbin/signage-update" /usr/local/sbin/signage-update
  install -m 0755 "${PROJECT_DIR}/update-signage.sh" /usr/local/sbin/update-signage
  install -m 0755 "${PROJECT_DIR}/files/bin/start-signage" /usr/local/bin/start-signage
  install -m 0755 "${PROJECT_DIR}/files/bin/signage-session" /usr/local/bin/signage-session
  install -m 0755 "${PROJECT_DIR}/files/bin/signagectl" /usr/local/bin/signagectl
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage.service" /etc/systemd/system/signage.service
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.service" /etc/systemd/system/signage-sync.service
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-sync.timer" /etc/systemd/system/signage-sync.timer
  install -m 0644 "${PROJECT_DIR}/files/systemd/signage-update.service" /etc/systemd/system/signage-update.service
  install -m 0644 "${PROJECT_DIR}/files/wayland-sessions/signage-session.desktop" /usr/share/wayland-sessions/signage-session.desktop

  chown -R root:root /etc/signage /usr/local/lib/signage /var/lib/signage /var/log/signage
  chmod 0755 /var/lib/signage /var/lib/signage/releases /var/lib/signage/staging /var/lib/signage/state /var/lib/signage/update /var/log/signage
}

install_ca_certificate_if_configured() {
  if [[ -z "${SLIDES_CA_CERT_URL}" ]]; then
    log "No SLIDES_CA_CERT_URL configured; skipping optional CA certificate update."
    return 0
  fi

  log "Updating optional slide-server CA certificate from ${SLIDES_CA_CERT_URL}"
  install -d -m 0755 "$(dirname "${CA_CERT_PATH}")"

  local tmp
  tmp="$(mktemp)"
  if ! python3 - "${SLIDES_CA_CERT_URL}" "${tmp}" "${HTTP_TIMEOUT_SECONDS}" <<'PY'
import sys
import urllib.request
import urllib.error

url, dest, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
req = urllib.request.Request(url, headers={"User-Agent": "digital-signage-update/0.1"})
try:
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = response.read()
except urllib.error.HTTPError as exc:
    print(f"HTTP error {exc.code} {exc.reason} while downloading CA certificate {url}", file=sys.stderr)
    raise SystemExit(1)
except urllib.error.URLError as exc:
    print(f"URL error while downloading CA certificate {url}: {exc.reason}", file=sys.stderr)
    raise SystemExit(1)

if not data:
    print(f"CA certificate download was empty: {url}", file=sys.stderr)
    raise SystemExit(1)

with open(dest, "wb") as fh:
    fh.write(data)
PY
  then
    rm -f "${tmp}"
    die "Failed to download CA certificate from SLIDES_CA_CERT_URL=${SLIDES_CA_CERT_URL}"
  fi

  if ! grep -q 'BEGIN CERTIFICATE' "${tmp}"; then
    rm -f "${tmp}"
    die "Downloaded CA certificate must be PEM format and contain BEGIN CERTIFICATE"
  fi

  install -m 0644 "${tmp}" "${CA_CERT_PATH}"
  rm -f "${tmp}"
  update-ca-certificates
  CA_CERT_INSTALLED="1"
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

configure_services() {
  log "Reloading systemd and applying timer state"
  write_update_timer
  systemctl daemon-reload

  systemctl enable signage.service >/dev/null 2>&1 || true
  systemctl enable --now signage-sync.timer >/dev/null 2>&1 || true

  if as_bool "${SIGNAGE_AUTO_UPDATE_ENABLED}"; then
    systemctl enable --now signage-update.timer
  else
    systemctl disable --now signage-update.timer >/dev/null 2>&1 || true
  fi

  if systemctl is-active --quiet signage.service; then
    systemctl restart signage.service
  fi
}

write_state_update_fields() {
  install -d -m 0755 "${STATE_DIR}"
  if [[ -f "${STATE_DIR}/install.state" ]]; then
    sed -i '/^CA_CERT_INSTALLED=/d;/^CA_CERT_PATH=/d' "${STATE_DIR}/install.state"
    cat >> "${STATE_DIR}/install.state" <<STATE
CA_CERT_INSTALLED="${CA_CERT_INSTALLED}"
CA_CERT_PATH="${CA_CERT_PATH}"
STATE
    chmod 0644 "${STATE_DIR}/install.state"
  fi
}

main() {
  require_root
  load_current_config_defaults
  merge_config
  reload_config_after_merge
  install_files
  install_ca_certificate_if_configured
  configure_services
  write_state_update_fields
  log "Software update applied."
}

main "$@"
