#!/usr/bin/env python3
"""Pack PNGs into a valid .icns container (dependency-free; for Linux builds
where iconutil is unavailable). ICNS = 'icns' + big-endian total length, then
entries of [4-byte OSType][big-endian length incl. 8-byte header][PNG bytes].

Usage: pack_icns.py OUT.icns TYPE=path.png [TYPE=path.png ...]
Modern PNG-based OSTypes: ic07=128 ic08=256 ic09=512 ic10=1024
ic11=32 ic12=64 ic13=256 ic14=512 (all PNG payloads; macOS picks what it needs)."""
import struct
import sys

out = sys.argv[1]
entries = []
for arg in sys.argv[2:]:
    ostype, path = arg.split("=", 1)
    assert len(ostype) == 4, f"OSType must be 4 chars: {ostype!r}"
    with open(path, "rb") as f:
        data = f.read()
    entries.append((ostype.encode("ascii"), data))

body = b"".join(t + struct.pack(">I", len(d) + 8) + d for t, d in entries)
with open(out, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print(f"wrote {out} ({len(entries)} entries, {len(body) + 8} bytes)")
