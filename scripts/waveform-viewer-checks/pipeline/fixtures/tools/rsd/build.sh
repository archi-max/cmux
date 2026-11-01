#!/bin/bash
# build.sh <rsd-checkout> <workdir> <fixture-dir>: RSD's own Verilator flow on a /tmp copy, then the cut.
# 1. copies Processor/ to <workdir>, applies icache-verilator5.patch (Verilator 5 rejects $onehot0 on an
#    unpacked array in an assertion), assembles pipetest.S at 0x1000 with data at 0x80000000 into
#    Verification/TestCode/Asm/PipeTest/code.hex (RSD's 128-bit-per-line ROM image)
# 2. `make -f Makefile.verilator.mk all` (+ -Wno-MULTIDRIVEN, which Verilator 5 now treats as fatal)
# 3. `make -f Makefile.verilator.mk dump` (simx.vcd + RSD.log + Kanata.log via its KanataConverter), 700 cycles
# 4. cut.sh (600 cycles), slang type dump, rsd_commits.py (expected.json + kanata.log), mkconfig.py
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; RSD="$1"; W="$2"; F="$3"
mkdir -p "$W" "$F"; rm -rf "$W/Processor"; cp -R "$RSD/Processor" "$W/"
cd "$W" && patch -p1 < "$here/icache-verilator5.patch"
"$here/../build-prog.sh" 0x1000 "$W/prog" -DDATA_ABS=0x80000000
S="$W/Processor/Src"; mkdir -p "$S/Verification/TestCode/Asm/PipeTest" "$W/Processor/Project/Verilator/obj_dir"
python3 -I "$here/mkhex.py" "$W/prog.bin" 0x1000 "$S/Verification/TestCode/Asm/PipeTest/code.hex"
cd "$S"
nice make -f Makefile.verilator.mk all MAKEFLAGS=-j4 \
  VERILATOR_DISABLED_WARNING="-Wno-WIDTH -Wno-INITIALDLY -Wno-UNOPTFLAT -Wno-MULTIDRIVEN" > "$W/build.log" 2>&1
nice make -f Makefile.verilator.mk dump TEST_CODE=Verification/TestCode/Asm/PipeTest MAX_TEST_CYCLES=700 \
  ENABLE_PC_GOAL=0 SHOW_SERIAL_OUT=0 > "$W/run.log" 2>&1
"$here/cut.sh" "$S" "$F"
TYPES=$(make -pn -f Makefile.verilator.mk all 2>/dev/null | grep "^TYPES = " | head -1 | sed "s/^TYPES = //")
nice slang -q $TYPES -DRSD_FUNCTIONAL_SIMULATION -DRSD_FUNCTIONAL_SIMULATION_VERILATOR -DRSD_MARCH_INT_ISSUE_WIDTH=2 \
  -DRSD_MARCH_FP_PIPE -DRSD_ENABLE_ZBA -DRSD_ENABLE_ZICOND -I. --ast-json "$W/types.json" --ast-json-detailed-types || true
python3 -I "$here/rsd_commits.py" "$F/rsd.vcd" "$S/Kanata.log" "$F/expected.json" "$F/kanata.log"
python3 -I "$here/mkconfig.py" "$W/types.json" "$F/rsd.vcd" > "$F/pipeline.json"
