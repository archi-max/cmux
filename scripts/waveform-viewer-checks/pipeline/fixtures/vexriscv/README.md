# VexRiscv pipeline-view fixture

- Upstream: https://github.com/SpinalHDL/VexRiscv, commit `baf7dc82f855eddaf5b0a20a6802c526f127e38a`
  (2026-09-24). Licence: MIT (`LICENSE` at that commit, copied here). This fixture holds only a
  waveform of a simulation of Verilog generated from it.
- Core config: the repo's `src/main/scala/vexriscv/demo/FormalSimple.scala`, unmodified: 5 stages
  (decode, execute, memory, writeBack, plus the IBusSimplePlugin fetch), `FormalPlugin` (RVFI port),
  `HazardSimplePlugin` with **all bypasses off** (so every RAW hazard stalls in decode), branches
  resolved in memory (`earlyBranch = false`), `DYNAMIC_TARGET` prediction, RVC enabled,
  `HaltOnExceptionPlugin`. No pregenerated Verilog for it exists in the repo, so `VexRiscv.v` was
  generated with sbt (SpinalHDL 1.13.0), see Regenerate. Generated `VexRiscv.v`: 225 982 bytes,
  sha256 `b9ccbda22e999165e63e07de8c8573de8d6bbe76005fe6bebe662e69648dffcc`.
- Testbench: `../tools/vexriscv/tb_vex.sv` (ours): 64 KiB RAM at 0, iBus/dBus commands always ready,
  responses one cycle after the command. Reset vector 0.
- Program: `../tools/pipetest.S` linked at 0 (data at 0x800); the shadow `addi` at 0x54 must never
  commit; `j .` at 0x6c.

## Files

| File | Size | What |
|---|---|---|
| `vexriscv.vcd` | 438 KB | 600 cycles, 137 signals: `tb.clk`, `tb.reset`, `tb.cpu.{clk,reset}`, all `rvfi_*`, the iBus/dBus ports, every `{decode,execute,memory,writeBack}_arbitration_*`, `*_PC`, `*_INSTRUCTION`, `*_FORMAL_INSTRUCTION`, the IBusSimplePlugin fetch/rsp/injector signals, `BranchPlugin_jumpInterface_*`, `HazardSimplePlugin_*` |
| `pipeline.json` | | config |
| `expected.json` | 20 KB | 156 RVFI commits (rvfi_order 0..155, contiguous) |

- Clock `tb.clk`, period **10 ns = 10000 ticks** (`$timescale 1ps`); edge 0 of the cut at t=5000.
- Cut: edges 2..602 of the full run (shift -20000 ps). `reset` (active high, synchronous) falls 1 ps
  after cut edge 2: high in cycles 0..1, low from **cycle 2**. First commit (pc 0, order 0) at
  cycle 8. The `j .` at 0x6c commits from cycle 365 every 4th cycle (2 x 2-cycle redirect).
