#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR]  $*" >&2; }
die()  { err "$*"; exit 1; }

SERVICE_USER="${SERVICE_USER:-radio}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Lance ce script en root (sudo -i)."
  fi
}

run_as_user() {
  local u="$1"; shift
  local uid
  uid="$(id -u "$u" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 0
  runuser -u "$u" -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/$uid
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
    $*
  "
}

main() {
  require_root

  log "Stop/disable system unit Liquidsoap..."
  systemctl disable --now spotify-roon-liquidsoap.service 2>/dev/null || true
  systemctl reset-failed spotify-roon-liquidsoap.service 2>/dev/null || true
  rm -f /etc/systemd/system/spotify-roon-liquidsoap.service || true
  systemctl daemon-reload || true

  if id "$SERVICE_USER" >/dev/null 2>&1; then
    log "Stop/disable user unit Pulse bridge..."
    run_as_user "$SERVICE_USER" "systemctl --user disable --now spotify-roon-pulse-bridge.service 2>/dev/null || true" || true
    run_as_user "$SERVICE_USER" "systemctl --user daemon-reload" || true

    local h
    h="$(getent passwd "$SERVICE_USER" | awk -F: '{print $6}')"
    rm -f "$h/.config/systemd/user/spotify-roon-pulse-bridge.service" || true
  fi

  log "Remove bridge binary..."
  rm -f /usr/local/bin/spotify-roon-pulse-bridge || true

  log "Remove configs/logs..."
  rm -rf /etc/spotify-roon-bridge || true
  rm -rf /var/log/spotify-roon-bridge || true

  log "Note: on ne purge pas icecast2/liquidsoap/pipewire par défaut."
  log "Terminé."
}

main "$@"
