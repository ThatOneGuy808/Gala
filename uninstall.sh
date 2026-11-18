#!/usr/bin/env bash
# Gala uninstaller: removes the app, OwnTone (including its
# database and Apple TV pairings) and the settings.
#
# It then offers to remove the system packages that install.sh installed,
# but only ones that weren't on the system before, and only if nothing else
# installed still needs them. It shows the list and asks first.
#
# Options (environment variables):
#   DRY_RUN=1   only show what would be removed; change nothing
#
# Works with apt, dnf, zypper and pacman, with or without systemd.

set -euo pipefail

OWNTONE_DIR="$HOME/.local/opt/owntone"
OWNTONE_SRC="$HOME/.local/src/owntone-server"
APP_DIR="$HOME/.local/share/gala"
APP_ID="app.gala.Gala"
PACKAGE_RECORD="$APP_DIR/installed-packages.txt"
DRY_RUN="${DRY_RUN:-0}"

run() {  # run a command, or just print it in dry-run mode
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry run] $*"; else "$@"; fi
}

ask() {  # ask <question>: yes/no, default no
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy] ]]
}

# --- System packages --------------------------------------------------------

# Which of the given packages, other than ones in our own list, would also be
# removed (because they depend on it)? Prints their names.
dependents() {  # <manager> <package> <our packages...>
  local manager="$1" pkg="$2"; shift 2
  local -A ours=()
  local p
  for p in "$@"; do ours["$p"]=1; done
  case "$manager" in
    apt)    apt-get -s remove "$pkg" 2>/dev/null | awk '/^Remv /{print $2}' ;;
    dnf|zypper)
            # rpm reports what would break: "… is needed by (installed) NAME-VERSION…"
            rpm -e --test "$pkg" 2>&1 | sed -n 's/.*is needed by (installed) //p' | sort -u \
              | while read -r nevra; do rpm -q --qf '%{NAME}\n' "$nevra" 2>/dev/null; done ;;
    pacman) pacman -Qi "$pkg" 2>/dev/null | sed -n 's/^Required By *: *//p' | tr -s ' ' '\n' | grep -vx 'None' ;;
  esac | sed 's/:.*//' | sort -u | while read -r p; do
    if [ -n "$p" ] && [ -z "${ours[$p]:-}" ]; then echo "$p"; fi
  done
  return 0
}

remove_packages() {
  [ -f "$PACKAGE_RECORD" ] || {
    echo "No record of packages installed by install.sh, so no system packages are removed."
    return
  }
  local manager pkg needed
  manager="$(sed -n 's/^# manager=//p' "$PACKAGE_RECORD")"
  local recorded=() removable=()
  while read -r pkg; do
    [ -n "$pkg" ] && [[ "$pkg" != \#* ]] && recorded+=("$pkg")
  done <"$PACKAGE_RECORD"
  [ ${#recorded[@]} -gt 0 ] || { echo "install.sh didn't install any system packages."; return; }

  echo
  echo "Checking the ${#recorded[@]} system packages that install.sh installed…"
  for pkg in "${recorded[@]}"; do
    case "$manager" in
      apt)    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || continue ;;
      dnf|zypper) rpm -q "$pkg" >/dev/null 2>&1 || continue ;;
      pacman) pacman -Qq "$pkg" >/dev/null 2>&1 || continue ;;
      *)      echo "Unknown package manager '$manager' in $PACKAGE_RECORD; skipping."; return ;;
    esac
    needed="$(dependents "$manager" "$pkg" "${recorded[@]}" | head -3 | paste -sd, - || true)"
    if [ -n "$needed" ]; then
      echo "  keeping $pkg (needed by $needed)"
    else
      removable+=("$pkg")
    fi
  done

  if [ ${#removable[@]} -eq 0 ]; then
    echo "All of them are still needed by other software, so none are removed."
    return
  fi
  echo
  echo "Not needed by anything else (${#removable[@]}):"
  printf '  %s\n' "${removable[@]}"
  if [ "$DRY_RUN" != 1 ] && ! ask "Remove these packages? (asks for your password)"; then
    echo "Packages kept."
    return
  fi
  case "$manager" in
    # dnf, zypper --clean-deps and pacman -s also remove dependencies nothing
    # else needs.
    apt)    run sudo apt-get remove -y "${removable[@]}" ;;
    dnf)    run sudo dnf remove -y "${removable[@]}" ;;
    zypper) run sudo zypper --non-interactive remove --clean-deps "${removable[@]}" ;;
    pacman) run sudo pacman -Rns --noconfirm "${removable[@]}" ;;
  esac
  if [ "$manager" = apt ]; then
    echo "Libraries that apt pulled in for these may now be unused too; 'sudo apt autoremove' cleans those up"
    echo "(it also removes any other packages apt considers unused, so check its list first)."
  fi
}

# --- Main -----------------------------------------------------------------------

echo "This removes Gala, OwnTone and their settings from your account:"
echo "  $APP_DIR"
echo "  $OWNTONE_DIR"
echo "  $OWNTONE_SRC"
echo "  the app menu entry, login entry, icon and the 'owntone' user service"
echo "and then offers to remove system packages that install.sh installed."
[ "$DRY_RUN" = 1 ] && echo "(Dry run: nothing will be changed.)"
ask "Continue?" || { echo "Nothing removed."; exit 0; }

# Quit the app and switch audio back to this computer.
run pkill -f "$APP_DIR/gala.py" || true
if command -v pactl >/dev/null; then
  for module in $(pactl list short modules 2>/dev/null | awk -F'\t' '$2 == "module-pipe-sink" && $3 ~ /sink_name=owntone/ {print $1}'); do
    run pactl unload-module "$module" || true
  done
fi

if systemctl --user cat owntone.service >/dev/null 2>&1; then
  run systemctl --user disable --now owntone.service 2>/dev/null || true
fi
# Without systemd, Gala started OwnTone itself.
if [ -f "$OWNTONE_DIR/var/owntone.pid" ]; then
  run kill "$(cat "$OWNTONE_DIR/var/owntone.pid")" 2>/dev/null || true
fi

# Firewall ports the installer opened for AirPlay (mDNS is left open, as other
# software uses it too).
FIREWALL_RECORD="$APP_DIR/firewall.txt"
if [ -f "$FIREWALL_RECORD" ] && ask "Close the AirPlay ports (UDP 3690-3691) that install.sh opened in the firewall?"; then
  case "$(cat "$FIREWALL_RECORD")" in
    firewalld) run sudo firewall-cmd --permanent --remove-port=3690-3691/udp && run sudo firewall-cmd --reload || true ;;
    ufw)       run sudo ufw delete allow 3690:3691/udp || true ;;
  esac
fi
run rm -f "$HOME/.config/systemd/user/owntone.service"
run systemctl --user daemon-reload 2>/dev/null || true

# Packages first: their record lives in the app folder removed below.
remove_packages

# (rm -rf on a symlink removes just the link, not what it points to.)
run rm -rf "$APP_DIR" "$OWNTONE_DIR" "$OWNTONE_SRC"
run rm -f "$HOME/.local/share/applications/$APP_ID.desktop" \
      "$HOME/.config/autostart/gala.desktop" \
      "$HOME/.local/share/icons/hicolor/scalable/apps/gala.svg"
[ "$DRY_RUN" = 1 ] || update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
if [ "$DRY_RUN" = 1 ]; then echo "Dry run finished: nothing was changed."; else echo "Gala has been removed."; fi
