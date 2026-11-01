#!/usr/bin/env python3
"""rsd_commits.py <rsd.vcd> <Kanata.log> <out expected.json> [<out kanata.log cut>]

Ground-truth commit stream for the RSD fixture, read from the commit stage's own ports (not
from any tracker), plus the alignment with RSD's own Kanata log.

Per cycle k (vcdtool.py rule: value just before posedge k+1 of TOP.clk_p) and commit slot
i = 0, 1: when core.cmStage.commit[i] is 1, the committed op is core.cmStage.alReadData[i]
(an ActiveListEntry, layout from slang: opId.sid [61:52], opId.mid [51:50], pc [49:31] (the
19-bit narrow PC: {pc[18], 13'b0, pc[17:0]} is the address)). The instruction word is joined
from the decode stage's debug register (core.debugIF.idReg[i], DecodeStageDebugRegister:
valid [80], opId.sid [77:68], opId.mid [67:66], pc [65:34], insn [33:2]): the most recent
decode of the same sid/mid before the commit.

RSD has no order tag; `order` here is the 0-based commit sequence number in this VCD
(slot 0 before slot 1), and `sid`/`mid` are the hardware OpId (sid wraps at 1024).

Kanata alignment: RSD's Kanata log is built from the registered `debugRegister`, so its cycle
numbers are offset from the VCD posedge index. Every `R <id> <rid> 0` retire line in the log
is matched to the VCD commit of the same op (Kanata `I <id> <gid> 0`, gid = unwrapped
sid*4+mid); the offset of the op's `S <id> 0 Cm` line (stage cells) and of its R line
(one cycle later) from the VCD commit cycle are reported (each must be one constant).
With a 4th argument the log is cut to the VCD's cycle range: only ops alive inside
[offset, offset + cycles) are kept (with all their lines, including ones before the range),
events at or after offset + cycles are dropped, and `C=` is the first kept event's cycle, so
absolute Kanata cycle numbers are unchanged.
"""
import json, sys, collections
sys.path.insert(0, __import__('os').path.join(__import__('os').path.dirname(__file__), '..'))
import vcdtool as V

C = 'TOP.Main_Zynq_Wrapper.main.core.'


def field(v, lsb, w):
    return (v >> lsb) & ((1 << w) - 1)


