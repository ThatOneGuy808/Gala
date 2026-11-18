#!/bin/sh
# Gala installer for FreeBSD.
#
# Installs everything needed and the app itself, for the current user:
#   1. Packages with pkg (build tools and libraries for OwnTone, Python with
#      GTK bindings, tray support, PulseAudio's pactl, Avahi). Uses sudo or doas.
#   2. Turns on D-Bus and Avahi (needed to find AirPlay devices).
#   3. OwnTone, the AirPlay 2 server, built from source into ~/.local/opt/owntone.
#      Gala starts it when Gala opens (there's no systemd on FreeBSD).
#   4. The Gala app into ~/.local/share/gala, with an app menu entry and icon.
#
# Run it as your normal user:   sh install-bsd.sh
#
# Linux? Use install.sh instead. OpenBSD and NetBSD aren't supported (different
# audio systems, and no OwnTone port).
#
# Options (environment variables):
#   DRY_RUN=1               show what would be done; change nothing
#   OWNTONE_REF=<git ref>   OwnTone version to build (default: a tested commit)
#   SKIP_PACKAGES=1         don't install packages (install them yourself)
#   NO_LAUNCH=1             don't open the app at the end

set -eu

OWNTONE_REF="${OWNTONE_REF:-8ed84f2b3cba25d3de65e05660d59ce034b5adab}"
OWNTONE_REPO="https://github.com/owntone/owntone-server.git"

HERE="$(cd "$(dirname "$0")" && pwd)"
OWNTONE_DIR="$HOME/.local/opt/owntone"
OWNTONE_SRC="$HOME/.local/src/owntone-server"
APP_DIR="$HOME/.local/share/gala"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
APP_ID="app.gala.Gala"
PACKAGE_RECORD="$APP_DIR/installed-packages.txt"
DRY_RUN="${DRY_RUN:-0}"
AIRPLAY_CONTROL_PORT=3690
AIRPLAY_TIMING_PORT=3691

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = FreeBSD ] || die "This installer is for FreeBSD (this is $(uname)). On Linux, run ./install.sh."
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not as root. It uses sudo or doas when needed."
[ -f "$HERE/gala.py" ] || die "Run this from the Gala folder (gala.py not found)."

# Admin rights: sudo, else doas.
if command -v sudo >/dev/null; then
  AS_ROOT=sudo
elif command -v doas >/dev/null; then
  AS_ROOT=doas
else
  die "Neither sudo nor doas is installed. Install one as root first, e.g.: su -m root -c 'pkg install -y sudo'
       (then allow your user in /usr/local/etc/sudoers), and run this again."
fi

# --- Detection -------------------------------------------------------------------

bold "Detected system"
info "System:       FreeBSD $(freebsd-version 2>/dev/null || uname -r) ($(uname -m))"
info "Admin tool:   $AS_ROOT"
info "Desktop:      ${XDG_CURRENT_DESKTOP:-unknown} (${XDG_SESSION_TYPE:-unknown})"
if command -v pactl >/dev/null && pactl info >/dev/null 2>&1; then
  info "Sound server: PulseAudio (running)"
else
  info "Sound server: PulseAudio not running (will be installed; your desktop needs to start it)"
fi
FIREWALL=none
for fw in pf ipfw; do
  service "$fw" onestatus >/dev/null 2>&1 && FIREWALL=$fw
done
info "Firewall:     $FIREWALL"

# --- 1. Packages -----------------------------------------------------------------

# OwnTone's build dependencies (from OwnTone's own FreeBSD script) and Gala's.
# Names checked against FreeBSD's package collection.
PACKAGES="gmake autoconf automake libtool gettext gperf pkgconf git bison flex
  ffmpeg libconfuse libevent libxml2 libgcrypt libunistring libiconv curl libplist
  libinotify avahi-app sqlite3 alsa-lib libsodium json-c libwebsockets protobuf-c gnutls
  dbus gtk3 libayatana-appindicator pulseaudio desktop-file-utils"

pkg_installed() { pkg info -e "$1" 2>/dev/null; }
pkg_available() { pkg rquery '%n' "$1" >/dev/null 2>&1; }

