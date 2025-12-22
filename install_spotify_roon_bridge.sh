#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# install_spotify_roon_bridge.sh  (v1.0-beta FROZEN)
#
# Spotifyd (Spotify Connect) -> ALSA Loopback -> Liquidsoap -> Icecast
# Outputs:
#   - /spotify.mp3  (MP3 320k)
#   - /spotify.aac  (AAC 320k, ADTS via %ffmpeg)
#
# Key design:
# - spotifyd + liquidsoap run as SYSTEM services (no systemd --user, no DBus headaches)
# - ALSA devices are FROZEN to the known-good mapping:
#     spotifyd OUT : plughw:CARD=Loopback,DEV=0,SUBDEV=0
#     liquidsoap IN: plughw:CARD=Loopback,DEV=1,SUBDEV=0
# - icecast.xml patched safely with perl (no bash "$ENV" expansion bug)
# - /etc/liquidsoap perms forced to avoid Permission denied
# - Validation uses Icecast /admin/listmounts (auth) + HTTP GET
#
# Env overrides (optional):
#   RADIO_USER=radio
#   ICECAST_PORT=8000
#   ICECAST_MOUNT_MP3=/spotify.mp3
#   ICECAST_MOUNT_AAC=/spotify.aac
#   SPOTIFY_DEVICE_NAME="Roon-Spotify-Bridge"
#   SPOTIFYD_VERSION=v0.4.2
#   SPOTIFYD_FLAVOR=full
#   CAPTURE_DRIVER=plughw|dsnoop         (default plughw)
#   ICECAST_SOURCE_PW=...
#   ICECAST_ADMIN_PW=...
#   ICECAST_ADMIN_USER=admin
#
# Run:
#   sudo ./install_spotify_roon_bridge.sh
# ============================================================

RADIO_USER="${RADIO_USER:-radio}"

ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_MOUNT_MP3="${ICECAST_MOUNT_MP3:-/spotify.mp3}"
ICECAST_MOUNT_AAC="${ICECAST_MOUNT_AAC:-/spotify.aac}"
ICECAST_ADMIN_USER="${ICECAST_ADMIN_USER:-admin}"

SPOTIFY_DEVICE_NAME="${SPOTIFY_DEVICE_NAME:-Roon-Spotify-Bridge}"
SPOTIFYD_VERSION="${SPOTIFYD_VERSION:-v0.4.2}"
SPOTIFYD_FLAVOR="${SPOTIFYD_FLAVOR:-full}"

CAPTURE_DRIVER="${CAPTURE_DRIVER:-plughw}" # plughw or dsnoop

SPOTIFYD_ALSA_OUT="plughw:CARD=Loopback,DEV=0,SUBDEV=0"
LOOPBACK_CAPTURE_BASE="CARD=Loopback,DEV=1,SUBDEV=0"

die(){ echo "✖ $*" >&2; exit 1; }
ok(){  echo "✔ $*"; }
warn(){ echo "⚠ $*" >&2; }
sec(){ echo -e "\n== $* ==\n"; }

require_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo $0"; }
have(){ command -v "$1" >/dev/null 2>&1; }

read_secret_if_empty() {
  local var="$1" prompt="$2"
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    read -rsp "${prompt}: " val; echo ""
    [[ -n "$val" ]] || die "Empty secret: $var"
    export "$var"="$val"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l) echo "armv7" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
  ok "Backup: ${f}.bak.${ts}"
}

wait_listen() {
  local port="$1" tries="${2:-80}" delay="${3:-0.2}"
  for _ in $(seq 1 "$tries"); do
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(:|\\])${port}\$"; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

http_code_get() {
  curl -sS -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"
}

ensure_user() {
  if ! id -u "$RADIO_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$RADIO_USER"
    ok "User created: ${RADIO_USER}"
  fi
  usermod -aG audio "$RADIO_USER" || true
  ok "User '${RADIO_USER}' in group audio (best effort)"
}

