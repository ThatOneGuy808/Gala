#!/usr/bin/python3
"""Gala - AirPlay On Linux: send this computer's audio to AirPlay speakers.

AirPlay devices are reached through OwnTone (an AirPlay 2 server running as a user
service), so HomePods and Apple TVs work. "Starting discovery" adds a PipeWire
output that feeds this computer's audio into OwnTone's pipe.

Run with --hidden to start in the system tray without opening the window.
"""

import base64
import json
import os
import queue
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.parse
import urllib.request

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk, Pango  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
except (ValueError, ImportError):
    AppIndicator = None  # no tray support: closing the window quits instead

APP_ID = "app.gala.Gala"
ICON = "gala"  # installed from gala.svg in this folder
# The same icon by file path (a link without spaces): KDE's panel and tray load
# it directly, without depending on their icon cache.
ICON_FILE = os.path.expanduser("~/.local/share/icons/hicolor/scalable/apps/gala.svg")
OWNTONE_API = "http://localhost:3689/api"
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
# OwnTone lives in this project folder (owntone/ and owntone-src/), but is used
# through links without spaces in the path: PipeWire's pipe module and OwnTone's
# build tools can't handle spaces, which the app's folder path may contain.
OWNTONE_DIR = os.path.expanduser("~/.local/opt/owntone")
OWNTONE_SRC = os.path.expanduser("~/.local/src/owntone-server")
PIPE_FILE = os.path.join(OWNTONE_DIR, "var/music/pc-audio.fifo")
PIPE_SINK = "owntone"
SEARCHING = "Searching for AirPlay devices…"
SETTINGS_FILE = os.path.join(PROJECT_DIR, "settings.json")
# The login entry is kept in the project folder and linked from autostart.
AUTOSTART_SOURCE = os.path.join(PROJECT_DIR, "gala-autostart.desktop")
AUTOSTART_FILE = os.path.expanduser("~/.config/autostart/gala.desktop")
SCRIPT = os.path.abspath(__file__)


# --- Settings ----------------------------------------------------------------

DEFAULT_SETTINGS = {
    "multi": False,        # multiple-speaker mode
    "running": False,      # discovery was running when last used
    "last": None,          # last output: {"kind": "local"|"airplay", "keys": [...], "title": ...}
    "favorites": [],       # entry keys shown at the top
    "hidden": [],          # entry keys left out of the list
    "hidden_titles": {},   # names of hidden devices, for the Hidden devices menu
    "favorite_titles": {}, # display names of favorites, to list them while offline
    "close_to_tray": True,     # closing the window keeps the app running in the tray
    "minimize_to_tray": False, # minimizing hides the window to the tray
    "player": None,        # media player last seen playing (for remote play/pause)
}


def load_settings():
    settings = json.loads(json.dumps(DEFAULT_SETTINGS))  # fresh copy of the defaults
    try:
        with open(SETTINGS_FILE) as f:
            settings.update(json.load(f))
    except (OSError, ValueError):
        pass
    return settings


def save_settings(settings):
    os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
    tmp = SETTINGS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp, SETTINGS_FILE)


def autostart_enabled():
    return os.path.lexists(AUTOSTART_FILE)


def set_autostart(enabled):
    if enabled:
        with open(AUTOSTART_SOURCE, "w") as f:
            f.write(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Gala\n"
                "Comment=Send this computer's audio to AirPlay speakers\n"
                f'Exec=/usr/bin/python3 "{SCRIPT}" --hidden\n'
                f"Icon={ICON_FILE}\n"
                "Terminal=false\n"
                f"StartupWMClass={APP_ID}\n"
                "X-GNOME-Autostart-enabled=true\n"
            )
        os.makedirs(os.path.dirname(AUTOSTART_FILE), exist_ok=True)
        if os.path.lexists(AUTOSTART_FILE):
            os.remove(AUTOSTART_FILE)
        os.symlink(AUTOSTART_SOURCE, AUTOSTART_FILE)
    elif os.path.lexists(AUTOSTART_FILE):
        os.remove(AUTOSTART_FILE)  # just the link; the file stays in the project


# --- PipeWire (pactl) --------------------------------------------------------

def run_pactl(*args):
    """Run a pactl command and return (success, stdout, stderr)."""
    try:
        result = subprocess.run(
            ["pactl", *args], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, "", str(exc)
    return result.returncode == 0, result.stdout.strip(), result.stderr.strip()


def pipe_module_id():
    """ID of the module-pipe-sink feeding OwnTone, or None if it isn't loaded."""
    ok, out, _ = run_pactl("list", "short", "modules")
    if not ok:
        return None
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] == "module-pipe-sink" and f"sink_name={PIPE_SINK}" in parts[2]:
            return parts[0]
    return None


def description_arg(name):
    """Build the sink_properties argument that names the OwnTone output.
    pactl only accepts plain ASCII here, and quotes need escaping."""
    name = name.replace("’", "'").replace("‘", "'").replace('"', "'")
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    name = name.replace("\\", "").replace("'", "\\'")
    return f"sink_properties='device.description=\"{name}\"'"


def start_pipe(name="OwnTone"):
    return run_pactl(
        "load-module", "module-pipe-sink", f"file={PIPE_FILE}", f"sink_name={PIPE_SINK}",
        "format=s16le", "rate=44100", "channels=2", description_arg(name),
    )


def stop_pipe():
    module = pipe_module_id()
    if module is None:
        return True, "", ""
    return run_pactl("unload-module", module)


def all_sinks():
    ok, out, _ = run_pactl("-f", "json", "list", "sinks")
    if not ok:
        return []
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []


def pipe_description():
    return next((s.get("description") for s in all_sinks() if s.get("name") == PIPE_SINK), None)


def rename_pipe(name):
    """Show the OwnTone output under `name` (e.g. the AirPlay device in use) in
    the system's sound settings. PipeWire can't rename an output, so it is
    recreated; playing audio waits on a silent placeholder meanwhile so it
    doesn't blip out of the computer's speakers."""
    if pipe_module_id() is None:
        return
    wanted = description_arg(name).split('"')[1].replace("\\'", "'")
    if pipe_description() == wanted:
        return
    ok, hold, _ = run_pactl(
        "load-module", "module-null-sink", "sink_name=owntone_hold",
        "sink_properties=device.description=Switching",
    )
    _, out, _ = run_pactl("list", "short", "sink-inputs")
    streams = [line.split()[0] for line in out.splitlines() if line.split()]
    if ok:
        for stream in streams:
            run_pactl("move-sink-input", stream, "owntone_hold")
    was_default = default_sink() == PIPE_SINK
    stop_pipe()
    start_pipe(name)
    if was_default:
        run_pactl("set-default-sink", PIPE_SINK)
    for stream in streams:
        run_pactl("move-sink-input", stream, PIPE_SINK if was_default else default_sink() or PIPE_SINK)
    if ok:
        run_pactl("unload-module", hold)


def local_sinks():
    """[(sink_name, label)] for this computer's own outputs."""
    result = []
    for sink in all_sinks():
        name = sink.get("name") or ""
        # Skip our OwnTone feed, the switching placeholder and any leftover
        # PipeWire AirPlay outputs.
        if not name or name in (PIPE_SINK, "owntone_hold") or name.startswith("raop_sink."):
            continue
        desc = sink.get("description") or ""
        result.append((name, desc if desc and desc != "(null)" else name))
    return result


