#!/usr/bin/env bash
# Gala installer.
#
# Installs everything needed and the app itself, for the current user:
#   1. System packages (build tools and libraries for OwnTone, GTK bindings,
#      tray support, pactl). Asks for your password once (sudo).
#   2. OwnTone, the AirPlay 2 server, built from source into
#      ~/.local/opt/owntone and run as a systemd user service.
#   3. The Gala app into ~/.local/share/gala, with an
#      app menu entry and icon. It also starts at login (can be turned off in
#      the app's menu).
#
# Run it as your normal user, not with sudo:   ./install.sh
#
# Options (environment variables):
#   OWNTONE_REF=<git ref>   OwnTone version to build (default: a tested commit)
#   SKIP_PACKAGES=1         don't install system packages
#   NO_SERVICE=1            don't install/start the systemd service
#   NO_LAUNCH=1             don't open the app at the end

set -euo pipefail

# OwnTone commit this app was tested with. Later versions can be installed from
# the app's menu (Update OwnTone). Release 29.3 is too old: HomePods running
# HomePod OS 27 refuse it.
OWNTONE_REF="${OWNTONE_REF:-8ed84f2b3cba25d3de65e05660d59ce034b5adab}"
OWNTONE_REPO="https://github.com/owntone/owntone-server.git"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNTONE_DIR="$HOME/.local/opt/owntone"
OWNTONE_SRC="$HOME/.local/src/owntone-server"
APP_DIR="$HOME/.local/share/gala"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
SERVICE_DIR="$HOME/.config/systemd/user"
APP_ID="app.gala.Gala"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root or with sudo. It will ask for your password when needed."
[ -f "$HERE/gala.py" ] || die "Run this from the Gala folder (gala.py not found)."

# --- 1. System packages ------------------------------------------------------

APT_PACKAGES=(
  # build tools
  build-essential git autotools-dev autoconf automake libtool gettext gawk gperf bison flex pkg-config
  # OwnTone libraries
  libconfuse-dev libunistring-dev libsqlite3-dev libavcodec-dev libavformat-dev libavfilter-dev
  libswscale-dev libavutil-dev libasound2-dev libxml2-dev libgcrypt20-dev libavahi-client-dev
  zlib1g-dev libevent-dev libplist-dev libsodium-dev libjson-c-dev libwebsockets-dev
  libcurl4-openssl-dev libprotobuf-c-dev libgnutls28-dev
  # the app
  python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 pulseaudio-utils avahi-daemon
)
DNF_PACKAGES=(
  gcc make git autoconf automake libtool gettext-devel gawk gperf bison flex pkgconf-pkg-config
  libconfuse-devel libunistring-devel sqlite-devel ffmpeg-free-devel alsa-lib-devel libxml2-devel
  libgcrypt-devel avahi-devel zlib-devel libevent-devel libplist-devel libsodium-devel json-c-devel
  libwebsockets-devel libcurl-devel protobuf-c-devel gnutls-devel
  python3 python3-gobject gtk3 libayatana-appindicator-gtk3 pulseaudio-utils avahi
)
PACMAN_PACKAGES=(
  base-devel git autoconf automake libtool gettext gawk gperf bison flex pkgconf
  confuse libunistring sqlite ffmpeg alsa-lib libxml2 libgcrypt avahi zlib libevent libplist
  libsodium json-c libwebsockets curl protobuf-c gnutls
  python python-gobject gtk3 libayatana-appindicator libpulse
)

# Packages this installer added (ones that weren't installed before), so
# uninstall.sh can offer to remove exactly those and nothing else.
PACKAGE_RECORD="$APP_DIR/installed-packages.txt"

is_installed() {  # <manager> <package>
  case "$1" in
    apt)    dpkg-query -W -f='${Status}' "$2" 2>/dev/null | grep -q "install ok installed" ;;
    dnf)    rpm -q "$2" >/dev/null 2>&1 ;;
    pacman) pacman -Qq "$2" >/dev/null 2>&1 ;;
  esac
}