def main():
    vcdp, kanp, outp = sys.argv[1:4]
    cutp = sys.argv[4] if len(sys.argv) > 4 else None
    _, vars_, ts = V.parse_header(open(vcdp))
    names = {}
    for i in (0, 1):
        names['commit%d' % i] = C + 'cmStage.commit[%d]' % i
        names['al%d' % i] = C + 'cmStage.alReadData[%d]' % i
        names['id%d' % i] = C + 'debugIF.idReg[%d]' % i
    codes = {k: V.find_code(vars_, p) for k, p in names.items()}
    _, _, edges, before = V.snapshot_pass(vcdp, 'TOP.clk_p', list(codes.values()))
    N = len(edges) - 1
    insn_of = {}
    commits = []
    for k in range(N):
        s = before[k + 1]
        for i in (0, 1):
            idr = V.bitval(s[codes['id%d' % i]])
            if idr is not None and field(idr, 80, 1):
                insn_of[(field(idr, 68, 10), field(idr, 66, 2))] = (field(idr, 34, 32), field(idr, 2, 32))
        for i in (0, 1):
            if V.bitval(s[codes['commit%d' % i]]) == 1:
                al = V.bitval(s[codes['al%d' % i]])
                sid, mid, npc = field(al, 52, 10), field(al, 50, 2), field(al, 31, 19)
                pc = ((npc >> 18) << 31) | (npc & 0x3ffff)
                dpc, insn = insn_of.get((sid, mid), (None, None))
                rec = {'cycle': k, 'time': edges[k], 'order': len(commits), 'slot': i, 'sid': sid, 'mid': mid,
                       'pc': '0x%08x' % pc, 'insn': ('0x%08x' % insn) if insn is not None else None}
                if dpc is not None and dpc != pc:
                    rec['warning'] = 'decode pc 0x%08x differs' % dpc
                commits.append(rec)
    # --- Kanata alignment ---
    cyc, start = None, None
    gid_of, retire, cm_start = {}, [], {}
    lines = open(kanp).read().split('\n')
    events = []   # (cycle, line)
    for ln in lines:
        p = ln.split('\t')
        if p[0] == 'C=':
            cyc = int(p[1]); start = cyc
            continue
        if p[0] == 'C':
            cyc += int(p[1]); continue
        if p[0] == 'I':
            gid_of[int(p[1])] = int(p[2])
        if p[0] == 'S' and p[2] == '0' and p[3] == 'Cm':
            cm_start[int(p[1])] = cyc
        if p[0] == 'R' and p[3] == '0':
            g = gid_of[int(p[1])]
            retire.append((cyc, (g // 4) % 1024, g % 4, int(p[2]), cm_start.get(int(p[1]))))
        if p[0] and p[0] not in ('Kanata', 'C=', 'C'):
            events.append((cyc, ln))
    offs = collections.Counter()
    vq = collections.defaultdict(list)
    for c in commits:
        vq[(c['sid'], c['mid'])].append(c)
    matched = 0
    soffs = collections.Counter()
    for kc, sid, mid, rid, kcm in retire:
        cands = vq.get((sid, mid), [])
        best = None
        for c in cands:
            d = kc - c['cycle']
            if best is None or abs(d - (offs.most_common(1)[0][0] if offs else 0)) < abs(best[0] - (offs.most_common(1)[0][0] if offs else 0)):
                best = (d, c)
        if best:
            offs[best[0]] += 1
            best[1]['kanataRid'] = rid
            if kcm is not None:
                soffs[kcm - best[1]['cycle']] += 1
            matched += 1
    roff = offs.most_common(1)[0][0] if offs else None
    off = soffs.most_common(1)[0][0] if soffs else None
    in_range = [r for r in retire if off is not None and 0 <= r[0] - off < N]
    unmatched_vcd = [c for c in commits if 'kanataRid' not in c]
    doc = {
        'source': 'RSD commit stage ports (cmStage.commit[i] + cmStage.alReadData[i]) sampled from rsd.vcd by '
                  'tools/rsd/rsd_commits.py; insn joined from debugIF.idReg[i] by OpId; not from a pipeline tracker',
        'cycleRule': 'cycle k = [posedge_k, posedge_{k+1}) of TOP.clk_p, k 0-based from the first posedge in this '
                     'VCD; values sampled just before posedge_{k+1}; a commit is a cycle where commit[i]==1 '
                     '(slot 0 is older than slot 1)',
        'order': 'RSD has no order tag: order = 0-based commit sequence number within this VCD',
        'timescale': ts, 'clockPeriod': edges[1] - edges[0], 'posedges': len(edges), 'cycles': N,
        'count': len(commits),
        'kanata': {'file': 'kanata.log', 'cycleOffset': off, 'retireLineOffset': roff,
                   'rule': 'Kanata cycles are absolute (counted from the C= line). A stage cell in Kanata cycle K '
                           'is VCD cycle K - cycleOffset (the op enters Cm in Kanata cycle vcdCommitCycle + '
                           'cycleOffset); the R (retire) line is written one Kanata cycle later, at '
                           'vcdCommitCycle + retireLineOffset',
                   'offsetHistogram': {str(k): v for k, v in soffs.items()},
                   'retireLineOffsetHistogram': {str(k): v for k, v in offs.items()},
                   'kanataRetiresInVcdRange': len(in_range), 'vcdCommitsWithoutKanataRetire': len(unmatched_vcd)},
        'commits': commits,
    }
    json.dump(doc, open(outp, 'w'), indent=1)
    print(json.dumps({k: v for k, v in doc.items() if k != 'commits'}, indent=1))
    if cutp and off is not None:
        lo, hi = off, off + N   # kanata cycles covered by the VCD
        # ops alive in [lo, hi): first event < hi and last event >= lo
        first, last = {}, {}
        for c, ln in events:
            iid = int(ln.split('\t')[1])
            first.setdefault(iid, c); last[iid] = c
        keep = {i for i in first if first[i] < hi and last[i] >= lo}
        lo2 = min(first[i] for i in keep)   # earliest event of a kept op (<= lo)
        out = ['Kanata\t0004', 'C=\t%d' % lo2]
        cur = lo2
        for c, ln in events:
            iid = int(ln.split('\t')[1])
            if iid not in keep or c >= hi:
                continue
            if c > cur:
                out.append('C\t%d' % (c - cur)); cur = c
            out.append(ln)
        open(cutp, 'w').write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
