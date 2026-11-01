#!/usr/bin/env python3
"""Writes text-breakpoints.vcd (run.sh text-breakpoints), written for cmux's checks.

top.clk: period 10, posedges at 5, 15, ... 495 (cycle n at 10n - 5).
top.inst [31:0] (RISC-V words), registered except one change between edges:
  0: csrw mtvec,t1 (the dump's first value)   5: li a0,0      15: csrw mtvec,t1   25: lw a3,0(a1)
  35: li a0,0      52: csrw mtvec,t1 (lands on 55)          65: bnez t0,pc-4      75: li a0,0
  85: 32'hx
top.flag: 0, 1 at 31, 0 at 39 (high only at the 35 posedge).
top.msg [31:0]: "cmux" at 105, "abcd" at 205 (ASCII).
"""
import sys

CSRW, LI, LW, BNEZ = 0x30531073, 0x00000513, 0x0005a683, 0xfe029ee3
events = {}
def at(t, line):
    events.setdefault(t, []).append(line)

for n in range(1, 51):
    at(10 * n - 5, "1!")
    at(10 * n, "0!")
for t, v in [(5, LI), (15, CSRW), (25, LW), (35, LI), (52, CSRW), (65, BNEZ), (75, LI)]:
    at(t, f"b{v:032b} \"")
at(85, "bx \"")
at(31, "1#")
at(39, "0#")
for t, s in [(105, b"cmux"), (205, b"abcd")]:
    at(t, f"b{int.from_bytes(s, 'big'):032b} $")

out = ["$timescale 1ns $end", "$scope module top $end",
       "$var wire 1 ! clk $end", '$var wire 32 " inst [31:0] $end', "$var wire 1 # flag $end",
       "$var wire 32 $ msg [31:0] $end", "$upscope $end", "$enddefinitions $end",
       "#0", "$dumpvars", "0!", f'b{CSRW:032b} "', "0#", "b0 $", "$end"]
for t in sorted(events):
    out.append(f"#{t}")
    out += events[t]
out.append("#500")
open(sys.argv[1] + "/text-breakpoints.vcd", "w").write("\n".join(out) + "\n")
