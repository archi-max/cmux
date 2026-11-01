#!/bin/bash
# build-prog.sh <base-hex> <out-prefix> [extra clang flags, e.g. -DDATA_ABS=0x80000000]
# Assembles pipetest.S with Homebrew LLVM (no GCC needed) and writes
# <out-prefix>.elf, .bin, .dis and .hex (one 32-bit little-endian word per line,
# word 0 = address <base>, for $readmemh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
base="$1"; out="$2"; shift 2
LLVM=/opt/homebrew/opt/llvm/bin
$LLVM/clang --target=riscv32-unknown-elf -march=rv32i -mabi=ilp32 -nostdlib "$@" -c "$here/pipetest.S" -o "$out.o"
/opt/homebrew/bin/ld.lld --image-base=0 -Ttext="$base" -e _start -o "$out.elf" "$out.o"
$LLVM/llvm-objcopy -O binary "$out.elf" "$out.bin"
$LLVM/llvm-objdump -d "$out.elf" > "$out.dis"
python3 -I -c '
import sys,struct
b=open(sys.argv[1],"rb").read(); b+=b"\0"*((-len(b))%4)
print("\n".join("%08x"%w for w in struct.unpack("<%dI"%(len(b)//4),b)))' "$out.bin" > "$out.hex"
