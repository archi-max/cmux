#!/bin/bash
# build.sh <VexRiscv.v> <workdir>: Verilate + run the VexRiscv fixture (writes <workdir>/vexriscv_full.vcd).
# VexRiscv.v comes from `sbt "runMain vexriscv.demo.FormalSimple"` (see ../../vexriscv/README.md).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; V="$1"; W="$2"; mkdir -p "$W"
"$here/../build-prog.sh" 0x0 "$W/vex"
cd "$W"
nice /opt/homebrew/bin/verilator --binary --timing -j 4 --trace --top-module tb -Wno-fatal -Wno-lint -Wno-style \
  "$V" "$here/tb_vex.sv" -o Vtb > verilate.log 2>&1 || { tail -30 verilate.log; exit 1; }
nice ./obj_dir/Vtb +prog=vex.hex +cycles=1200
