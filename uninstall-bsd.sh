#!/bin/sh
# Gala uninstaller for FreeBSD: removes the app, OwnTone (including its
# database and Apple TV pairings) and the settings.
#
# It then offers to remove the packages that install-bsd.sh installed, but only
# ones that weren't installed before, and only if nothing else installed still
# needs them. It shows the list and asks first. D-Bus and Avahi stay switched
# on, as other software uses them.
#
# Options (environment variables):
#   DRY_RUN=1   only show what would be removed; change nothing

set -eu

OWNTONE_DIR="$HOME/.local/opt/owntone"
OWNTONE_SRC="$HOME/.local/src/owntone-server"
APP_DIR="$HOME/.local/share/gala"
APP_ID="app.gala.Gala"
PACKAGE_RECORD="$APP_DIR/installed-packages.txt"
DRY_RUN="${DRY_RUN:-0}"

run() { if [ "$DRY_RUN" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi; }
ask() { printf '%s [y/N] ' "$1"; read -r answer; case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

if command -v sudo >/dev/null; then AS_ROOT=sudo; elif command -v doas >/dev/null; then AS_ROOT=doas; else AS_ROOT=""; fi

remove_packages() {
  if [ ! -f "$PACKAGE_RECORD" ]; then
    echo "No record of packages installed by install-bsd.sh, so no packages are removed."
    return 0
  fi
  recorded="$(grep -v '^#' "$PACKAGE_RECORD" | grep -v '^$' || true)"
  [ -n "$recorded" ] || { echo "install-bsd.sh didn't install any packages."; return 0; }

  echo
  echo "Checking the packages that install-bsd.sh installed…"
  removable=""
  for p in $recorded; do
    pkg info -e "$p" 2>/dev/null || continue
    # Installed packages that need this one, other than ones on our own list.
    others=""
    for r in $(pkg query '%rn' "$p" 2>/dev/null); do
      echo "$recorded" | grep -qx "$r" || others="$others $r"
    done
    if [ -n "$others" ]; then
      echo "  keeping $p (needed by$(echo "$others" | cut -d' ' -f1-4))"
    else
      removable="$removable $p"
    fi
  done

  if [ -z "$removable" ]; then
    echo "All of them are still needed by other software, so none are removed."
    return 0
  fi
  echo
  echo "Not needed by anything else:"
  for p in $removable; do echo "  $p"; done
  if [ "$DRY_RUN" != 1 ] && ! ask "Remove these packages? (asks for your password)"; then
    echo "Packages kept."
    return 0
  fi
  [ -n "$AS_ROOT" ] || { echo "sudo/doas not found; remove them as root with: pkg delete$removable"; return 0; }
  # shellcheck disable=SC2086
  run $AS_ROOT pkg delete -y $removable
  echo "Libraries pulled in for these may now be unused too; 'pkg autoremove' lists and removes those"
  echo "(it also removes any other packages pkg considers unused, so check its list first)."
}

echo "This removes Gala, OwnTone and their settings from your account:"
echo "  $APP_DIR"
echo "  $OWNTONE_DIR"
echo "  $OWNTONE_SRC"
echo "  the app menu entry, login entry and icon"
echo "and then offers to remove packages that install-bsd.sh installed."
[ "$DRY_RUN" = 1 ] && echo "(Dry run: nothing will be changed.)"
ask "Continue?" || { echo "Nothing removed."; exit 0; }

# Quit Gala, switch audio back to this computer and stop OwnTone.
run pkill -f "$APP_DIR/gala.py" || true
if command -v pactl >/dev/null; then
  for module in $(pactl list short modules 2>/dev/null | awk -F'\t' '$2 == "module-pipe-sink" && $3 ~ /sink_name=owntone/ {print $1}'); do
    run pactl unload-module "$module" || true
  done
fi
if [ -f "$OWNTONE_DIR/var/owntone.pid" ]; then
  run kill "$(cat "$OWNTONE_DIR/var/owntone.pid")" 2>/dev/null || true
fi

# Packages first: their record lives in the app folder removed below.
remove_packages

run rm -rf "$APP_DIR" "$OWNTONE_DIR" "$OWNTONE_SRC"
run rm -f "$HOME/.local/share/applications/$APP_ID.desktop" \
      "$HOME/.config/autostart/gala.desktop" \
      "$HOME/.local/share/icons/hicolor/scalable/apps/gala.svg"
[ "$DRY_RUN" = 1 ] || update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
if [ "$DRY_RUN" = 1 ]; then echo "Dry run finished: nothing was changed."; else echo "Gala has been removed."; fi
