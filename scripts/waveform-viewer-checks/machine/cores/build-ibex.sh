#!/bin/bash
# build-ibex.sh <ibex checkout> <work dir> <-DTOHOST=...>: Verilator --binary of ibex_tb.sv, run in <work dir>.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
I="$1"; W="$2"; T="$3"
P="$I/vendor/lowrisc_ip/ip/prim/rtl"; G="$I/vendor/lowrisc_ip/ip/prim_generic/rtl"
pkgs=("$P/prim_util_pkg.sv" "$P/prim_mubi_pkg.sv" "$P/prim_secded_pkg.sv" "$P/prim_count_pkg.sv" "$P/prim_cipher_pkg.sv" "$G/prim_ram_1p_pkg.sv"
  "$I/rtl/ibex_pkg.sv" "$I/rtl/ibex_cheriot_pkg.sv")
cd "$W"
nice verilator --binary --timing --trace -j 4 -O1 -Wno-fatal -Wno-lint -Wno-style -Wno-PINMISSING -Wno-UNOPTFLAT -DRVFI -DSYNTHESIS "$T" \
  --top-module tb -I"$P" -I"$I/vendor/lowrisc_ip/dv/sv/dv_utils" -I"$HERE" -y "$I/rtl" -y "$P" -y "$G" \
  "${pkgs[@]}" "$HERE/ibex_tb.sv" -Mdir obj_ibex -o ibex_sim > verilator.log 2>&1 || { tail -30 verilator.log; exit 1; }
nice ./obj_ibex/ibex_sim