def default_sink():
    ok, out, _ = run_pactl("get-default-sink")
    return out if ok else None


def use_sink(name):
    """Make `name` the default output and move audio that's already playing to it."""
    ok, _, err = run_pactl("set-default-sink", name)
    if not ok:
        return False, err
    _, out, _ = run_pactl("list", "short", "sink-inputs")
    for line in out.splitlines():
        if line.split():
            run_pactl("move-sink-input", line.split()[0], name)
    return True, ""


# --- OwnTone (AirPlay 2) -----------------------------------------------------

def owntone(method, path, body=None):
    """Call the OwnTone JSON API. Returns (success, parsed JSON or error text)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{OWNTONE_API}{path}", data=data, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read()
            return True, json.loads(raw) if raw else None
    except Exception as exc:  # connection refused, timeout, bad JSON...
        return False, str(exc)


def airplay_outputs():
    """OwnTone's AirPlay devices as dicts (id, name, selected, volume,
    needs_auth_key), or None if OwnTone can't be reached."""
    ok, data = owntone("GET", "/outputs")
    if not ok:
        return None
    outputs = [o for o in data.get("outputs", []) if o.get("type", "").startswith("AirPlay")]
    outputs.sort(key=lambda o: o["name"].lower())
    return outputs


def use_airplay(output_ids, name):
    """Send this computer's audio to one or more AirPlay devices through OwnTone.
    OwnTone keeps several devices in sync with each other."""
    ok, err = owntone("PUT", "/outputs/set", {"outputs": list(output_ids)})
    if not ok:
        return False, f"OwnTone: {err}"
    rename_pipe(name)
    return use_sink(PIPE_SINK)


def set_volume(output_ids, volume):
    for oid in output_ids:
        owntone("PUT", f"/outputs/{oid}", {"volume": int(volume)})


def send_code(pin, output_ids):
    """Pair with each waiting device using the code it shows on screen."""
    for oid in output_ids:
        ok, err = owntone("PUT", f"/outputs/{oid}", {"pin": pin})
        if not ok:
            return False, err
    return True, None


def stop_airplay():
    owntone("PUT", "/player/stop")
    owntone("PUT", "/outputs/set", {"outputs": []})


def player_state():
    ok, data = owntone("GET", "/player")
    return data.get("state") if ok and data else None


def player_info():
    """OwnTone's player: state, current queue item and its progress."""
    ok, data = owntone("GET", "/player")
    return data if ok and data else None


def keep_spare_queue_item():
    """Skip buttons on an AirPlay remote move OwnTone to the next item in its
    queue. Keep exactly one spare copy of this computer's audio queued after the
    current one, so "next" has somewhere to go (and the app can notice it), and
    remove copies that were already played."""
    info = player_info()
    ok, queue = owntone("GET", "/queue")
    if not info or not ok or not queue:
        return
    items = queue.get("items", [])
    current = next((i for i in items if i["id"] == info.get("item_id")), None)
    if not current or current.get("data_kind") != "pipe":
        return
    for item in items:
        if item["position"] < current["position"]:
            owntone("DELETE", f"/queue/items/{item['id']}")
    spares = [i for i in items if i["position"] > current["position"]]
    if not spares:
        owntone("POST", "/queue/items/add?uris=" + urllib.parse.quote(current["uri"]))


UPDATE_SCRIPT = f"""
set -e
cd "{OWNTONE_SRC}"
git fetch -q origin
before=$(git rev-parse HEAD)
after=$(git rev-parse origin/master)
if [ "$before" = "$after" ]; then echo UP_TO_DATE; exit 0; fi
git checkout -q origin/master
autoreconf -fi
./configure --prefix="{OWNTONE_DIR}" --sysconfdir="{OWNTONE_DIR}/etc" \\
  --localstatedir="{OWNTONE_DIR}/var" --disable-spotify \\
  --disable-install_systemd --disable-install-user
make -j"$(nproc)"
systemctl --user stop owntone
make install
systemctl --user start owntone
echo "UPDATED $(git rev-parse --short HEAD)"
"""


def update_owntone():
    """Rebuild OwnTone from its latest code. Returns (ok, message). Slow: run
    it on a background thread."""
    log_path = os.path.join(OWNTONE_DIR, "var/log/update.log")
    try:
        with open(log_path, "w") as log:
            result = subprocess.run(
                ["bash", "-c", UPDATE_SCRIPT], stdout=subprocess.PIPE,
                stderr=log, text=True, timeout=1800,
            )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"Update failed: {exc}"
    out = result.stdout.strip().splitlines()
    last = out[-1] if out else ""
    if result.returncode != 0:
        # Make sure OwnTone is running again even if the build broke.
        subprocess.run(["systemctl", "--user", "start", "owntone"])
        return False, f"Update failed. Details in {log_path}"
    if last == "UP_TO_DATE":
        return True, "OwnTone is already up to date."
    return True, f"OwnTone updated ({last.split()[-1]})."


# --- Linked speakers (stereo pairs) ------------------------------------------

class AirPlayLinks:
    """Watches AirPlay announcements on the network (via Avahi) to learn which
    speakers are linked. Speakers in a stereo pair share a tight-sync ID ("tsid")
    and a group name ("gpn")."""

    def __init__(self):
        self.info = {}  # device name -> its announcement's TXT fields
        try:
            self._bus = Gio.bus_get_sync(Gio.BusType.SYSTEM)
            self._avahi = Gio.DBusProxy.new_sync(
                self._bus, 0, None, "org.freedesktop.Avahi", "/",
                "org.freedesktop.Avahi.Server", None,
            )
            # Subscribe before creating the browser so no early results are missed.
            self._bus.signal_subscribe(
                "org.freedesktop.Avahi", "org.freedesktop.Avahi.ServiceBrowser",
                None, None, None, 0, self._on_signal,
            )
            self._avahi.call_sync(
                "ServiceBrowserNew",
                GLib.Variant("(iissu)", (-1, -1, "_airplay._tcp", "local", 0)),
                0, -1, None,
            )
        except GLib.Error:
            pass  # No Avahi: everything still works, just without pairs.

    def _on_signal(self, _conn, _sender, _path, _iface, signal, params, *_):
        if signal == "ItemNew":
            iface, proto, name, stype, domain, _flags = params.unpack()
            self._avahi.call(
                "ResolveService",
                GLib.Variant("(iisssiu)", (iface, proto, name, stype, domain, -1, 0)),
                0, 5000, None, self._on_resolved, name,
            )
        elif signal == "ItemRemove":
            self.info.pop(params.unpack()[2], None)

    def _on_resolved(self, proxy, result, name):
        try:
            txt_records = proxy.call_finish(result).unpack()[9]
        except GLib.Error:
            return
        txt = {}
        for record in txt_records:
            key, sep, value = bytes(record).decode(errors="replace").partition("=")
            if sep:
                txt[key] = value
        self.info[name] = txt

    def group(self, outputs):
        """Turn OwnTone outputs into list entries {key, ids, title}, merging
        stereo pairs into one entry that plays to every speaker in the pair."""
        by_tsid = {}
        for o in outputs:
            tsid = self.info.get(o["name"], {}).get("tsid")
            by_tsid.setdefault(tsid or f"single:{o['id']}", []).append(o)

        entries = []
        for members in by_tsid.values():
            ids = tuple(sorted(str(o["id"]) for o in members))
            names = [o["name"] for o in members]
            if len(members) == 1:
                title = names[0]
            else:
                # Use the pair's own name when it isn't shared with other devices
                # (e.g. an Apple TV that uses the pair as its speakers).
                gpn = self.info.get(names[0], {}).get("gpn")
                same_group = [n for n, t in self.info.items() if gpn and t.get("gpn") == gpn]
                title = gpn if gpn and len(same_group) == len(members) else " + ".join(sorted(names))
                title += " (stereo pair)"
            entries.append({"key": ",".join(ids), "ids": ids, "title": title})
        entries.sort(key=lambda e: e["title"].lower())
        return entries


