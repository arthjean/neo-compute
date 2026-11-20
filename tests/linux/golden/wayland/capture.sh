#!/bin/sh
# Records the Wayland golden trace of US-079 in a gnome test session:
#   zig build session -- gnome exec -- sh tests/linux/golden/wayland/capture.sh <zig>
# WAYLAND_DEBUG=client gives the requests and events as libwayland sees
# them, strace the bytes it sent and received.
set -e
zig=${1:-zig}
dir=tests/linux/golden/wayland
bin="$XDG_RUNTIME_DIR/nc-wayland-reference"
"$zig" cc -O1 -o "$bin" "$dir/reference_client.c" -lwayland-client
WAYLAND_DEBUG=client strace -qq -e trace=sendmsg,recvmsg -e write=all -e read=all -xx -s 65536 -o "$XDG_RUNTIME_DIR/nc-wayland.strace" "$bin" 2> "$dir/gnome.trace"
python3 -I "$dir/split.py" "$XDG_RUNTIME_DIR/nc-wayland.strace" "$dir/gnome"
rm -f "$bin" "$XDG_RUNTIME_DIR/nc-wayland.strace"
