#!/bin/bash
# cut.sh <workdir> <fixture-dir>: cut ibex_full.vcd to the fixture and extract expected.json.
set -euo pipefail
T="$(cd "$(dirname "$0")/.." && pwd)"; W="$1"; F="$2"; C=tb.u_top.u_ibex_core
python3 -I "$T/vcdtool.py" cut "$W/ibex_full.vcd" "$F/ibex.vcd" --clock tb.clk --reset tb.rst_ni --reset-active 0 \
 --pre 3 --cycles 500 \
 --keep '^tb\.(clk|rst_ni|instr_[a-z_]+|data_[a-z_]+)$' --keep "^${C//./\\.}\.[^.]+\$" \
 --keep '\.if_stage_i\.(if_instr_valid|fetch_valid|fetch_ready|fetch_addr|if_instr_addr|if_instr_rdata|instr_new_id_q|instr_valid_id_q|if_id_pipe_reg_we|pc_set_i|instr_valid_clear_i|id_in_ready_i|nt_branch_mispredict_i|instr_rdata_id_o|instr_is_compressed_id_o)$' \
 --keep '\.id_stage_i\.(stall_[a-z_]+|flush_id|instr_executing|instr_done|instr_first_cycle|id_fsm_q|branch_set|jump_set|branch_taken|branch_in_dec|jump_in_dec|wb_exception|multicycle_done|en_wb_o|instr_id_done_o|controller_run|instr_valid_i|pc_id_i|instr_rdata_i)$' \
 --keep '\.id_stage_i\.g_[a-z_]+\.instr_kill$' \
 --keep '\.id_stage_i\.controller_i\.(ctrl_fsm_cs|flush_id_o|pc_set_o|instr_valid_clear_o|special_req|halt_if|retain_id)$' \
 --keep '\.wb_stage_i\.g_writeback_stage\.(wb_valid_q|wb_valid_d|wb_done|wb_pc_q|wb_instr_type_q)$' > "$W/cut-info.json"
cat "$W/cut-info.json"
python3 -I "$T/vcdtool.py" commits "$F/ibex.vcd" --clock tb.clk --valid $C.rvfi_valid --order $C.rvfi_order \
 --pc $C.rvfi_pc_rdata --insn $C.rvfi_insn --trap $C.rvfi_trap > "$F/expected.json"
