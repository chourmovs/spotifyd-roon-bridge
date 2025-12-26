#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SERVICE_USER="${SERVICE_USER:-radio}"
ICECAST_HOST="${ICECAST_HOST:-127.0.0.1}"
ICECAST_PORT="${ICECAST_PORT:-8000}"

sec()  { echo "== $* =="; }
line() { echo "--------------------------------------------------------------------------------"; }

run_as_user() {
  local u="$1"; shift
  local uid
  uid="$(id -u "$u" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1
  runuser -u "$u" -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/$uid
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
    $*
  "
}

main() {
  if [[ -f /etc/spotify-roon-bridge/bridge.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/spotify-roon-bridge/bridge.conf
  fi

  local pulse_source
  pulse_source="${SINK_NAME:-loopback}.monitor"

  sec "Context"
  echo "Date:          $(date --iso-8601=seconds)"
  echo "Host:          $(hostname)"
  echo "Kernel:        $(uname -a)"
  echo "Service user:  ${SERVICE_USER}"
  echo "Icecast MP3:   http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_MP3:-/spotify.mp3}"
  echo "Icecast AAC:   http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_AAC:-/spotify.aac}"
  echo "Icecast FLAC:  http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_FLAC:-/spotify.flac}"
  echo "Pulse sink:    ${SINK_NAME:-loopback}"
  echo "Pulse source:  ${pulse_source}"
  echo "ALSA capture:  ${ALSA_CAPTURE_DEVICE:-hw:Loopback,1,0}"
  line

  sec "Services"
  systemctl --no-pager -l status icecast2.service | sed -n '1,12p' || true
  echo
  systemctl --no-pager -l status spotify-roon-liquidsoap.service | sed -n '1,14p' || true
  line

  sec "Icecast"
  if curl -fsS "http://${ICECAST_HOST}:${ICECAST_PORT}/status.xsl" >/dev/null 2>&1; then
    echo "status.xsl: OK"
  else
    echo "status.xsl: FAIL"
  fi
  line

  sec "Pulse (user)"
  if id "${SERVICE_USER}" >/dev/null 2>&1; then
    run_as_user "${SERVICE_USER}" "pactl info | egrep 'Server Name|Server Version|Default Sink|Default Source' || true" || true
    echo
    run_as_user "${SERVICE_USER}" "pactl list short sinks || true" || true
    echo
    run_as_user "${SERVICE_USER}" "pactl list short sink-inputs || true" || true
  fi
  line

  sec "Logs (last 30)"
  journalctl -u spotify-roon-liquidsoap.service -n 30 --no-pager -l || true
}

main "$@"
