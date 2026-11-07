#!/usr/bin/env python3
# trace-kdb's comparison: the design model npi-model.py exported from a KDB against cmux-sv-model's
# (`--once '*'`) of the same design. The KDB's must have the same instances and signals, the same
# widths, ranges and arrays, and a write for (nearly) every signal the slang model writes.
# Usage: compare.py <kdb-model.json> <slang-model.json> [export summary line [cached model.json, its summary]]
# The cached export must be the same model, from the cache ("cached": true).
import json
import sys


def slang_writes(inst):
    names = {}

    def add(name, loc):
        if name and not name.startswith("$"):
            names.setdefault(name, set()).add(loc[1] if loc else None)

    def walk(b):
        if isinstance(b, dict):
            if b.get("k") == "asgn" and isinstance(b.get("lhs"), dict):
                add(b["lhs"].get("name"), b.get("loc"))
            if b.get("k") == "opaque":
                for w in b.get("writes", []):
                    add(w["name"], b.get("loc"))
            for v in b.values():
                walk(v)
        elif isinstance(b, list):
            for x in b:
                walk(x)

    for a in inst.get("assigns", []):
        add(a["lhs"].get("name"), a.get("loc"))
    for p in inst.get("procs", []):
        walk(p.get("body"))
    return names


def shape(sig):
    a = sig.get("array")
    return (sig.get("width"), sig.get("msb"), sig.get("lsb"), (a["lo"], a["hi"], a["elemWidth"]) if a else None)


def main():
    failures = []
    try:
        kdb = json.load(open(sys.argv[1]))
    except ValueError:
        print("FAIL no model exported: " + (sys.argv[3] if len(sys.argv) > 3 else ""))
        print("TRACE KDB CHECKS FAILED")
        sys.exit(1)
    slang = json.load(open(sys.argv[2]))
    if len(sys.argv) > 3:
        print("export", sys.argv[3])
    if len(sys.argv) > 5:
        print("again ", sys.argv[5])
        try:
            again, said = json.load(open(sys.argv[4])), json.loads(sys.argv[5] or "{}")
        except ValueError:
            again, said = None, {}
        if again != kdb:
            failures.append("the second export is not the same model")
        if said.get("cached") is not True or "load" in said.get("seconds", {}):
            failures.append("the second export did not come from the cache (or loaded the KDB)")
    ki, si = set(kdb["instances"]), set(slang["instances"])
    print(f"instances: kdb {len(ki)}, slang {len(si)}, only kdb {len(ki - si)}, only slang {len(si - ki)}")
    if kdb["tops"] != slang["tops"]:
        failures.append(f"tops {kdb['tops']} != {slang['tops']}")
    if ki != si:
        failures.append(f"instances differ: only kdb {sorted(ki - si)[:3]}, only slang {sorted(si - ki)[:3]}")
    signals = missing = differ = 0
    written = unwritten = 0
    bound = unbound = 0
    examples = []
    for path in sorted(ki & si):
        k, s = kdb["instances"][path], slang["instances"][path]
        for name, sig in s["signals"].items():
            signals += 1
            got = k["signals"].get(name)
            if got is None:
                missing += 1
                examples.append(f"missing {path}.{name}")
            elif shape(got) != shape(sig) and sig.get("width") != 0:  # width 0: a string, real, ...
                differ += 1
                examples.append(f"shape {path}.{name}: kdb {shape(got)} slang {shape(sig)}")
        kc = {p["name"]: p.get("conn") for p in k.get("ports", [])}
        for p in s.get("ports", []):
            c = p.get("conn") or {}
            single = len(c.get("leaves", [])) == 1 and c.get("src") == c["leaves"][0]
            if single and s.get("parent"):
                bound += 1
                got = kc.get(p["name"])
                if not got or got.get("leaves") != c["leaves"]:
                    unbound += 1
                    if len(examples) < 40:
                        examples.append(f"no conn {path}.{p['name']} ({c['src']})")
        for name in slang_writes(s):
            written += 1
            if name not in k.get("writes", {}):
                unwritten += 1
                if len(examples) < 40:
                    examples.append(f"no write {path}.{name}")
    print(f"signals: {signals}, missing in kdb {missing}, other shape {differ}")
    print(f"written in slang: {written}, without a kdb write {unwritten}")
    print(f"single-net port connections in slang: {bound}, without the same kdb connection {unbound}")
    if unbound:
        failures.append(f"{unbound} of {bound} single-net port connections differ")
    if missing:
        failures.append(f"{missing} signals missing")
    if differ:
        failures.append(f"{differ} signals of another width, range or array")
    if written and unwritten * 100 > written:
        failures.append(f"{unwritten} of {written} written signals without a kdb write (over 1%)")
    for e in examples[:12]:
        print("  " + e)
    for f in failures:
        print("FAIL " + f)
    print("TRACE KDB CHECKS " + ("FAILED" if failures else "PASSED"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