# ---------- spotifyd download (robust URL resolution + fallbacks)
resolve_spotifyd_url() {
  local arch flavor v base asset url
  arch="$(detect_arch)"
  flavor="$SPOTIFYD_FLAVOR"
  v="${SPOTIFYD_VERSION#v}"
  base="https://github.com/Spotifyd/spotifyd/releases/download/v${v}"

  for asset in \
    "spotifyd-linux-${arch}-${flavor}.tar.gz" \
    "spotifyd-linux-${arch}-full.tar.gz" \
    "spotifyd-linux-${arch}-default.tar.gz" \
    "spotifyd-linux-${arch}-slim.tar.gz"
  do
    url="${base}/${asset}"
    if curl -fsI "$url" >/dev/null 2>&1; then
      echo "$url"; return 0
    fi
  done

  # Last resort: try GitHub API for exact asset naming
  local tag api json found
  for tag in "v${v}" "${v}"; do
    api="https://api.github.com/repos/Spotifyd/spotifyd/releases/tags/${tag}"
    if json="$(curl -fsSL "$api" 2>/dev/null)"; then
      found="$(
        python3 -c '
import json, sys
arch=sys.argv[1]
flavor=sys.argv[2]
data=json.load(sys.stdin)
assets=data.get("assets") or []
cand=[]
exact=f"spotifyd-linux-{arch}-{flavor}.tar.gz".lower()
for a in assets:
    n=(a.get("name") or "")
    u=(a.get("browser_download_url") or "")
    if not (n and u and n.lower().endswith(".tar.gz")):
        continue
    ln=n.lower()
    s=0
    if "linux" in ln: s+=50
    if arch in ln: s+=50
    if flavor and flavor.lower() in ln: s+=40
    if ln == exact: s+=200
    cand.append((s,u,n))
cand.sort(reverse=True, key=lambda x:x[0])
print(cand[0][1] if cand and cand[0][0] >= 100 else "", end="")
' "$arch" "$flavor" <<<"$json" 2>/dev/null || true
      )"
      if [[ -n "${found:-}" ]]; then
        echo "$found"; return 0
      fi
    fi
  done

  return 1
}

install_spotifyd() {
  sec "Install spotifyd binary"
  local url tmp
  tmp="/tmp/spotifyd_dl"
  rm -rf "$tmp"; mkdir -p "$tmp"

  url="$(resolve_spotifyd_url)" || die "Could not resolve spotifyd asset URL."
  echo "Resolved asset: $url"

  curl -fL --retry 6 --retry-delay 1 --connect-timeout 10 \
    -o "$tmp/spotifyd.tgz" "$url" || die "Download failed: $url"

  tar -xzf "$tmp/spotifyd.tgz" -C "$tmp"
  local bin
  bin="$(find "$tmp" -maxdepth 3 -type f -name spotifyd | head -n 1 || true)"
  [[ -n "${bin:-}" && -f "$bin" ]] || die "spotifyd binary missing after extract"

  install -m 0755 "$bin" /usr/local/bin/spotifyd
  ok "spotifyd installed at /usr/local/bin/spotifyd"
}

# ---------- spotifyd.conf (minimal + stable)
configure_spotifyd_conf() {
  sec "Configure spotifyd.conf (ALSA loopback OUT frozen)"
  local cfg_dir="/home/${RADIO_USER}/.config/spotifyd"
  local cfg="${cfg_dir}/spotifyd.conf"

  install -d -m 0755 -o "$RADIO_USER" -g "$RADIO_USER" "$cfg_dir"
  install -d -m 0755 -o "$RADIO_USER" -g "$RADIO_USER" "/home/${RADIO_USER}/.cache/spotifyd"

  backup_file "$cfg"

  cat >"$cfg" <<EOF
[global]
device_name = "${SPOTIFY_DEVICE_NAME}"
use_mpris = false

backend = "alsa"
device = "${SPOTIFYD_ALSA_OUT}"

audio_format = "S16"
bitrate = 320

cache_path = "/home/${RADIO_USER}/.cache/spotifyd"
volume_controller = "softvol"
initial_volume = 90
EOF

  chown "$RADIO_USER:$RADIO_USER" "$cfg"
  chmod 600 "$cfg"
  ok "spotifyd.conf written"
}

install_spotifyd_system_service() {
  sec "Install spotifyd systemd service"
  cat >/etc/systemd/system/spotifyd.service <<EOF
[Unit]
Description=spotifyd (Spotify Connect daemon)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=${RADIO_USER}
Group=audio
SupplementaryGroups=audio
Environment=HOME=/home/${RADIO_USER}
WorkingDirectory=/home/${RADIO_USER}
ExecStart=/usr/local/bin/spotifyd --no-daemon --config-path /home/${RADIO_USER}/.config/spotifyd/spotifyd.conf
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now spotifyd
  systemctl restart spotifyd
  systemctl is-active --quiet spotifyd || { systemctl status spotifyd --no-pager -l; die "spotifyd not active"; }
  ok "spotifyd active (system)"
}

