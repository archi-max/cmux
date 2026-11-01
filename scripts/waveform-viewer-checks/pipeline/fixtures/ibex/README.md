# Ibex pipeline-view fixture

- Upstream: https://github.com/lowRISC/ibex, commit `f4515520c0045bb8ef1e72d46ed82499a6ac5f18`
  (2026-10-29). Licence: Apache-2.0 (`LICENSE` at that commit, copied here). The RTL itself is not
  copied; only this simulation's waveform is. Upstream's NOTICE: "This product includes hardware
  and/or software developed as part of the Ibex(R) (https://github.com/lowRISC/ibex) and
  OpenTitan(R) projects."
- Core config: `ibex_top` with `WritebackStage=1` (3 stages: IF, ID/EX, WB), RV32IMC defaults
  (`RV32MFast`), no icache, no PMP, CHERIoT off (`cheriot_enable_i = IbexMuBiOff`), `RVFI` defined.
- Testbench: `../tools/ibex/tb_ibex.sv` (ours): 64 KiB RAM at 0, grant in the request cycle,
  rvalid one cycle later, `boot_addr = 0`, so the first fetch is 0x80.
- Program: `../tools/pipetest.S`, linked at 0x80 (data at 0x880). Counted loops (taken / not-taken
  backward branches), load-use (`lw t2` then `add t3,t2,..`), stores, a not-taken and a taken
  forward branch whose shadow `addi` at 0xd4 must never commit, `jal`/`ret`, then `j .` at 0xec.

## Files

| File | Size | What |
|---|---|---|
| `ibex.vcd` | 665 KB | 500 cycles, 707 signals: `tb.clk`, `tb.rst_ni`, the memory ports, every signal directly in `tb.u_top.u_ibex_core` (incl. all `rvfi_*` and `rvfi_stage_*[0..1]`), and selected IF/ID/WB/controller internals |
| `pipeline.json` | | config (schema of status/pipeline-view.md) |
| `expected.json` | 34 KB | 272 RVFI commits (orders 1..272, contiguous) |

- Clock: `tb.clk`, period **10 ns = 10000 ticks** (`$timescale 1ps`). Edge 0 of the cut is at t=5000.
- Cut: edges 2..502 of the full run (time shifted by -20000 ps). `rst_ni` rises 1 ps after cut
  edge 2, so it samples low in cycles 0..1 and high from **cycle 2, the first cycle out of reset**. First
  commit (pc 0x80, order 1) at cycle 8; the `j .` loop (pc 0xec) commits from cycle 151 every 2nd
  cycle to the end.
- Cycle rule (also in expected.json): cycle k = [posedge_k, posedge_{k+1}) of `tb.clk`, k 0-based
  from the first posedge in the VCD; values sampled just before posedge_{k+1}.

## Config: stages and what their signals mean

Scope `tb.u_top.u_ibex_core`. Clock is the absolute `tb.clk` (see doubts).

| Stage | valid | pc / inst | "stays this cycle" (stall) | "squashed this cycle" (flush) |
|---|---|---|---|---|
| IF | `if_stage_i.if_instr_valid` (head of the prefetch FIFO, offered to ID) | `pc_if` / `if_stage_i.if_instr_rdata` | `!id_in_ready` (ID won't take it) | `pc_set` (a branch/jump/exception redirects; IF→ID is `if_instr_valid & id_in_ready & ~pc_set`) |
| ID (ID/EX) | `instr_valid_id` | `pc_id` / `instr_rdata_id` | `!instr_id_done` (= `!(en_wb & ready_wb)`; covers `stall_id` = ld-hazard/mem/multdiv/branch/jump and `stall_wb`) | `id_stage_i.flush_id` (controller flush: exceptions, CSR side effects, mret...). Never true in this run |
| WB | `wb_stage_i.g_writeback_stage.wb_valid_q` | `pc_wb` / (no instruction word in WB) | `!wb_stage_i.g_writeback_stage.wb_done` (load waiting for its response). Never true in this run (1-cycle memory) | none |
| commit | `rvfi_valid`, tag `rvfi_order`, `rvfi_pc_rdata`, `rvfi_insn`, `rvfi_trap` | | | |

`../tools/checkcfg.py pipeline.json ibex.vcd expected.json --table 14:40` prints the per-cycle
occupancy (S = stall, F = flush). Excerpt (load-use, then the taken `bnez` at 0xbc):

```
cycle IF          ID          WB          commit
   15 a8          a4          a0          009c#8
   16 acS         a8S         a4          00a0#9      <- add waits for the lw in WB (stall_ld_hz)
   17 ac          a8          .           00a4#10
   22 c0S         bcS         b8          00b4#14     <- bnez: 2 cycles in ID (stall_branch)
   23 c0F         bc          .           00b8#15     <- pc_set squashes c0 in IF
   24 b8          .           bc
```

Counts over the 500 cycles: IF valid 495 / stall 25 / flush 196; ID valid 476 / stall 203; WB valid 272.

## Doubts / things that do not map cleanly

1. **Commit trails WB by exactly one cycle.** RVFI with the writeback stage is registered
   (`rvfi_stage_*[1]`): an instruction leaving WB in cycle c appears on `rvfi_valid` in cycle c+1
   (checked: all 272 commits, `checkcfg.py` latency histogram `{1: 272}`). The tracker's "retire
   on the commit cycle" rule needs a commit delay (e.g. a `commit.delay: 1` option), or the match
   must allow the commit one cycle after the record left the last stage.
2. **`clk_i` inside the core is gated** (`prim_clock_gating` in `ibex_top`) and has no edges while
   reset is active (497 edges vs 501). The config uses `tb.clk` so the cycle numbering matches
   expected.json.
3. **IF is only the FIFO head.** Ibex's prefetch buffer holds several fetched words; only the one at
   the head (`if_instr_valid`, `pc_if`) is visible as "in IF". Requests in flight are not
   instructions yet. `pc_if` is also driven while `if_instr_valid` is 0.
4. **Flush beats stall in IF**: cycles with `!id_in_ready && pc_set` drop the IF instruction.
   The tracker must evaluate flush before stall.
5. `pc_wb` holds a stale value when WB is empty (`wb_valid_q = 0`); valid must gate it.
6. No order tag per stage: the only tags are `rvfi_stage_order[0]`/`[1]` (dumped with `[i]` in the
   name, which clashes with the expression syntax's bit select). Identity is pc (+ adjacency).
7. Taken branches stay 2 cycles in ID (first cycle `stall_branch`, second `pc_set`), so a bubble
   follows in ID, not a squashed instruction; the squash happens in IF.
8. With a self loop (`j .` at 0xec), IF holds 0xec and then the wrong-path 0xf0 (flushed) every
   other cycle; consecutive records with the same pc never sit in adjacent stages for more than
   one cycle.

## Regenerate

```sh
T=../tools            # this directory's sibling
IBEX=<ibex checkout at f4515520c0045bb8ef1e72d46ed82499a6ac5f18>
W=/tmp/pipe-fixtures/ibex
$T/ibex/build.sh "$IBEX" "$W"   # assembles pipetest.S (Homebrew LLVM clang/ld.lld), Verilator 5.052
                                # --binary --timing --trace -DRVFI=1 -j 4, runs 1200 cycles after reset
$T/ibex/cut.sh "$W" .           # vcdtool.py cut (pre 3, 500 cycles) + vcdtool.py commits
python3 -I $T/checkcfg.py pipeline.json ibex.vcd expected.json
rm -rf "$W"
```

Verilator flags (from `build.sh`): `--binary --timing -j 4 --trace -DRVFI=1 --top-module tb -Wno-fatal
-Wno-lint -Wno-style -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-MULTIDRIVEN` plus the include dirs and file
list in the script (lowRISC prim_generic prims, pulp common cells, `rtl/*.sv`).
