"""Turns the strace dump of capture.sh into the bytes the reference client
sent (<name>-sent.bin) and received (<name>-received.bin), in order, and
<name>.chunks: one line per system call, `send <bytes>` or `recv <bytes>`,
so a test replays the compositor's side at the moments it answered.

  python3 -I split.py <dump.strace> <name>
"""

import re
import sys

sent, received = bytearray(), bytearray()
chunks = []
target = None
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("sendmsg("):
        target = sent
        chunks.append(["send", 0])
    elif line.startswith("recvmsg("):
        target = received
        chunks.append(["recv", 0])
    elif line.startswith(" | ") and target is not None:
        data = bytes.fromhex(line[10:58].replace(" ", ""))
        target.extend(data)
        chunks[-1][1] += len(data)
open(sys.argv[2] + ".chunks", "w").write("".join(f"{k} {n}\n" for k, n in chunks if n > 0))
open(sys.argv[2] + "-sent.bin", "wb").write(sent)
open(sys.argv[2] + "-received.bin", "wb").write(received)
print(f"{len(sent)} bytes sent, {len(received)} received")
