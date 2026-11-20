"""Proof that both Linux fixtures write the events they receive (US-076).

Run with `python3 -I` inside a gnome test session:

  zig-out/bin/linux-session gnome exec -- python3 -I tests/linux/fixture/smoke.py [gtk] [chrome]

It opens each fixture full screen, injects real input through a Mutter
RemoteDesktop session of its own (pointer through a ScreenCast stream of
the monitor, keyboard by keysym), and requires, in the fixture's
NC_FIXTURE_LOG, the layout, a click on the button with its activation,
the keys and the text typed in the text field, the hover zone's entry and
exit, the check box's new value, the pointer on the canvas, the wheel and
the list's scroll, a completed drag and drop; the decoy's keys; and, for
Chrome, the live region of counters read through AT-SPI.
Exits 0 when every fixture passed, 1 with the missing events otherwise,
77 when PyGObject, GTK 4 or Chrome is missing.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except (ImportError, ValueError):
    print("PyGObject et GTK 4 requis : installe python3-gobject et gtk4.", file=sys.stderr)
    sys.exit(77)

HERE = os.path.dirname(os.path.abspath(__file__))
MISSING_GTK = "PyGObject et GTK 4 requis : installe python3-gobject et gtk4."
# Why a fixture that exits with 77 is skipped, in its own words.
SKIPPED = {"gtk": MISSING_GTK, "decoy": MISSING_GTK, "chrome": "Chrome introuvable : installe google-chrome ou chromium."}
BTN_LEFT = 0x110
XK = {"Shift_L": 0xFFE1, "a": 0x61, "b": 0x62, "c": 0x63, "Escape": 0xFF1B}


class Input:
    """One RemoteDesktop session with a ScreenCast stream of the monitor."""

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        (self.rd,) = self.call(
            "org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop", "CreateSession", None, "(o)"
        )
        sid = self.call(
            "org.gnome.Mutter.RemoteDesktop", self.rd, "org.freedesktop.DBus.Properties", "Get",
            GLib.Variant("(ss)", ("org.gnome.Mutter.RemoteDesktop.Session", "SessionId")), "(v)",
        )[0]
        (sc,) = self.call(
            "org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession",
            GLib.Variant("(a{sv})", ({"remote-desktop-session-id": GLib.Variant("s", sid)},)), "(o)",
        )
        state = self.call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None)
        connector = state[1][0][0][0]
        (self.stream,) = self.call(
            "org.gnome.Mutter.ScreenCast", sc, "org.gnome.Mutter.ScreenCast.Session", "RecordMonitor",
            GLib.Variant("(sa{sv})", (connector, {})), "(o)",
        )
        self.rd_call("Start")
        time.sleep(0.3)
        # The first key after Start and a first click without a prior
        # motion are lost (audit 4.1): spend both.
        self.key("Shift_L")
        self.move(5, 5)

    def call(self, dest, path, iface, method, params, reply):
        ret = self.bus.call_sync(dest, path, iface, method, params, GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 5000, None)
        return ret.unpack()

    def rd_call(self, method, params=None):
        self.call("org.gnome.Mutter.RemoteDesktop", self.rd, "org.gnome.Mutter.RemoteDesktop.Session", method, params, None)

    def move(self, x, y):
        self.rd_call("NotifyPointerMotionAbsolute", GLib.Variant("(sdd)", (self.stream, float(x), float(y))))
        time.sleep(0.05)

    def click(self, x, y):
        self.move(x, y)
        self.rd_call("NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, True)))
        time.sleep(0.03)
        self.rd_call("NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, False)))
        time.sleep(0.15)

    def drag(self, start, end, steps=12):
        self.move(*start)
        self.rd_call("NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, True)))
        time.sleep(0.1)
        for i in range(1, steps + 1):
            self.move(start[0] + (end[0] - start[0]) * i / steps, start[1] + (end[1] - start[1]) * i / steps)
        time.sleep(0.1)
        self.rd_call("NotifyPointerButton", GLib.Variant("(ib)", (BTN_LEFT, False)))
        time.sleep(0.3)

    def wheel(self, x, y, steps):
        self.move(x, y)
        self.rd_call("NotifyPointerAxisDiscrete", GLib.Variant("(ui)", (0, steps)))
        time.sleep(0.15)

    def key(self, name):
        for down in (True, False):
            self.rd_call("NotifyKeyboardKeysym", GLib.Variant("(ub)", (XK[name], down)))
            time.sleep(0.03)

    def stop(self):
        try:
            self.rd_call("Stop")
        except GLib.Error:
            pass


def read_log(path):
    events = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        pass
    return events


def wait_for(path, pred, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for e in read_log(path):
            if pred(e):
                return e
        time.sleep(0.05)
    return None


def center(rect):
    x, y, w, h = rect
    return x + w / 2, y + h / 2


def exercise(name, argv, log, inp):
    env = dict(os.environ, NC_FIXTURE_LOG=log)
    child = subprocess.Popen(argv, env=env)
    missing = []
    try:
        layout = wait_for(log, lambda e: e.get("event") == "layout", 20)
        if layout is None:
            code = child.poll()
            if code == 77:
                return SKIPPED[name]
            return [f"{name} : aucun événement layout"]
        if wait_for(log, lambda e: e.get("event") == "active" and e.get("value") or e.get("event") == "layout" and e.get("active"), 10) is None:
            return [f"{name} : la fenêtre n'est jamais devenue active"]
        time.sleep(0.3)
        controls = layout["controls"]
        # The pointer enters the new window before the first click.
        sw, sh = layout.get("surface") or layout.get("viewport")
        inp.move(sw / 2, sh / 2)
        origin = (0, 0)
        if layout.get("role") == "decoy":
            for k in ("a", "b"):
                inp.key(k)
            time.sleep(0.3)
            checks = {
                "touche a du leurre": lambda e: e["event"] == "key" and e.get("pressed") and e.get("name") == "a",
                "touche b du leurre": lambda e: e["event"] == "key" and e.get("pressed") and e.get("name") == "b",
            }
            return report(name, read_log(log), checks)
        inp.click(*shift(center(controls["button"]), origin))
        inp.click(*shift(center(controls["entry"]), origin))
        for k in ("a", "b", "c"):
            inp.key(k)
        inp.move(*shift(center(controls["hover"]), origin))
        inp.click(*shift(center(controls["checkbox"]) if name == "gtk" else center(controls["checkbox"]), origin))
        cx, cy = center(controls["canvas"])
        inp.move(cx - 20, cy)
        inp.move(cx + 20, cy)
        inp.wheel(*center(controls["list"]), 2)
        inp.drag(center(controls["drag-source"]), center(controls["drop-target"]))
        time.sleep(0.4)
        checks = {
            "clic sur le bouton": lambda e: e["event"] == "click" and e.get("control") == "button" and e.get("n_press") == 1,
            "activation du bouton": lambda e: e["event"] == "activate" and e.get("control") == "button",
            "touche a": lambda e: e["event"] == "key" and e.get("pressed") and (e.get("name") == "a" or e.get("key") == "a"),
            "texte abc": lambda e: e["event"] == "text" and e.get("control") == "entry" and e.get("value") == "abc",
            "entrée de survol": lambda e: e["event"] == "enter" and e.get("control") == "hover",
            "sortie de survol": lambda e: e["event"] == "leave" and e.get("control") == "hover",
            "case cochée": lambda e: e["event"] == "value" and e.get("control") == "checkbox" and e.get("value") is True,
            "pointeur sur le canevas": lambda e: e["event"] == "pointer" and e.get("control") == "canvas",
            "molette": lambda e: e["event"] == "wheel",
            "défilement de la liste": lambda e: e["event"] == "scroll" and e.get("control") == "list",
            "dépôt terminé": lambda e: e["event"] == "drop" and e.get("value") == "nc-drag",
        }
        if name == "chrome":
            checks["région live lue par AT-SPI"] = lambda e, ok=live_region_read(): ok
        return report(name, read_log(log), checks)
    finally:
        child.terminate()
        try:
            child.wait(10)
        except subprocess.TimeoutExpired:
            child.kill()
    return missing


def report(name, events, checks):
    missing = [f"{name} : {what} absent du journal" for what, pred in checks.items() if not any(pred(e) for e in events)]
    print(f"{name} : {len(events)} événements, {len(checks) - len(missing)}/{len(checks)} attendus", flush=True)
    return missing


def live_region_read():
    """The page's counters, read through AT-SPI from Chrome's tree."""
    try:
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
    except (ImportError, ValueError):
        return False
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None or "chrom" not in (app.get_name() or "").lower():
            continue
        stack = [app]
        seen = 0
        while stack and seen < 5000:
            node = stack.pop()
            seen += 1
            try:
                attrs = node.get_attributes() or {}
                if attrs.get("live") == "polite" or attrs.get("container-live") == "polite":
                    value = node.get_name() or ""
                    if node.get_text_iface() is not None:
                        value += Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node)) or ""
                    if "clics" in value:
                        return True
                for j in range(node.get_child_count()):
                    child = node.get_child_at_index(j)
                    if child is not None:
                        stack.append(child)
            except (GLib.Error, TypeError):
                continue
    return False


def shift(point, origin):
    return point[0] + origin[0], point[1] + origin[1]


def main():
    which = [a for a in sys.argv[1:] if a in ("gtk", "decoy", "chrome")] or ["gtk", "decoy", "chrome"]
    if os.environ.get("NC_SESSION") != "gnome":
        print("smoke.py : à lancer dans une session gnome de tools/linux-session.", file=sys.stderr)
        return 2
    inp = Input()
    out = tempfile.mkdtemp(prefix="fixture-smoke-", dir=os.environ.get("XDG_CACHE_HOME"))
    runs = {
        "gtk": [sys.executable, "-I", os.path.join(HERE, "gtk_fixture.py"), "--fullscreen"],
        "decoy": [sys.executable, "-I", os.path.join(HERE, "gtk_fixture.py"), "--role", "decoy", "--fullscreen"],
        "chrome": [sys.executable, "-I", os.path.join(HERE, "chrome_fixture.py"), "--", "--start-fullscreen"],
    }
    missing = []
    skipped = 0
    try:
        for name in which:
            got = exercise(name, runs[name], os.path.join(out, name + ".jsonl"), inp)
            if isinstance(got, str):
                skipped += 1
                print(f"{name} : skipped ({got})", flush=True)
            else:
                missing += got
    finally:
        inp.stop()
    for m in missing:
        print(m, file=sys.stderr)
    if missing:
        return 1
    return 77 if skipped == len(which) else 0


if __name__ == "__main__":
    sys.exit(main())