# ---------- Icecast patch (safe; no bash $ENV bug)
patch_icecast_xml_debian_style() {
  sec "Patch Icecast config (safe in-place)"
  local f="/etc/icecast2/icecast.xml"
  [[ -f "$f" ]] || die "Missing $f (icecast2 not installed?)"

  if [[ ! -f "${f}.bak.spotify-roon-bridge" ]]; then
    cp -a "$f" "${f}.bak.spotify-roon-bridge"
    ok "Backup created: ${f}.bak.spotify-roon-bridge"
  fi

  export ICECAST_SOURCE_PW ICECAST_ADMIN_PW ICECAST_PORT

  # Update passwords
  perl -0777 -i -pe 's~(<source-password>).*?(</source-password>)~$1.$ENV{ICECAST_SOURCE_PW}.$2~seg' "$f"
  perl -0777 -i -pe 's~(<admin-password>).*?(</admin-password>)~$1.$ENV{ICECAST_ADMIN_PW}.$2~seg' "$f"

  # Ensure port within first listen-socket; handles empty <port></port>
  perl -0777 -i -pe 's~(<listen-socket>\s*.*?<port>)\s*[^<]*\s*(</port>)~$1.$ENV{ICECAST_PORT}.$2~seg' "$f"

  grep -q "<paths>" "$f" || die "icecast.xml sanity check failed (<paths> missing)"
  grep -q "<security>" "$f" || die "icecast.xml sanity check failed (<security> missing)"
  ok "icecast.xml patched"
}

enable_icecast_debian() {
  sec "Enable Icecast on Debian"
  if [[ -f /etc/default/icecast2 ]]; then
    if grep -q '^ENABLE=' /etc/default/icecast2; then
      sed -i 's/^ENABLE=.*/ENABLE=true/' /etc/default/icecast2 || true
    else
      echo 'ENABLE=true' >> /etc/default/icecast2
    fi
  fi

  systemctl enable --now icecast2
  systemctl restart icecast2
  systemctl is-active --quiet icecast2 || { systemctl status icecast2 --no-pager -l; die "icecast2 not active"; }
  wait_listen "$ICECAST_PORT" || {
    ss -lntp || true
    journalctl -u icecast2 -n 200 --no-pager -l || true
    die "icecast2 not listening on ${ICECAST_PORT}"
  }
  ok "icecast2 listening on ${ICECAST_PORT}"
}

# ---------- Liquidsoap config (MP3 + AAC ADTS) - known good
configure_liquidsoap() {
  sec "Configure Liquidsoap (MP3 + AAC ADTS)"

  local in_dev
  case "$CAPTURE_DRIVER" in
    plughw) in_dev="plughw:${LOOPBACK_CAPTURE_BASE}" ;;
    dsnoop) in_dev="dsnoop:${LOOPBACK_CAPTURE_BASE}" ;;
    *) die "CAPTURE_DRIVER must be plughw or dsnoop (got: $CAPTURE_DRIVER)" ;;
  esac

  install -d -m 0755 /etc/liquidsoap
  backup_file /etc/liquidsoap/spotify.liq

  cat >/etc/liquidsoap/spotify.liq <<EOF
set("log.stdout", true)
set("server.telnet", false)

s = input.alsa(id="spotify_capture", device="${in_dev}")
src = mksafe(s)

# MP3 (web-friendly)
output.icecast(
  %mp3(bitrate=320, samplerate=44100, stereo=true),
  host="127.0.0.1", port=${ICECAST_PORT}, password="${ICECAST_SOURCE_PW}",
  mount="${ICECAST_MOUNT_MP3}",
  name="Spotify (WEB MP3)",
  description="Browser-friendly MP3",
  src
)

# AAC (ADTS) - known working on your box
output.icecast(
  %ffmpeg(format="adts",
    %audio(codec="aac", samplerate=44100, channels=2, b="320k")
  ),
  host="127.0.0.1", port=${ICECAST_PORT}, password="${ICECAST_SOURCE_PW}",
  mount="${ICECAST_MOUNT_AAC}",
  name="Spotify (WEB AAC)",
  description="AAC 320k ADTS",
  src
)
EOF

  # perms: MUST be readable by User=radio service, avoid Permission denied
  chmod 0644 /etc/liquidsoap/spotify.liq
  chmod 0755 /etc/liquidsoap

  # compatibility symlink if older unit points to spotify_icecast.liq
  ln -sf /etc/liquidsoap/spotify.liq /etc/liquidsoap/spotify_icecast.liq

  ok "Liquidsoap config written (/etc/liquidsoap/spotify.liq) [input=${in_dev}]"
}

