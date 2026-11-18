#!/usr/bin/env bash
# Gala installer.
#
# Detects your system, then installs everything needed and the app itself, for
# the current user:
#   1. System packages (build tools and libraries for OwnTone, GTK bindings,
#      tray support, pactl). Asks for your password once (sudo).
#   2. OwnTone, the AirPlay 2 server, built from source into ~/.local/opt/owntone.
#      Runs as a systemd user service where available; otherwise Gala starts it.
#   3. The Gala app into ~/.local/share/gala, with an app menu entry and icon.
#      It also starts at login (can be turned off in the app's menu).
#
# Run it as your normal user, not with sudo:   ./install.sh
#
# Supported package managers: apt (Debian, Ubuntu, Mint, Pop!_OS…), dnf (Fedora,
# RHEL-likes), zypper (openSUSE) and pacman (Arch, Manjaro, EndeavourOS…).
#
# Options (environment variables):
#   DRY_RUN=1               show what was detected and what would be done; change nothing
#   OWNTONE_REF=<git ref>   OwnTone version to build (default: a tested commit)
#   SKIP_PACKAGES=1         don't install system packages (install them yourself)
#   NO_SERVICE=1            don't set up/start OwnTone's background service
#   NO_LAUNCH=1             don't open the app at the end
#   NO_FIREWALL=1           don't offer to open firewall ports
#   OS_RELEASE=<file>       read the distro from this file instead of /etc/os-release (testing)
#   PKG_MANAGER=<name>      use this package manager instead of detecting it (testing)

set -euo pipefail

# OwnTone commit Gala was tested with. Later versions can be installed from the
# app's menu (Update OwnTone). Release 29.3 is too old: HomePods running
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
DRY_RUN="${DRY_RUN:-0}"
# Fixed UDP ports for the connections AirPlay 2 devices make back to OwnTone
# (random by default, which no firewall rule can allow).
AIRPLAY_CONTROL_PORT=3690
AIRPLAY_TIMING_PORT=3691

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "  $1 [Y/n] " a; [[ ! "$a" =~ ^[Nn] ]]; }

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root or with sudo. It will ask for your password when needed."
[ -f "$HERE/gala.py" ] || die "Run this from the Gala folder (gala.py not found)."

# --- System detection ----------------------------------------------------------

detect_system() {
  local release="${OS_RELEASE:-/etc/os-release}"
  OS_NAME="Unknown Linux"; OS_ID=""; OS_LIKE=""; OS_VARIANT=""
  if [ -r "$release" ]; then
    OS_NAME="$(. "$release"; echo "${PRETTY_NAME:-${NAME:-Linux}}")"
    OS_ID="$(. "$release"; echo "${ID:-}")"
    OS_LIKE="$(. "$release"; echo "${ID_LIKE:-}")"
    OS_VARIANT="$(. "$release"; echo "${VARIANT_ID:-}")"
  fi

  # Package manager: forced, then by distro family, then whatever is installed.
  PKG="${PKG_MANAGER:-}"
  if [ -z "$PKG" ]; then
    case " $OS_ID $OS_LIKE " in
      *" debian "*|*" ubuntu "*)                     PKG=apt ;;
      *" fedora "*|*" rhel "*|*" centos "*)          PKG=dnf ;;
      *" opensuse "*|*" suse "*|*opensuse-*)         PKG=zypper ;;
      *" arch "*)                                    PKG=pacman ;;
    esac
    if [ -z "$PKG" ] || ! command -v "${PKG/apt/apt-get}" >/dev/null; then
      PKG=none
      for candidate in apt-get dnf zypper pacman; do
        command -v "$candidate" >/dev/null && { PKG="${candidate/apt-get/apt}"; break; }
      done
    fi
  fi

  # Immutable / image-based systems can't install packages the normal way.
  IMMUTABLE=no
  if [ -e /run/ostree-booted ] || [ "$OS_ID" = steamos ] || [[ " $OS_ID $OS_LIKE " == *" nixos "* ]] \
     || [[ " silverblue kinoite sericea onyx iot coreos " == *" $OS_VARIANT "* && -n "$OS_VARIANT" ]]; then
    IMMUTABLE=yes
  fi

  # systemd user services (OwnTone's background service).
  if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    INIT=systemd
  else
    INIT=other
  fi

  DESKTOP="${XDG_CURRENT_DESKTOP:-unknown}"
  SESSION="${XDG_SESSION_TYPE:-unknown}"

  # Tray icons (StatusNotifier): KDE, Xfce, Cinnamon… have it; plain GNOME
  # needs the AppIndicator extension.
  TRAY=unknown
  if command -v gdbus >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
         --method org.freedesktop.DBus.NameHasOwner org.kde.StatusNotifierWatcher 2>/dev/null | grep -q true; then
      TRAY=yes
    else
      TRAY=no
    fi
  fi

  # Sound server: Gala uses pactl, which works with PulseAudio and with
  # PipeWire's PulseAudio layer (pipewire-pulse).
  AUDIO=unknown
  if command -v pactl >/dev/null && pactl info >/dev/null 2>&1; then
    pactl info 2>/dev/null | grep -qi pipewire && AUDIO=pipewire || AUDIO=pulseaudio
  elif pgrep -x pipewire >/dev/null 2>&1; then
    AUDIO=pipewire-without-pulse
  elif pgrep -x pulseaudio >/dev/null 2>&1; then
    AUDIO=pulseaudio
  fi

  FIREWALL=none
  if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    FIREWALL=firewalld
  elif command -v ufw >/dev/null && systemctl is-active --quiet ufw 2>/dev/null \
       && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
    FIREWALL=ufw
  fi

  PYTHON=/usr/bin/python3
  [ -x "$PYTHON" ] || PYTHON="$(command -v python3 || echo /usr/bin/python3)"
}

