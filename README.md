# Gala - AirPlay On Linux

Send your Linux computer's audio to AirPlay speakers: HomePods, Apple TVs,
AirPlay-enabled receivers and Macs, one at a time or several in sync.

Gala is a small app that lives in your system tray. Pick a speaker and
everything you play on your computer comes out of it.

## Features

- **Any AirPlay 2 device**, including HomePods and Apple TVs (through
  [OwnTone](https://github.com/owntone/owntone-server), which the installer
  builds for you)
- **Stereo pairs** detected automatically and shown as one speaker
- **Multiple speakers** at once, kept in sync
- **Volume sliders** per speaker, kept in step with Siri and the Home app
- **Now playing** on the Apple TV / Home app: title, artist, album and cover
  art from Spotify or any MPRIS media player
- **Remote control**: play, pause, next and previous from an Apple TV remote
  or HomePod control your media player
- **Apple TV pairing**: type the 4-digit code shown on the TV into the app
- **System tray** icon, start at login, close/minimize to tray
- **Favorites and hidden devices**, with offline devices marked
- **Remembers** your last speaker and reconnects to it
- **Update OwnTone** from the app's menu

## Install

```bash
git clone https://github.com/ThatOneGuy808/gala.git
cd gala
./install.sh
```

That's it. The script:

1. installs the system packages it needs (asks for your password once),
2. builds OwnTone and runs it as a background service for your user,
3. installs Gala with an app menu entry and starts it.

Run it as your normal user, **not** with `sudo`. Building OwnTone takes a few
minutes.

**Requirements:** Linux with PipeWire (or PulseAudio) and systemd. The installer
supports apt (Debian, Ubuntu, Mint…), dnf (Fedora) and pacman (Arch). Tested on
Ubuntu 26.04 with KDE Plasma on Wayland; other distributions and desktops
should work but are less tested.

## Using it

1. Open **Gala** from your app menu.
2. Click **Start AirPlay Discovery**. Your AirPlay devices appear in the list.
3. Click a speaker. Your computer's audio now plays there. Click your
   computer's own output to switch back.

Turn on **Multiple speakers** to tick several speakers at once. Right-click a
device to favorite or hide it. The ☰ menu has the rest of the options.

### HomePods and Apple TVs

- In the Home app, set **Home Settings → Speakers & TV → Allow Speaker & TV
  Access** to **Everyone** or **Anyone on the Same Network**, with no password.
  With "Only People Sharing This Home", the devices refuse the connection.
- The first time you play to an Apple TV, it may show a 4-digit code. Type it
  into the box that appears in Gala and press **Pair**. This is needed only
  once per Apple TV.
- For Macs: **System Settings → General → AirDrop & Handoff → AirPlay Receiver
  → Allow AirPlay for: Everyone on the same network**.

### Good to know

- AirPlay 2 buffers about 2 seconds, so audio lags slightly behind video.
- A pause from an AirPlay remote takes about 3 seconds to reach the media
  player.
- On Wayland, only Gala's own minimize button can minimize to the tray.

## Troubleshooting

- **No devices found**: check that the Avahi service is running
  (`systemctl status avahi-daemon`) and that your computer is on the same
  network as the speakers. A firewall must allow mDNS (UDP 5353).
- **"Can't reach OwnTone"**: check the service with
  `systemctl --user status owntone`. Its log is at
  `~/.local/opt/owntone/var/log/owntone.log`.
- **A device is listed but silent**: look for `403 Forbidden` or pairing
  messages in the OwnTone log, and check the Home app access setting above.

## Uninstall

```bash
./uninstall.sh
```

This removes Gala, OwnTone (including its database and Apple TV pairings) and
the settings. It then lists the system packages that `install.sh` installed and
that nothing else on your system needs, and asks before removing them.
Packages that were already installed before Gala, or that other software uses,
are kept. Add `DRY_RUN=1` to see what would be removed without changing
anything.

## How it works

Gala adds a PipeWire output that writes your computer's audio into a pipe.
OwnTone reads the pipe and streams it over AirPlay 2 to the speakers Gala
selects through OwnTone's local web API. Song information is read from your
media player over MPRIS and passed to OwnTone through a second pipe.

Installed files:

| What | Where |
|---|---|
| App | `~/.local/share/gala/` (settings are stored here too) |
| OwnTone | `~/.local/opt/owntone/` (source in `~/.local/src/owntone-server/`) |
| OwnTone service | `~/.config/systemd/user/owntone.service` |
| Menu and login entries | `~/.local/share/applications/`, `~/.config/autostart/` |

## Credits

Audio streaming is done by [OwnTone](https://github.com/owntone/owntone-server),
which `install.sh` downloads and builds from source. It isn't included in this
repository.

AirPlay, HomePod and Apple TV are trademarks of Apple Inc. This project isn't
affiliated with or endorsed by Apple.
