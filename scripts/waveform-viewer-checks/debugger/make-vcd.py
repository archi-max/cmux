#!/usr/bin/env python3
"""Writes the debugger checks' dumps (run.sh debugger).

stepping.vcd: top.clk, period 10 ns, first posedge at 5; top.count counts
posedges; top.core.state is count/3 (4 bits); top.core.valid is high on odd
cycles; top.core.alu.acc is 16 bits. 4000 posedges, so wellen sends the clock
LZ4-packed (more than 65000 bytes of records).
small.vcd: the same for 20 posedges (sent as JSON), with a clock named `clock`
one level down (TOP.tb.clock), below a simulator wrapper.
"""
import sys


def write(path, cycles, top, clock_scope, clock_name):
    out = ["$timescale 1ns $end"]
    out.append(f"$scope module {top} $end")
    if clock_scope:
        out.append(f"$scope module {clock_scope} $end")
    out += [f"$var wire 1 ! {clock_name} $end", '$var wire 8 " count [7:0] $end',
            "$scope module core $end", "$var wire 1 # valid $end", "$var wire 4 $ state [3:0] $end",
            "$scope module alu $end", "$var wire 16 % acc [15:0] $end", "$upscope $end", "$upscope $end"]
    if clock_scope:
        out.append("$upscope $end")
    out += ["$upscope $end", "$enddefinitions $end", "#0", "$dumpvars", "0!", 'b0 "', "0#", "b0 $", "b0 %", "$end"]
    for n in range(1, cycles + 1):
        t = 10 * n - 5
        out.append(f"#{t}")
        out.append("1!")
        out.append(f'b{n % 256:b} "')
        out.append(f"{n % 2}#")
        if n % 3 == 0:
            out.append(f"b{(n // 3) % 16:b} $")
        if n % 5 == 0:
            out.append(f"b{(n * 7) % 65536:b} %")
        out.append(f"#{t + 5}")
        out.append("0!")
    out.append(f"#{10 * cycles + 10}")
    open(path, "w").write("\n".join(out) + "\n")


write(sys.argv[1] + "/stepping.vcd", 4000, "top", None, "clk")
write(sys.argv[1] + "/small.vcd", 20, "TOP", "tb", "clock")
