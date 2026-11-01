# RSD pipeline-view fixture (out-of-order, 2-wide)

- Upstream: https://github.com/rsd-devel/rsd, commit `7b65f6ba0bce58d4d859082660123b7100aae975`
  (2024-07-27). Licence: Apache-2.0 (`LICENSE` at that commit, copied here). Only a waveform and
  RSD's own Kanata log of one simulation are included, no RSD source.
- Core config: RSD's default Verilator configuration (`Makefiles/CoreSources.inc.mk`:
  `RSD_MARCH_INT_ISSUE_WIDTH=2`, `RSD_MARCH_FP_PIPE`, `RSD_ENABLE_ZBA`, `RSD_ENABLE_ZICOND`;
  fetch/decode/rename/dispatch/commit width 2; 16-entry issue queue; int x2, complex x1, mem x2
  (load + store), fp x1 back-end lanes), top `Main_Zynq_Wrapper`, its own C++ testbench
  (`SysDeps/Verilator/TestMain.cpp`).
- Two local changes to the /tmp copy, needed for Verilator 5.052 (RSD targets older Verilator):
  `../tools/rsd/icache-verilator5.patch` (`$onehot0(we)` on an unpacked array in an assertion ->
  `$onehot0({we[1], we[0]})`), and `-Wno-MULTIDRIVEN` added to `VERILATOR_DISABLED_WARNING`.
  Also, macOS `mkdir` rejects the Makefile's `mkdir <dir> -p`, so the obj_dir is created first.
- Program: `../tools/pipetest.S` assembled at RSD's reset vector 0x1000 (ROM) with the data at
  0x80000000 (RAM) (`-DDATA_ABS`, so the prologue is one `lui` instead of auipc/li/add). The
  shadow `addi` at 0x1048 must never commit; `j .` at 0x1060. `ENABLE_PC_GOAL=0`, 700 cycles.

## Files

| File | Size | What |
|---|---|---|
| `rsd.vcd` | 546 KB | 600 cycles, 129 signals: `TOP.clk_p`, `TOP.negResetIn`, `TOP.posResetOut`, `TOP.ledOut`, every signal directly in `core.debugIF` (all per-stage debug registers `npReg[i]`..`cmReg[i]`, `scheduler[i]`, `issueQueue[i]`, the `*StagePipeCtrl` {stall, clear}, `stallByDecodeStage`, `recover`, ...; not the 2930-bit `debugRegister` bundle), every signal directly in `core.cmStage` (`commit[i]`, `alReadData[i]`, ...), `activeList.{headPtr,tailPtr,count}` |
| `pipeline.json` | 39 KB | config, including generated `layouts` for 84 flat struct signals |
| `expected.json` | 55 KB | 316 commits (from `cmStage`), with the Kanata alignment |
| `kanata.log` | 273 KB | RSD's own Kanata log for the same run (`make dump` → `KanataConverter.py`), cut to the ops alive in the VCD's range |

`core` = `TOP.Main_Zynq_Wrapper.main.core`.

