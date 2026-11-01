#!/usr/bin/env python3
"""layouts.py <slang-ast.json> <Type:width> ...: flattened packed-struct layouts for the config.

The JSON comes from `slang -q <package files> <defines> --ast-json X --ast-json-detailed-types`.
Each field's lsb is slang's bitOffset; its width is the gap to the previous (more significant)
field, the first field taking the rest of the given total width (taken from the VCD $var width).
Nested packed structs (via typedef) are flattened as "outer.inner". Prints {Type: [{name,lsb,width}]}.
"""
import json, sys
alias = {}


def load(path):
    """Index every TypeAlias in a slang --ast-json dump (call once)."""
    walk(json.load(open(path)))


def walk(o):
    if isinstance(o, dict):
        if o.get('kind') == 'TypeAlias':
            alias[o['name']] = o
            alias[str(o.get('addr'))] = o
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)

def struct_of(t):
    """t: a type (dict or "addr pkg::name" string) -> PackedStructType dict or None."""
    for _ in range(16):   # alias chains are short; a self-referencing name lookup must not spin
        if isinstance(t, str):
            a = alias.get(t.split()[0]) or alias.get(t.split('::')[-1])
            if not a: return None
            t = a['target']
        elif t.get('kind') == 'TypeAlias':
            t = t['target']
        elif t.get('kind') == 'PackedStructType':
            return t
        else:
            return None
    return None


def flatten(st, width, base, prefix, out):
    ms = sorted(st['members'], key=lambda m: -m['bitOffset'])
    top = width
    for m in ms:
        w = top - m['bitOffset']; top = m['bitOffset']
        sub = struct_of(m['type'])
        name = prefix + m['name']
        if sub:
            flatten(sub, w, base + m['bitOffset'], name + '.', out)
        else:
            out.append({'name': name, 'lsb': base + m['bitOffset'], 'width': w})


def layout(type_name, total_width):
    out = []
    flatten(struct_of(alias[type_name]), total_width, 0, '', out)
    return out


if __name__ == '__main__':
    load(sys.argv[1])
    res = {}
    for arg in sys.argv[2:]:
        tn, w = arg.split(':')
        res[tn] = layout(tn, int(w))
    json.dump(res, sys.stdout, indent=1)
