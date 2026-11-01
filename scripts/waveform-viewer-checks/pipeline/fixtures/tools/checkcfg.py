#!/usr/bin/env python3
"""checkcfg.py: sanity-check a fixture's pipeline.json against its VCD and expected.json.

  checkcfg.py pipeline.json core.vcd expected.json [--table FROM:TO]

--table prints one line per cycle: per stage pc (or '.' when invalid), with S = stall
and F = flush, then the commit pc of that cycle.

1. Every signal name used in the config resolves (scope-relative, else absolute).
2. Commit latency: for each commit in expected.json at cycle c, finds the smallest
   L >= 0 such that the LAST configured stage held the same pc at cycle c-L and was
   leaving it (valid && !stall && !flush).  Prints the histogram of L, which tells
   the tracker how many cycles the commit port trails the last stage.
3. Prints, per stage, how many cycles were valid / stalled / flushed.

Expressions are evaluated with a tiny translator (! && || == != ~ & | ^, ( ), ints,
bit select x[i] / x[h:l]); enough for these fixtures, not a cmux-expr.js replacement.
Same cycle rule as vcdtool.py (values just before posedge k+1).
"""
import json, re, sys, collections
sys.path.insert(0, __import__('os').path.dirname(__file__))
import vcdtool as V

def idents(expr):
    out = []
    for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_$.]*", re.sub(r"\[[^\]]*\]", "", expr)):
        out.append(m.group(0))
    return out


def main():
    cfgp, vcdp, expp = sys.argv[1:4]
    table = None
    if len(sys.argv) > 5 and sys.argv[4] == '--table':
        table = tuple(int(x) for x in sys.argv[5].split(':'))
    cfg = json.load(open(cfgp))['pipelines'][0]
    scope = cfg['scope']
    _, vars_, _ = V.parse_header(open(vcdp))
    paths = {p: c for p, c, *_ in vars_}

    def resolve(n):
        for cand in (scope + '.' + n, n):
            if cand in paths:
                return cand
        return None
    exprs = {}
    for st in cfg['stages']:
        for f in ('valid', 'pc', 'inst', 'tag', 'stall', 'flush'):
            if f in st:
                exprs[(st['name'], f)] = st[f]
    for f, e in cfg.get('commit', {}).items():
        if isinstance(e, str):
            exprs[('commit', f)] = e
    names, bad = {}, []
    for k, e in exprs.items():
        for n in idents(e):
            r = resolve(n)
            if r is None:
                bad.append((k, n))
            names[n] = r
    clock = resolve(cfg['clock'])
    if bad or clock is None:
        print('UNRESOLVED:', bad, 'clock' if clock is None else '')
        sys.exit(1)
    print('all %d names resolve' % len(names))
    codes = sorted({paths[r] for r in names.values()})
    _, _, edges, before = V.snapshot_pass(vcdp, clock, codes)

    def ev(e, s):
        py = e
        for n in sorted(names, key=len, reverse=True):
            v = V.bitval(s[paths[names[n]]])
            py = re.sub(r"(?<![A-Za-z0-9_$.])" + re.escape(n) + r"(?![A-Za-z0-9_$.])", '(%d)' % (v if v is not None else 0), py)
        py = re.sub(r"\[(\d+):(\d+)\]", lambda m: '>>%s&%d' % (m.group(2), (1 << (int(m.group(1)) - int(m.group(2)) + 1)) - 1), py)
        py = re.sub(r"\[(\d+)\]", lambda m: '>>%s&1' % m.group(1), py)
        py = py.replace('&&', ' and ').replace('||', ' or ')
        py = re.sub(r"!(?!=)", ' not ', py)
        return int(eval(py))
    stages = [s for s in cfg['stages'] if 'valid' in s]
    last = stages[-1]
    N = len(edges) - 1
    rows = []
    stat = {s['name']: collections.Counter() for s in stages}
    for k in range(N):
        s = before[k + 1]
        r = {}
        for st in stages:
            v = ev(st['valid'], s)
            stl = ev(st['stall'], s) if 'stall' in st else 0
            fl = ev(st['flush'], s) if 'flush' in st else 0
            pc = ev(st['pc'], s) if 'pc' in st else None
            r[st['name']] = (v, stl, fl, pc)
            if v:
                stat[st['name']]['valid'] += 1
                stat[st['name']]['stall'] += bool(stl and not fl)
                stat[st['name']]['flush'] += bool(fl)
        rows.append(r)
    for n, c in stat.items():
        print('%-6s valid=%d stall=%d flush=%d' % (n, c['valid'], c['stall'], c['flush']))
    exp = json.load(open(expp))
    if table:
        cm = {c['cycle']: c for c in exp['commits']}
        print('cycle ' + ' '.join('%-11s' % st['name'] for st in stages) + ' commit')
        for k in range(table[0], min(table[1], N)):
            cells = []
            for st in stages:
                v, stl, fl, pc = rows[k][st['name']]
                cells.append('%-11s' % (('%x' % pc if pc is not None else 'v') + ('F' if fl else 'S' if stl else '')
                                        if v else '.'))
            c = cm.get(k)
            print('%5d ' % k + ' '.join(cells) + ' ' + (('%s#%s' % (c['pc'][-4:], c['order'])) if c else ''))
    hist = collections.Counter()
    for cm in exp['commits']:
        c, pc = cm['cycle'], int(cm['pc'], 16)
        for L in range(0, 8):
            if c - L < 0:
                L = None
                break
            v, stl, fl, p = rows[c - L][last['name']]
            if v and not stl and not fl and p == pc:
                break
        else:
            L = None
        hist[L] += 1
    print('commit latency after leaving %s: %s  (None = no match within 7 cycles or before the cut)'
          % (last['name'], dict(hist)))


if __name__ == '__main__':
    main()
