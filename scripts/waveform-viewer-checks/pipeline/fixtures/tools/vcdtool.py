#!/usr/bin/env python3
"""vcdtool.py: small VCD helpers for the pipeline-view fixtures (no dependencies).

  cut      Keep only the signals whose dot-joined path matches one of the --keep
           regexes, and only a window of clock cycles; times are rebased so the
           window starts at 0.
  commits  Extract a commit (RVFI-style) stream from a VCD as ground truth.

Cycle rule (same as status/pipeline-view.md, sample=beforeEdge):
  e_k = the k-th rising edge of --clock in the file (k = 0, 1, ...).
  cycle k = [e_k, e_{k+1}); a signal's value "in cycle k" is the value just before
  e_{k+1}, i.e. after every change at times < e_{k+1}.  The last edge of the file
  has no e_{k+1}, so it opens no cycle.

cut window: let R = the index (in the full file) of the first rising edge at which
reset is inactive (sampled before that edge, same rule).  The cut keeps edges
R-pre .. R-pre+cycles (inclusive, so `cycles` complete cycles), starting at the
clock change just before edge R-pre (normally the falling edge), so edge 0 of the
cut is a real 0->1 transition.  Values at the cut start are emitted in $dumpvars.

Usage:
  vcdtool.py cut IN.vcd OUT.vcd --clock TOP.tb.clk --reset TOP.tb.rst_ni --reset-active 0 \
      --pre 3 --cycles 1000 --keep 'TOP\\.tb\\.clk$' --keep '\\.rvfi_' ...
  vcdtool.py commits IN.vcd --clock P --valid P --order P --pc P --insn P [--trap P] > out.json
"""
import argparse, json, re, sys


def parse_header(f):
    """Reads the declarations; returns (None, vars, timescale) with f positioned after
    $enddefinitions.  vars = [(dot-joined path, id code, width, type, reference text)]."""
    scope, vars_, timescale, cmd = [], [], None, []
    for line in f:
        for tok in line.split():
            cmd.append(tok)
            if tok != '$end':
                continue
            kw = cmd[0]
            if kw == '$scope':
                scope.append(cmd[2])
            elif kw == '$upscope':
                scope.pop()
            elif kw == '$var':
                typ, width, code, name = cmd[1], int(cmd[2]), cmd[3], cmd[4]
                rest = ' '.join(cmd[5:-1])
                vars_.append(('.'.join(scope + [name]), code, width, typ, name + (' ' + rest if rest else '')))
            elif kw == '$timescale':
                timescale = ' '.join(cmd[1:-1])
            elif kw == '$enddefinitions':
                return None, vars_, timescale
            cmd = []
    raise SystemExit('no $enddefinitions')


def iter_changes(f):
    """Yields ('t', time) or ('v', code, value) for the body of a VCD."""
    for line in f:
        s = line.strip()
        if not s:
            continue
        c = s[0]
        if c == '#':
            yield ('t', int(s[1:]))
        elif c in '01xzXZ':
            yield ('v', s[1:], c.lower())
        elif c in 'bBrR':
            val, code = s[1:].split()
            yield ('v', code, (c.lower() if c in 'rR' else '') + val.lower())
        elif c == '$':
            continue  # $dumpvars / $end / $dumpall etc.


def find_code(vars_, path):
    for p, code, *_ in vars_:
        if p == path:
            return code
    raise SystemExit('signal not found: ' + path)


def bitval(v):
    """VCD value string -> int, or None if it has x/z."""
    if v.startswith('r'):
        return None
    if any(ch in 'xz' for ch in v):
        return None
    return int(v, 2)