# --- Now playing (song info on AirPlay devices) ------------------------------

METADATA_PIPE = PIPE_FILE + ".metadata"
SAMPLE_RATE = 44100  # OwnTone reads progress as sample counts at this rate


def _session_bus():
    try:
        return Gio.bus_get_sync(Gio.BusType.SESSION)
    except GLib.Error:
        return None


def mpris_players():
    bus = _session_bus()
    if not bus:
        return []
    try:
        names = bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "ListNames", None, GLib.VariantType("(as)"), 0, 2000, None,
        ).unpack()[0]
    except GLib.Error:
        return []
    return sorted(n for n in names if n.startswith("org.mpris.MediaPlayer2."))


def mpris_props(player):
    bus = _session_bus()
    try:
        return bus.call_sync(
            player, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
            "GetAll", GLib.Variant("(s)", ("org.mpris.MediaPlayer2.Player",)),
            GLib.VariantType("(a{sv})"), 0, 2000, None,
        ).unpack()[0]
    except (GLib.Error, AttributeError):
        return None


def mpris_command(player, method):
    """Send Play/Pause/... to a media player."""
    bus = _session_bus()
    try:
        bus.call_sync(
            player, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
            method, None, None, 0, 2000, None,
        )
        return True
    except (GLib.Error, AttributeError):
        return False


def mpris_now_playing():
    """Song info from whichever media player (Spotify, a browser...) is playing,
    via the standard MPRIS D-Bus interface. Returns a dict or None."""
    for player in mpris_players():
        props = mpris_props(player)
        if not props or props.get("PlaybackStatus") != "Playing":
            continue
        meta = props.get("Metadata") or {}
        title = meta.get("xesam:title") or ""
        if not title:
            continue
        artists = meta.get("xesam:artist") or []
        return {
            "player": player,
            "title": title,
            "artist": ", ".join(artists) if isinstance(artists, list) else str(artists),
            "album": meta.get("xesam:album") or "",
            "art_url": meta.get("mpris:artUrl") or "",
            "length_us": int(meta.get("mpris:length") or 0),
            "position_us": int(props.get("Position") or 0),
        }
    return None


def metadata_item(item_type, code, data):
    """One item in the shairport-sync metadata format that OwnTone reads."""
    return (
        f"<item><type>{item_type.encode().hex()}</type><code>{code.encode().hex()}</code>"
        f"<length>{len(data)}</length>\n<data encoding=\"base64\">\n"
        f"{base64.b64encode(data).decode()}</data></item>\n"
    ).encode()


def fetch_artwork(url):
    """Cover art as JPEG/PNG bytes, or None."""
    try:
        if url.startswith("file://"):
            with open(urllib.parse.unquote(url[7:]), "rb") as f:
                data = f.read()
        elif url.startswith(("http://", "https://")):
            with urllib.request.urlopen(url, timeout=10) as resp:
                data = resp.read(1_048_576 + 1)
        else:
            return None
    except (OSError, ValueError):
        return None
    if len(data) > 1_048_576 or data[:2] not in (b"\xff\xd8", b"\x89P"):
        return None  # OwnTone only takes JPEG/PNG up to 1 MB
    return data


class NowPlaying:
    """Sends the current song's title, artist, album, cover art and progress to
    OwnTone, which shows them on the AirPlay devices."""

    def __init__(self):
        self.player = None  # MPRIS name of the player last seen playing
        self._fd = None
        self._last_song = None
        self._last_pos = None  # (position in seconds, time it was read)
        self._queue = queue.Queue()
        threading.Thread(target=self._writer, daemon=True).start()
        if not os.path.exists(METADATA_PIPE):
            try:
                os.mkfifo(METADATA_PIPE)
            except OSError:
                pass

    def _writer(self):
        # Writes happen on this thread so a slow reader never freezes the window.
        while True:
            fd, data = self._queue.get()
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
            except OSError:  # OwnTone stopped reading: reopen on the next poll
                if self._fd == fd:
                    self._fd = None
                try:
                    os.close(fd)
                except OSError:
                    pass

    def _send(self, data):
        if self._fd is not None:
            self._queue.put((self._fd, data))

    def poll(self):
        song = mpris_now_playing()
        if song:
            self.player = song["player"]

        if self._fd is None:
            try:
                # Fails unless OwnTone has the pipe open for reading (it does
                # while it's playing this computer's audio).
                fd = os.open(METADATA_PIPE, os.O_WRONLY | os.O_NONBLOCK)
            except OSError:
                return
            os.set_blocking(fd, True)
            self._fd = fd
            self._last_song = None  # new reader: send everything again

        if not song:
            return
        now = time.monotonic()
        position = song["position_us"] / 1e6
        key = (song["title"], song["artist"], song["album"], song["art_url"])

        if key != self._last_song:
            self._last_song = key
            for code, field in (("minm", "title"), ("asar", "artist"), ("asal", "album")):
                if song[field]:
                    self._send(metadata_item("core", code, song[field].encode()))
            self._send_progress(position, song["length_us"] / 1e6)
            if song["art_url"]:
                fd = self._fd
                threading.Thread(
                    target=self._send_artwork, args=(fd, song["art_url"], key), daemon=True
                ).start()
        elif self._last_pos is not None:
            # Resend progress only after a seek (position jumped).
            expected = self._last_pos[0] + (now - self._last_pos[1])
            if abs(position - expected) > 3:
                self._send_progress(position, song["length_us"] / 1e6)
        self._last_pos = (position, now)

    def _send_progress(self, position, length):
        if length <= 0:
            return
        start = 1_000_000  # any nonzero base; OwnTone only uses the differences
        pos = start + int(position * SAMPLE_RATE)
        end = start + int(length * SAMPLE_RATE)
        self._send(metadata_item("ssnc", "prgr", f"{start}/{pos}/{end}".encode()))

    def _send_artwork(self, fd, url, key):
        data = fetch_artwork(url)
        if data and self._last_song == key and self._fd == fd:
            self._queue.put((fd, metadata_item("ssnc", "PICT", data)))


# --- Window ------------------------------------------------------------------

class AirPlayWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title="Gala", application=app)
        self.app = app
        self.set_default_size(380, -1)
        self.set_resizable(False)
        self.set_icon_name(ICON)

        self.settings = load_settings()
        self._links = AirPlayLinks()
        self._now_playing = NowPlaying()
        self._error = ""            # last error to show instead of the device count
        self._notice = ""           # short-lived info message (e.g. update result)
        self._running = False
        self._using_airplay = False
        self._entries = []          # AirPlay entries from the last refresh
        self._rows_key = None       # what the list shows, to avoid needless rebuilds
        self._volume_key = None     # which entries have volume sliders
        self._volume_touched = 0.0  # when the user last moved a slider
        self._volume_timers = {}
        self._tray_key = None
        self._last_airplay = None   # (ids, title) of the last AirPlay pick, for pairing
        self._remote_prev = None    # OwnTone player state at the last remote poll
        self._pending_reset = None  # (time, item) of a progress reset still being judged
        self._remote_ignore_until = 0.0
        self._reconnect_tries = 0
        self._updating = False

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(16)
        self.add(box)

        # The app's own title bar. On Wayland the app isn't told when KDE's title
        # bar minimizes it, so it draws its own minimize/close buttons to make
        # "Minimize to tray" possible. The options menu lives here too.
        titlebar = Gtk.HeaderBar()
        titlebar.set_title("Gala")
        titlebar.set_show_close_button(False)
        icon = Gtk.Image.new_from_icon_name(ICON, Gtk.IconSize.LARGE_TOOLBAR)
        titlebar.pack_start(icon)
        close_btn = self._title_button("window-close-symbolic", "Close", self.on_close_clicked, "close")
        min_btn = self._title_button("window-minimize-symbolic", "Minimize", self.on_minimize_clicked, "minimize")
        titlebar.pack_end(close_btn)
        titlebar.pack_end(min_btn)
        self.menu_btn = Gtk.MenuButton()
        self.menu_btn.set_image(Gtk.Image.new_from_icon_name("open-menu-symbolic", Gtk.IconSize.BUTTON))
        self.menu_btn.set_relief(Gtk.ReliefStyle.NONE)
        self.menu_btn.set_tooltip_text("Options")
        self.menu_btn.set_popup(self._build_options_menu())
        titlebar.pack_end(self.menu_btn)
        self.set_titlebar(titlebar)

        self.status = Gtk.Label(xalign=0)
        box.pack_start(self.status, False, False, 0)

        # One button that starts discovery when it's stopped and stops it when running.
        self.toggle_btn = Gtk.Button()
        self.toggle_btn.connect("clicked", self.on_toggle)
        box.pack_start(self.toggle_btn, False, False, 0)

        # "Audio output: <current device>", updated on every refresh.
        self.output_label = Gtk.Label(xalign=0)
        self.output_label.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(self.output_label, False, False, 0)

        # Single or multiple speakers.
        mode_row = Gtk.Box(spacing=6)
        mode_row.pack_start(Gtk.Label(label="Multiple speakers", xalign=0), True, True, 0)
        self.multi_switch = Gtk.Switch()
        self.multi_switch.set_active(self.settings["multi"])
        self.multi_switch.connect("notify::active", self.on_multi_toggled)
        mode_row.pack_start(self.multi_switch, False, False, 0)
        box.pack_start(mode_row, False, False, 0)

        # A scrollable list inside the window instead of a dropdown: dropdown popups
        # get flipped or squashed on Wayland when there are many devices.
        self.device_list = Gtk.ListBox()
        self._list_handler = self.device_list.connect("row-selected", self.on_row_selected)
        self.device_list.connect("row-activated", self.on_row_activated)
        self.device_list.connect("button-press-event", self.on_list_button)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_shadow_type(Gtk.ShadowType.IN)
        scroller.set_min_content_height(240)
        scroller.add(self.device_list)
        box.pack_start(scroller, False, False, 0)
        hint = Gtk.Label(xalign=0)
        hint.set_markup("<small>Right-click a device to favorite or hide it.</small>")
        hint.get_style_context().add_class("dim-label")
        box.pack_start(hint, False, False, 0)

        # Volume sliders for the speakers in use.
        self.volume_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.volume_box.set_no_show_all(True)
        box.pack_start(self.volume_box, False, False, 0)

        # Pairing: shown only while a device (like an Apple TV) is waiting for the
        # code it displays on screen.
        self.pin_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.pin_label = Gtk.Label(xalign=0)
        self.pin_label.set_line_wrap(True)
        self.pin_label.set_max_width_chars(44)
        self.pin_box.pack_start(self.pin_label, False, False, 0)
        pin_row = Gtk.Box(spacing=6)
        self.pin_entry = Gtk.Entry()
        self.pin_entry.set_max_length(4)
        self.pin_entry.set_placeholder_text("Code")
        self.pin_entry.set_input_purpose(Gtk.InputPurpose.DIGITS)
        self.pin_entry.connect("activate", self.on_pair)
        pin_row.pack_start(self.pin_entry, True, True, 0)
        pair_btn = Gtk.Button(label="Pair")
        pair_btn.connect("clicked", self.on_pair)
        pin_row.pack_start(pair_btn, False, False, 0)
        self.pin_box.pack_start(pin_row, False, False, 0)
        self.pin_label.show()
        pin_row.show_all()
        self.pin_box.set_no_show_all(True)  # hidden until a device asks for a code
        box.pack_start(self.pin_box, False, False, 0)

        self.message = Gtk.Label()
        self.message.set_line_wrap(True)
        self.message.set_max_width_chars(44)
        box.pack_start(self.message, False, False, 0)

        self.tray = Tray(self) if AppIndicator else None
        # With a tray icon, closing the window keeps the app running there.
        self.connect("delete-event", self.on_close)

        # Pick up where we left off: restart discovery and reconnect.
        if self.settings["running"] and pipe_module_id() is None:
            start_pipe()
            self._schedule_reconnect()
        elif self.settings["running"] and default_sink() != PIPE_SINK:
            self._schedule_reconnect()

        self.refresh()
        GLib.timeout_add_seconds(3, self._poll)
        GLib.timeout_add_seconds(2, self._poll_now_playing)
        GLib.timeout_add(300, self._poll_remote)

    # --- options menu ---

    def _build_options_menu(self):
        menu = Gtk.Menu()
        hidden_item = Gtk.MenuItem(label="Hidden devices")
        self.hidden_menu = Gtk.Menu()
        hidden_item.set_submenu(self.hidden_menu)
        menu.append(hidden_item)
        self._hidden_menu_key = None
        for label, key in (("Close to tray", "close_to_tray"), ("Minimize to tray", "minimize_to_tray")):
            item = Gtk.CheckMenuItem(label=label)
            item.set_active(self.settings[key])
            item.set_sensitive(AppIndicator is not None)  # needs tray support
            item.connect("toggled", self.on_tray_option, key)
            menu.append(item)
        autostart_item = Gtk.CheckMenuItem(label="Start at login")
        autostart_item.set_active(autostart_enabled())
        autostart_item.connect("toggled", lambda item: set_autostart(item.get_active()))
        menu.append(autostart_item)
        menu.append(Gtk.SeparatorMenuItem())
        self.update_item = Gtk.MenuItem(label="Update OwnTone")
        self.update_item.connect("activate", self.on_update)
        menu.append(self.update_item)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _i: self.app.quit())
        menu.append(quit_item)
        menu.show_all()
        return menu

    # --- polling ---

    def _poll(self):
        self.refresh()
        return True

    def _poll_now_playing(self):
        if self._running:
            self._now_playing.poll()
            player = self._now_playing.player
            if player and player != self.settings.get("player"):
                self.settings["player"] = player
                save_settings(self.settings)
        return True

    def _remote_player(self):
        """The media player that remote play/pause should control: the one last
        seen playing (remembered across restarts), else any paused player."""
        players = mpris_players()
        for known in (self._now_playing.player, self.settings.get("player")):
            if known in players:
                return known
        for player in players:
            props = mpris_props(player) or {}
            if props.get("PlaybackStatus") == "Paused" and (props.get("Metadata") or {}).get("xesam:title"):
                return player
        return None

    def _poll_remote(self):
        """Keep OwnTone's player and the media player (Spotify...) in step.

        - Play/pause pressed on a HomePod or Apple TV remote reaches OwnTone,
          which pauses/resumes its own player: pass that on to the media player.
        - Next on the remote moves OwnTone to the spare queue item (see
          keep_spare_queue_item): send Next. Previous restarts OwnTone's current
          item: send Previous (Spotify then restarts the song, or goes back a
          song if pressed again quickly, like on a phone).
        - Play pressed in the media player while OwnTone is paused: resume
          OwnTone too (a paused OwnTone doesn't wake up for new audio by itself).

        Only *changes* count, so nothing loops back: e.g. Spotify pausing makes
        OwnTone pause a moment later, which changes nothing in Spotify."""
        if not self._using_airplay:
            self._remote_prev = None
            return True
        info = player_info() or {}
        state = info.get("state")
        item = info.get("item_id")
        progress = info.get("item_progress_ms") or 0
        player = self._remote_player()
        props = (mpris_props(player) or {}) if player else {}
        playing = props.get("PlaybackStatus") == "Playing"

        prev = self._remote_prev
        quiet = time.monotonic() < self._remote_ignore_until
        if quiet and prev is not None:
            # Quiet period (right after a skip or a pause/play we passed on):
            # OwnTone's brief in-between states are ignored, but the state from
            # before is kept, so a real change made meanwhile (e.g. play pressed
            # soon after pause) is still acted on once the period ends.
            self._remote_prev = (prev[0], playing, item, progress)
            return True
        self._remote_prev = (state, playing, item, progress)
        if prev is None or player is None:
            return True
        prev_state, prev_playing, prev_item, prev_progress = prev

        was_playing = prev_state == "play" and prev_playing
        reset = item == prev_item and prev_progress > 4000 and progress < 2500

        # A pause and a "previous" both reset OwnTone's progress to 0; the
        # difference is that "previous" goes back to playing within a moment.
        # So a pause with a reset waits up to 3 s before being treated as one.
        if self._pending_reset:
            since, reset_item = self._pending_reset
            if state == "play" and item == reset_item:
                self._pending_reset = None
                mpris_command(player, "Previous")
                self._resume_owntone(state)
            elif time.monotonic() - since > 3 or item != reset_item:
                self._pending_reset = None
                if state == "pause" and playing:
                    mpris_command(player, "Pause")
                    self._remote_ignore_until = time.monotonic() + 3
            return True

        if was_playing and prev_item and item != prev_item:
            # Moved to the spare item while playing: the remote's Next. (Only
            # while playing, so OwnTone changing items for any other reason can
            # never start Spotify by surprise.)
            mpris_command(player, "Next")
            self._resume_owntone(state)
            GLib.idle_add(lambda: (keep_spare_queue_item(), False)[1])
        elif was_playing and reset and state == "play":
            # Restarted without pausing: the remote's Previous.
            mpris_command(player, "Previous")
            self._resume_owntone(state)
        elif was_playing and reset:
            # Pause or previous? Decide on the next polls (see above).
            self._pending_reset = (time.monotonic(), item)
        elif state != prev_state:
            # The remote (via OwnTone) changed state.
            if prev_state == "play" and state == "pause" and playing:
                mpris_command(player, "Pause")
            elif prev_state != "play" and state == "play" and not playing:
                mpris_command(player, "Play")
            # OwnTone's progress can jump back to 0 right after a pause/resume;
            # don't mistake that for the remote's Previous.
            self._remote_ignore_until = time.monotonic() + 3
        elif playing and not prev_playing and state == "pause":
            # Resumed in the media player itself while OwnTone was paused.
            owntone("PUT", "/player/play")
        return True

    def _resume_owntone(self, state):
        """After a skip: make sure OwnTone keeps playing, and ignore the brief
        pause it reports while switching (it isn't the user pausing)."""
        if state != "play":
            owntone("PUT", "/player/play")
        self._remote_ignore_until = time.monotonic() + 3

    def _schedule_reconnect(self):
        self._reconnect_tries = 10
        GLib.timeout_add_seconds(2, self._try_reconnect)

    def _try_reconnect(self):
        """Reconnect to the last used output once OwnTone has found it again."""
        last = self.settings.get("last")
        if not last or self._reconnect_tries <= 0:
            return False
        self._reconnect_tries -= 1
        if last["kind"] == "local":
            self._reconnect_tries = 0
            use_sink(last["keys"][0])
            return False
        outputs = airplay_outputs() or []
        by_key = {e["key"]: e for e in self._links.group(outputs)}
        if not all(k in by_key for k in last["keys"]):
            return True  # not all found yet: try again
        ids = tuple(i for k in last["keys"] for i in by_key[k]["ids"])
        self._reconnect_tries = 0
        self._remote_ignore_until = time.monotonic() + 4
        use_airplay(ids, last["title"])
        self.refresh()
        return False

    # --- refresh ---

    def refresh(self):
        running = pipe_module_id() is not None
        state = "Running" if running else "Stopped"
        color = "#2e9e44" if running else "#c0392b"
        self.status.set_markup(f"Discovery: <b><span foreground='{color}'>{state}</span></b>")
        self._running = running
        if self.settings["running"] != running:
            # Keep the saved state in step, even when changed outside the app.
            self.settings["running"] = running
            save_settings(self.settings)
        self.toggle_btn.set_label("Stop AirPlay Discovery" if running else "Start AirPlay Discovery")

        outputs = airplay_outputs() if running else []
        self._entries = self._links.group(outputs or [])
        current = default_sink()
        self._using_airplay = current == PIPE_SINK
        selected_ids = {str(o["id"]) for o in outputs or [] if o.get("selected")}
        self.refresh_devices(current, selected_ids)
        self.refresh_volumes(outputs or [], selected_ids)
        self.refresh_pairing(outputs or [])
        self.refresh_hidden_menu()
        if self._using_airplay:
            keep_spare_queue_item()

        # The bottom line is rebuilt from the current state every refresh, so the
        # count never goes stale. Only AirPlay devices are counted, a stereo pair
        # counts once and hidden devices don't count.
        hidden = set(self.settings["hidden"])
        found = sum(1 for e in self._entries if e["key"] not in hidden)
        if self._error:
            text = self._error
        elif self._notice:
            text = self._notice
        elif running and outputs is None:
            text = "Can't reach OwnTone. Is the owntone service running?"
        elif running and found:
            text = f"Found {found} {'device' if found == 1 else 'devices'}"
        elif running:
            text = SEARCHING
        else:
            text = ""
        self.message.set_text(text)

    def _rows(self):
        """Everything the list shows: [(kind, key, title, ids)], favorites first."""
        favs = set(self.settings["favorites"])
        hidden = set(self.settings["hidden"])
        rows = [("local", name, label, ()) for name, label in local_sinks()]
        rows += [("airplay", e["key"], e["title"], e["ids"]) for e in self._entries]
        rows = [r for r in rows if r[1] not in hidden]  # unhide via ☰ > Hidden devices

        # Favorites that aren't around right now stay listed, marked (offline).
        # Remember favorites' names while they're online so they can be shown.
        online = {r[1] for r in rows}
        titles = self.settings["favorite_titles"]
        changed = False
        for kind, key, title, _ in rows:
            label = f"AirPlay: {title}" if kind == "airplay" else title
            if key in favs and titles.get(key) != label:
                titles[key] = label
                changed = True
        if changed:
            save_settings(self.settings)
        for key in favs - online - hidden:
            label = titles.get(key)
            # AirPlay favorites only count as offline while discovery is running.
            if label and (self._running or not label.startswith("AirPlay: ")):
                rows.append(("offline", key, label, ()))

        # Favorites at the top (offline ones after the usable ones); otherwise
        # this computer's outputs, then AirPlay.
        rows.sort(key=lambda r: (r[1] not in favs, r[0] == "offline", r[0] != "local", r[2].lower()))
        return rows

    def _chosen(self, current, selected_ids):
        """Keys of the rows in use right now."""
        if current != PIPE_SINK:
            return {current}
        return {e["key"] for e in self._entries if set(e["ids"]) <= selected_ids and e["ids"]}

    def refresh_devices(self, current, selected_ids):
        rows = self._rows()
        chosen = self._chosen(current, selected_ids)
        multi = self.settings["multi"]
        self._sync_last(chosen, current)
        favs = set(self.settings["favorites"])
        hidden = set(self.settings["hidden"])

        # Show the device(s) in use next to "Audio output:".
        # (Looked up in all rows, so a hidden device in use still shows here.)
        titles = [r[2] for r in self._rows_all() if r[1] in chosen]
        self.output_label.set_markup(
            f"Audio output: <b>{GLib.markup_escape_text(self._join_titles(titles) or 'None')}</b>"
        )

        key = (tuple(rows), multi, frozenset(favs), frozenset(hidden))
        self.device_list.handler_block(self._list_handler)
        try:
            if key != self._rows_key:
                self._rows_key = key
                self.device_list.set_selection_mode(
                    Gtk.SelectionMode.NONE if multi else Gtk.SelectionMode.SINGLE
                )
                for row in self.device_list.get_children():
                    self.device_list.remove(row)
                for kind, rkey, title, ids in rows:
                    self.device_list.add(self._make_row(kind, rkey, title, ids, multi, favs, hidden))
                self.device_list.show_all()

            # Reflect what's in use: highlight (single) or tick boxes (multi).
            for row in self.device_list.get_children():
                if row.check:
                    row.check.handler_block(row.check_handler)
                    row.check.set_active(row.key in chosen)
                    row.check.handler_unblock(row.check_handler)
            if not multi:
                selected = self.device_list.get_selected_row()
                if not selected or selected.key not in chosen:
                    self.device_list.unselect_all()
                    for row in self.device_list.get_children():
                        if row.key in chosen:
                            self.device_list.select_row(row)
                            break
        finally:
            self.device_list.handler_unblock(self._list_handler)

        if self.tray:
            self.tray.update(rows, chosen, multi, self._running)

    def _sync_last(self, chosen, current):
        """Remember what's in use (however it was picked) for reconnecting later.
        Skipped while a reconnect is still pending, so it isn't overwritten."""
        if not chosen or self._reconnect_tries > 0:
            return
        kind = "airplay" if current == PIPE_SINK else "local"
        last = self.settings.get("last") or {}
        if last.get("kind") == kind and set(last.get("keys", [])) == chosen:
            return
        titles = [r[2] for r in self._rows_all() if r[1] in chosen]
        self._remember(kind, sorted(chosen), self._join_titles(titles))

    def _rows_all(self):
        rows = [("local", name, label, ()) for name, label in local_sinks()]
        rows += [("airplay", e["key"], e["title"], e["ids"]) for e in self._entries]
        return rows

    @staticmethod
    def _join_titles(titles):
        if len(titles) <= 2:
            return " + ".join(titles)
        return f"{len(titles)} speakers"

    def _make_row(self, kind, key, title, ids, multi, favs, hidden):
        row = Gtk.ListBoxRow()
        row.kind, row.key, row.title, row.ids = kind, key, title, ids
        hbox = Gtk.Box(spacing=8)
        hbox.set_margin_start(8)
        hbox.set_margin_end(8)
        hbox.set_margin_top(4)
        hbox.set_margin_bottom(4)
        row.check = None
        if kind == "offline":
            # Greyed out and can't be picked; right-click still works (it's
            # handled by the list), e.g. to unfavorite.
            row.set_selectable(False)
            row.set_activatable(False)
            row.set_sensitive(False)
            label = Gtk.Label(xalign=0)
            label.set_markup(f"{'★ ' if key in favs else ''}{GLib.markup_escape_text(title)} <i>(offline)</i>")
            label.set_ellipsize(Pango.EllipsizeMode.END)
            label.set_margin_top(2)
            label.set_margin_bottom(2)
            label.get_style_context().add_class("dim-label")
            hbox.pack_start(label, True, True, 0)
            row.add(hbox)
            return row
        if multi and kind == "airplay":
            row.check = Gtk.CheckButton()
            row.check_handler = row.check.connect("toggled", self.on_check_toggled)
            hbox.pack_start(row.check, False, False, 0)
        text = ("★ " if key in favs else "") + (f"AirPlay: {title}" if kind == "airplay" else title)
        label = Gtk.Label(label=text, xalign=0)
        label.set_ellipsize(Pango.EllipsizeMode.END)
        label.set_margin_top(2)
        label.set_margin_bottom(2)
        if key in hidden:
            label.set_markup(f"<i>{GLib.markup_escape_text(text)} (hidden)</i>")
            label.get_style_context().add_class("dim-label")
        hbox.pack_start(label, True, True, 0)
        row.add(hbox)
        return row

    def refresh_volumes(self, outputs, selected_ids):
        """A volume slider for each speaker (or pair) in use."""
        in_use = [e for e in self._entries if self._using_airplay and e["ids"] and set(e["ids"]) <= selected_ids]
        key = tuple(e["key"] for e in in_use)
        volumes = {str(o["id"]): o.get("volume", 0) for o in outputs}
        if key != self._volume_key:
            self._volume_key = key
            for child in self.volume_box.get_children():
                self.volume_box.remove(child)
            self._sliders = {}
            if in_use:
                title = Gtk.Label(label="Volume:", xalign=0)
                self.volume_box.pack_start(title, False, False, 0)
            for e in in_use:
                row = Gtk.Box(spacing=8)
                name = Gtk.Label(label=e["title"].replace(" (stereo pair)", ""), xalign=0)
                name.set_width_chars(14)
                name.set_max_width_chars(14)
                name.set_ellipsize(Pango.EllipsizeMode.END)
                row.pack_start(name, False, False, 0)
                scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
                scale.set_draw_value(True)
                scale.set_value_pos(Gtk.PositionType.RIGHT)
                scale.set_hexpand(True)
                scale.ids = e["ids"]
                scale.handler = scale.connect("value-changed", self.on_volume_changed)
                row.pack_start(scale, True, True, 0)
                self.volume_box.pack_start(row, False, False, 0)
                self._sliders[e["key"]] = scale
            # (show_all() on the box itself is skipped because of no_show_all.)
            for child in self.volume_box.get_children():
                child.show_all()
            self.volume_box.set_visible(bool(in_use))
        # Follow volume changes made elsewhere (Home app, Siri), but not while the
        # user is dragging a slider.
        if time.monotonic() - self._volume_touched > 2:
            for e in in_use:
                scale = self._sliders.get(e["key"])
                vol = volumes.get(e["ids"][0])
                if scale is not None and vol is not None and int(scale.get_value()) != vol:
                    scale.handler_block(scale.handler)
                    scale.set_value(vol)
                    scale.handler_unblock(scale.handler)

    def refresh_pairing(self, outputs):
        waiting = [o for o in outputs if o.get("needs_auth_key")] if self._running else []
        if not waiting:
            if self.pin_box.get_visible():
                self.pin_box.hide()
                self.pin_entry.set_text("")
            return
        names = " / ".join(o["name"] for o in waiting)
        self.pin_label.set_text(
            f"Enter the code shown on {names}. "
            "If no code is showing, select the device again."
        )
        if not self.pin_box.get_visible():
            self.pin_box.show()
            self.pin_entry.grab_focus()

    # --- switching outputs ---

    def on_row_selected(self, _listbox, row):
        # Single-speaker mode. Do the switch after GTK has finished handling the
        # click: switching can rebuild the list, and destroying the clicked row
        # inside its own signal crashes GTK.
        if row is None or self.settings["multi"]:
            return
        GLib.idle_add(self._switch_single, row.kind, row.key, row.title, row.ids)

    def on_row_activated(self, _listbox, row):
        # Multi-speaker mode: clicking a row toggles its box; clicking one of this
        # computer's outputs switches back to it.
        if not self.settings["multi"]:
            return
        if row.check:
            row.check.set_active(not row.check.get_active())
        else:
            GLib.idle_add(self._switch_single, row.kind, row.key, row.title, row.ids)

    def on_check_toggled(self, _check):
        GLib.idle_add(self._switch_multi)

    def _switch_single(self, kind, key, title, ids):
        self._remote_ignore_until = time.monotonic() + 4
        if kind == "airplay":
            self._last_airplay = (ids, title)
            ok, err = use_airplay(ids, title)
            if ok:
                self._remember("airplay", [key], title)
        else:
            ok, err = use_sink(key)
            if ok:
                stop_airplay()
                rename_pipe("OwnTone")  # not in use, so back to its plain name
                self._remember("local", [key], title)
        self._error = "" if ok else f"Couldn't switch output: {err}"
        self.refresh()
        return False  # run once

    def _switch_multi(self):
        checked = [row for row in self.device_list.get_children() if row.check and row.check.get_active()]
        if not checked:
            # Nothing ticked: back to this computer's speakers.
            local = local_sinks()
            if local:
                return self._switch_single("local", local[0][0], local[0][1], ())
            return False
        self._remote_ignore_until = time.monotonic() + 4
        ids = tuple(i for row in checked for i in row.ids)
        title = self._join_titles([row.title for row in checked])
        self._last_airplay = (ids, title)
        ok, err = use_airplay(ids, title)
        if ok:
            self._remember("airplay", [row.key for row in checked], title)
        self._error = "" if ok else f"Couldn't switch output: {err}"
        self.refresh()
        return False

    def _remember(self, kind, keys, title):
        self.settings["last"] = {"kind": kind, "keys": keys, "title": title}
        save_settings(self.settings)

    def on_multi_toggled(self, switch, _param):
        self.settings["multi"] = switch.get_active()
        save_settings(self.settings)
        self.refresh()

    def on_volume_changed(self, scale):
        self._volume_touched = time.monotonic()
        # Debounce: send the value once the slider settles for a moment.
        timer = self._volume_timers.pop(id(scale), None)
        if timer:
            GLib.source_remove(timer)

        def send():
            self._volume_timers.pop(id(scale), None)
            set_volume(scale.ids, scale.get_value())
            return False

        self._volume_timers[id(scale)] = GLib.timeout_add(150, send)

    # --- favorites / hidden ---

    def on_list_button(self, listbox, event):
        if event.button != 3:
            return False
        row = listbox.get_row_at_y(int(event.y))
        if row is None:
            return False
        menu = Gtk.Menu()
        is_fav = row.key in self.settings["favorites"]
        fav = Gtk.MenuItem(label="Remove from favorites" if is_fav else "Add to favorites")
        fav.connect("activate", lambda _i: self._toggle_setting_list("favorites", row.key, row.title, row.kind))
        menu.append(fav)
        is_hidden = row.key in self.settings["hidden"]
        hide = Gtk.MenuItem(label="Unhide" if is_hidden else "Hide")
        hide.connect("activate", lambda _i: self._toggle_setting_list("hidden", row.key, row.title))
        menu.append(hide)
        menu.show_all()
        menu.attach_to_widget(listbox)
        menu.popup_at_pointer(event)
        return True

    def _toggle_setting_list(self, name, key, title=None, kind=None):
        items = self.settings[name]
        titles = self.settings["hidden_titles" if name == "hidden" else "favorite_titles"]
        if key in items:
            items.remove(key)
            titles.pop(key, None)
        else:
            items.append(key)
            if title and name == "hidden":
                titles[key] = title
            elif title and kind != "offline":
                titles[key] = f"AirPlay: {title}" if kind == "airplay" else title
        save_settings(self.settings)
        GLib.idle_add(lambda: (self.refresh(), False)[1])

    def refresh_hidden_menu(self):
        """☰ > Hidden devices: one item per hidden device; clicking unhides it."""
        hidden = list(self.settings["hidden"])
        titles = self.settings["hidden_titles"]
        known = {r[1]: r[2] for r in self._rows_all()}
        # Marked (offline) only while discovery runs; when it's stopped no AirPlay
        # device is visible, so "offline" would be misleading.
        offline = " (offline)" if self._running else ""
        names = [
            (k, known[k] if k in known else f"{titles.get(k) or 'Unknown device'}{offline}")
            for k in hidden
        ]
        names.sort(key=lambda n: n[1].lower())
        key = tuple(names)
        if key == self._hidden_menu_key:
            return
        self._hidden_menu_key = key
        for child in self.hidden_menu.get_children():
            self.hidden_menu.remove(child)
        if not names:
            empty = Gtk.MenuItem(label="No hidden devices")
            empty.set_sensitive(False)
            self.hidden_menu.append(empty)
        else:
            header = Gtk.MenuItem(label="Click a device to unhide it")
            header.set_sensitive(False)
            self.hidden_menu.append(header)
            for k, title in names:
                item = Gtk.MenuItem(label=title)
                item.connect("activate", lambda _i, k=k: self._toggle_setting_list("hidden", k))
                self.hidden_menu.append(item)
        self.hidden_menu.show_all()

    # --- discovery on/off ---

    def on_toggle(self, _button):
        self.toggle_discovery()

    def toggle_discovery(self):
        if self._running:
            stop_airplay()
            ok, out, err = stop_pipe()
            self._error = "" if ok else f"Failed to stop: {err or out}"
            self.settings["running"] = not ok
        else:
            ok, out, err = start_pipe()
            self._error = "" if ok else f"Failed to start: {err or out}"
            self.settings["running"] = ok
            if ok:
                self._schedule_reconnect()
        save_settings(self.settings)
        self.refresh()

    # --- pairing ---

    def on_pair(self, _widget):
        pin = self.pin_entry.get_text().strip()
        if len(pin) != 4 or not pin.isdigit():
            self._error = "The code is 4 digits."
            self.refresh()
            return
        waiting = [str(o["id"]) for o in airplay_outputs() or [] if o.get("needs_auth_key")]
        self.pin_entry.set_text("")
        if not waiting:
            self._error = ""
            self.refresh()
            return
        ok, err = send_code(pin, waiting)
        self._error = "" if ok else f"Pairing failed: {err}"
        # Give the device a moment to finish pairing, then try playing to it again.
        GLib.timeout_add_seconds(3, self._after_pairing)
        self.refresh()

    def _after_pairing(self):
        waiting = {str(o["id"]) for o in airplay_outputs() or [] if o.get("needs_auth_key")}
        if self._last_airplay and not waiting & set(self._last_airplay[0]):
            ok, err = use_airplay(*self._last_airplay)
            self._error = "" if ok else f"Couldn't switch output: {err}"
        elif waiting:
            self._error = "Pairing didn't work. Check the code and try again."
        self.refresh()
        return False

    # --- OwnTone update ---

    def on_update(self, _item):
        if self._updating:
            return
        self._updating = True
        self.update_item.set_sensitive(False)
        self._notice = "Updating OwnTone… this can take a few minutes."
        self.refresh()

        def work():
            ok, msg = update_owntone()
            GLib.idle_add(self._update_done, ok, msg)

        threading.Thread(target=work, daemon=True).start()

    def _update_done(self, ok, msg):
        self._updating = False
        self.update_item.set_sensitive(True)
        self._notice = msg
        self.refresh()
        GLib.timeout_add_seconds(15, self._clear_notice, msg)
        return False

    def _clear_notice(self, msg):
        if self._notice == msg:
            self._notice = ""
            self.refresh()
        return False

    # --- window ---

    @staticmethod
    def _title_button(icon_name, tooltip, handler, kind):
        button = Gtk.Button.new_from_icon_name(icon_name, Gtk.IconSize.MENU)
        # "titlebutton" + "close"/"minimize" lets the theme (Breeze) draw them
        # like the window buttons of other apps.
        button.get_style_context().add_class("titlebutton")
        button.get_style_context().add_class(kind)
        # Same size as Breeze's own title buttons (18 px), so the hover circle
        # isn't oversized like on a regular header bar button.
        css = Gtk.CssProvider()
        css.load_from_data(
            b"button.titlebutton { padding: 1px; min-height: 18px; min-width: 18px; margin: 0 2px; }"
            b"button.titlebutton, button.titlebutton:hover, button.titlebutton:active,"
            b"button.titlebutton:backdrop { background-size: 18px 18px;"
            b" background-position: center; background-repeat: no-repeat; }"
        )
        button.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_valign(Gtk.Align.CENTER)
        button.set_tooltip_text(tooltip)
        button.connect("clicked", handler)
        return button

    def on_tray_option(self, item, key):
        self.settings[key] = item.get_active()
        save_settings(self.settings)

    def on_minimize_clicked(self, _button):
        if self.tray and self.settings["minimize_to_tray"]:
            self.hide()
        else:
            self.iconify()

    def on_close_clicked(self, _button):
        # Same as the window being closed any other way (e.g. Alt+F4).
        if not self.on_close():
            self.destroy()

    def on_close(self, *_args):
        if self.tray and self.settings["close_to_tray"]:
            self.hide()
            return True  # keep running in the tray
        self.app.quit()
        return False

    def show_window(self):
        self.show_all()
        self.volume_box.set_visible(bool(self._volume_key))
        self.present()


