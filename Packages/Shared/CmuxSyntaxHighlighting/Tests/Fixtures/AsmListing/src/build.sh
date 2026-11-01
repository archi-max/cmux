#!/bin/sh
# Regenerates the asm-listing fixtures (cmux tests). Needs Homebrew llvm (clang, llvm-objdump)
# and riscv64-elf-binutils. Usage: ./build.sh <out dir>   (the .dis files go to ..)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
B=${1:-/tmp/asmbp-build}
mkdir -p "$B"
CL=/opt/homebrew/opt/llvm/bin/clang
OD=riscv64-elf-objdump
LOD=/opt/homebrew/opt/llvm/bin/llvm-objdump
map="-fdebug-prefix-map=$here=/fixture/src -fdebug-compilation-dir=/fixture/src"
for v in 32 64; do
  if [ $v = 32 ]; then M=rv32imc_zicsr; A=ilp32; E=elf32lriscv; else M=rv64imac_zicsr; A=lp64; E=elf64lriscv; fi
  f="--target=riscv$v-unknown-elf -march=$M -mabi=$A -mcmodel=medany -gdwarf-4 $map"
  $CL $f -O1 -c "$here/sum.c" -o "$B/sum$v.o"
  $CL $f -c "$here/start.S" -o "$B/start$v.o"
  riscv64-elf-ld -m $E -T "$here/link.ld" "$B/start$v.o" "$B/sum$v.o" -o "$B/prog$v.elf"
  cd "$B"
  $OD -d prog$v.elf > "$here/../gnu-rv$v-code.dis"
  $OD -D prog$v.elf > "$here/../gnu-rv$v-all.dis"
  cd "$here/.."
done
cd "$B"
$OD -d -M numeric,no-aliases prog32.elf > "$here/../gnu-rv32-numeric-noaliases.dis"
$OD -S --prefix="$here" --prefix-strip=2 prog32.elf > "$here/../gnu-rv32-S.dis"
$OD -d -l prog32.elf > "$here/../gnu-rv32-l.dis"
$OD -d --no-show-raw-insn prog32.elf > "$here/../gnu-rv32-noraw.dis"
$OD -d --prefix-addresses prog32.elf > "$here/../gnu-rv32-prefix.dis"
$OD -d --prefix-addresses --show-raw-insn prog32.elf > "$here/../gnu-rv32-prefix-raw.dis"
$OD -d -z prog32.elf > "$here/../gnu-rv32-z.dis"
# binutils 2.43.1 and 2.47 print the whole of .text as .word with --visualize-jumps once it holds the
# zero gap; the ranged run stops before the gap and decodes normally. Both are kept.
$OD -d --visualize-jumps prog32.elf > "$here/../gnu-rv32-jumps.dis"
$OD -d --visualize-jumps --stop-address=0x8000002c prog32.elf > "$here/../gnu-rv32-jumps-start.dis"
$OD -d -r sum32.o > "$here/../gnu-rv32-reloc-obj.dis"
$OD -d -r start32.o > "$here/../gnu-rv32-reloc-start-obj.dis"
$LOD -d prog32.elf > "$here/../llvm-rv32-code.dis"
$LOD -d prog64.elf > "$here/../llvm-rv64-code.dis"
$LOD -D prog32.elf > "$here/../llvm-rv32-all.dis"
$LOD -d -l prog32.elf > "$here/../llvm-rv32-l.dis"
$LOD -d -S --prefix="$here" --prefix-strip=2 prog32.elf > "$here/../llvm-rv32-S.dis"
$LOD -d --no-show-raw-insn prog32.elf > "$here/../llvm-rv32-noraw.dis"
$LOD -d -M numeric -M no-aliases prog32.elf > "$here/../llvm-rv32-numeric-noaliases.dis"
$LOD -d -r sum32.o > "$here/../llvm-rv32-reloc-obj.dis"
# Paths in the outputs: the build dir is printed in headers; make it fixed.
cd "$here/.."
for f in *.dis; do sed -i '' "s#$B/##g" "$f"; done