def snapshot_pass(path, clock, codes):
    """Returns (vars_, timescale, edges, before) where before[k] = {code: value} just
    before edge k (state after all changes at times < e_k)."""
    with open(path) as f:
        _, vars_, ts = parse_header(f)
        ck = find_code(vars_, clock)
        state = {}
        at_t = []          # changes at the current timestamp, not yet applied
        t = None
        edges, before = [], []

        def flush_time():
            # apply the changes of timestamp t; detect a rising clock edge
            # a rising edge at t: snapshot the state BEFORE any change at t is applied
            # (changes at t may be listed before or after the clock's own line)
            ckv = [val for code, val in at_t if code == ck]
            if ckv and state.get(ck, 'x') != '1' and ckv[-1] == '1':
                edges.append(t)
                before.append({c: state.get(c, 'x') for c in codes})
            for code, val in at_t:
                state[code] = val

        for ev in iter_changes(f):
            if ev[0] == 't':
                if t is not None:
                    flush_time()
                at_t = []
                t = ev[1]
            else:
                at_t.append((ev[1], ev[2]))
        if t is not None:
            flush_time()
        return vars_, ts, edges, before


def cmd_cut(a):
    keeps = [re.compile(k) for k in a.keep]
    with open(a.inp) as f:
        _, vars_, ts = parse_header(f)
    rc = find_code(vars_, a.reset)
    vars_, ts, edges, before = snapshot_pass(a.inp, a.clock, [rc])
    R = None
    for k in range(1, len(edges)):
        v = bitval(before[k][rc])
        if v is not None and v != a.reset_active:
            R = k
            break
    if R is None:
        raise SystemExit('reset never released')
    first = max(0, R - a.pre)
    last = first + a.cycles
    if last >= len(edges):
        raise SystemExit('only %d edges after the start; need %d' % (len(edges) - first, a.cycles + 1))
    t_first, t_last = edges[first], edges[last]
    kept = [v for v in vars_ if any(r.search(v[0]) for r in keeps)]
    kcodes = {v[1] for v in kept}
    ck = find_code(vars_, a.clock)
    if ck not in kcodes:
        raise SystemExit('the clock must be kept')
    # Start just after the previous clock change (so edge 0 is a 0->1 transition).
    with open(a.inp) as f:
        parse_header(f)
        state, t, at_t = {}, None, []
        t_start = None
        out_body = []
        last_ck_change = 0

        def apply(tt, changes):
            nonlocal last_ck_change
            for code, val in changes:
                if code == ck and tt < t_first:
                    last_ck_change = tt
                state[code] = val
        # pass 1: find the clock change before t_first
        for ev in iter_changes(f):
            if ev[0] == 't':
                if t is not None:
                    apply(t, at_t)
                at_t, t = [], ev[1]
                if t >= t_first:
                    break
            else:
                at_t.append((ev[1], ev[2]))
    t_start = last_ck_change
    with open(a.inp) as f:
        parse_header(f)
        state, t, at_t = {}, None, []
        started = False
        body = []
        init = {}

        def emit_time(tt, changes):
            nonlocal started
            if tt <= t_start:
                for code, val in changes:
                    state[code] = val
                return
            if not started:
                started = True
                init.update(state)
            ch = [(c, v) for c, v in changes if c in kcodes]
            # drop no-op changes
            ch2 = []
            for c, v in ch:
                if state.get(c) != v:
                    ch2.append((c, v))
                state[c] = v
            for c, v in changes:
                state[c] = v
            if ch2:
                body.append('#%d\n' % (tt - t_start))
                for c, v in ch2:
                    body.append(fmt(c, v))
        widths = {v[1]: v[2] for v in vars_}

        def fmt(c, v):
            if v.startswith('r'):
                return 'r%s %s\n' % (v[1:], c)
            if widths.get(c, 1) == 1 and len(v) == 1:
                return '%s%s\n' % (v, c)
            return 'b%s %s\n' % (v, c)
        for ev in iter_changes(f):
            if ev[0] == 't':
                if t is not None:
                    emit_time(t, at_t)
                at_t, t = [], ev[1]
                if t > t_last:
                    t = None
                    break
            else:
                at_t.append((ev[1], ev[2]))
        if t is not None and t <= t_last:
            emit_time(t, at_t)
    with open(a.out, 'w') as o:
        o.write('$comment cut by vcdtool.py: %s edges %d..%d of the full run (reset released at edge %d); '
                'time shifted by -%d $end\n' % (a.inp.split('/')[-1], first, last, R, t_start))
        o.write('$timescale %s $end\n' % ts)
        # rebuild the scope tree
        cur = []
        for path, code, width, typ, ref in kept:
            parts = path.split('.')[:-1]
            i = 0
            while i < len(cur) and i < len(parts) and cur[i] == parts[i]:
                i += 1
            for _ in range(len(cur) - i):
                o.write('$upscope $end\n')
            cur = cur[:i]
            for p in parts[i:]:
                o.write('$scope module %s $end\n' % p)
                cur.append(p)
            o.write('$var %s %d %s %s $end\n' % (typ, width, code, ref))
        for _ in cur:
            o.write('$upscope $end\n')
        o.write('$enddefinitions $end\n#0\n$dumpvars\n')
        for code in sorted(kcodes):
            o.write(fmt(code, (init or state).get(code, 'x')))
        o.write('$end\n')
        o.writelines(body)
    info = {'full_run_edge_first': first, 'full_run_edge_last': last, 'reset_release_edge_full': R,
            'reset_release_edge_cut': R - first, 'time_shift': t_start, 'timescale': ts,
            'cycles': a.cycles, 'kept_signals': len(kept),
            'period': (edges[first + 1] - edges[first]) if first + 1 < len(edges) else None}
    print(json.dumps(info, indent=1))