show_system() {
  bold "Detected system"
  info "Distribution:    $OS_NAME"
  info "Package manager: $PKG"
  info "Background services: $([ "$INIT" = systemd ] && echo "systemd (user services)" || echo "no systemd user session; Gala will start OwnTone itself")"
  info "Desktop:         $DESKTOP ($SESSION)"
  info "Tray icons:      $TRAY"
  info "Sound server:    $AUDIO"
  info "Firewall:        $FIREWALL"
  [ "$IMMUTABLE" = yes ] && info "Immutable system: yes"
  return 0
}

detect_system
show_system

if [ "$IMMUTABLE" = yes ]; then
  die "This looks like an immutable system ($OS_NAME). Its system packages can't be installed
       the usual way, so the installer can't continue. You can try installing the packages
       listed in install.sh with your system's layering tool (e.g. rpm-ostree install …),
       rebooting, and running again with SKIP_PACKAGES=1."
fi

# --- 1. System packages ----------------------------------------------------------

# apt and pacman names are checked against Ubuntu 26.04 and the Arch package
# database. dnf and zypper use capabilities (pkgconfig(…), typelib(…), file
# paths) where possible, so the right package is found whatever it's called.
APT_PACKAGES=(
  build-essential git autotools-dev autoconf automake libtool gettext gawk gperf bison flex pkg-config
  libconfuse-dev libunistring-dev libsqlite3-dev libavcodec-dev libavformat-dev libavfilter-dev
  libswscale-dev libavutil-dev libasound2-dev libxml2-dev libgcrypt20-dev libavahi-client-dev
  zlib1g-dev libevent-dev libplist-dev libsodium-dev libjson-c-dev libwebsockets-dev
  libcurl4-openssl-dev libprotobuf-c-dev libgnutls28-dev
  python3 python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 pulseaudio-utils avahi-daemon
)
DNF_PACKAGES=(
  gcc make git autoconf automake libtool gettext-devel gawk gperf bison flex pkgconf-pkg-config
  # Libraries by pkg-config name, so dnf picks whichever package provides them on
  # this release (Fedora 45 replaced protobuf-c with protobuf3-c, for example).
  "pkgconfig(libconfuse)" libunistring-devel "pkgconfig(sqlite3)"
  "pkgconfig(libavcodec)" "pkgconfig(libavformat)" "pkgconfig(libavfilter)" "pkgconfig(libswscale)" "pkgconfig(libavutil)"
  "pkgconfig(alsa)" "pkgconfig(libxml-2.0)" "pkgconfig(libgcrypt)" "pkgconfig(avahi-client)" "pkgconfig(zlib)"
  "pkgconfig(libevent)" "pkgconfig(libplist-2.0)" "pkgconfig(libsodium)" "pkgconfig(json-c)"
  "pkgconfig(libwebsockets)" "pkgconfig(libcurl)" "pkgconfig(libprotobuf-c)" "pkgconfig(gnutls)"
  python3 python3-gobject gtk3 libayatana-appindicator-gtk3 pulseaudio-utils avahi
)
ZYPPER_PACKAGES=(
  gcc make git autoconf automake libtool gettext-tools gawk gperf bison flex /usr/bin/pkg-config
  "pkgconfig(libconfuse)" libunistring-devel "pkgconfig(sqlite3)"
  "pkgconfig(libavcodec)" "pkgconfig(libavformat)" "pkgconfig(libavfilter)" "pkgconfig(libswscale)" "pkgconfig(libavutil)"
  "pkgconfig(alsa)" "pkgconfig(libxml-2.0)" "pkgconfig(libgcrypt)" "pkgconfig(avahi-client)" "pkgconfig(zlib)"
  "pkgconfig(libevent)" "pkgconfig(libplist-2.0)" "pkgconfig(libsodium)" "pkgconfig(json-c)"
  "pkgconfig(libwebsockets)" "pkgconfig(libcurl)" "pkgconfig(libprotobuf-c)" "pkgconfig(gnutls)"
  python3 python3-gobject "typelib(Gtk) = 3.0" "typelib(AyatanaAppIndicator3)" /usr/bin/pactl avahi
)
PACMAN_PACKAGES=(
  base-devel git autoconf automake libtool gettext gawk gperf bison flex pkgconf
  confuse libunistring sqlite ffmpeg alsa-lib libxml2 libgcrypt avahi zlib libevent libplist
  libsodium json-c libwebsockets curl protobuf-c gnutls
  python python-gobject gtk3 libayatana-appindicator libpulse
)