record_new_packages() {  # <manager> <packages that were missing before>
  local manager="$1"; shift
  mkdir -p "$APP_DIR"
  [ -f "$PACKAGE_RECORD" ] || echo "# manager=$manager" >"$PACKAGE_RECORD"
  local pkg
  for pkg in "$@"; do
    if is_installed "$manager" "$pkg" && ! grep -qx "$pkg" "$PACKAGE_RECORD"; then
      echo "$pkg" >>"$PACKAGE_RECORD"
    fi
  done
}

install_packages() {
  bold "1/4  Installing system packages (you may be asked for your password)"
  local manager packages missing=() pkg
  if command -v apt-get >/dev/null; then
    manager=apt; packages=("${APT_PACKAGES[@]}")
  elif command -v dnf >/dev/null; then
    manager=dnf; packages=("${DNF_PACKAGES[@]}")
  elif command -v pacman >/dev/null; then
    manager=pacman; packages=("${PACMAN_PACKAGES[@]}")
  else
    die "Unsupported package manager. Install the packages listed in install.sh (APT_PACKAGES) by hand, then run again with SKIP_PACKAGES=1."
  fi
  for pkg in "${packages[@]}"; do
    is_installed "$manager" "$pkg" || missing+=("$pkg")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    info "All needed packages are already installed."
  else
    info "Installing: ${missing[*]}"
    case "$manager" in
      apt)    sudo apt-get update && sudo apt-get install -y "${missing[@]}" ;;
      dnf)    info "Fedora: ffmpeg-free-devel comes from Fedora; RPM Fusion's ffmpeg-devel also works."
              sudo dnf install -y "${missing[@]}" ;;
      pacman) sudo pacman -S --needed --noconfirm "${missing[@]}" ;;
    esac
    record_new_packages "$manager" "${missing[@]}"
  fi

  if command -v systemctl >/dev/null && ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    info "Starting the Avahi service (finds AirPlay devices on your network)"
    sudo systemctl enable --now avahi-daemon || info "Couldn't start avahi-daemon; device discovery may not work."
  fi
}

if [ "${SKIP_PACKAGES:-0}" = 1 ]; then
  bold "1/4  Skipping system packages (SKIP_PACKAGES=1)"
else
  install_packages
fi

command -v pactl >/dev/null || die "pactl not found. Gala needs PipeWire (with pipewire-pulse) or PulseAudio."
pactl info >/dev/null 2>&1 || info "Note: pactl can't reach the sound server right now; that's fine during install, but the app needs PipeWire/PulseAudio running."

# --- 2. OwnTone ---------------------------------------------------------------

bold "2/4  Building OwnTone (the AirPlay 2 server). This takes a few minutes."
mkdir -p "$(dirname "$OWNTONE_SRC")"
if [ -d "$OWNTONE_SRC/.git" ]; then
  info "Updating existing source in $OWNTONE_SRC"
  git -C "$OWNTONE_SRC" fetch -q origin
else
  info "Downloading OwnTone source"
  git clone -q "$OWNTONE_REPO" "$OWNTONE_SRC"
fi
git -C "$OWNTONE_SRC" checkout -q "$OWNTONE_REF"
info "Version: $(git -C "$OWNTONE_SRC" log -1 --format='%h (%cd)' --date=short)"

LOG="$(mktemp -t owntone-build.XXXXXX.log)"
(
  cd "$OWNTONE_SRC"
  autoreconf -fi
  ./configure --prefix="$OWNTONE_DIR" --sysconfdir="$OWNTONE_DIR/etc" \
    --localstatedir="$OWNTONE_DIR/var" --disable-spotify \
    --disable-install_systemd --disable-install-user
  make -j"$(nproc)"
) >"$LOG" 2>&1 || die "Building OwnTone failed. Build log: $LOG"
info "Built. (Build log: $LOG)"