install_liquidsoap_service() {
  sec "Install liquidsoap-spotify systemd service"
  cat >/etc/systemd/system/liquidsoap-spotify.service <<EOF
[Unit]
Description=Liquidsoap Spotify -> Icecast bridge
After=network-online.target icecast2.service spotifyd.service
Wants=network-online.target icecast2.service spotifyd.service

[Service]
Type=simple
User=${RADIO_USER}
Group=audio
SupplementaryGroups=audio
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/spotify.liq
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  # Preflight syntax check (prevents "mount absent" surprises)
  if ! /usr/bin/liquidsoap --check /etc/liquidsoap/spotify.liq; then
    die "Liquidsoap config check failed. Fix /etc/liquidsoap/spotify.liq then re-run."
  fi

  systemctl daemon-reload
  systemctl enable --now liquidsoap-spotify
  systemctl restart liquidsoap-spotify
  systemctl is-active --quiet liquidsoap-spotify || {
    systemctl status liquidsoap-spotify --no-pager -l || true
    journalctl -u liquidsoap-spotify -n 200 --no-pager -l || true
    die "liquidsoap-spotify not active"
  }
  ok "liquidsoap-spotify active"
}

# ---------- ALSA loopback (best-effort, non-destructive)
ensure_alsa_loopback() {
  sec "ALSA loopback (snd-aloop)"
  modprobe snd-aloop 2>/dev/null || true
  echo "snd-aloop" >/etc/modules-load.d/snd-aloop.conf
  ok "snd-aloop load requested (best effort)"
}

smoke_tests() {
  sec "Smoke tests"

  local st
  st="$(http_code_get "http://127.0.0.1:${ICECAST_PORT}/status.xsl")"
  [[ "$st" == "200" ]] || die "Icecast status page not reachable (HTTP $st)"
  ok "Icecast status OK (HTTP 200)"

  # Validate mounts exist (auth)
  local mounts
  mounts="$(curl -fsS "http://127.0.0.1:${ICECAST_PORT}/admin/listmounts" \
            -u "${ICECAST_ADMIN_USER}:${ICECAST_ADMIN_PW}" || true)"

  echo "$mounts" | grep -q "mount=\"${ICECAST_MOUNT_MP3}\"" || {
    journalctl -u liquidsoap-spotify -n 200 --no-pager -l || true
    die "MP3 mount not visible: ${ICECAST_MOUNT_MP3}"
  }
  ok "Mount visible: ${ICECAST_MOUNT_MP3}"

  echo "$mounts" | grep -q "mount=\"${ICECAST_MOUNT_AAC}\"" || {
    journalctl -u liquidsoap-spotify -n 200 --no-pager -l || true
    die "AAC mount not visible: ${ICECAST_MOUNT_AAC}"
  }
  ok "Mount visible: ${ICECAST_MOUNT_AAC}"

  # Quick HTTP GET checks (expect 200 once connected)
  local mp3 aac
  mp3="$(http_code_get "http://127.0.0.1:${ICECAST_PORT}${ICECAST_MOUNT_MP3}")"
  aac="$(http_code_get "http://127.0.0.1:${ICECAST_PORT}${ICECAST_MOUNT_AAC}")"
  echo "MP3 HTTP=${mp3}  AAC HTTP=${aac}"
  ok "Smoke tests done"
}

main() {
  require_root

  read_secret_if_empty ICECAST_SOURCE_PW "Icecast SOURCE password"
  read_secret_if_empty ICECAST_ADMIN_PW  "Icecast ADMIN  password"

  sec "Install packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl perl python3 \
    alsa-utils \
    icecast2 \
    liquidsoap \
    avahi-daemon
  ok "Packages installed"

  ensure_user
  ensure_alsa_loopback

  patch_icecast_xml_debian_style
  enable_icecast_debian

  install_spotifyd
  configure_spotifyd_conf
  install_spotifyd_system_service

  configure_liquidsoap
  install_liquidsoap_service

  smoke_tests

  sec "DONE"
  local ip
  ip="$(hostname -I | awk '{print $1}')"
  echo "MP3: http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_MP3}"
  echo "AAC: http://${ip}:${ICECAST_PORT}${ICECAST_MOUNT_AAC}"
  echo "Services:"
  echo "  systemctl status spotifyd icecast2 liquidsoap-spotify --no-pager"
}

main "$@"