# Extras that depend on the detected system (installed if available; a failure
# here doesn't stop the install).
EXTRAS=()
if [ "$TRAY" = no ] && [[ "$DESKTOP" == *GNOME* ]]; then
  EXTRAS+=(gnome-shell-extension-appindicator)   # same name on all four package managers
fi
if [ "$AUDIO" = pipewire-without-pulse ]; then
  case "$PKG" in
    apt|pacman) EXTRAS+=(pipewire-pulse) ;;
    dnf|zypper) EXTRAS+=(pipewire-pulseaudio) ;;
  esac
fi

# Packages this installer added (ones that weren't installed before), so
# uninstall.sh can offer to remove exactly those and nothing else.
PACKAGE_RECORD="$APP_DIR/installed-packages.txt"

is_installed() {  # <package or capability>
  case "$PKG" in
    apt)        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    dnf|zypper) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    pacman)     pacman -T "$1" >/dev/null 2>&1 ;;
  esac
}

package_name() {  # the real package name behind a capability (for the record)
  case "$PKG" in
    dnf|zypper) rpm -q --whatprovides --qf '%{NAME}\n' "$1" 2>/dev/null | head -1 ;;
    *)          echo "$1" ;;
  esac
}

pkg_install() {  # <packages…>
  case "$PKG" in
    apt)    sudo apt-get update && sudo apt-get install -y "$@" ;;
    dnf)    sudo dnf install -y "$@" ;;
    zypper) sudo zypper --non-interactive install "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm "$@" ;;
  esac
}

record_new_packages() {  # <packages that were missing before>
  mkdir -p "$APP_DIR"
  [ -f "$PACKAGE_RECORD" ] || echo "# manager=$PKG" >"$PACKAGE_RECORD"
  local p name
  for p in "$@"; do
    is_installed "$p" || continue
    name="$(package_name "$p")"
    [ -n "$name" ] && ! grep -qx "$name" "$PACKAGE_RECORD" && echo "$name" >>"$PACKAGE_RECORD"
  done
  return 0
}

