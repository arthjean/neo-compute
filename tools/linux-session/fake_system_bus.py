"""Services of a test session's fake system bus (US-074, US-075).

Run by tools/linux-session with `python3 -I`, connected through
DBUS_SYSTEM_BUS_ADDRESS to the session's private system bus, never the
real one. The audit's incidents came from compositors that reached the
real GDM and logind (audit section 12); these stand-ins answer instead.

  --gdm     org.gnome.DisplayManager: the version GNOME Shell reads before
            it accepts to lock (misc/loginManager.js canLock), and the
            RegisterSession and RegisterDisplay calls it makes at startup.
  --login1  org.freedesktop.login1: one session of the user whose
            LockedHint the selftest changes (SetLockedHint), as logind
            would for a locker under sway or labwc.
"""

import os
import sys

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except (ImportError, ValueError):
    print("PyGObject requis : installe python3-gobject.", file=sys.stderr)
    sys.exit(77)

GDM_XML = """
<node>
  <interface name="org.gnome.DisplayManager.Manager">
    <!-- GNOME Shell calls both without arguments. -->
    <method name="RegisterDisplay"/>
    <method name="RegisterSession"/>
    <method name="OpenReauthenticationChannel">
      <arg type="s" direction="in"/><arg type="s" direction="out"/>
    </method>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>
"""

LOGIN1_XML = """
<node>
  <interface name="org.freedesktop.login1.Manager">
    <method name="ListSessions"><arg type="a(susso)" direction="out"/></method>
    <method name="GetSession">
      <arg type="s" direction="in"/><arg type="o" direction="out"/>
    </method>
    <method name="GetSessionByPID">
      <arg type="u" direction="in"/><arg type="o" direction="out"/>
    </method>
    <signal name="PrepareForSleep"><arg type="b"/></signal>
    <signal name="SessionRemoved"><arg type="s"/><arg type="o"/></signal>
  </interface>
  <interface name="org.freedesktop.login1.Session">
    <method name="SetLockedHint"><arg type="b" direction="in"/></method>
    <method name="Lock"/>
    <method name="Unlock"/>
    <signal name="Lock"/>
    <signal name="Unlock"/>
    <property name="Id" type="s" access="read"/>
    <property name="LockedHint" type="b" access="read"/>
    <property name="State" type="s" access="read"/>
    <property name="Active" type="b" access="read"/>
  </interface>
</node>
"""

SESSION_ID = "nc-none"
SESSION_PATH = "/org/freedesktop/login1/session/nc_2dnone"


class Fake:
    def __init__(self, conn, role):
        self.conn = conn
        self.locked = False
        if role == "gdm":
            info = Gio.DBusNodeInfo.new_for_xml(GDM_XML)
            conn.register_object(
                "/org/gnome/DisplayManager/Manager", info.interfaces[0], self.gdm_call, self.gdm_get, None
            )
        else:
            info = Gio.DBusNodeInfo.new_for_xml(LOGIN1_XML)
            conn.register_object("/org/freedesktop/login1", info.interfaces[0], self.manager_call, None, None)
            conn.register_object(SESSION_PATH, info.interfaces[1], self.session_call, self.session_get, None)

    def gdm_call(self, conn, sender, path, iface, method, params, inv):
        if method == "OpenReauthenticationChannel":
            inv.return_dbus_error("org.gnome.DisplayManager.Error", "faux GDM : pas de canal")
            return
        inv.return_value(None)

    def gdm_get(self, conn, sender, path, iface, prop):
        return GLib.Variant("s", "51.0")

    def manager_call(self, conn, sender, path, iface, method, params, inv):
        if method == "ListSessions":
            row = (SESSION_ID, os.getuid(), os.environ.get("USER", ""), "seat0", SESSION_PATH)
            inv.return_value(GLib.Variant("(a(susso))", ([row],)))
        else:
            inv.return_value(GLib.Variant("(o)", (SESSION_PATH,)))

    def session_call(self, conn, sender, path, iface, method, params, inv):
        if method == "SetLockedHint":
            self.locked = params.unpack()[0]
            changed = {"LockedHint": GLib.Variant("b", self.locked)}
            conn.emit_signal(
                None,
                SESSION_PATH,
                "org.freedesktop.DBus.Properties",
                "PropertiesChanged",
                GLib.Variant("(sa{sv}as)", ("org.freedesktop.login1.Session", changed, [])),
            )
        elif method in ("Lock", "Unlock"):
            conn.emit_signal(None, SESSION_PATH, "org.freedesktop.login1.Session", method, None)
        inv.return_value(None)

    def session_get(self, conn, sender, path, iface, prop):
        return {
            "Id": GLib.Variant("s", SESSION_ID),
            "LockedHint": GLib.Variant("b", self.locked),
            "State": GLib.Variant("s", "active"),
            "Active": GLib.Variant("b", True),
        }[prop]


def main():
    roles = [a[2:] for a in sys.argv[1:] if a in ("--gdm", "--login1")]
    if not roles:
        print("usage: fake_system_bus.py --gdm|--login1 ...", file=sys.stderr)
        return 2
    if "DBUS_SYSTEM_BUS_ADDRESS" not in os.environ:
        print("DBUS_SYSTEM_BUS_ADDRESS absent : refus de parler au vrai bus système.", file=sys.stderr)
        return 2
    conn = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    keep = [Fake(conn, role) for role in roles]
    names = {"gdm": "org.gnome.DisplayManager", "login1": "org.freedesktop.login1"}
    for role in roles:
        Gio.bus_own_name_on_connection(conn, names[role], Gio.BusNameOwnerFlags.NONE, None, None)
    loop = GLib.MainLoop()
    try:
        gi.require_version("GLibUnix", "2.0")
        from gi.repository import GLibUnix

        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, 15, loop.quit)
    except (ImportError, ValueError):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, loop.quit)
    loop.run()
    del keep
    return 0


if __name__ == "__main__":
    sys.exit(main())
