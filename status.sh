#!/usr/bin/env bash
set -euo pipefail

line() { printf '%*s\n' "${1:-80}" '' | tr ' ' '-'; }

CFG="/etc/spotify-roon-bridge/bridge.env"
if [[ -f "$CFG" ]]; then
  # shellcheck disable=SC1090
  source "$CFG" || true
fi

SERVICE_USER="${SERVICE_USER:-radio}"
ICECAST_HOST="${ICECAST_HOST:-127.0.0.1}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_MOUNT_OGG="${ICECAST_MOUNT_OGG:-/spotify.ogg}"
ICECAST_MOUNT_FLAC="${ICECAST_MOUNT_FLAC:-/spotify-lossless.ogg}"
ALSA_LOOPBACK_CAPTURE="${ALSA_LOOPBACK_CAPTURE:-hw:Loopback,1,0}"
PULSE_TARGET_SINK="${PULSE_TARGET_SINK:-}"

echo "== Context =="
echo "Date:          $(date --iso-8601=seconds)"
echo "Host:          $(hostname)"
echo "Kernel:        $(uname -a)"
echo "Service user:  ${SERVICE_USER}"
echo "Icecast OGG:   http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_OGG}"
echo "Icecast FLAC:  http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_FLAC}"
echo "ALSA capture:  ${ALSA_LOOPBACK_CAPTURE}"
echo "PULSE_TARGET_SINK: ${PULSE_TARGET_SINK:-<auto>}"
line

echo "== Core services (system) =="
for s in icecast2 spotify-roon-liquidsoap; do
  st="$(systemctl is-active "${s}.service" 2>/dev/null || true)"
  en="$(systemctl is-enabled "${s}.service" 2>/dev/null || true)"
  pid="$(systemctl show -p MainPID --value "${s}.service" 2>/dev/null || true)"
  printf "%-30s active=%-10s enabled=%-10s pid=%s\n" "${s}.service" "${st:-unknown}" "${en:-unknown}" "${pid:-?}"
done
line

echo "== Icecast Debian enable flag =="
if [[ -f /etc/default/icecast2 ]]; then
  grep -E '^ENABLE=' /etc/default/icecast2 || true
else
  echo "/etc/default/icecast2 absent"
fi
line

echo "== Icecast port + HTTP checks =="
if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :${ICECAST_PORT} )" | grep -q ":${ICECAST_PORT}"; then
    echo "Port ${ICECAST_PORT}: LISTEN"
  else
    echo "Port ${ICECAST_PORT}: NOT LISTENING"
  fi
fi

if command -v curl >/dev/null 2>&1; then
  echo "HTTP / :"
  curl -sSI "http://${ICECAST_HOST}:${ICECAST_PORT}/" | head -n 5 | sed 's/^/  /' || true
  echo "HTTP mount OGG :"
  curl -sSI "http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_OGG}" | head -n 5 | sed 's/^/  /' || true
  echo "HTTP mount FLAC :"
  curl -sSI "http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_FLAC}" | head -n 5 | sed 's/^/  /' || true
fi
line

echo "== Pulse bridge (user) =="
if id "${SERVICE_USER}" >/dev/null 2>&1; then
  uid="$(id -u "${SERVICE_USER}")"
  xdg="/run/user/${uid}"
  bus="unix:path=${xdg}/bus"

  if [[ -S "${xdg}/bus" ]]; then
    st="$(sudo -u "${SERVICE_USER}" XDG_RUNTIME_DIR="$xdg" DBUS_SESSION_BUS_ADDRESS="$bus" \
      systemctl --user is-active spotify-roon-pulse-bridge.service 2>/dev/null || true)"
    echo "spotify-roon-pulse-bridge.service: ${st:-unknown}"
    echo
    sudo -u "${SERVICE_USER}" XDG_RUNTIME_DIR="$xdg" DBUS_SESSION_BUS_ADDRESS="$bus" \
      /usr/local/bin/spotify-roon-pulse-bridge status || true
  else
    echo "systemd user bus absent (${xdg}/bus)"
  fi
else
  echo "User ${SERVICE_USER} absent."
fi
line

echo "== Liquidsoap file log (tail) =="
if [[ -f /var/log/spotify-roon-bridge/liquidsoap.log ]]; then
  tail -n 80 /var/log/spotify-roon-bridge/liquidsoap.log | sed 's/^/  /' || true
else
  echo "  /var/log/spotify-roon-bridge/liquidsoap.log absent"
fi
line

echo "== Journald (diagnostic) =="
echo "-- spotify-roon-liquidsoap (last 80) --"
journalctl -u spotify-roon-liquidsoap.service -n 80 --no-pager -l 2>/dev/null | sed 's/^/  /' || true
echo
echo "-- icecast2 (last 80) --"
journalctl -u icecast2.service -n 80 --no-pager -l 2>/dev/null | sed 's/^/  /' || true
