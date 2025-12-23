#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# status.sh — Spotify -> Roon Bridge diagnostics (Debian 12)
# Services: spotifyd (system), icecast2, liquidsoap-spotify, avahi-daemon
# Mounts: MP3 + AAC + Ogg/FLAC + Raw FLAC
#
# Usage:
#   sudo ./status.sh
#   ICECAST_ADMIN_PASS='xxxx' sudo -E ./status.sh
#   sudo ./status.sh --full
# ============================================================

RADIO_USER="${RADIO_USER:-radio}"

ICECAST_HOST="${ICECAST_HOST:-127.0.0.1}"
ICECAST_PORT="${ICECAST_PORT:-8000}"

ICECAST_ADMIN_USER="${ICECAST_ADMIN_USER:-admin}"
ICECAST_ADMIN_PASS="${ICECAST_ADMIN_PASS:-}"   # optional; if empty, listmounts will be skipped

# New mounts (defaults aligned with install script)
ICECAST_MOUNT_MP3="${ICECAST_MOUNT_MP3:-/spotify.mp3}"
ICECAST_MOUNT_AAC="${ICECAST_MOUNT_AAC:-/spotify.aac}"
ICECAST_MOUNT_LOSSLESS_OGG="${ICECAST_MOUNT_LOSSLESS_OGG:-/spotify-lossless.ogg}"
ICECAST_MOUNT_RAW_FLAC="${ICECAST_MOUNT_RAW_FLAC:-/spotify-raw.flac}"

# Backward-compat: if user still exports ICECAST_MOUNT, we check it too
ICECAST_MOUNT_LEGACY="${ICECAST_MOUNT:-}"

FULL=0
if [[ "${1:-}" == "--full" ]]; then FULL=1; fi

CLR_RESET="\033[0m"
CLR_BOLD="\033[1m"
CLR_GREEN="\033[32m"
CLR_YELLOW="\033[33m"
CLR_RED="\033[31m"
CLR_CYAN="\033[36m"

sec()  { echo -e "\n${CLR_BOLD}${CLR_CYAN}== $* ==${CLR_RESET}\n"; }
ok()   { echo -e "${CLR_GREEN}✔${CLR_RESET} $*"; }
warn() { echo -e "${CLR_YELLOW}⚠${CLR_RESET} $*"; }
err()  { echo -e "${CLR_RED}✖${CLR_RESET} $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Lance ce script en root: sudo $0"
    exit 1
  fi
}

http_head() {
  local url="$1"
  curl -sS -I "$url" 2>/dev/null | sed -n '1,20p' || true
}

http_code() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000"
}

show_unit_short() {
  local u="$1"
  if systemctl list-unit-files | grep -q "^${u}\.service"; then
    systemctl is-active --quiet "$u" && ok "$u: active" || warn "$u: NOT active"
    systemctl status "$u" --no-pager -l | sed -n '1,20p' || true
  else
    warn "$u: unit not found"
  fi
}

