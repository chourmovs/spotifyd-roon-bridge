#!/usr/bin/env bash
set -euo pipefail

RADIO_USER="${RADIO_USER:-radio}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/spotify.flac}"
ICECAST_ADMIN_USER="${ICECAST_ADMIN_USER:-admin}"
ICECAST_ADMIN_PASS="${ICECAST_ADMIN_PASS:-}"

ok(){  echo "✔ $*"; }
warn(){ echo "⚠ $*" >&2; }
sec(){  echo -e "\n== $* ==\n"; }
have(){ command -v "$1" >/dev/null 2>&1; }

unit_short() {
  local u="$1"
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "$u"; then
    if systemctl is-active --quiet "$u"; then ok "$u: active"; else warn "$u: NOT active"; fi
    systemctl status "$u" --no-pager -l | sed -n '1,22p' || true
  else
    warn "$u: unit not found"
  fi
}

http_code_get() { curl -sS -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"; }

main() {
  sec "Context"
  echo "Date:          $(date -Iseconds)"
  echo "Host:          $(hostname)"
  echo "Kernel:        $(uname -srmo)"
  echo "User:          ${RADIO_USER}"
  echo "Icecast URL:   http://<IP>:${ICECAST_PORT}${ICECAST_MOUNT}"

  sec "Core services (systemd)"
  unit_short icecast2.service
  echo ""
  unit_short spotifyd.service
  echo ""
  unit_short liquidsoap-spotify.service
  echo ""
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "avahi-daemon.service"; then
    unit_short avahi-daemon.service
  else
    warn "avahi-daemon: not installed (optional)"
  fi

  sec "Configs (relevant lines)"
  if [[ -f "/home/${RADIO_USER}/.config/spotifyd/spotifyd.conf" ]]; then
    echo "# spotifyd.conf: device/backend/use_mpris"
    grep -nE '^\s*(backend|device|use_mpris|device_name)\s*=' "/home/${RADIO_USER}/.config/spotifyd/spotifyd.conf" || true
  else
    warn "spotifyd.conf missing"
  fi

  echo ""
  if [[ -f "/etc/liquidsoap/spotify.liq" ]]; then
    echo "# liquidsoap: input.alsa device line"
    grep -nE 'input\.alsa|device=' /etc/liquidsoap/spotify.liq | head -n 20 || true
  else
    warn "/etc/liquidsoap/spotify.liq missing"
  fi

  sec "Listening sockets"
  if have ss; then
    ss -ltnp | sed -n '1,200p'
    echo ""
    ss -ltnp | grep -E ":${ICECAST_PORT}\b" && ok "Icecast port ${ICECAST_PORT} listening" || warn "No listener on ${ICECAST_PORT}"
  else
    warn "ss not available"
  fi

  sec "Icecast HTTP checks (GET)"
  if have curl; then
    st="$(http_code_get "http://127.0.0.1:${ICECAST_PORT}/status.xsl")"
    echo "status.xsl: HTTP ${st}"
    mc="$(http_code_get "http://127.0.0.1:${ICECAST_PORT}${ICECAST_MOUNT}")"
    echo "mount ${ICECAST_MOUNT}: HTTP ${mc}"

    if [[ -n "$ICECAST_ADMIN_PASS" ]]; then
      echo ""
      echo "admin/listmounts (auth):"
      curl -sS "http://127.0.0.1:${ICECAST_PORT}/admin/listmounts" \
        -u "${ICECAST_ADMIN_USER}:${ICECAST_ADMIN_PASS}" | head -n 120 || true
    else
      warn "ICECAST_ADMIN_PASS empty -> skipping /admin/listmounts"
      echo "Tip: ICECAST_ADMIN_PASS='xxxx' sudo ./status.sh"
    fi
  else
    warn "curl not available"
  fi

  sec "ALSA loopback sanity"
  lsmod | grep -E "^snd_aloop" && ok "snd_aloop loaded" || warn "snd_aloop NOT loaded"
  if have aplay; then
    echo ""
    echo "# aplay -L | grep -i loopback"
    aplay -L | grep -i loopback || true
    echo ""
    echo "# arecord -L | grep -i loopback"
    arecord -L | grep -i loopback || true
  fi

  sec "Recent logs"
  journalctl -u spotifyd -n 80 --no-pager -l 2>/dev/null || true
  echo ""
  journalctl -u liquidsoap-spotify -n 120 --no-pager -l 2>/dev/null || true
  echo ""
  journalctl -u icecast2 -n 80 --no-pager -l 2>/dev/null || true
}

main
