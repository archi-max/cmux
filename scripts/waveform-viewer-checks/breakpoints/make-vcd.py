#!/usr/bin/env python3
"""Writes the breakpoint checks' dump (run.sh breakpoints): breakpoints.vcd.

top.clk: period 10, posedges at 5, 15, ... 995 (cycle n at 10n - 5).
top.state [3:0]: registered (changes on posedges): 3 from cycle 10, 5 from 20, 3 from 30, 0 from 40.
top.irq: pulses between edges: 1 at 52, 0 at 53 (both land on 55, cycle 6); 1 at 702, 0 at 707 (land on 705).
top.data [7:0]: x at 0, 'h00 at 25, 'ha5 at 305, x at 505, 'h5a at 605.
top.busy: 0 throughout (never changes).
"""
import sys

events = {}
def at(t, line):
    events.setdefault(t, []).append(line)

for n in range(1, 101):
    t = 10 * n - 5
    at(t, "1!")
    at(t + 5, "0!")
for t, v in [(95, 3), (195, 5), (295, 3), (395, 0)]:
    at(t, f"b{v:b} \"")
for t, v in [(52, 1), (53, 0), (702, 1), (707, 0)]:
    at(t, f"{v}#")
for t, v in [(25, "0"), (305, "10100101"), (505, "x"), (605, "1011010")]:
    at(t, f"b{v} $")

out = ["$timescale 1ns $end", "$scope module top $end",
       "$var wire 1 ! clk $end", '$var wire 4 " state [3:0] $end', "$var wire 1 # irq $end",
       "$var wire 8 $ data [7:0] $end", "$var wire 1 % busy $end",
       "$upscope $end", "$enddefinitions $end",
       "#0", "$dumpvars", "0!", 'b0 "', "0#", "bx $", "0%", "$end"]
for t in sorted(events):
    out.append(f"#{t}")
    out += events[t]
out.append("#1010")
open(sys.argv[1] + "/breakpoints.vcd", "w").write("\n".join(out) + "\n")
