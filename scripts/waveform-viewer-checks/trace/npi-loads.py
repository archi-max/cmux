#!/usr/bin/env python3
# The load trace oracle: each signal's loads (readers) in a VCS KDB, from Verdi's documented Python
# NPI call lang.trace_load2 (Python NPI Language Model, "L1 APIs / Signal"), with is_pass_thr off
# (stop at a port: the connection is the load) and on (go through ports into the child).
# Verdi comes from VERDI_HOME only (nothing guessed). NPI holds a licence seat from load_design to
# its end: every signal is read first, NPI is ended, then the JSON is written.
# Usage: npi-loads.py <simv.daidir> <signals.txt: one hierarchical path per line> <out.json>
# Output: {"signals": {path: {"stop": [load], "through": [load]}}}; a load is
#   {"file": basename, "line", "type": the use's NPI type (npiContAssign, npiIf, npiPort, ...),
#    "text": its source as NPI prints it, "scope": the scope path, "scopeType", "upper": true when
#    the load is in an upper statement (num_sig_use 0: a statement under a read condition or event),
#    "from": the signal read (differs from the path once a port is gone through), "targets": [paths]}
# File names are basenames, so the output names no host folder.
import json
import os
import re
import sys

INFO = re.compile(r'^(\w+), (.*), \{(.*) : (\d+)\}$', re.S)


def info(lang, hdl):
    """(type, name or text, file basename, line) of an NPI handle, from get_hdl_info."""
    if hdl is None:
        return None
    text = lang.get_hdl_info(hdl) or ''
    m = INFO.match(text.strip())
    if not m:
        return (None, text.strip(), None, None)
    return (m.group(1), m.group(2), os.path.basename(m.group(3)), int(m.group(4)))


def loads(lang, path, through):
    out = []
    for d in lang.trace_load2(path, through) or []:
        use = info(lang, d.get_use_hdl()) or (None, None, None, None)
        scope = info(lang, d.get_scope_hdl()) or (None, None, None, None)
        src = info(lang, d.get_src_hdl()) or (None, None, None, None)
        targets = sorted({re.sub(r'\[\d+\]$', '', t[1]) for t in (info(lang, h) for h in d.get_sig_hdl_list() or []) if t and t[1]})
        out.append({"file": use[2], "line": use[3], "type": use[0], "text": use[1], "scope": scope[1], "scopeType": scope[0],
                    "upper": d.get_num_sig_use() == 0, "from": src[1], "targets": targets})
    return out


def main():
    if len(sys.argv) != 4:
        print(json.dumps({"ok": False, "error": "usage"}))
        sys.exit(2)
    daidir, listing, out = sys.argv[1:]
    home = os.environ.get("VERDI_HOME")
    if not home:
        print(json.dumps({"ok": False, "error": "noVerdi", "message": "VERDI_HOME is not set"}))
        sys.exit(1)
    sys.path.insert(0, os.path.join(home, "share", "NPI", "python"))
    from pynpi import npisys, lang
    paths = [p.strip() for p in open(listing) if p.strip()]
    if not npisys.init([sys.argv[0]]):
        sys.exit(1)
    if not npisys.load_design(["-dbdir", daidir]):
        npisys.end()
        print(json.dumps({"ok": False, "error": "load"}))
        sys.exit(1)
    result = {}
    for p in paths:
        result[p] = {"stop": loads(lang, p, False), "through": loads(lang, p, True)}
    npisys.end()
    with open(out, "w") as f:
        json.dump({"signals": result}, f, indent=0, sort_keys=True)
    print(json.dumps({"ok": True, "signals": len(result), "loads": sum(len(v["stop"]) for v in result.values())}))


if __name__ == "__main__":
    main()