# Stop a running OwnTone before replacing its files.
if [ "${NO_SERVICE:-0}" != 1 ] && systemctl --user is-active --quiet owntone 2>/dev/null; then
  systemctl --user stop owntone
fi
make -C "$OWNTONE_SRC" install >>"$LOG" 2>&1 || die "Installing OwnTone failed. Build log: $LOG"

# Configure OwnTone: run as this user, and watch a folder that holds the pipe
# this computer's audio is fed into.
CONF="$OWNTONE_DIR/etc/owntone.conf"
MUSIC="$OWNTONE_DIR/var/music"
mkdir -p "$MUSIC" "$OWNTONE_DIR/var/log" "$OWNTONE_DIR/var/cache/owntone"
sed -i -E "s|^(\s*)uid = \".*\"|\1uid = \"$USER\"|" "$CONF"
sed -i -E "s|^(\s*)directories = \{.*\}|\1directories = { \"$MUSIC\" }|" "$CONF"
for fifo in "$MUSIC/pc-audio.fifo" "$MUSIC/pc-audio.fifo.metadata"; do
  [ -p "$fifo" ] || mkfifo "$fifo"
done
info "Installed to $OWNTONE_DIR"

if [ "${NO_SERVICE:-0}" = 1 ]; then
  info "Skipping the OwnTone service (NO_SERVICE=1)"
else
  mkdir -p "$SERVICE_DIR"
  cat >"$SERVICE_DIR/owntone.service" <<EOF
[Unit]
Description=OwnTone media server (AirPlay 2 output for Gala)
After=network-online.target sound.target

[Service]
ExecStart=$OWNTONE_DIR/sbin/owntone -f -c $OWNTONE_DIR/etc/owntone.conf
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now owntone.service
  info "OwnTone is running (systemd user service 'owntone')"
fi

# --- 3. The app -----------------------------------------------------------------

bold "3/4  Installing the Gala app"
mkdir -p "$APP_DIR" "$ICON_DIR" "$DESKTOP_DIR"
install -m 755 "$HERE/gala.py" "$APP_DIR/gala.py"
install -m 644 "$HERE/gala.svg" "$APP_DIR/gala.svg"
install -m 644 "$HERE/gala.svg" "$ICON_DIR/gala.svg"
# Use the system Python: that's where the distro's GTK bindings are installed
# (a python3 from Homebrew, pyenv or conda earlier in PATH won't have them).
PYTHON=/usr/bin/python3
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
"$PYTHON" -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
  || die "$PYTHON can't load GTK 3 (python3-gi / python3-gobject missing?)."
cat >"$DESKTOP_DIR/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Gala
GenericName=AirPlay On Linux
Comment=Send this computer's audio to AirPlay speakers, HomePods and Apple TVs
Exec=$PYTHON "$APP_DIR/gala.py"
Icon=$ICON_DIR/gala.svg
Terminal=false
StartupWMClass=$APP_ID
Categories=AudioVideo;Audio;
Keywords=AirPlay;HomePod;Apple TV;speaker;audio;output;stream;
EOF
update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
info "Installed to $APP_DIR, with an app menu entry"

# --- 4. Done --------------------------------------------------------------------

bold "4/4  Done!"
cat <<EOF
  Open "Gala" from your app menu, click "Start AirPlay Discovery"
  and pick a speaker. The app also starts at login (turn that off in its ☰ menu).

  Tips:
  - HomePods/Apple TVs: in the Home app, set Home Settings > Speakers & TV >
    "Allow Speaker & TV Access" to "Everyone" or "Anyone on the Same Network".
  - An Apple TV may show a 4-digit code the first time; type it into the app.
  - To uninstall: ./uninstall.sh
EOF

if [ "${NO_LAUNCH:-0}" != 1 ] && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  setsid -f "$PYTHON" "$APP_DIR/gala.py" >/dev/null 2>&1 || true
fi
