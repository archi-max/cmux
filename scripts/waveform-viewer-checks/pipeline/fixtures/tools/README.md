# Fixture tools (pipeline view)

Small, dependency-free scripts that build the core fixtures in `../<core>/`. Python runs with
`python3 -I`. Simulation work goes under `/tmp/pipe-fixtures/` and is deleted afterwards.

| Script | What |
|---|---|
| `pipetest.S` | The shared RV32I test program (loops, taken/not-taken branches, load-use, stores, a squashed shadow instruction, call/return, `j .`). `-DDATA_ABS=<addr>` puts the data at an absolute address. |
| `build-prog.sh <base> <out> [clang flags]` | Assembles `pipetest.S` with Homebrew LLVM (`clang --target=riscv32-unknown-elf -march=rv32i`, `ld.lld`, `llvm-objcopy`) into `.elf/.bin/.dis/.hex` (`$readmemh`, one word per line). |
| `vcdtool.py cut` | Keeps the signals matching `--keep` regexes and a window of clock cycles around reset release (`--pre`, `--cycles`); rebases time to the falling edge before the window's first posedge. |
| `vcdtool.py commits` | Commit/RVFI stream from a VCD as `expected.json` (the cycle rule is written into the file). |
| `checkcfg.py cfg vcd expected [--table A:B]` | Resolves every name in a (non-`$i`) `pipeline.json`, counts valid/stall/flush per stage, measures commit latency after the last stage, prints an occupancy table. |
| `ibex/` | `tb_ibex.sv`, `build.sh` (Verilator), `cut.sh`. |
| `vexriscv/` | `gen-verilog.sh` (sbt in /tmp, FormalSimple), `tb_vex.sv`, `build.sh`, `cut.sh`. |
| `rsd/` | `build.sh` (whole flow), `icache-verilator5.patch`, `mkhex.py` (RSD code.hex), `cut.sh`, `layouts.py` (packed-struct layouts from slang `--ast-json`), `rsd_commits.py` (commit stream + Kanata alignment + Kanata cut), `mkconfig.py` (RSD pipeline.json). |

Cycle rule used everywhere: cycle k = [posedge_k, posedge_{k+1}) of the clock, k 0-based from the
first posedge in the VCD; a signal's value in cycle k is its value just before posedge_{k+1}
(after all changes at earlier times; changes at the posedge's own timestamp belong to cycle k).
