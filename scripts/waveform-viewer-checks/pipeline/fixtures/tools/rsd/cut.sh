#!/bin/bash
# cut.sh <rsd Src dir with simx.vcd> <fixture-dir>: cut RSD's simx.vcd to the fixture.
set -euo pipefail
T="$(cd "$(dirname "$0")/.." && pwd)"; S="$1"; F="$2"
C='TOP\.Main_Zynq_Wrapper\.main\.core'
python3 -I "$T/vcdtool.py" cut "$S/simx.vcd" "$F/rsd.vcd" --clock TOP.clk_p --reset TOP.posResetOut --reset-active 1 \
 --pre 3 --cycles 600 \
 --keep '^TOP\.(clk_p|negResetIn|posResetOut|ledOut)$' \
 --keep "^$C\\.debugIF\\.(?!debugRegister$|perfCounter$)[^.]+\$" \
 --keep "^$C\\.cmStage\\.[^.]+\$" \
 --keep "^$C\\.(activeList\\.(headPtr|tailPtr|count)|recoveryManager\\.(phase|toRecoveryPhase|recoveryFromRwStage|recoveryFromCmStage|exceptionDetectedInCommitStage|flushIQ_Entry\\[[0-9]+\\]))\$" \
 > "$S/cut-info.json"
cat "$S/cut-info.json"
