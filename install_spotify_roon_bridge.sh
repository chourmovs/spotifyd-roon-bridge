#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Spotify (user session radio) -> PipeWire/Pulse null sink -> loopback vers ALSA Loopback -> Liquidsoap -> Icecast
# Debian 13 / Proxmox VM

########################################
# Defaults
########################################
SERVICE_USER="${SERVICE_USER:-radio}"

ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_HOST="${ICECAST_HOST:-127.0.0.1}"

MOUNT_MP3="${MOUNT_MP3:-/spotify.mp3}"
MOUNT_AAC="${MOUNT_AAC:-/spotify.aac}"
MOUNT_FLAC="${MOUNT_FLAC:-/spotify.flac}"

ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:-hackme}"
ICECAST_ADMIN_PASSWORD="${ICECAST_ADMIN_PASSWORD:-hackme}"

# Pulse side
SINK_NAME="${SINK_NAME:-loopback}"
PULSE_TARGET_SINK="${PULSE_TARGET_SINK:-loopback}"

# ALSA loopback capture device for Liquidsoap
ALSA_CAPTURE_DEVICE="${ALSA_CAPTURE_DEVICE:-hw:Loopback,1,0}"

# Encoding defaults
MP3_BITRATE="${MP3_BITRATE:-320}"
AAC_BITRATE="${AAC_BITRATE:-320k}"
FLAC_BITS="${FLAC_BITS:-16}"
FLAC_SR="${FLAC_SR:-44100}"

# Logging
LOG_GROUP="${LOG_GROUP:-spotify-roon-bridge}"
LOG_DIR="${LOG_DIR:-/var/log/spotify-roon-bridge}"
LOG_FILE="${LOG_FILE:-/var/log/spotify-roon-bridge/liquidsoap.log}"

########################################
# Helpers
########################################
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR]  $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Lance ce script en root (sudo -i)."
  fi
}

user_home() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

run_as_user() {
  local u="$1"; shift
  local uid
  uid="$(id -u "$u")"
  runuser -u "$u" -- bash -lc "
    export XDG_RUNTIME_DIR=/run/user/$uid
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus
    $*
  "
}

xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

mount_norm() {
  # Liquidsoap mount="foo.mp3" => Icecast URL /foo.mp3
  local m="$1"
  m="${m#/}"
  printf '%s' "$m"
}

########################################
# Packages
########################################
install_packages() {
  log "Installation paquets..."
  apt-get update -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    icecast2 liquidsoap ffmpeg \
    pipewire pipewire-pulse wireplumber \
    pulseaudio-utils alsa-utils

  # Optionnel
  apt-get install -y spotify-client || warn "spotify-client non installé (skip)."
}

########################################
# Users/groups/perms
########################################
ensure_groups_and_perms() {
  log "Préparation groupes & permissions..."

  # Log group
  groupadd -f "$LOG_GROUP"

  # Ensure user exists
  id "$SERVICE_USER" >/dev/null 2>&1 || die "User '$SERVICE_USER' introuvable."

  # Audio + log group
  usermod -aG audio "$SERVICE_USER" || true
  usermod -aG "$LOG_GROUP" "$SERVICE_USER" || true

  # Log directory must be writable by SERVICE_USER (via group)
  install -d -m 2775 -o root -g "$LOG_GROUP" "$LOG_DIR"
  touch "$LOG_FILE"
  chown "$SERVICE_USER":"$LOG_GROUP" "$LOG_FILE"
  chmod 0664 "$LOG_FILE"
}

########################################
# ALSA loopback
########################################
enable_snd_aloop() {
  log "Activation ALSA loopback (snd-aloop)..."
  cat >/etc/modules-load.d/snd-aloop.conf <<'EOF'
# spotify-roon-bridge
snd-aloop
EOF

  cat >/etc/modprobe.d/snd-aloop.conf <<'EOF'
# spotify-roon-bridge
options snd-aloop pcm_substreams=2
EOF

  modprobe snd_aloop || true
}

