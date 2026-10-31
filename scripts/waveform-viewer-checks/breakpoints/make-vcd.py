#!/usr/bin/env python3
"""Writes the breakpoint checks' dumps (run.sh breakpoints): breakpoints.vcd, and
breakpoints-wide.vcd, the same with top.data 16 bits wide (a reload that changes a width).

top.clk: period 10, posedges at 5, 15, ... 995 (cycle n at 10n - 5).
top.state [3:0]: registered (changes on posedges): 3 from cycle 10, 5 from 20, 3 from 30, 0 from 40.
top.irq: pulses between edges: 1 at 52, 0 at 53 (both land on 55, cycle 6); 1 at 702, 0 at 707 (land on 705).
top.data [7:0]: x at 0, 'h00 at 25, 'ha5 at 305, x at 505, 'h5a at 605.
top.busy: 0 throughout (never changes).
top.pulse: 0, 1 at 41 (lands on 45, cycle 5).
top.mode [1:0]: 0, 1 at 105, 3 at 205, 2 at 305, 1 at 405 (registered).
top.late: 0, 1 at 1000 (after the last posedge, 995).
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
at(41, "1&")
for t, v in [(105, 1), (205, 3), (305, 2), (405, 1)]:
    at(t, f"b{v:b} '")
at(1000, "1(")

def write(name, data_width):
  out = ["$timescale 1ns $end", "$scope module top $end",
       "$var wire 1 ! clk $end", '$var wire 4 " state [3:0] $end', "$var wire 1 # irq $end",
       f"$var wire {data_width} $ data [{data_width - 1}:0] $end", "$var wire 1 % busy $end",
       "$var wire 1 & pulse $end", "$var wire 2 ' mode [1:0] $end", "$var wire 1 ( late $end",
       "$upscope $end", "$enddefinitions $end",
       "#0", "$dumpvars", "0!", 'b0 "', "0#", "bx $", "0%", "0&", "b0 '", "0(", "$end"]
  for t in sorted(events):
    out.append(f"#{t}")
    out += events[t]
  out.append("#1010")
  open(sys.argv[1] + "/" + name, "w").write("\n".join(out) + "\n")

write("breakpoints.vcd", 8)
write("breakpoints-wide.vcd", 16)
