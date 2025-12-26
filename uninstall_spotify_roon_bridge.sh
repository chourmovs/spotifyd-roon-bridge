#!/usr/bin/env bash
set -euo pipefail

die(){ echo "✖ $*" >&2; exit 1; }
ok(){  echo "✔ $*"; }
require_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo $0"; }

main() {
  require_root

  read -rp "Remove bridge services/configs (keep packages). Continue? [y/N] " yn
  [[ "${yn:-n}" =~ ^[yY]$ ]] || exit 0

  systemctl disable --now liquidsoap-spotify 2>/dev/null || true
  rm -f /etc/systemd/system/liquidsoap-spotify.service
  rm -f /etc/liquidsoap/spotify.liq /etc/liquidsoap/spotify_icecast.liq
  ok "Liquidsoap bridge removed"

  systemctl disable --now spotifyd 2>/dev/null || true
  rm -f /etc/systemd/system/spotifyd.service
  ok "spotifyd system service removed (binary kept: /usr/local/bin/spotifyd)"

  systemctl daemon-reload || true

  if [[ -f /etc/icecast2/icecast.xml.bak.spotify-roon-bridge ]]; then
    cp -a /etc/icecast2/icecast.xml.bak.spotify-roon-bridge /etc/icecast2/icecast.xml
    systemctl restart icecast2 2>/dev/null || true
    ok "icecast.xml restored from backup"
  else
    ok "No icecast.xml backup found"
  fi

  echo ""
  echo "Uninstall done."
  echo "Optional purge packages:"
  echo "  apt-get purge icecast2 liquidsoap avahi-daemon alsa-utils"
}

main "$@"