icecast_sources_limit() {
  local f="/etc/icecast2/icecast.xml"
  [[ -f "$f" ]] || return 0
  local v
  v="$(grep -n "<sources>" "$f" | head -n 1 | sed -E 's/.*<sources>\s*([0-9]+)\s*<\/sources>.*/\1/' || true)"
  [[ -n "${v:-}" && "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "unknown"
}

ffmpeg_decode_smoke() {
  local url="$1" label="$2"
  if ! have ffmpeg; then
    warn "ffmpeg absent -> skip decode smoke for ${label} (apt install -y ffmpeg)"
    return 0
  fi
  # decode 2 seconds to null; no ALSA needed
  if ffmpeg -v error -i "$url" -t 2 -f null - >/dev/null 2>&1; then
    ok "Decode OK: ${label}"
  else
    warn "Decode FAILED: ${label} (si RAW FLAC: normal en midstream; retente juste après restart liquidsoap)"
  fi
}

main() {
  need_root

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${ip:-}" ]] || ip="<IP>"

  local sources_lim
  sources_lim="$(icecast_sources_limit)"

  sec "Context"
  echo "Date:          $(date -Is)"
  echo "Host:          $(hostname)"
  echo "Kernel:        $(uname -srmo)"
  echo "Radio user:    ${RADIO_USER}"
  echo "Icecast base:  http://${ICECAST_HOST}:${ICECAST_PORT}"
  echo "Mounts:"
  echo "  MP3:         ${ICECAST_MOUNT_MP3}"
  echo "  AAC:         ${ICECAST_MOUNT_AAC}"
  echo "  LOSSLESS:    ${ICECAST_MOUNT_LOSSLESS_OGG}"
  echo "  RAW FLAC:    ${ICECAST_MOUNT_RAW_FLAC}"
  [[ -n "${ICECAST_MOUNT_LEGACY:-}" ]] && echo "  LEGACY:      ${ICECAST_MOUNT_LEGACY}"
  echo "Icecast sources limit (icecast.xml): ${sources_lim}"
  echo "Mode:          $([[ $FULL -eq 1 ]] && echo FULL || echo NORMAL)"
  echo ""
  echo "URLs:"
  echo "  http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_MP3}"
  echo "  http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_AAC}"
  echo "  http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_LOSSLESS_OGG}"
  echo "  http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_RAW_FLAC}"

  sec "Core services (systemd)"
  for u in spotifyd icecast2 liquidsoap-spotify avahi-daemon; do
    show_unit_short "$u"
    echo ""
  done

  sec "Listening sockets (ports)"
  if have ss; then
    ss -ltnp | sed -n '1,200p'
    echo ""
    echo "Filtered (icecast ${ICECAST_PORT}):"
    ss -ltnp | grep -E ":${ICECAST_PORT}\b" || warn "No listener on port ${ICECAST_PORT}"
  else
    warn "ss not available"
  fi

  sec "spotifyd config (sanity)"
  local cfg="/home/${RADIO_USER}/.config/spotifyd/spotifyd.conf"
  if [[ -f "$cfg" ]]; then
    echo "File: $cfg"
    nl -ba "$cfg" | sed -n '1,140p'
  else
    warn "spotifyd.conf not found: $cfg"
  fi

  sec "Icecast HTTP checks"
  if have curl; then
    echo "# status page"
    http_head "http://${ICECAST_HOST}:${ICECAST_PORT}/status.xsl"
    echo ""

    # HEAD per mount
    for m in "${ICECAST_MOUNT_MP3}" "${ICECAST_MOUNT_AAC}" "${ICECAST_MOUNT_LOSSLESS_OGG}" "${ICECAST_MOUNT_RAW_FLAC}"; do
      echo "# HEAD $m"
      http_head "http://${ICECAST_HOST}:${ICECAST_PORT}${m}"
      echo ""
    done

    if [[ -n "${ICECAST_MOUNT_LEGACY:-}" ]]; then
      echo "# HEAD legacy ${ICECAST_MOUNT_LEGACY}"
      http_head "http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_LEGACY}"
      echo ""
    fi

    # listmounts if admin pass provided
    if [[ -n "$ICECAST_ADMIN_PASS" ]]; then
      echo "# listmounts (admin auth)"
      local mounts
      mounts="$(curl -fsS "http://${ICECAST_HOST}:${ICECAST_PORT}/admin/listmounts" \
        -u "${ICECAST_ADMIN_USER}:${ICECAST_ADMIN_PASS}" || true)"
      if [[ -n "$mounts" ]]; then
        echo "$mounts" | head -n 160
        echo ""
        for m in "${ICECAST_MOUNT_MP3}" "${ICECAST_MOUNT_AAC}" "${ICECAST_MOUNT_LOSSLESS_OGG}" "${ICECAST_MOUNT_RAW_FLAC}"; do
          echo "$mounts" | grep -q "mount=\"${m}\"" && ok "listmounts: present ${m}" || warn "listmounts: ABSENT ${m}"
        done
      else
        warn "listmounts empty or failed (bad admin creds?)"
      fi
    else
      warn "ICECAST_ADMIN_PASS empty -> skipping /admin/listmounts"
      echo "Tip:"
      echo "  ICECAST_ADMIN_PASS='xxxx' sudo -E ./status.sh"
    fi
  else
    warn "curl not available"
  fi

  sec "Decode smoke tests (server-side)"
  # LOSSLESS OGG/FLAC should always decode
  ffmpeg_decode_smoke "http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_LOSSLESS_OGG}" "LOSSLESS OGG/FLAC"
  # RAW FLAC may fail midstream (expected); still useful as a hint
  ffmpeg_decode_smoke "http://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT_RAW_FLAC}" "RAW FLAC (experimental)"

  sec "ALSA loopback sanity"
  echo "snd_aloop loaded?"
  lsmod | grep -E "^snd_aloop" >/dev/null 2>&1 && ok "snd_aloop loaded" || warn "snd_aloop NOT loaded"
  echo ""
  if have aplay; then
    echo "# aplay -l"
    aplay -l || true
    echo ""
    echo "# arecord -l"
    arecord -l || true
    echo ""
    echo "# aplay -L (loopback-related)"
    aplay -L | grep -i -n "loopback\|dsnoop\|plughw" | head -n 120 || true
  else
    warn "alsa-utils not installed (apt install -y alsa-utils)"
  fi

  if [[ $FULL -eq 1 ]]; then
    sec "FULL: last logs"
    for u in spotifyd icecast2 liquidsoap-spotify; do
      echo "## journalctl -u $u -n 120"
      journalctl -u "$u" -n 120 --no-pager -l || true
      echo ""
    done

    sec "FULL: process list"
    ps auxww | grep -E "spotifyd|liquidsoap|icecast2|avahi-daemon" | grep -v grep || true

    sec "FULL: open files (top 200)"
    if have lsof; then
      lsof -nP | grep -E "spotifyd|liquidsoap|icecast2" | head -n 200 || true
    else
      warn "lsof not installed (apt install -y lsof)"
    fi
  fi

  sec "Summary hints"
  echo "- Mount ABSENT (404 + listmounts absent) => Liquidsoap n'arrive pas à publier (erreur ALSA, ou Icecast refuse)."
  echo "- Icecast refuse en 403 côté Liquidsoap => souvent limits/sources trop bas (tu vises 10)."
  echo "- LOSSLESS OGG/FLAC doit décoder OK quasi tout le temps."
  echo "- RAW FLAC peut échouer si le client accroche midstream : retenter juste après restart liquidsoap."
  echo ""
  ok "Done."
}

main "$@"
