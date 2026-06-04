#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/signage/signage.conf"
CONFIG_EXAMPLE="${PROJECT_DIR}/signage.conf.example"
STATE_DIR="/var/lib/signage/state"
COMMON_SRC="${PROJECT_DIR}/files/lib/signage-install-common.sh"

SIGNAGE_AUTO_UPDATE_ENABLED="false"
SIGNAGE_AUTO_UPDATE_ONCALENDAR="Tue *-*-* 03:00:00"
SIGNAGE_CONFIG_PRESERVE_KEYS="SLIDES_URL"
SIGNAGE_AUTO_UPDATE_REPO_URL=""
SIGNAGE_AUTO_UPDATE_REF="HEAD"
SLIDES_CA_CERT_URL=""
HTTP_TIMEOUT_SECONDS="30"
CA_CERT_PATH="/usr/local/share/ca-certificates/signage-slides-ca.crt"
CA_CERT_INSTALLED="0"

log() { printf '[update-signage] %s\n' "$*"; }
die() { printf '[update-signage] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this updater as root."
  fi
}

load_common_files() {
  [[ -f "${COMMON_SRC}" ]] || die "Missing ${COMMON_SRC}"
  # shellcheck source=files/lib/signage-install-common.sh
  source "${COMMON_SRC}"
  load_shared_defaults
}

load_current_config_defaults() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
  fi

  apply_config_defaults
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
    out_lines.append("# Preserved Pi-local values not present in signage.conf.example.")
    out_lines.extend(append_lines)

out_conf.write_text("\n".join(out_lines) + "\n")
PY

  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${CONFIG_FILE}"
}

reload_config_after_merge() {
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  : "${SLIDES_URL:?SLIDES_URL must be set in ${CONFIG_FILE}}"
  apply_config_defaults
  validate_runtime_numbers
  validate_update_config
}

install_files() {
  log "Updating managed signage files"
  install_managed_files
}

install_ca_certificate_if_configured() {
  if [[ -z "${SLIDES_CA_CERT_URL}" ]]; then
    if [[ -e "${CA_CERT_PATH}" ]]; then
      log "Removing installer-managed CA certificate because SLIDES_CA_CERT_URL is empty."
      rm -f "${CA_CERT_PATH}"
      update-ca-certificates >/dev/null 2>&1 || true
    else
      log "No SLIDES_CA_CERT_URL configured; skipping optional CA certificate update."
    fi
    CA_CERT_INSTALLED="0"
    return 0
  fi

  log "Updating optional slide-server CA certificate from ${SLIDES_CA_CERT_URL}"
  "${PROJECT_DIR}/files/sbin/signage-install-ca" "${SLIDES_CA_CERT_URL}" "${CA_CERT_PATH}" "${HTTP_TIMEOUT_SECONDS}" || \
    die "Failed to install CA certificate from SLIDES_CA_CERT_URL=${SLIDES_CA_CERT_URL}"
  CA_CERT_INSTALLED="1"
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
  load_common_files
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
