#!/usr/bin/env python3
"""Writes commit-page.vcd (run.sh commit-page), written for cmux's checks.

The signals of text-breakpoints.vcd (top.clk, top.inst, top.flag, top.msg; see its make-vcd.py), plus a
RISC-V Formal Interface commit stream in top (rvfi_*, NRET 2 as packed vectors: channel c at
[c*W +: W]) that cmux-machine.js indexes. Each commit's values are set 2 ns before its posedge and
valid drops 3 ns after it.

  k  posedge ch  pc          insn                    writes
  0  15      0   0x80000000  li a0,0                 a0 = 0
  1  25      0   0x80000004  jal t0,pc+8             t0
  2  25      1   0x80000008  csrw mtvec,t1           mtvec
  3  35      0   0x80000004  jal t0,pc+8             t0
  4  45      0   0x80000004  jal t0,pc+8             t0
  5  65      0   0x80000010  sw a3,0(a1)             [0x1000..0x1003]
  6  85      0   0x80000004  jal t0,pc+8             t0
"""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("tb", os.path.join(here, "..", "text-breakpoints", "make-vcd.py"))

LI, JAL, CSRW, SW = 0x00000513, 0x008002EF, 0x30531073, 0x00D5A023
COMMITS = [  # (posedge, channel, pc, insn, rd, rd_wdata, mem_addr, mem_wmask, csr_mtvec_wmask)
    (15, 0, 0x80000000, LI, 10, 0, 0, 0, 0),
    (25, 0, 0x80000004, JAL, 5, 0x80000008, 0, 0, 0),
    (25, 1, 0x80000008, CSRW, 0, 0, 0, 0, 0xFFFFFFFF),
    (35, 0, 0x80000004, JAL, 5, 0x80000008, 0, 0, 0),
    (45, 0, 0x80000004, JAL, 5, 0x80000008, 0, 0, 0),
    (65, 0, 0x80000010, SW, 0, 0, 0x1000, 0xF, 0),
    (85, 0, 0x80000004, JAL, 5, 0x80000008, 0, 0, 0),
]
# role: (width per channel, value of a commit)
ROLES = {
    "valid": (1, lambda c, o: 1),
    "order": (64, lambda c, o: o),
    "insn": (32, lambda c, o: c[3]),
    "trap": (1, lambda c, o: 0),
    "pc_rdata": (32, lambda c, o: c[2]),
    "pc_wdata": (32, lambda c, o: c[2] + 4),
    "rd_addr": (5, lambda c, o: c[4]),
    "rd_wdata": (32, lambda c, o: c[5]),
    "mem_addr": (32, lambda c, o: c[6]),
    "mem_rmask": (4, lambda c, o: 0),
    "mem_wmask": (4, lambda c, o: c[7]),
    "mem_wdata": (32, lambda c, o: 0x11223344 if c[7] else 0),
    "csr_mtvec_wmask": (32, lambda c, o: c[8]),
    "csr_mtvec_wdata": (32, lambda c, o: 0x80000100 if c[8] else 0),
}
NRET = 2


def main(outdir):
    # The base signals: run text-breakpoints/make-vcd.py into outdir, then add the stream to its text.
    tb_path = os.path.join(outdir, "text-breakpoints.vcd")
    saved = sys.argv
    sys.argv = [spec.origin, outdir]
    try:
        spec.loader.exec_module(importlib.util.module_from_spec(spec))
    finally:
        sys.argv = saved
    lines = open(tb_path).read().split("\n")

    ids = {role: f"r{i}" for i, role in enumerate(ROLES)}
    var_lines = [f"$var wire {w * NRET} {ids[r]} rvfi_{r} [{w * NRET - 1}:0] $end" for r, (w, _) in ROLES.items()]
    # Per posedge: the packed value of each role (channels without a commit are 0).
    by_edge = {}
    for order, c in enumerate(COMMITS):
        by_edge.setdefault(c[0], {})[c[1]] = (c, order)
    changes = {}  # time -> [vcd lines]

    def packed(role, chans):
        w, f = ROLES[role]
        v = 0
        for ch, (c, order) in chans.items():
            v |= (f(c, order) & ((1 << w) - 1)) << (ch * w)
        return v

    for edge, chans in by_edge.items():
        for role in ROLES:
            changes.setdefault(edge - 2, []).append(f"b{packed(role, chans):b} {ids[role]}")
        changes.setdefault(edge + 3, []).append(f"b0 {ids['valid']}")

    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line == "$upscope $end" and not any(l.startswith("$var wire") and "rvfi_" in l for l in out):
            out += var_lines
        if line == "$dumpvars":
            out.append(line)
            out += [f"b0 {ids[r]}" for r in ROLES]
            i += 1
            continue
        if line.startswith("#") and line != "#0":
            t = int(line[1:])
            for ct in sorted(k for k in list(changes) if k < t):
                out.append(f"#{ct}")
                out += changes.pop(ct)
            out.append(line)
            out += changes.pop(t, [])
            i += 1
            continue
        out.append(line)
        i += 1
    assert not changes, changes
    open(os.path.join(outdir, "commit-page.vcd"), "w").write("\n".join(out))


main(sys.argv[1])
