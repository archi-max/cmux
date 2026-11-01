#!/bin/bash
# cut.sh <workdir> <fixture-dir>: cut vexriscv_full.vcd to the fixture and extract expected.json.
set -euo pipefail
T="$(cd "$(dirname "$0")/.." && pwd)"; W="$1"; F="$2"; C=tb.cpu
P='(decode|execute|memory|writeBack)'
python3 -I "$T/vcdtool.py" cut "$W/vexriscv_full.vcd" "$F/vexriscv.vcd" --clock tb.clk --reset tb.reset --reset-active 1 \
 --pre 3 --cycles 600 \
 --keep '^tb\.(clk|reset)$' --keep '^tb\.cpu\.(clk|reset)$' --keep '^tb\.cpu\.rvfi_' \
 --keep '^tb\.cpu\.(iBus|dBus)_' \
 --keep "^tb\\.cpu\\.${P}_arbitration_[A-Za-z]+\$" \
 --keep "^tb\\.cpu\\.${P}_(PC|INSTRUCTION|FORMAL_INSTRUCTION|FormalPlugin_order)\$" \
 --keep '^tb\.cpu\.writeBack_FormalPlugin_' \
 --keep '^tb\.cpu\.IBusSimplePlugin_(iBusRsp_output_[A-Za-z_]+|iBusRsp_flush|externalFlush|fetchPc_pcReg|fetchPc_output_valid|fetchPc_output_payload|injector_decodeInput_(valid|ready|payload_pc|payload_rsp_inst)|decodePc_pcReg|pending_value)$' \
 --keep '^tb\.cpu\.(BranchPlugin_jumpInterface_(valid|payload)|HazardSimplePlugin_[A-Za-z_]+|execute_BRANCH_DO|memory_BRANCH_DO|execute_BranchPlugin_branch_src[12])$' \
 > "$W/cut-info.json"
cat "$W/cut-info.json"
python3 -I "$T/vcdtool.py" commits "$F/vexriscv.vcd" --clock tb.clk --valid $C.rvfi_valid --order $C.rvfi_order \
 --pc $C.rvfi_pc_rdata --insn $C.rvfi_insn --trap $C.rvfi_trap > "$F/expected.json"