########################################
# Icecast
########################################
configure_icecast() {
  log "Configuration Icecast..."

  if [[ -f /etc/icecast2/icecast.xml ]]; then
    cp -a /etc/icecast2/icecast.xml "/etc/icecast2/icecast.xml.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  local src_xml adm_xml host_xml
  src_xml="$(xml_escape "$ICECAST_SOURCE_PASSWORD")"
  adm_xml="$(xml_escape "$ICECAST_ADMIN_PASSWORD")"
  host_xml="$(xml_escape "$ICECAST_HOST")"

  cat >/etc/icecast2/icecast.xml <<EOF
<icecast>
  <location>Home</location>
  <admin>root@localhost</admin>

  <limits>
    <clients>100</clients>
    <sources>10</sources>
    <queue-size>524288</queue-size>
    <client-timeout>30</client-timeout>
    <header-timeout>15</header-timeout>
    <source-timeout>10</source-timeout>
    <burst-on-connect>1</burst-on-connect>
    <burst-size>65535</burst-size>
  </limits>

  <authentication>
    <source-password>${src_xml}</source-password>
    <relay-password>${src_xml}</relay-password>
    <admin-user>admin</admin-user>
    <admin-password>${adm_xml}</admin-password>
  </authentication>

  <hostname>${host_xml}</hostname>

  <listen-socket>
    <port>${ICECAST_PORT}</port>
    <bind-address>0.0.0.0</bind-address>
  </listen-socket>

  <fileserve>1</fileserve>

  <paths>
    <basedir>/usr/share/icecast2</basedir>
    <logdir>/var/log/icecast2</logdir>
    <webroot>/usr/share/icecast2/web</webroot>
    <adminroot>/usr/share/icecast2/admin</adminroot>
    <alias source="/" dest="/status.xsl"/>
  </paths>

  <logging>
    <accesslog>access.log</accesslog>
    <errorlog>error.log</errorlog>
    <loglevel>3</loglevel>
    <logsize>10000</logsize>
  </logging>

  <security>
    <chroot>0</chroot>
  </security>
</icecast>
EOF

  systemctl enable --now icecast2
  systemctl restart icecast2
}

########################################
# Pulse bridge (user) : null sink + loopback to ALSA Loopback playback
########################################
install_pulse_bridge() {
  log "Installation Pulse bridge: /usr/local/bin/spotify-roon-pulse-bridge"

  cat >/usr/local/bin/spotify-roon-pulse-bridge <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SINK_NAME="${SINK_NAME:-loopback}"
TARGET_SINK="${PULSE_TARGET_SINK:-loopback}"

log() { echo "[bridge] $*"; }

ensure_modules() {
  # null sink for capture
  if ! pactl list short sinks | awk '{print $2}' | grep -qx "$SINK_NAME"; then
    log "Creating null sink: $SINK_NAME"
    pactl load-module module-null-sink "sink_name=$SINK_NAME sink_properties=device.description=$SINK_NAME" >/dev/null || true
  fi

  # ALSA sink to Loopback playback
  if ! pactl list short sinks | awk '{print $2}' | grep -q '^alsa_loopback$'; then
    log "Creating ALSA sink: alsa_loopback (hw:Loopback,0,0)"
    pactl load-module module-alsa-sink "sink_name=alsa_loopback device=hw:Loopback,0,0" >/dev/null || true
  fi

  # loopback from capture monitor to alsa sink
  local mon="${SINK_NAME}.monitor"
  if ! pactl list short modules | grep -q "module-loopback.*source=${mon}.*sink=alsa_loopback"; then
    log "Creating loopback: ${mon} -> alsa_loopback"
    pactl load-module module-loopback "source=${mon} sink=alsa_loopback latency_msec=50" >/dev/null || true
  fi

  pactl set-default-sink "$TARGET_SINK" >/dev/null 2>&1 || pactl set-default-sink "$SINK_NAME" >/dev/null 2>&1 || true
  log "Default sink set to: $(pactl get-default-sink 2>/dev/null || true)"
}

cmd="${1:-start}"
case "$cmd" in
  start) ensure_modules ;;
  stop)  log "Stop: non destructif (modules laissés en place)." ;;
  *) echo "Usage: $0 {start|stop}" >&2; exit 2 ;;
esac
EOF

  chmod 0755 /usr/local/bin/spotify-roon-pulse-bridge

  local h
  h="$(user_home "$SERVICE_USER")"
  install -d -m 0755 "$h/.config/systemd/user"

  cat >"$h/.config/systemd/user/spotify-roon-pulse-bridge.service" <<EOF
[Unit]
Description=Spotify Roon Bridge (Pulse bridge: null sink + loopback -> ALSA)
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=SINK_NAME=${SINK_NAME}
Environment=PULSE_TARGET_SINK=${PULSE_TARGET_SINK}
ExecStart=/usr/local/bin/spotify-roon-pulse-bridge start
ExecStop=/usr/local/bin/spotify-roon-pulse-bridge stop

[Install]
WantedBy=default.target
EOF

  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$h/.config/systemd/user"

  run_as_user "$SERVICE_USER" "
    systemctl --user daemon-reload
    systemctl --user enable --now spotify-roon-pulse-bridge.service
  "
}