record() {  # record packages this installer added, for uninstall-bsd.sh
  mkdir -p "$APP_DIR"
  [ -f "$PACKAGE_RECORD" ] || echo "# manager=pkg" >"$PACKAGE_RECORD"
  for p in "$@"; do
    pkg_installed "$p" && ! grep -qx "$p" "$PACKAGE_RECORD" && echo "$p" >>"$PACKAGE_RECORD"
  done
  return 0
}

install_pkgs() {  # install_pkgs <packages…>: installs the missing ones and records them
  missing=""
  for p in "$@"; do pkg_installed "$p" || missing="$missing $p"; done
  [ -n "$missing" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    info "Would install:$missing"
    return 0
  fi
  info "Installing:$missing"
  # shellcheck disable=SC2086
  $AS_ROOT pkg install -y $missing || die "Installing packages failed (see the messages above)."
  # shellcheck disable=SC2086
  record $missing
}

if [ "${SKIP_PACKAGES:-0}" = 1 ]; then
  bold "1/4  Skipping packages (SKIP_PACKAGES=1)"
else
  bold "1/4  Packages (you may be asked for your password)"
  # shellcheck disable=SC2086
  install_pkgs $PACKAGES
  # Python: FreeBSD names Python packages after the Python version (py311-…).
  PYPKG=""
  for cand in python3 python311 python312 python313 python314; do
    if pkg_installed "$cand" || pkg_available "$cand"; then PYPKG=$cand; break; fi
  done
  [ -n "$PYPKG" ] || die "No Python 3 package found in your pkg repository."
  install_pkgs "$PYPKG"
fi

PYTHON="$(command -v python3 || ls /usr/local/bin/python3.[0-9]* 2>/dev/null | grep -E 'python3\.[0-9]+$' | sort -V | tail -1 || true)"
if [ -n "$PYTHON" ] && [ "${SKIP_PACKAGES:-0}" != 1 ]; then
  PYVER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info[0]}{sys.version_info[1]}")')"
  install_pkgs "py${PYVER}-pygobject"
elif [ -z "$PYTHON" ] && [ "$DRY_RUN" = 1 ]; then
  info "Would install the PyGObject package matching the installed Python (py3XX-pygobject)"
fi

