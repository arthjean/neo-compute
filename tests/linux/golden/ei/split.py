"""Keeps, of the strace dump of capture.sh, the bytes sent and received on
the EI descriptor the reference client printed: <name>-sent.bin,
<name>-received.bin and <name>.chunks (`send <bytes>` or `recv <bytes>` per
system call, in order).

  python3 -I split.py <dump.strace> <fd> <name>
"""

import re
import sys

fd = sys.argv[2]
sent, received = bytearray(), bytearray()
chunks = []
target = None
call = re.compile(r"^(?:\d+ )?(sendmsg|recvmsg|sendto|recvfrom|write|read|writev|readv)\((\d+),")
for line in open(sys.argv[1], encoding="utf-8"):
    m = call.match(line)
    if m:
        target = None
        if m.group(2) == fd:
            kind = "send" if m.group(1) in ("sendmsg", "sendto", "write", "writev") else "recv"
            target = sent if kind == "send" else received
            chunks.append([kind, 0, line.count("SCM_RIGHTS") and len(re.findall(r"cmsg_data=\[([^\]]*)\]", line)[0].split(","))])
        continue
    if line.lstrip("0123456789 ").startswith("| ") and target is not None:
        body = line[line.index("|") + 2 :]
        data = bytes.fromhex(body[7:55].replace(" ", ""))
        target.extend(data)
        chunks[-1][1] += len(data)
    elif not line.lstrip("0123456789 ").startswith(("|", "*")):
        target = None
open(sys.argv[3] + ".chunks", "w").write("".join(f"{k} {n} {f}\n" for k, n, f in chunks if n > 0))
open(sys.argv[3] + "-sent.bin", "wb").write(sent)
open(sys.argv[3] + "-received.bin", "wb").write(received)
print(f"{len(sent)} bytes sent, {len(received)} received")
