"""The GTK 4 fixture of the Linux selftests (US-076).

Run with `python3 -I` inside a test session (tools/linux-session). It opens
"Fixture neo-compute" and writes every event it receives, one timestamped
JSON line each, to the file NC_FIXTURE_LOG names, so a selftest proves the
real effect of an action rather than the call that asked for it.

  gtk_fixture.py [--fullscreen] [--app-id ID]
  gtk_fixture.py --role decoy [--fullscreen] [--app-id ID]

Each line holds "t" (Unix time, seconds), "mono_ns" (CLOCK_MONOTONIC, the
clock of the selftests) and "event". At startup the fixture writes one
"layout" line with the rectangle of each control in the coordinates of its
surface. A password field's value never reaches the log: only its length.
"""

import json
import os
import sys
import time

MISSING = "PyGObject et GTK 4 requis : installe python3-gobject et gtk4."

try:
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, Gio, GLib, Gtk
except (ImportError, ValueError):
    print(MISSING, file=sys.stderr)
    sys.exit(77)


class Log:
    def __init__(self, path):
        self.file = open(path, "a", buffering=1, encoding="utf-8") if path else None

    def write(self, event, **fields):
        line = {"t": time.time(), "mono_ns": time.monotonic_ns(), "event": event}
        line.update(fields)
        text = json.dumps(line, ensure_ascii=False)
        if self.file:
            self.file.write(text + "\n")
        else:
            print(text, flush=True)


def modifiers(state):
    names = []
    for flag, name in (
        (Gdk.ModifierType.SHIFT_MASK, "shift"),
        (Gdk.ModifierType.CONTROL_MASK, "control"),
        (Gdk.ModifierType.ALT_MASK, "alt"),
        (Gdk.ModifierType.SUPER_MASK, "super"),
        (Gdk.ModifierType.META_MASK, "meta"),
        (Gdk.ModifierType.LOCK_MASK, "lock"),
    ):
        if state & flag:
            names.append(name)
    return names


def name_of(widget):
    """The nearest named control holding `widget`."""
    while widget is not None:
        name = widget.get_name()
        if name and not name.startswith("Gtk"):
            return name
        widget = widget.get_parent()
    return None