# --- Tray icon ---------------------------------------------------------------

class Tray:
    """System tray icon with a menu to show the window, pick a device, start or
    stop discovery and quit."""

    def __init__(self, window):
        self.window = window
        self._key = None
        self.indicator = AppIndicator.Indicator.new(
            "gala", ICON,
            AppIndicator.IndicatorCategory.APPLICATION_STATUS,
        )
        # Tell the tray where the icon's theme folder is, so it finds the icon
        # without depending on the desktop's icon cache. (KDE's tray doesn't
        # accept a file path as the icon.)
        self.indicator.set_icon_theme_path(os.path.expanduser("~/.local/share/icons"))
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Gala")
        self.update([], set(), False, False)

    def update(self, rows, chosen, multi, running):
        key = (tuple(rows), frozenset(chosen), multi, running)
        if key == self._key:
            return  # rebuilding the menu only when something changed
        self._key = key
        menu = Gtk.Menu()
        show = Gtk.MenuItem(label="Show Gala")
        show.connect("activate", lambda _i: self.window.show_window())
        menu.append(show)
        menu.append(Gtk.SeparatorMenuItem())
        for kind, rkey, title, ids in rows:
            if kind == "offline":
                item = Gtk.MenuItem(label=f"{title} (offline)")
                item.set_sensitive(False)
                menu.append(item)
                continue
            item = Gtk.CheckMenuItem(label=f"AirPlay: {title}" if kind == "airplay" else title)
            item.set_draw_as_radio(not multi or kind == "local")
            item.set_active(rkey in chosen)
            item.connect("activate", self._on_device, kind, rkey, title, ids, multi)
            menu.append(item)
        if rows:
            menu.append(Gtk.SeparatorMenuItem())
        toggle = Gtk.MenuItem(label="Stop AirPlay Discovery" if running else "Start AirPlay Discovery")
        toggle.connect("activate", lambda _i: GLib.idle_add(lambda: (self.window.toggle_discovery(), False)[1]))
        menu.append(toggle)
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _i: self.window.app.quit())
        menu.append(quit_item)
        menu.show_all()
        self.indicator.set_menu(menu)
        self.menu = menu  # keep a reference

    def _on_device(self, item, kind, key, title, ids, multi):
        w = self.window
        if multi and kind == "airplay":
            # Tick/untick it like the box in the window.
            for row in w.device_list.get_children():
                if row.key == key and row.check:
                    GLib.idle_add(lambda r=row: (r.check.set_active(not r.check.get_active()), False)[1])
                    return
        GLib.idle_add(w._switch_single, kind, key, title, ids)


# --- App ---------------------------------------------------------------------

class App(Gtk.Application):
    """Single instance: launching it again shows the existing window."""

    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None

    def do_command_line(self, command_line):
        hidden = "--hidden" in command_line.get_arguments()
        if self.window is None:
            self.hold()  # keep running while the window is hidden in the tray
            self.window = AirPlayWindow(self)
            if hidden and self.window.tray:
                return 0
        self.window.show_window()
        return 0


def main():
    # Present as "Gala" rather than as the Python script.
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Gala")
    # First run: start at login unless the user has turned it off.
    settings = load_settings()
    if not settings.get("autostart_set"):
        set_autostart(True)
        settings["autostart_set"] = True
        save_settings(settings)
    sys.exit(App().run(sys.argv))


if __name__ == "__main__":
    main()