if [ "$DRY_RUN" = 1 ]; then
  bold "Dry run: what would happen next"
  info "2/4  Turn on D-Bus and Avahi (sysrc dbus_enable=YES avahi_daemon_enable=YES, then start them)"
  info "3/4  Build OwnTone ${OWNTONE_REF%"${OWNTONE_REF#????????}"} into $OWNTONE_DIR with gmake (AirPlay ports UDP $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT)"
  info "4/4  Install Gala into $APP_DIR with an app menu entry"
  [ "$FIREWALL" != none ] && info "     Firewall ($FIREWALL): you'd need to allow UDP 5353 and $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT yourself"
  bold "Dry run finished: nothing was changed."
  exit 0
fi

[ -n "$PYTHON" ] || die "python3 not found after installing packages."
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Gala needs Python 3.9 or newer."
"$PYTHON" -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
  || die "$PYTHON can't load GTK 3 (py${PYVER:-3XX}-pygobject or gtk3 missing?)."

# --- 2. D-Bus and Avahi -------------------------------------------------------------

bold "2/4  Turning on D-Bus and Avahi (they find AirPlay devices on your network)"
for svc in dbus avahi_daemon; do
  rcvar="${svc}_enable"
  [ "$(sysrc -n "$rcvar" 2>/dev/null || echo NO)" = YES ] || $AS_ROOT sysrc "$rcvar=YES" >/dev/null
done
$AS_ROOT service dbus status >/dev/null 2>&1 || $AS_ROOT service dbus start || warn "Couldn't start D-Bus."
$AS_ROOT service avahi-daemon status >/dev/null 2>&1 || $AS_ROOT service avahi-daemon start || warn "Couldn't start Avahi."

# --- 3. OwnTone -----------------------------------------------------------------------

bold "3/4  Building OwnTone (the AirPlay 2 server). This takes a few minutes."
mkdir -p "$(dirname "$OWNTONE_SRC")"
if [ -d "$OWNTONE_SRC/.git" ]; then
  git -C "$OWNTONE_SRC" fetch -q origin
else
  info "Downloading OwnTone source"
  git clone -q "$OWNTONE_REPO" "$OWNTONE_SRC"
fi
git -C "$OWNTONE_SRC" checkout -q "$OWNTONE_REF"
info "Version: $(git -C "$OWNTONE_SRC" log -1 --format='%h (%cd)' --date=short)"

LOG="$(mktemp /tmp/owntone-build.XXXXXX)"
(
  cd "$OWNTONE_SRC"
  export CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib"
  autoreconf -fi
  ./configure --prefix="$OWNTONE_DIR" --sysconfdir="$OWNTONE_DIR/etc" \
    --localstatedir="$OWNTONE_DIR/var" --disable-spotify \
    --disable-install_systemd --disable-install-user
  gmake -j"$(sysctl -n hw.ncpu)"
) >"$LOG" 2>&1 || die "Building OwnTone failed. Build log: $LOG"

[ -f "$OWNTONE_DIR/var/owntone.pid" ] && kill "$(cat "$OWNTONE_DIR/var/owntone.pid")" 2>/dev/null || true
gmake -C "$OWNTONE_SRC" install >>"$LOG" 2>&1 || die "Installing OwnTone failed. Build log: $LOG"

CONF="$OWNTONE_DIR/etc/owntone.conf"
MUSIC="$OWNTONE_DIR/var/music"
mkdir -p "$MUSIC" "$OWNTONE_DIR/var/log" "$OWNTONE_DIR/var/cache/owntone"
sed -i '' -E "s|^([[:space:]]*)uid = \".*\"|\\1uid = \"$(id -un)\"|" "$CONF"
sed -i '' -E "s|^([[:space:]]*)directories = \\{.*\\}|\\1directories = { \"$MUSIC\" }|" "$CONF"
if ! grep -q '^airplay_shared {' "$CONF"; then
  printf '\n# Added by Gala'"'"'s installer: fixed ports so firewalls can allow them.\nairplay_shared {\n\tcontrol_port = %s\n\ttiming_port = %s\n}\n' \
    "$AIRPLAY_CONTROL_PORT" "$AIRPLAY_TIMING_PORT" >>"$CONF"
fi
for fifo in "$MUSIC/pc-audio.fifo" "$MUSIC/pc-audio.fifo.metadata"; do
  [ -p "$fifo" ] || mkfifo "$fifo"
done
"$OWNTONE_DIR/sbin/owntone" -c "$CONF" -P "$OWNTONE_DIR/var/owntone.pid" || warn "OwnTone didn't start; Gala will try when it opens."
info "Installed to $OWNTONE_DIR. Gala starts OwnTone whenever Gala opens."

if [ "$FIREWALL" != none ]; then
  warn "A firewall ($FIREWALL) is on. Allow UDP 5353 (mDNS) and UDP $AIRPLAY_CONTROL_PORT-$AIRPLAY_TIMING_PORT"
  warn "(AirPlay) in its rules, or devices may be missing or silent."
fi

# --- 4. The app -------------------------------------------------------------------------

bold "4/4  Installing Gala"
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
info "Installed to $APP_DIR, with an app menu entry"

bold "Done!"
cat <<EOF
  Open "Gala" from your app menu, click "Start AirPlay Discovery"
  and pick a speaker. Gala also starts at login (turn that off in its ☰ menu).

  Gala routes audio through PulseAudio. KDE and most FreeBSD desktops start it
  for you; if 'pactl info' fails, start PulseAudio (pulseaudio --start) or set
  your desktop to use it.

  To uninstall: sh uninstall-bsd.sh
EOF

if [ "${NO_LAUNCH:-0}" != 1 ] && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  daemon -f "$PYTHON" "$APP_DIR/gala.py" >/dev/null 2>&1 || true
fi