install_packages() {
  bold "1/4  System packages"
  local packages=() missing=() extras_missing=() p
  case "$PKG" in
    apt)    packages=("${APT_PACKAGES[@]}") ;;
    dnf)    packages=("${DNF_PACKAGES[@]}") ;;
    zypper) packages=("${ZYPPER_PACKAGES[@]}") ;;
    pacman) packages=("${PACMAN_PACKAGES[@]}") ;;
    *)
      warn "No supported package manager found (apt, dnf, zypper or pacman)."
      info "Install these with your system's package manager, then run again with SKIP_PACKAGES=1:"
      info "  - C build tools, git, autoconf, automake, libtool, gettext, gawk, gperf, bison, flex, pkg-config"
      info "  - development files for: libconfuse, libunistring, sqlite3, FFmpeg (libavcodec, libavformat,"
      info "    libavfilter, libswscale, libavutil), ALSA, libxml2, libgcrypt, Avahi (client), zlib, libevent,"
      info "    libplist, libsodium, json-c, libwebsockets, libcurl, protobuf-c, GnuTLS"
      info "  - Python 3 with PyGObject, GTK 3 and Ayatana AppIndicator 3 introspection data"
      info "  - pactl (PulseAudio utilities), and the Avahi daemon"
      [ "$DRY_RUN" = 1 ] && return 0
      exit 1 ;;
  esac
  for p in "${packages[@]}"; do
    # pkg-config is packaged under different names across releases; the command
    # being there is what counts.
    case "$p" in pkg-config|pkgconf|pkgconf-pkg-config|/usr/bin/pkg-config)
      command -v pkg-config >/dev/null && continue ;;
    esac
    is_installed "$p" || missing+=("$p")
  done
  for p in "${EXTRAS[@]}"; do is_installed "$p" || extras_missing+=("$p"); done

  if [ ${#missing[@]} -eq 0 ] && [ ${#extras_missing[@]} -eq 0 ]; then
    info "All needed packages are already installed."
  elif [ "$DRY_RUN" = 1 ]; then
    [ ${#missing[@]} -gt 0 ] && info "Would install (${#missing[@]}): ${missing[*]}"
    [ ${#extras_missing[@]} -gt 0 ] && info "Would also try: ${extras_missing[*]}"
  else
    info "You may be asked for your password."
    if [ ${#missing[@]} -gt 0 ]; then
      info "Installing ${#missing[@]} packages: ${missing[*]}"
      pkg_install "${missing[@]}" || die "Installing packages failed (see the messages above)."
      record_new_packages "${missing[@]}"
    fi
    if [ ${#extras_missing[@]} -gt 0 ]; then
      info "Installing: ${extras_missing[*]}"
      if pkg_install "${extras_missing[@]}"; then
        record_new_packages "${extras_missing[@]}"
      else
        warn "Couldn't install ${extras_missing[*]}; continuing without."
      fi
    fi
  fi

  if [ "$DRY_RUN" != 1 ] && command -v systemctl >/dev/null && ! systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    info "Starting the Avahi service (finds AirPlay devices on your network)"
    sudo systemctl enable --now avahi-daemon || warn "Couldn't start avahi-daemon; device discovery may not work."
  fi
}

if [ "${SKIP_PACKAGES:-0}" = 1 ]; then
  bold "1/4  Skipping system packages (SKIP_PACKAGES=1)"
else
  install_packages
fi

if [ "$DRY_RUN" = 1 ]; then
  bold "Dry run: what would happen next"
  info "2/4  Build OwnTone ${OWNTONE_REF:0:8} into $OWNTONE_DIR (AirPlay ports UDP $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT)"
  if [ "$INIT" = systemd ]; then
    info "     and run it as the systemd user service 'owntone'"
  else
    info "     (no systemd user session: Gala starts OwnTone when it opens)"
  fi
  case "$FIREWALL" in
    firewalld) info "     Offer to allow mDNS and UDP $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT in firewalld" ;;
    ufw)       info "     Offer to allow UDP 5353 and $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT in ufw" ;;
  esac
  info "3/4  Install Gala into $APP_DIR with an app menu entry (using $PYTHON)"
  [ "$TRAY" = no ] && info "     No tray on this desktop: closing Gala will quit it instead of hiding it"
  bold "Dry run finished: nothing was changed."
  exit 0
fi

# Checks that need the packages in place.
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null \
  || die "Gala needs Python 3.9 or newer ($PYTHON is older)."
"$PYTHON" -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
  || die "$PYTHON can't load GTK 3 (PyGObject / GTK 3 introspection data missing?)."
command -v pactl >/dev/null || die "pactl not found. Gala needs PipeWire (with its PulseAudio layer) or PulseAudio."
pactl info >/dev/null 2>&1 || warn "pactl can't reach the sound server right now. Gala needs PipeWire's PulseAudio layer (pipewire-pulse) or PulseAudio running; you may need to log out and back in."

# --- 2. OwnTone ---------------------------------------------------------------------

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
if [ "$INIT" = systemd ] && systemctl --user is-active --quiet owntone 2>/dev/null; then
  systemctl --user stop owntone
elif [ -f "$OWNTONE_DIR/var/owntone.pid" ]; then
  kill "$(cat "$OWNTONE_DIR/var/owntone.pid")" 2>/dev/null || true
fi
make -C "$OWNTONE_SRC" install >>"$LOG" 2>&1 || die "Installing OwnTone failed. Build log: $LOG"

# Configure OwnTone: run as this user, watch the folder holding the pipe this
# computer's audio is fed into, and use fixed ports for AirPlay 2 connections.
CONF="$OWNTONE_DIR/etc/owntone.conf"
MUSIC="$OWNTONE_DIR/var/music"
mkdir -p "$MUSIC" "$OWNTONE_DIR/var/log" "$OWNTONE_DIR/var/cache/owntone"
sed -i -E "s|^(\s*)uid = \".*\"|\1uid = \"$USER\"|" "$CONF"
sed -i -E "s|^(\s*)directories = \{.*\}|\1directories = { \"$MUSIC\" }|" "$CONF"
if ! grep -q '^airplay_shared {' "$CONF"; then
  cat >>"$CONF" <<EOF

# Added by Gala's installer: fixed ports so firewalls can allow them.
airplay_shared {
	control_port = $AIRPLAY_CONTROL_PORT
	timing_port = $AIRPLAY_TIMING_PORT
}
EOF
fi
for fifo in "$MUSIC/pc-audio.fifo" "$MUSIC/pc-audio.fifo.metadata"; do
  [ -p "$fifo" ] || mkfifo "$fifo"
done
info "Installed to $OWNTONE_DIR"

if [ "${NO_SERVICE:-0}" = 1 ]; then
  info "Skipping OwnTone's background service (NO_SERVICE=1)"
elif [ "$INIT" = systemd ]; then
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
else
  "$OWNTONE_DIR/sbin/owntone" -c "$CONF" -P "$OWNTONE_DIR/var/owntone.pid"
  info "OwnTone is running. Without systemd, Gala starts it whenever Gala opens."
fi

# Firewall: AirPlay devices are found with mDNS and connect back to OwnTone.
if [ "${NO_FIREWALL:-0}" != 1 ] && [ "$FIREWALL" != none ]; then
  info "A firewall ($FIREWALL) is active. AirPlay needs mDNS (UDP 5353) and UDP ports $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT."
  if ask "Allow them in the firewall?"; then
    case "$FIREWALL" in
      firewalld)
        sudo firewall-cmd --permanent --add-service=mdns \
          && sudo firewall-cmd --permanent --add-port="$AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT/udp" \
          && sudo firewall-cmd --reload >/dev/null \
          && { mkdir -p "$APP_DIR"; echo firewalld >"$APP_DIR/firewall.txt"; info "Firewall updated."; } \
          || warn "Couldn't update the firewall." ;;
      ufw)
        sudo ufw allow 5353/udp comment 'mDNS (Gala)' >/dev/null \
          && sudo ufw allow "$AIRPLAY_CONTROL_PORT:$AIRPLAY_TIMING_PORT/udp" comment 'AirPlay (Gala)' >/dev/null \
          && { mkdir -p "$APP_DIR"; echo ufw >"$APP_DIR/firewall.txt"; info "Firewall updated."; } \
          || warn "Couldn't update the firewall." ;;
    esac
  else
    info "Firewall left unchanged. If devices are missing or silent, allow those ports later."
  fi
fi

# --- 3. The app ---------------------------------------------------------------------

bold "3/4  Installing Gala"
mkdir -p "$APP_DIR" "$ICON_DIR" "$DESKTOP_DIR"
install -m 755 "$HERE/gala.py" "$APP_DIR/gala.py"
install -m 644 "$HERE/gala.svg" "$APP_DIR/gala.svg"
install -m 644 "$HERE/gala.svg" "$ICON_DIR/gala.svg"
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

# GNOME: the tray needs the AppIndicator extension switched on.
if [[ "$DESKTOP" == *GNOME* ]] && [ "$TRAY" = no ] && command -v gnome-extensions >/dev/null; then
  if gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com 2>/dev/null; then
    info "Turned on GNOME's AppIndicator extension for the tray icon (takes effect after logging out and in)."
  fi
fi

# --- 4. Done ------------------------------------------------------------------------

bold "4/4  Done!"
cat <<EOF
  Open "Gala" from your app menu, click "Start AirPlay Discovery"
  and pick a speaker. Gala also starts at login (turn that off in its ☰ menu).

  Tips:
  - HomePods/Apple TVs: in the Home app, set Home Settings > Speakers & TV >
    "Allow Speaker & TV Access" to "Everyone" or "Anyone on the Same Network".
  - An Apple TV may show a 4-digit code the first time; type it into Gala.
  - To uninstall: ./uninstall.sh
EOF
if [ "$TRAY" = no ]; then
  info ""
  info "Note: no tray was found on this desktop, so closing Gala quits it."
fi

if [ "${NO_LAUNCH:-0}" != 1 ] && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  setsid -f "$PYTHON" "$APP_DIR/gala.py" >/dev/null 2>&1 || true
fi
