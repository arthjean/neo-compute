#!/bin/sh
# Records the D-Bus golden messages of US-078 in a gnome test session:
#   zig build session -- gnome exec -- sh tests/linux/golden/dbus/capture.sh
# dbus-monitor --binary writes each message as the bus delivered it;
# split.py keeps those the reference client sent and received.
set -e
dir=tests/linux/golden/dbus
raw="$XDG_RUNTIME_DIR/dbus-capture.bin"
dbus-monitor --session --binary > "$raw" &
mon=$!
sleep 0.5
python3 -I "$dir/reference_client.py"
sleep 0.3
kill "$mon"
wait "$mon" || true
python3 -I "$dir/split.py" "$raw" "$dir/mutter-remote-desktop.bin"
rm -f "$raw"
