#!/usr/bin/env python3
"""Machine-state fixtures (our own): an ELF's PT_LOAD bytes as $readmemh words for a 64 KiB window
at 0x80000000. Reads the segment table with the toolchain's readelf (not parsed here)."""
import re, subprocess, sys
readelf, elf, out = sys.argv[1:4]
words = {}
data = open(elf, 'rb').read()
for line in subprocess.check_output([readelf, '-lW', elf], text=True).splitlines():
    m = re.match(r'\s*LOAD\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)', line)
    if not m: continue
    off, vaddr, _, filesz, _ = (int(x, 16) for x in m.groups())
    for i in range(filesz):
        a = vaddr + i - 0x80000000
        words.setdefault(a >> 2, [0, 0, 0, 0])[a & 3] = data[off + i]
with open(out, 'w') as f:
    for w in sorted(words):
        b = words[w]
        f.write('@%x %02x%02x%02x%02x\n' % (w, b[3], b[2], b[1], b[0]))