- Clock `TOP.clk_p`, period **16 ticks** (`$timescale 1ps` as written by Verilator's C++ tracer;
  TestMain's comment intends 8 ns half periods, i.e. 62.5 MHz, but the VCD says ps). Edge 0 at t=8.
- Cut: edges 10005..10605 of the full run (RSD's reset controller holds `posResetOut` for ~10000
  cycles; time shifted by -160088). `posResetOut` samples high in cycles 0..1 and low from
  **cycle 2**. First commits (0x1000, 0x1004, 2-wide) at cycle 25; the `j .` commits from cycle 373.
- Cycle rule: cycle k = [posedge_k, posedge_{k+1}) of `TOP.clk_p`, values sampled just before
  posedge_{k+1}.

## expected.json

Read straight from the commit stage: `cmStage.commit[i]` and `cmStage.alReadData[i]` (an
`ActiveListEntry`: `opId.sid` [61:52], `opId.mid` [51:50], `pc` [49:31], the 19-bit narrow PC; all
PCs here are in the ROM, so narrow pc == address). The instruction word is joined from the decode
debug register by OpId. Fields: `cycle`, `time`, `order`, `slot`, `sid`, `mid`, `pc`, `insn`,
`kanataRid`. **RSD has no order tag**: `order` is the commit sequence number in this VCD (slot 0
before slot 1 in a cycle). `sid` is the 10-bit hardware serial and wraps at 1024 (not within this
window: no micro-op splitting happens either, `mid` is always 0). 28 of the 316 commits use slot 1.

## Kanata log ↔ VCD cycle mapping

Measured by `../tools/rsd/rsd_commits.py`, over all 316 commits (each Kanata retire `R id rid 0`
matched to the VCD commit of the same op, via `I id gid 0` with gid = sid*4 + mid):

- **Stage cells: `vcdCycle = kanataCycle + 2`**. The op's `S id 0 Cm` line is at Kanata cycle
  `vcdCommitCycle - 2` for all 316 (histogram `{-2: 316}`). This is `logs[0].offset = 2` in the config.
- The `R` (retire) line is written one Kanata cycle after `Cm` starts, i.e. at `vcdCommitCycle - 1`
  (`{-1: 316}`). A tool that aligns on `R` lines instead of stage cells sees an offset of 1.
- Kanata cycles are absolute: the original log starts with `C= -1`; the cut log keeps the absolute
  numbering (`C= 0`, the first event of a kept op) and drops events at Kanata cycle >= 598.
  It has 416 `R` lines (315 retires in range, 101 flushes).
- Cause of the 2 cycles: RSD's `Debug` module registers `debugIF` into `debugRegister` (1 cycle), and
  the C++ dumper samples `debugRegister` after the edge, with `RSD_KANATA_CYCLE_DISPLACEMENT = -1`.
- Front-end cross-check (not shipped; per (cycle, stage) the set of valid sids in `debugIF.*Reg[i]`
  vs the ops Kanata shows in that stage, cycles 30..589, offset 2): Pd 369/379, Dc 356/370,
  Rn 352/359, Ds 324/331 agree; F only 274/560: the VCD's `ifReg[i].valid` includes wrong-path
  fetches that RSD's converter closes in the same cycle (most likely the `ifReg[i].flush` /
  `ifStagePipeCtrl.clear` ops, which `KanataConverter` writes as flushed); not chased further.

## Config: stages and what their signals mean

Mirrors RSD's own Kanata dumper (`Processor/Src/SysDeps/Verilator/Dumper.h`). Stage names are
the Kanata names from `KanataGenerator.py` (Np F Pd Dc Rn Ds Sc Is Rr X Ma Mt Rw Wc Cm); back-end
stages exist once per unit as `<name>:<unit>` (unit = int, cx, mem, fp). Tag everywhere = the OpId
sid. `PipeCtrl` is `{stall [1], clear [0]}`.

| Stage | kind | valid / fire | stays (stall) | squashed (flush) |
|---|---|---|---|---|
| Np (entry) | in order, `slots: 2` | `debugIF.npReg[$i].valid` (tag `.sid`) | `npStagePipeCtrl.stall` | `npStagePipeCtrl.clear` |
| F | in order, 2 | `ifReg[$i].valid` | `ifStagePipeCtrl.stall && !ifReg[$i].flush` | `ifStagePipeCtrl.clear \|\| ifReg[$i].flush` |
| Pd | in order, 2 | `pdReg[$i].valid` | `pdStagePipeCtrl.stall` | `pdStagePipeCtrl.clear` |
| Dc | in order, 2 | `idReg[$i].valid` (+ `pc`, `insn`) | `idStagePipeCtrl.stall && !stallByDecodeStage` | `idStagePipeCtrl.clear \|\| idReg[$i].flushed` |
| Rn | in order, 2 | `rnReg[$i].valid` | `rnStagePipeCtrl.stall` | `rnStagePipeCtrl.clear` |
| Ds | in order, 2 | `dsReg[$i].valid` | `dsStagePipeCtrl.stall` | `dsStagePipeCtrl.clear` |
| Sc | `pool`, 16 entries | `scheduler[$i].valid`, tag `issueQueue[$i].opId.sid` | `backEndPipeCtrl.stall` | `issueQueue[$i].flush` |
| Is/Rr/X/Rw:{int,cx,mem,fp}, Mt:mem, Ma:mem | `event`, slots = lanes | `<unit><Stage>Reg[$i].valid` | `backEndPipeCtrl.stall` | `<...>Reg[$i].flush` |
| commit | `nret: 2` | `cmStage.commit[$i]`, tag `cmStage.alReadData[$i].opId.sid`, pc `cmStage.alReadData[$i].pc` | | |