class Fixture:
    def __init__(self, app, args, log):
        self.log = log
        self.args = args
        self.window = Gtk.ApplicationWindow(application=app)
        self.controls = {}
        if args.role == "decoy":
            self.window.set_title("Leurre neo-compute")
            self.build_decoy()
        else:
            self.window.set_title("Fixture neo-compute")
            self.build_main()
        self.window.set_default_size(1000, 760)
        self.window.connect("notify::is-active", self.on_active)
        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self.on_key, True)
        keys.connect("key-released", self.on_key, False)
        self.window.add_controller(keys)
        if args.role != "decoy":
            click = Gtk.GestureClick(button=0)
            click.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            click.connect("pressed", self.on_click)
            self.window.add_controller(click)
            scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES)
            scroll.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
            scroll.connect("scroll", self.on_scroll)
            self.window.add_controller(scroll)
        if args.fullscreen:
            self.window.fullscreen()
        self.window.connect("map", lambda *_: GLib.timeout_add(200, self.write_layout))
        self.last_size = None
        self.window.present()

    def named(self, widget, name):
        widget.set_name(name)
        self.controls[name] = widget
        return widget

    def build_decoy(self):
        label = self.named(Gtk.Label(label="Leurre : chaque touche reçue est journalisée"), "decoy")
        label.set_hexpand(True)
        label.set_vexpand(True)
        self.window.set_child(label)

    def build_main(self):
        grid = Gtk.Grid(column_spacing=12, row_spacing=8, margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
        self.window.set_child(grid)
        row = 0

        def add(label, widget, width=1):
            nonlocal row
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            grid.attach(widget, 1, row, width, 1)
            row += 1

        button = self.named(Gtk.Button(label="Bouton"), "button")
        button.connect("clicked", lambda *_: self.log.write("activate", control="button"))
        add("Bouton", button)

        check = self.named(Gtk.CheckButton(label="Case à cocher"), "checkbox")
        check.connect("toggled", lambda w: self.log.write("value", control="checkbox", value=w.get_active()))
        add("Case", check)

        entry = self.named(Gtk.Entry(placeholder_text="Champ de texte"), "entry")
        entry.connect("changed", lambda w: self.log.write("text", control="entry", value=w.get_text()))
        add("Texte", entry)

        password = self.named(Gtk.PasswordEntry(), "password")
        password.connect("changed", lambda w: self.log.write("text", control="password", length=len(w.get_text())))
        add("Mot de passe", password)

        scale = self.named(Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1), "slider")
        scale.set_hexpand(True)
        scale.connect("value-changed", lambda w: self.log.write("value", control="slider", value=w.get_value()))
        add("Curseur", scale)

        listbox = Gtk.ListBox()
        for i in range(1, 31):
            listbox.append(Gtk.Label(label=f"Entrée {i}", xalign=0))
        listbox.connect("row-selected", self.on_row)
        scrolled = self.named(Gtk.ScrolledWindow(min_content_height=120), "list")
        scrolled.set_child(listbox)
        scrolled.get_vadjustment().connect("value-changed", lambda adj: self.log.write("scroll", control="list", value=adj.get_value()))
        add("Liste", scrolled)

        dropdown = self.named(Gtk.DropDown.new_from_strings(["Un", "Deux", "Trois", "Quatre"]), "dropdown")
        dropdown.connect("notify::selected", lambda w, _: self.log.write("value", control="dropdown", value=w.get_selected()))
        add("Liste déroulante", dropdown)

        text = Gtk.TextView()
        text.get_buffer().connect("insert-text", lambda _b, _it, s, _n: self.log.write("text", control="textview", inserted=s))
        frame = self.named(Gtk.ScrolledWindow(min_content_height=80), "textview")
        frame.set_child(text)
        add("Zone de texte", frame)

        drag = self.named(self.zone("Glisse-moi"), "drag-source")
        source = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        source.connect("prepare", lambda *_: Gdk.ContentProvider.new_for_value("nc-drag"))
        drag.add_controller(source)
        drop = self.named(self.zone("Dépose ici"), "drop-target")
        target = Gtk.DropTarget.new(str, Gdk.DragAction.COPY)
        target.connect("drop", self.on_drop)
        drop.add_controller(target)
        zones = Gtk.Box(spacing=12)
        zones.append(drag)
        zones.append(drop)
        add("Glisser-déposer", zones)

        hover = self.named(self.zone("Survole-moi"), "hover")
        motion = Gtk.EventControllerMotion()
        motion.connect("enter", lambda _c, x, y: self.log.write("enter", control="hover", x=x, y=y))
        motion.connect("leave", lambda _c: self.log.write("leave", control="hover"))
        hover.add_controller(motion)
        add("Survol", hover)

        canvas = self.named(Gtk.DrawingArea(content_width=400, content_height=160), "canvas")
        canvas.set_draw_func(lambda _a, cr, w, h: (cr.set_source_rgb(0.9, 0.9, 0.95), cr.paint()))
        pointer = Gtk.EventControllerMotion()
        pointer.connect("motion", lambda _c, x, y: self.log.write("pointer", control="canvas", x=x, y=y))
        canvas.add_controller(pointer)
        add("Canevas", canvas)

    def zone(self, text):
        label = Gtk.Label(label=text)
        label.set_size_request(160, 48)
        box = Gtk.Box()
        box.append(label)
        box.add_css_class("frame")
        return box

    def on_row(self, _listbox, row):
        if row is not None:
            self.log.write("value", control="list", value=row.get_index())

    def on_drop(self, _target, value, x, y):
        self.log.write("drop", control="drop-target", value=value, x=x, y=y)
        return True

    def on_active(self, window, _):
        self.log.write("active", value=window.is_active())

    def on_key(self, _controller, keyval, keycode, state, pressed):
        if name_of(self.window.get_focus()) == "password":
            # The keys typed in the password field would spell its value.
            self.log.write("key", pressed=pressed, control="password", modifiers=modifiers(state))
            return False
        self.log.write(
            "key",
            pressed=pressed,
            keysym=keyval,
            name=Gdk.keyval_name(keyval),
            keycode=keycode,
            modifiers=modifiers(state),
        )
        return False

    def on_click(self, gesture, n_press, x, y):
        picked = self.window.pick(x, y, Gtk.PickFlags.DEFAULT)
        self.log.write("click", button=gesture.get_current_button(), n_press=n_press, x=x, y=y, control=name_of(picked))

    def on_scroll(self, _controller, dx, dy):
        self.log.write("wheel", dx=dx, dy=dy)
        return False

    def write_layout(self):
        # Written once the window has settled: full screen reached when
        # asked, and the same size over two checks 100 ms apart.
        size = (self.window.get_width(), self.window.get_height())
        if (self.args.fullscreen and not self.window.is_fullscreen()) or size != self.last_size:
            self.last_size = size
            GLib.timeout_add(100, self.write_layout)
            return False
        # Widget coordinates plus the surface transform (client-side
        # decorations and shadow) give surface coordinates.
        ox, oy = self.window.get_surface_transform()
        rects = {}
        for name, widget in self.controls.items():
            ok, bounds = widget.compute_bounds(self.window)
            if ok:
                rects[name] = [
                    round(bounds.get_x() + ox, 1),
                    round(bounds.get_y() + oy, 1),
                    round(bounds.get_width(), 1),
                    round(bounds.get_height(), 1),
                ]
        self.log.write(
            "layout",
            title=self.window.get_title(),
            active=self.window.is_active(),
            role=self.args.role,
            app_id=self.window.get_application().get_application_id(),
            surface=[self.window.get_width(), self.window.get_height()],
            controls=rects,
        )
        return False


class Args:
    def __init__(self, argv):
        self.role = "main"
        self.fullscreen = False
        self.app_id = "org.neocompute.Fixture"
        i = 0
        while i < len(argv):
            a = argv[i]
            if a == "--role" and i + 1 < len(argv):
                self.role = argv[i + 1]
                i += 1
            elif a == "--app-id" and i + 1 < len(argv):
                self.app_id = argv[i + 1]
                i += 1
            elif a == "--fullscreen":
                self.fullscreen = True
            else:
                raise SystemExit(f"argument inconnu : {a}\n" + __doc__)
            i += 1
        if self.role not in ("main", "decoy"):
            raise SystemExit("--role attend main ou decoy")
        if self.role == "decoy" and self.app_id == "org.neocompute.Fixture":
            self.app_id = "org.neocompute.Decoy"


def stop_on_sigterm(callback):
    try:
        gi.require_version("GLibUnix", "2.0")
        from gi.repository import GLibUnix

        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, 15, callback)
    except (ImportError, ValueError):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, callback)


def main():
    args = Args(sys.argv[1:])
    log = Log(os.environ.get("NC_FIXTURE_LOG"))
    app = Gtk.Application(application_id=args.app_id, flags=Gio.ApplicationFlags.NON_UNIQUE)
    keep = []
    app.connect("activate", lambda a: keep.append(Fixture(a, args, log)))
    stop_on_sigterm(app.quit)
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