def cmd_commits(a):
    names = {'valid': a.valid, 'order': a.order, 'pc': a.pc, 'insn': a.insn}
    if a.trap:
        names['trap'] = a.trap
    with open(a.inp) as f:
        _, vars_, ts = parse_header(f)
    codes = {k: find_code(vars_, v) for k, v in names.items()}
    vars_, ts, edges, before = snapshot_pass(a.inp, a.clock, list(codes.values()))
    out = []
    for k in range(len(edges) - 1):
        s = before[k + 1]
        if bitval(s[codes['valid']]) == 1:
            rec = {'cycle': k, 'time': edges[k],
                   'order': bitval(s[codes['order']]),
                   'pc': '0x%08x' % bitval(s[codes['pc']]),
                   'insn': '0x%08x' % bitval(s[codes['insn']])}
            if 'trap' in codes:
                rec['trap'] = bitval(s[codes['trap']])
            out.append(rec)
    period = edges[1] - edges[0] if len(edges) > 1 else None
    doc = {
        'source': 'commit port sampled from the VCD by tools/vcdtool.py commits (not from a pipeline tracker)',
        'cycleRule': 'cycle k = [posedge_k, posedge_{k+1}) of the clock, k 0-based from the first posedge in '
                     'this VCD; values sampled just before posedge_{k+1} (after all changes at times < '
                     'posedge_{k+1}); a commit is a cycle where valid==1',
        'signals': names, 'timescale': ts, 'clockPeriod': period,
        'posedges': len(edges), 'cycles': len(edges) - 1,
        'count': len(out), 'commits': out,
    }
    json.dump(doc, sys.stdout, indent=1)
    sys.stdout.write('\n')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest='cmd', required=True)
    c = sp.add_parser('cut')
    c.add_argument('inp'); c.add_argument('out')
    c.add_argument('--clock', required=True); c.add_argument('--reset', required=True)
    c.add_argument('--reset-active', type=int, default=1)
    c.add_argument('--pre', type=int, default=3)
    c.add_argument('--cycles', type=int, default=1000)
    c.add_argument('--keep', action='append', required=True)
    m = sp.add_parser('commits')
    m.add_argument('inp')
    for n in ('clock', 'valid', 'order', 'pc', 'insn'):
        m.add_argument('--' + n, required=True)
    m.add_argument('--trap')
    a = p.parse_args()
    {'cut': cmd_cut, 'commits': cmd_commits}[a.cmd](a)


if __name__ == '__main__':
    main()