The `layouts` (field lsb/width for every flat struct signal) were generated from slang's
`--ast-json` of RSD's type packages with the simulation defines (`../tools/rsd/layouts.py`,
`mkconfig.py`), with each struct's total width taken from the VCD `$var`.

## Doubts / things that do not map cleanly

1. **Names with `[i]`.** Verilator dumps unpacked-array elements as separate signals named
   `ifReg[0]`, `commit[1]`, ... The config writes `debugIF.ifReg[$i].valid` and `cmStage.commit[$i]`;
   cmux-expr must treat `name[<n>]` as part of a dumped name when such a signal exists, before
   reading it as a bit select. `layouts` keys are the literal element names (`debugIF.ifReg[0]`).
2. **Schema fields beyond P1**: `slots`/`$i`, `kind: pool|event`, `entries`, `fire`, `commit.nret`
   come from design §3.5/§3.6; there is no field for the commit stage's own flush (`cmReg[i].flush`,
   Kanata's `Wc`) and none for RSD's narrow-PC conversion (`{pc[18], 13'b0, pc[17:0]}`; identity
   here because every PC is in the ROM).
3. **Several units feed one Kanata stage.** Kanata's `Is`, `Rr`, `X`, `Rw` merge int, complex,
   mem and fp lanes; the config has one stage per unit (`Is:int` ...). A Konata comparison must
   strip the `:<unit>` suffix. `Ma`/`Mt` exist only for mem.
4. **`complexExReg` and `fpExReg` are multi-cycle**: their `valid`/`flush` are vectors (one bit per
   sub-stage, 3 and 5) and `opId` an array; the config uses element 0 (`valid[0]`,
   `opId[11:2]` = element 0's sid). Not exercised (no mul/div/fp in the program).
5. **Stall is pipeline-wide**: RSD has one stall per front-end stage group and one
   `backEndPipeCtrl.stall` for the whole back end, not per op; "stays in the issue queue" is
   simply "still valid in `Sc`" (pool membership).
6. `sid` is the only identity tag and wraps at 1024; front-end ops are tagged from Np on, so the
   tracker's "entry at rename" handoff (§3.6) is not needed here: sid exists from fetch.
7. The cut keeps no `debugRegister` (2930 bits, changes every cycle, ~1.8 MB per 600 cycles).

## Regenerate

```sh
T=../tools; RSD=<rsd checkout at 7b65f6ba0bce58d4d859082660123b7100aae975>
$T/rsd/build.sh "$RSD" /tmp/pipe-fixtures/rsd .
#  = copy Processor/ to /tmp, apply icache-verilator5.patch, build-prog.sh 0x1000 -DDATA_ABS=0x80000000,
#    mkhex.py -> Verification/TestCode/Asm/PipeTest/code.hex,
#    make -f Makefile.verilator.mk all MAKEFLAGS=-j4 VERILATOR_DISABLED_WARNING="-Wno-WIDTH -Wno-INITIALDLY -Wno-UNOPTFLAT -Wno-MULTIDRIVEN"
#    make -f Makefile.verilator.mk dump TEST_CODE=Verification/TestCode/Asm/PipeTest MAX_TEST_CYCLES=700 ENABLE_PC_GOAL=0 SHOW_SERIAL_OUT=0
#    rsd/cut.sh (vcdtool.py cut, pre 3, 600 cycles), slang --ast-json of the type packages,
#    rsd_commits.py (expected.json + kanata.log), mkconfig.py (pipeline.json)
rm -rf /tmp/pipe-fixtures/rsd
```

Verified: a second run of `build.sh` from scratch reproduced all four files byte for byte.
Build ~21 s (`-j4`), simulation < 1 s, full VCD 43 MB (deleted).