- Cycle rule: cycle k = [posedge_k, posedge_{k+1}) of `tb.clk`, values sampled just before
  posedge_{k+1} (same as expected.json's `cycleRule`).

## Config: stages and what their signals mean

Scope `tb.cpu`, clock `clk`, reset `reset` (active 1).

| Stage | valid | pc / inst | "stays this cycle" (stall) | "squashed this cycle" (flush) |
|---|---|---|---|---|
| F | `IBusSimplePlugin_iBusRsp_output_valid` (fetch response offered to decode) | `IBusSimplePlugin_iBusRsp_output_payload_pc` / `..._payload_rsp_inst` | `!IBusSimplePlugin_iBusRsp_output_ready` | `IBusSimplePlugin_iBusRsp_flush` |
| D | `decode_arbitration_isValid` | `decode_PC` / `decode_INSTRUCTION` | `decode_arbitration_isStuck` (= haltItself, i.e. the hazard, or stuck by a later stage) | `decode_arbitration_removeIt` (includes `isFlushed`) |
| E | `execute_arbitration_isValid` | `execute_PC` / `execute_INSTRUCTION` | `execute_arbitration_isStuck` | `execute_arbitration_removeIt` |
| M | `memory_arbitration_isValid` | `memory_PC` / `memory_INSTRUCTION` | `memory_arbitration_isStuck` | `memory_arbitration_removeIt` |
| W | `writeBack_arbitration_isValid` | `writeBack_PC` / `writeBack_INSTRUCTION` | `writeBack_arbitration_isStuck` | `writeBack_arbitration_removeIt` |
| commit | `rvfi_valid`, tag `rvfi_order`, `rvfi_pc_rdata`, `rvfi_insn`, `rvfi_trap` | | | |

SpinalHDL semantics: a stage advances when `isValid && !isStuck && !removeIt` (`isMoving` /
`isFiring`); `removeIt` wins over `isStuck` (the instruction is dropped even if stuck).
`*_arbitration_flushIt` is constant 0 in this config; flushes come through `flushNext` of a later
stage, which shows up as `removeIt`/`isFlushed` on the earlier stages.

`../tools/checkcfg.py pipeline.json vexriscv.vcd expected.json --table 20:75` (S = stall, F = flush):

```
cycle F           D           E           M           W           commit
   27 2cS         28S         24          20          1c          001c#7    <- add (0x28) waits for lw (0x24): no bypass
   31 2c          28          .           .           .
   49 44          40          3c          .           .
   50 48F         44F         40F         3c          .                     <- bnez 0x3c taken, resolved in M
   51 .           .           .           .           3c          003c#15
   52 38          .           .           .           .
```

Counts over the 600 cycles: F valid 581 / stall 189 / flush 78; D 502 / 189 / 78; E 234 / 0 / 77;
M 156; W 156. Commit latency (`checkcfg.py`): every commit is on the cycle its instruction is in W
and leaving it (`{0: 156}`).

## Doubts / things that do not map cleanly

1. **The commit is in the same cycle as W** (`rvfi_valid` = writeBack firing), unlike Ibex (+1).
2. **F is a stream, not a register stage.** `iBusRsp_output_valid` is the iBus response for the
   oldest outstanding fetch; while a response is pending, the pc being fetched is not visible as a
   valid F entry. `IBusSimplePlugin_fetchPc_pcReg` / `iBus_cmd_*` show the request side.
   F→D takes one cycle through the injector register (`IBusSimplePlugin_injector_decodeInput_*`).
3. `decode_PC` comes from `IBusSimplePlugin_decodePc_pcReg`; fine here, but with RVC the decode pc
   and the F pc can differ by 2 for a split 32-bit instruction (not exercised: `-march=rv32i`).
4. E/M/W never stall in this run (1-cycle memory; no multi-cycle units in this config), so stall
   coverage is decode-only; flushes only from taken branches (and the `j .`).
5. `rvfi_order` starts at 0 (Ibex starts at 1).

## Regenerate

```sh
T=../tools; VEX=<VexRiscv checkout at baf7dc82f855eddaf5b0a20a6802c526f127e38a>
W=/tmp/pipe-fixtures
$T/vexriscv/gen-verilog.sh "$VEX" "$W"          # sbt (launcher 1.10.7, caches under $W), JDK 21:
                                                 #   sbt -batch "runMain vexriscv.demo.FormalSimple"
$T/vexriscv/build.sh "$W/VexRiscv/VexRiscv.v" "$W/vexsim"
                                                 # pipetest.S at 0; verilator --binary --timing -j 4 --trace
                                                 #   --top-module tb -Wno-fatal -Wno-lint -Wno-style; 1200 cycles
$T/vexriscv/cut.sh "$W/vexsim" .                 # vcdtool.py cut (pre 3, 600 cycles) + vcdtool.py commits
python3 -I $T/checkcfg.py pipeline.json vexriscv.vcd expected.json
rm -rf "$W"
```
