#!/usr/bin/env python3
"""mkhex.py <code.bin> <base> <out code.hex>: RSD's code.hex format (see its TestMain.cpp):
4096 lines (the 64 KiB ROM), each 128 bits = 4 little-endian 32-bit words printed word3..word0.
<code.bin> is placed at byte offset <base> (0x1000 = INSN_RESET_VECTOR); the rest is zero."""
import struct, sys
b = open(sys.argv[1], 'rb').read(); base = int(sys.argv[2], 0)
rom = bytearray(65536); rom[base:base + len(b)] = b
with open(sys.argv[3], 'w') as o:
    for i in range(0, 65536, 16):
        w = struct.unpack('<4I', rom[i:i + 16])
        o.write(''.join('%08x' % x for x in reversed(w)) + '\n')
