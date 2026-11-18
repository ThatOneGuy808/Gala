# Gala - AirPlay On Linux

**THIS PROJECT WAS MADE WITH THE HELP OF AI**. I do not know anything about coding, this project was made for fun. I am sharing it here though because I still think it may be useful to some. But please be aware that this project was coded with AI. Project details are below
** **


Gala is an app for Linux that allows you to stream your computer's audio over AirPlay to any AirPlay 1 & 2 device on your network! It has a simple, easy to use GUI, and will work with Apple TVs, HomePods, Macs, and more!

<img width="648" height="813" alt="image" src="https://github.com/user-attachments/assets/448f655a-beba-4911-a796-cbba53fc0030" />

## Features
- Works with any AirPlay 1 & 2 device (Apple TV, HomePod, Mac, etc.)
- Multiple speaker support
- Favorite or hide devices
- Independent volume control
- Launch on start
- Tray icon
- Media controls from Apple TV (experimental and is a little janky)

## OS Support

**This has only been tested on Ubuntu (Kubuntu), and partially tested on Fedora, so it may not work on all systems.**

**Other distros are work in progress.**

**A Windows version is planned for the future**

| OS               | Status                             |
|------------------|------------------------------------|
| Ubuntu/Debian    | ✅ Supported                       | 
| Fedora           | ✅ Supported (Still being tested)  | 
| Arch             | ⚠️ Untested                        |
| openSUSE         | ⚠️ Untested                        |
| BSD              | ❌ Not supported (planned)                        |
| Windows          | ❌ Not supported (planned)         |

## Install

```bash
git clone https://github.com/ThatOneGuy808/gala.git
cd gala
./install.sh
```

## Uninstall

```bash
cd gala
./uninstall.sh
```

## How to Use

1. Open up **Gala** from the application launcher
2. Click **Start AirPlay Discovery**. Your AirPlay devices appear in the list.
3. Click on the device you want to use. You can also play from multiple speakers
   with the toggle at top right
4. Favorite or hide a device by rick clicking on a device. Favorites will stick to the top
   and hidden ones will go to a menu at the very top right

### Some settings to change

- In the Home app on your iPhone, iPad, or Mac, go to your Home Settings,
  or device settings, and enable **Allow Speaker & TV Access** to **Everyone**
  - For Macs: **System Settings → General → AirDrop & Handoff → AirPlay Receiver
  → Allow AirPlay for: Everyone on the same network**.
  or **Anyone on the Same Network**. Make sure password is off
- The first time you connect to an Apple TV, it may prompt you with a 4-digit code. Type the code
  into the box that appears in Gala at the bottom of the window and press **Pair** or enter.


## Troubleshooting

- **No devices found**: check that the Avahi service is running
  (`systemctl status avahi-daemon`) and that your computer is on the same
  network as the speakers. A firewall must allow mDNS (UDP 5353).
- **"Can't reach OwnTone"**: check the service with
  `systemctl --user status owntone`. Its log is at
  `~/.local/opt/owntone/var/log/owntone.log`.
- **A device is listed but silent**: look for `403 Forbidden` or pairing
  messages in the OwnTone log
- **Unable to connect to a devce**: Check Home/Mac settings (see above)

Installed files:

| What | Where |
|---|---|
| App | `~/.local/share/gala/` (settings are stored here too) |
| OwnTone | `~/.local/opt/owntone/` (source in `~/.local/src/owntone-server/`) |
| OwnTone service | `~/.config/systemd/user/owntone.service` |
| Menu and login entries | `~/.local/share/applications/`, `~/.config/autostart/` |

## Disclaimer and Credits

**THIS PROJECT WAS MADE WITH THE HELP OF AI**. I do not know anything about coding, 
this project was made for fun. I am sharing it here though because I still think it may 
be useful to some. But please be aware that this project was coded with AI

This project is heavily based on [OwnTone](https://github.com/owntone/owntone-server). 
A lot of the code is taken and or modified to work with this project.

Mac, AirPlay, HomePod and Apple TV are trademarks of Apple Inc. This project isn't
affiliated with or endorsed by Apple.
