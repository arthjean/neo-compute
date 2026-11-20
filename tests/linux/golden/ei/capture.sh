#!/bin/sh
# Records the EI golden conversation of US-080 in a gnome test session:
#   zig build session -- gnome exec -- sh tests/linux/golden/ei/capture.sh
set -e
dir=tests/linux/golden/ei
dump="$XDG_RUNTIME_DIR/nc-ei.strace"
fd=$(strace -qq -f -e trace=sendmsg,recvmsg,sendto,recvfrom,write,read,writev,readv -e write=all -e read=all -xx -s 65536 -o "$dump" python3 -I "$dir/reference_client.py")
python3 -I "$dir/split.py" "$dump" "$fd" "$dir/mutter"
rm -f "$dump"
