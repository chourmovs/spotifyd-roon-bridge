# spotifyd-roon-bridge

Bridge Spotify Connect (spotifyd) -> ALSA Loopback -> Liquidsoap -> Icecast.

This project transforms a reliable Spotify Connect session (spotifyd) into an Icecast web radio stream, which can be played on any device that can open a URL (Antipodes, closed audiophile players, IP radios, network amplifiers, etc.).
Objective: to add Spotify Connect to closed-source devices without custom firmware, plugins, or reverse engineering on the hardware side.

## The promise 

✅ A true Spotify Connect device (visible in the Spotify app)

✅ Icecast output (MP3/AAC/FLAC depending on your profile)

✅ Compatible with closed players via their Webradio/HTTP stream input

✅ Standalone service (systemd), reproducible, “homelab friendly”

## Why this exists
Closed audiophile players (e.g., Antipodes and equivalents) often offer flawless Webradio/HTTP playback... but not Spotify Connect, or a fragile/unsupported Connect.
Classic open-source solutions (spotifyd, librespot, Raspotify) solve Spotify Connect, but output local audio. They don't help you power a closed device that can't run your code.
This bridge solves exactly that gap:
Server-side Spotify Connect (reliable, standard)
Network-side HTTP audio stream (universal)
Result: your closed-source hardware becomes “Spotify Connect compatible” via its web radio player, without installing anything on it.

## Non-objectives (useful for avoiding absurd issues)
This is not an alternative UI-oriented “Spotify client.”
This is not a Snapcast-type multiroom system.
This is not a hack on the player's firmware.

## Primary audience
Audiophiles / hi-fi network players: Antipodes, closed network players, DAC/streamers with URL input
Homelab: Debian VM/NAS, systemd services, Nginx Proxy Manager, audio VLAN
Roon users: who want to keep their stack but “add Spotify” to otherwise limited hardware

## Secondary audience
Makers / IP radios / home automation integrators: need a stable HTTP stream controllable from Spotify

## Features

<img width="1162" height="89" alt="image" src="https://github.com/user-attachments/assets/f5931902-cd3b-4f31-ba0b-e4aa9889fb9b" />

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

access to your streamlist at http://debianip:8000

Add desired stream into the "own webradio" section of your streamer.