########################################
# Liquidsoap
########################################
configure_liquidsoap() {
  log "Configuration Liquidsoap..."
  install -d -m 0755 /etc/spotify-roon-bridge

  local liq="/etc/spotify-roon-bridge/spotify-bridge.liq"

  local mp3_mount aac_mount flac_mount
  mp3_mount="$(mount_norm "$MOUNT_MP3")"
  aac_mount="$(mount_norm "$MOUNT_AAC")"
  flac_mount="$(mount_norm "$MOUNT_FLAC")"

  cat >"$liq" <<EOF
#!/usr/bin/liquidsoap

# Logging (Liquidsoap 2.3.x)
settings.log.file.path := "${LOG_FILE}"
settings.log.stdout := true
settings.log.level := 3

# ALSA capture (Loopback, capture side)
s = input.alsa(id="spotify_capture", device="${ALSA_CAPTURE_DEVICE}")

# Buffer anti-jitter
s = buffer(s, buffer=2.0, max=10.0)

# Always-on stream
src = fallback(track_sensitive=false, [mksafe(s), blank()])

# MP3
output.icecast(
  %mp3(bitrate=${MP3_BITRATE}, stereo=true),
  host="${ICECAST_HOST}", port=${ICECAST_PORT}, password="${ICECAST_SOURCE_PASSWORD}",
  mount="${mp3_mount}",
  name="Spotify (MP3 ${MP3_BITRATE})",
  description="Spotify -> Icecast (MP3)",
  src
)

# AAC (ADTS via ffmpeg)
output.icecast(
  %ffmpeg(
    format="adts",
    %audio(codec="aac", b="${AAC_BITRATE}", samplerate=${FLAC_SR}, channels=2)
  ),
  host="${ICECAST_HOST}", port=${ICECAST_PORT}, password="${ICECAST_SOURCE_PASSWORD}",
  mount="${aac_mount}",
  name="Spotify (AAC ${AAC_BITRATE})",
  description="Spotify -> Icecast (AAC)",
  src
)

# FLAC
output.icecast(
  %flac(samplerate=${FLAC_SR}, channels=2, bits_per_sample=${FLAC_BITS}),
  host="${ICECAST_HOST}", port=${ICECAST_PORT}, password="${ICECAST_SOURCE_PASSWORD}",
  mount="${flac_mount}",
  name="Spotify (FLAC ${FLAC_BITS}b/${FLAC_SR}Hz)",
  description="Spotify -> Icecast (FLAC)",
  src
)
EOF

  chmod 0644 "$liq"
  chown root:root "$liq"

  log "Validation liquidsoap --check (user=${SERVICE_USER})..."
  run_as_user "$SERVICE_USER" "liquidsoap --check /etc/spotify-roon-bridge/spotify-bridge.liq"
}

install_system_unit_liquidsoap() {
  log "Installation unit systemd (liquidsoap -> icecast)..."

  cat >/etc/systemd/system/spotify-roon-liquidsoap.service <<EOF
[Unit]
Description=Spotify Roon Bridge (Liquidsoap -> Icecast)
After=network.target sound.target icecast2.service
Wants=icecast2.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${LOG_GROUP}
SupplementaryGroups=audio
ExecStart=/usr/bin/liquidsoap /etc/spotify-roon-bridge/spotify-bridge.liq
Restart=always
RestartSec=2
UMask=002
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now spotify-roon-liquidsoap.service
}

write_public_conf() {
  install -d -m 0755 /etc/spotify-roon-bridge
  cat >/etc/spotify-roon-bridge/bridge.conf <<EOF
SERVICE_USER=${SERVICE_USER}
ICECAST_HOST=${ICECAST_HOST}
ICECAST_PORT=${ICECAST_PORT}
MOUNT_MP3=${MOUNT_MP3}
MOUNT_AAC=${MOUNT_AAC}
MOUNT_FLAC=${MOUNT_FLAC}
ALSA_CAPTURE_DEVICE=${ALSA_CAPTURE_DEVICE}
SINK_NAME=${SINK_NAME}
PULSE_TARGET_SINK=${PULSE_TARGET_SINK}
LOG_GROUP=${LOG_GROUP}
LOG_DIR=${LOG_DIR}
LOG_FILE=${LOG_FILE}
EOF
  chmod 0644 /etc/spotify-roon-bridge/bridge.conf
}

########################################
# Main
########################################
main() {
  require_root
  install_packages
  ensure_groups_and_perms
  enable_snd_aloop
  configure_icecast
  install_pulse_bridge
  configure_liquidsoap
  install_system_unit_liquidsoap
  write_public_conf

  log "OK."
  log "URLs:"
  log "  MP3 : http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_MP3}"
  log "  AAC : http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_AAC}"
  log "  FLAC: http://${ICECAST_HOST}:${ICECAST_PORT}${MOUNT_FLAC}"
}

main "$@"
