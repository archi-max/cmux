#!/bin/bash
# Machine-state fixtures (phase 0): builds prog/ for each core, simulates it, and writes the dump,
# the ELF, and Spike's --log-commits of the same ELF (the oracle) to fixtures/<core>/.
#   build-fixtures.sh [core...]      cores: nerv picorv32 ibex (default: all)
# Needs: Homebrew llvm (clang, lld, llvm-readelf, llvm-objcopy), iverilog, verilator; Spike on
# $SPIKE_HOST (default ews-01, /class/ece411/riscv/bin). Upstream cores are read from $THIRD_PARTY
# (pinned commits in fixtures/<core>/NOTICE); they are never copied into the repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
THIRD_PARTY="${THIRD_PARTY:-$HERE/../../../../third-party-ref/machine}"
WORK="${WORK:-/tmp/ansht2-vv/machine}"
SPIKE_HOST="${SPIKE_HOST:-ews-01}"
SPIKE_DIR="${SPIKE_DIR:-/class/ece411/riscv/bin}"
LLVM="${LLVM:-/opt/homebrew/opt/llvm/bin}"
mkdir -p "$WORK"
cores=("$@"); [ ${#cores[@]} -gt 0 ] || cores=(nerv picorv32 ibex)

elf() {  # elf <out> <march> <defines...>
  local out="$1" march="$2"; shift 2
  "$LLVM/clang" --target=riscv32-unknown-elf -march="$march" -mabi=ilp32 -O1 "$@" -ffreestanding -nostdlib \
    -fno-builtin -fuse-ld=lld -Wl,-T,"$HERE/prog/link.ld" -o "$out" "$HERE/prog/start.S" "$HERE/prog/main.c"
}
tohost() { "$LLVM/llvm-nm" "$1" | awk '/ [Dd] tohost$/{print $1}'; }
spike() {  # spike <elf> <isa> <log>
  ssh "$SPIKE_HOST" "mkdir -p /tmp/ansht2-vv/machine" 2>/dev/null
  scp -q "$1" "$SPIKE_HOST:/tmp/ansht2-vv/machine/$(basename "$1")"
  ssh "$SPIKE_HOST" "cd /tmp/ansht2-vv/machine && PATH=$SPIKE_DIR:\$PATH nice spike --isa=$2 -m0x80000000:0x10000 --log-commits $(basename "$1") 2>&1 >/dev/null" 2>/dev/null |
    # Spike notices tohost only every few thousand steps: keep 64 turns of the final self-loop.
    awk '{ if ($4 == last) { if (++rep > 63) next } else { rep = 0 }; last = $4; print }' > "$3"
}

for core in "${cores[@]}"; do
  W="$WORK/$core"; F="$HERE/fixtures/$core"; mkdir -p "$W" "$F"
  case "$core" in
    nerv) isa=rv32i_zicsr; elf "$W/prog.elf" "$isa" -DWITH_CSR ;;
    *) isa=rv32imc; elf "$W/prog.elf" "$isa" -DWITH_M ;;
  esac
  python3 "$HERE/mkhex.py" "$LLVM/llvm-readelf" "$W/prog.elf" "$W/prog.hex"
  T="-DTOHOST=32'h$(tohost "$W/prog.elf")"
  case "$core" in
    nerv)
      (cd "$W" && nice iverilog -g2012 -DNERV_RVFI "$T" -o sim "$HERE/cores/nerv_tb.sv" "$THIRD_PARTY/riscv-formal/cores/nerv/nerv.sv" 2>&1 | grep -v sorry || true; nice vvp -N sim) ;;
    picorv32)
      (cd "$W" && nice iverilog -g2012 -DRISCV_FORMAL -DCOMPRESSED=1 -DMULDIV=1 "$T" -o sim "$HERE/cores/picorv32_tb.v" "$THIRD_PARTY/picorv32/picorv32.v" && nice vvp -N sim) ;;
    ibex)
      "$HERE/cores/build-ibex.sh" "$THIRD_PARTY/ibex" "$W" "$T"
      mv "$W/ibex.vcd" "$W/ibex-all.vcd"
      python3 "$HERE/vcd-keep.py" "$W/ibex-all.vcd" "$W/ibex.vcd" 'tb\.(clk_i|rst_ni)' \
        'tb\.dut\.rvfi_(valid|order|insn|trap|halt|intr|mode|ixl|rs[12]_(addr|rdata)|rd_(addr|wdata)|pc_[rw]data|mem_(addr|[rw]mask|[rw]data))' ;;
  esac
  cp "$W/$core.vcd" "$W/prog.elf" "$F/"
  spike "$W/prog.elf" "$isa" "$F/spike.log"
  echo "$core: $(grep -c . "$F/spike.log") spike commits, dump $(du -h "$F/$core.vcd" | cut -f1)"
done
