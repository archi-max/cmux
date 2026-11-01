#!/bin/bash
# build.sh <ibex-checkout> <workdir>: Verilate + run the Ibex fixture (writes <workdir>/ibex_full.vcd).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; IBEX="$1"; W="$2"; mkdir -p "$W"
L="$IBEX/vendor/lowrisc_ip/ip"
"$here/../build-prog.sh" 0x80 "$W/ibex"
files=(
 $L/prim_generic/rtl/prim_pkg.sv $L/prim/rtl/prim_assert.sv $L/prim/rtl/prim_util_pkg.sv
 $L/prim/rtl/prim_count_pkg.sv $L/prim/rtl/prim_count.sv $L/prim/rtl/prim_secded_pkg.sv
 $L/prim/rtl/prim_mubi_pkg.sv $L/prim_generic/rtl/prim_ram_1p_pkg.sv
 $L/prim/rtl/prim_ram_1p_adv.sv $L/prim/rtl/prim_ram_1p_scr.sv $L/prim_generic/rtl/prim_ram_1p.sv
 $L/prim_generic/rtl/prim_clock_gating.sv $L/prim_generic/rtl/prim_buf.sv $L/prim_generic/rtl/prim_clock_mux2.sv
 $L/prim_generic/rtl/prim_flop.sv $L/prim_generic/rtl/prim_and2.sv
 $L/prim/rtl/prim_cipher_pkg.sv $L/prim/rtl/prim_lfsr.sv $L/prim/rtl/prim_onehot_check.sv
 $L/prim/rtl/prim_secded_inv_39_32_enc.sv $L/prim/rtl/prim_secded_inv_39_32_dec.sv
 $L/prim/rtl/prim_fifo_sync_cnt.sv $L/prim/rtl/prim_fifo_sync.sv
 $IBEX/vendor/pulp_common_cells/rtl/stream_fork.sv $IBEX/vendor/pulp_common_cells/rtl/stream_join_dynamic.sv
)
for f in ibex_pkg ibex_cheriot_pkg ibex_cheriot_ex ibex_alu ibex_branch_predict ibex_compressed_decoder \
  ibex_controller ibex_csr ibex_cs_registers ibex_counter ibex_decoder ibex_dummy_instr ibex_ex_block \
  ibex_wb_stage ibex_id_stage ibex_icache ibex_if_stage ibex_load_store_unit ibex_lockstep ibex_multdiv_slow \
  ibex_multdiv_fast ibex_prefetch_buffer ibex_fetch_fifo ibex_register_file_ff ibex_register_file_fpga \
  ibex_register_file_latch ibex_pmp ibex_core ibex_trvk ibex_top; do files+=("$IBEX/rtl/$f.sv"); done
cd "$W"
nice /opt/homebrew/bin/verilator --binary --timing -j 4 --trace -DRVFI=1 --top-module tb \
  -Wno-fatal -Wno-lint -Wno-style -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
  +incdir+$L/prim/rtl +incdir+$IBEX/vendor/lowrisc_ip/dv/sv/dv_utils +incdir+$IBEX/rtl +incdir+$IBEX/vendor/pulp_common_cells/include \
  "${files[@]}" "$here/tb_ibex.sv" -o Vtb > verilate.log 2>&1 || { tail -30 verilate.log; exit 1; }
nice ./obj_dir/Vtb +prog=ibex.hex +cycles=1200
