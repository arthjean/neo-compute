"""Keeps, of a dbus-monitor --binary recording, the messages the reference
client sent and received (sender or destination is its unique name, the
one that owns org.neocompute.Golden), and prints a summary of each.

  python3 -I split.py <recording.bin> <out.bin>
"""

import struct
import sys


def messages(data):
    off = 0
    while off < len(data):
        body_len, _, fields_len = struct.unpack_from("<III", data, off + 4)
        total = 16 + ((fields_len + 7) & ~7) + body_len
        yield data[off : off + total]
        off += total


def fields(m):
    out = {}
    p, end = 16, 16 + struct.unpack_from("<I", m, 12)[0]
    while p < end:
        p = (p + 7) & ~7
        code, sl = m[p], m[p + 1]
        sig = m[p + 2 : p + 2 + sl].decode()
        p += 2 + sl + 1
        if sig in ("s", "o"):
            p = (p + 3) & ~3
            n = struct.unpack_from("<I", m, p)[0]
            v = m[p + 4 : p + 4 + n].decode()
            p += 4 + n + 1
        elif sig == "g":
            n = m[p]
            v = m[p + 1 : p + 1 + n].decode()
            p += 1 + n + 1
        else:
            p = (p + 3) & ~3
            v = struct.unpack_from("<I", m, p)[0]
            p += 4
        out.setdefault("order", []).append(code)
        out[code] = v
    return out


def main():
    data = open(sys.argv[1], "rb").read()
    msgs = list(messages(data))
    client = None
    for m in msgs:
        f = fields(m)
        if f.get(3) == "RequestName" and b"org.neocompute.Golden" in m:
            client = f[7]
    kept = [m for m in msgs if client in (fields(m).get(7), fields(m).get(6))]
    with open(sys.argv[2], "wb") as out:
        for m in kept:
            out.write(m)
    for m in kept:
        f = fields(m)
        print(m[1], m[2], struct.unpack_from("<I", m, 8)[0], f["order"], f.get(3) or f.get(4) or "", len(m))


main()
