#!/usr/bin/env python3
"""Machine-state fixtures (our own): keep only some variables of a VCD (Verilator's --trace dumps
every signal whatever $dumpvars names). vcd-keep.py <in> <out> <scope.path.regex>...
A variable is kept when its dotted path (scopes + name) fully matches one of the regexes."""
import re, sys
src, dst, pats = sys.argv[1], sys.argv[2], [re.compile(p) for p in sys.argv[3:]]
keep, scopes, out = set(), [], []
with open(src) as f:
    lines = iter(f)
    for line in lines:
        t = line.split()
        if t[:1] == ['$scope']: scopes.append(t[2]); out.append(line); continue
        if t[:1] == ['$upscope']: scopes.pop(); out.append(line); continue
        if t[:1] == ['$var']:
            path = '.'.join(scopes + [t[4]])
            if any(p.fullmatch(path) for p in pats): keep.add(t[3]); out.append(line)
            continue
        out.append(line)
        if t[:1] == ['$enddefinitions']: break
    for line in lines:
        c = line[:1]
        if c in '#$' or not line.strip(): out.append(line); continue
        ident = line[1:].strip() if c in '01xzXZ' else line.split()[-1]
        if ident in keep: out.append(line)
# Drop scopes left empty.
text, changed = ''.join(out), True
while changed:
    n = len(text); text = re.sub(r'(?m)^\s*\$scope [^\n]*\$end\n\s*\$upscope \$end\n', '', text); changed = len(text) != n
open(dst, 'w').write(text)
