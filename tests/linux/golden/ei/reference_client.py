"""The reference EI client of the byte tests (US-080).

Run by capture.sh under strace inside a gnome test session: libei 1.6
(libei.so.1, through ctypes) opens a sender context on the descriptor
Mutter's RemoteDesktop session gives (ConnectToEIS), binds the pointer,
absolute pointer, button and keyboard capabilities, and once the absolute
pointer is resumed moves it to (100, 200) in one frame. Prints the
descriptor number on stdout so split.py keeps its bytes only.
"""

import ctypes
import os
import select
import sys
import time

from gi.repository import Gio, GLib

CONNECT, DISCONNECT, SEAT_ADDED, DEVICE_ADDED, DEVICE_RESUMED = 1, 2, 3, 5, 8
CAP_POINTER, CAP_POINTER_ABSOLUTE, CAP_KEYBOARD, CAP_BUTTON = 1, 2, 4, 32

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
RD = "org.gnome.Mutter.RemoteDesktop"
(session,) = bus.call_sync(RD, "/org/gnome/Mutter/RemoteDesktop", RD, "CreateSession", None, GLib.VariantType("(o)"), 0, 1000, None).unpack()
bus.call_sync(RD, session, RD + ".Session", "Start", None, None, 0, 1000, None)
result, fds = bus.call_with_unix_fd_list_sync(RD, session, RD + ".Session", "ConnectToEIS", GLib.Variant("(a{sv})", ({},)), GLib.VariantType("(h)"), 0, 1000, None, None)
fd = fds.steal_fds()[result.unpack()[0]]
print(fd, flush=True)

ei_lib = ctypes.CDLL("libei.so.1")
p = ctypes.c_void_p
for name, res, args in [
    ("ei_new_sender", p, [p]),
    ("ei_configure_name", None, [p, ctypes.c_char_p]),
    ("ei_setup_backend_fd", ctypes.c_int, [p, ctypes.c_int]),
    ("ei_get_fd", ctypes.c_int, [p]),
    ("ei_dispatch", None, [p]),
    ("ei_get_event", p, [p]),
    ("ei_event_get_type", ctypes.c_int, [p]),
    ("ei_event_get_seat", p, [p]),
    ("ei_event_get_device", p, [p]),
    ("ei_event_unref", p, [p]),
    ("ei_device_has_capability", ctypes.c_bool, [p, ctypes.c_int]),
    ("ei_device_start_emulating", None, [p, ctypes.c_uint32]),
    ("ei_device_stop_emulating", None, [p]),
    ("ei_device_pointer_motion_absolute", None, [p, ctypes.c_double, ctypes.c_double]),
    ("ei_device_frame", None, [p, ctypes.c_uint64]),
    ("ei_unref", p, [p]),
]:
    f = getattr(ei_lib, name)
    f.restype = res
    f.argtypes = args
bind = ei_lib.ei_seat_bind_capabilities
bind.restype = None

ei = ei_lib.ei_new_sender(None)
ei_lib.ei_configure_name(ei, b"neo-compute golden")
if ei_lib.ei_setup_backend_fd(ei, fd) != 0:
    sys.exit("ei_setup_backend_fd failed")
moved = False
deadline = time.monotonic() + 5
while not moved and time.monotonic() < deadline:
    select.select([ei_lib.ei_get_fd(ei)], [], [], 0.5)
    ei_lib.ei_dispatch(ei)
    while True:
        ev = ei_lib.ei_get_event(ei)
        if not ev:
            break
        kind = ei_lib.ei_event_get_type(ev)
        if kind == SEAT_ADDED:
            bind(p(ei_lib.ei_event_get_seat(ev)), ctypes.c_int(CAP_POINTER), ctypes.c_int(CAP_POINTER_ABSOLUTE), ctypes.c_int(CAP_BUTTON), ctypes.c_int(CAP_KEYBOARD), p(None))
        elif kind == DEVICE_RESUMED:
            dev = ei_lib.ei_event_get_device(ev)
            if ei_lib.ei_device_has_capability(dev, CAP_POINTER_ABSOLUTE):
                ei_lib.ei_device_start_emulating(dev, 1)
                ei_lib.ei_device_pointer_motion_absolute(dev, 100.0, 200.0)
                ei_lib.ei_device_frame(dev, 1000000)
                ei_lib.ei_device_stop_emulating(dev)
                moved = True
        elif kind == DISCONNECT:
            sys.exit("EIS disconnected")
        ei_lib.ei_event_unref(ev)
ei_lib.ei_dispatch(ei)
time.sleep(0.2)
ei_lib.ei_dispatch(ei)
ei_lib.ei_unref(ei)
bus.call_sync(RD, session, RD + ".Session", "Stop", None, None, 0, 1000, None)
print("reference client: moved" if moved else "reference client: no absolute pointer", file=sys.stderr)
sys.exit(0 if moved else 1)
