"""The reference D-Bus client of the byte tests (US-078).

Run by capture.sh inside a gnome test session: GDBus (through PyGObject)
makes the calls that the native client of src/backend/linux/wire/dbus.zig
must encode byte for byte, while dbus-monitor --binary records them.
"""

import sys

from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def call(dest, path, iface, method, params=None, reply=None, fds=False):
    if fds:
        return bus.call_with_unix_fd_list_sync(dest, path, iface, method, params, GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 1000, None, None)
    return bus.call_sync(dest, path, iface, method, params, GLib.VariantType(reply) if reply else None, Gio.DBusCallFlags.NONE, 1000, None)


DBUS = ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus")
call(*DBUS, "AddMatch", GLib.Variant("(s)", ("type='signal',interface='org.gnome.Mutter.RemoteDesktop.Session',member='Closed'",)))
call(*DBUS, "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.gnome.Mutter.RemoteDesktop",)), "(u)")
call(*DBUS, "RequestName", GLib.Variant("(su)", ("org.neocompute.Golden", 4)), "(u)")
RD = "org.gnome.Mutter.RemoteDesktop"
(session,) = call(RD, "/org/gnome/Mutter/RemoteDesktop", RD, "CreateSession", None, "(o)").unpack()
call(RD, session, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (RD + ".Session", "SessionId")), "(v)")
call(RD, session, RD + ".Session", "Start")
result, fd_list = call(RD, session, RD + ".Session", "ConnectToEIS", GLib.Variant("(a{sv})", ({},)), "(h)", fds=True)
for fd in fd_list.steal_fds():
    import os

    os.close(fd)
call(RD, session, RD + ".Session", "Stop")
call("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig", "GetCurrentState")
print("reference client: done", file=sys.stderr)
