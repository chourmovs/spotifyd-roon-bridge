# spotifyd-roon-bridge

Bridge Spotify Connect (spotifyd) -> ALSA Loopback -> Liquidsoap -> Icecast.

## Features
- System services (no systemd --user)
- ALSA loopback mapping frozen:
  - spotifyd OUT: `plughw:CARD=Loopback,DEV=0,SUBDEV=0`
  - liquidsoap IN: `plughw:CARD=Loopback,DEV=1,SUBDEV=0`
- Icecast mounts:
  - `/spotify.mp3` (MP3 320k)
  - `/spotify.aac` (AAC 320k ADTS via %ffmpeg)

## Requirements
- Debian 12+ (tested)
- Packages installed by installer: `icecast2`, `liquidsoap`, `alsa-utils`, `avahi-daemon`, etc.

## Install
```bash
chmod +x install_spotify_roon_bridge.sh uninstall_spotify_roon_bridge.sh status.sh
sudo ./install_spotify_roon_bridge.sh
