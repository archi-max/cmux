#!/usr/bin/env python3
# trace-kdb's comparison: the design model npi-model.py exported from a KDB against cmux-sv-model's
# (`--once '*'`) of the same design. The KDB's must have
# - the same tops and instances, each with the same module, parent and children (paths and modules);
# - the same ports (name, direction, width; an unpacked-array port has width 0 in both; interface
#   ports, which slang's model doesn't list, are the KDB's only and counted);
# - every slang signal, with the same shape: width, msb/lsb and signedness for a packed one, the
#   array's bounds, element width and dimensions for an unpacked one (a signal with neither, a string
#   or a real, is skipped, counted, and at most --max-skipped of them pass);
# - a write for every signal slang's model writes, at each of slang's lines (file and line; a line in
#   the span of a statement slang keeps opaque, a for loop or a system task call; a file of the same
#   name, which may be a copy, when it is the only file of that name in both instances; those lines
#   are counted);
# - the same port aliases (the [port, net] pairs of ports bound to one whole net of the parent, both
#   ways, as DesignAliasPairs makes them for the helper's aliasHints) per instance.
# Signals and writes the KDB has beyond slang's are counted (at most --max-kdb-only signals pass).
#
# Usage: compare.py [--max-skipped N] [--max-kdb-only N] <kdb-model.json> <slang-model.json>
#                   [export summary line [cached model.json, its summary]]
#   The cached export must be the same model, from the cache ("cached": true, no load).
#        compare.py --self-test <kdb-model.json> <slang-model.json>
#   The comparison passes on the pair, and fails on each of its mutations of the KDB model (a gate
#   that can't tell them apart is no gate); no host or seat needed.
import copy
import json
import sys


def slang_writes(inst):
    """{name: {(file, first line, last line)}}: where slang's model writes each signal. An assignment is
    its own line; a statement slang keeps opaque (a for loop, a system task call) spans its lines, and
    the KDB names the assignment inside it, so any KDB line in the span is the same write."""
    files = inst.get("files", [])
    names = {}

    def add(name, loc, span=False):
        if name and not name.startswith("$"):
            where = names.setdefault(name, set())
            if loc and 0 <= loc[0] < len(files):
                last = loc[3] if span and len(loc) > 3 and loc[3] >= loc[1] else loc[1]
                where.add((files[loc[0]], loc[1], last))

    def walk(b):
        if isinstance(b, dict):
            if b.get("k") == "asgn" and isinstance(b.get("lhs"), dict):
                add(b["lhs"].get("name"), b.get("loc"))
            if b.get("k") == "opaque":
                for w in b.get("writes", []):
                    add(w["name"], b.get("loc"), span=True)
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


def kdb_lines(inst, name):
    files = inst.get("files", [])
    return {(files[w["loc"][0]], w["loc"][1]) for w in inst.get("writes", {}).get(name, [])
            if w.get("loc") and 0 <= w["loc"][0] < len(files)}


def base(path):
    return path.rsplit("/", 1)[-1]


def same_file(kdb_file, slang_file, kdb_files=None, slang_files=None):
    """"path" when the KDB's file is slang's: VCS names files as it read them (absolute), slang as its
    file list did (often relative). "name" for a copy of it (bigwave compiled picorv32.v from
    another folder than slang): the same file name, when it is the only one of that name among the
    instance's files in both models. None otherwise."""
    if kdb_file == slang_file or kdb_file.endswith("/" + slang_file.lstrip("./")):
        return "path"
    name = base(slang_file)
    if base(kdb_file) != name:
        return None
    if kdb_files is not None and sum(1 for f in kdb_files if base(f) == name) != 1:
        return None
    if slang_files is not None and sum(1 for f in slang_files if base(f) == name) != 1:
        return None
    return "name"


def alias_pairs(path, inst):
    """The instance's port aliases as DesignAliasPairs makes them: a port bound to one whole net of
    its parent, of the same width -> (port signal, net) both ways."""
    out = set()
    parent = inst.get("parent")
    if not parent:
        return out
    for port in inst.get("ports", []):
        c = port.get("conn")
        if not isinstance(c, dict):
            continue
        leaves, width = c.get("leaves") or [], port.get("width")
        if len(leaves) != 1 or c.get("src") != leaves[0] or not isinstance(width, int) or width <= 0 or c.get("width") != width:
            continue
        inner, outer = path + "." + (port.get("internal") or port["name"]), parent + "." + leaves[0]
        out |= {(inner, outer), (outer, inner)}
    return out


def shape(sig):
    """A signal's shape, or None for one with neither a width nor an array (a string, a real)."""
    a = sig.get("array")
    if a:
        return ("array", a.get("lo"), a.get("hi"), a.get("elemWidth"), a.get("dims", 1))
    if not sig.get("width"):
        return None
    return ("packed", sig.get("width"), sig.get("msb"), sig.get("lsb"), bool(sig.get("signed")))


def children(inst):
    return sorted((c.get("path"), c.get("module")) for c in inst.get("children", []))


def ports(inst):
    """An instance's ports but its interface ports (the KDB marks them; slang's model lists none)."""
    return sorted((p.get("name"), p.get("dir"), p.get("width")) for p in inst.get("ports", []) if not p.get("interface"))


def compare(kdb, slang, max_skipped=1, max_kdb_only=None):
    """(report lines, failures)."""
    out, failures, examples = [], [], []
    ki, si = set(kdb["instances"]), set(slang["instances"])
    out.append(f"instances: kdb {len(ki)}, slang {len(si)}, only kdb {len(ki - si)}, only slang {len(si - ki)}")
    if sorted(kdb["tops"]) != sorted(slang["tops"]):
        failures.append(f"tops {kdb['tops']} != {slang['tops']}")
    if ki != si:
        failures.append(f"instances differ: only kdb {sorted(ki - si)[:3]}, only slang {sorted(si - ki)[:3]}")
    n = {k: 0 for k in ("signals", "missing", "shape", "skipped", "kdbOnly", "tree", "ports", "written",
                        "unwritten", "lines", "lineMissing", "kdbOnlyWrites", "interfacePorts", "byName",
                        "aliases", "aliasDiffs")}
    skipped = []

    def example(text):
        if len(examples) < 40:
            examples.append(text)

    for path in sorted(ki & si):
        k, s = kdb["instances"][path], slang["instances"][path]
        for field, get in (("module", lambda m: m.get("module")), ("parent", lambda m: m.get("parent")), ("children", children)):
            if get(k) != get(s):
                n["tree"] += 1
                example(f"{field} {path}: kdb {get(k)} slang {get(s)}")
        n["interfacePorts"] += sum(1 for p in k.get("ports", []) if p.get("interface"))
        ka, sa = alias_pairs(path, k), alias_pairs(path, s)
        n["aliases"] += len(sa)
        if ka != sa:
            n["aliasDiffs"] += 1
            example(f"aliases {path}: kdb only {sorted(ka - sa)[:2]} slang only {sorted(sa - ka)[:2]}")
        if ports(k) != ports(s):
            n["ports"] += 1
            example(f"ports {path}: kdb {sorted(set(ports(k)) - set(ports(s)))[:3]} slang {sorted(set(ports(s)) - set(ports(k)))[:3]}")
        ks = k.get("signals", {})
        for name, sig in s["signals"].items():
            n["signals"] += 1
            got = ks.get(name)
            if got is None:
                n["missing"] += 1
                example(f"missing {path}.{name}")
                continue
            if shape(sig) is None:
                n["skipped"] += 1
                skipped.append(f"{path}.{name}")
                continue
            if shape(got) != shape(sig):
                n["shape"] += 1
                example(f"shape {path}.{name}: kdb {shape(got)} slang {shape(sig)}")
        n["kdbOnly"] += len(set(ks) - set(s["signals"]))
        writes = slang_writes(s)
        for name, lines in writes.items():
            n["written"] += 1
            if name not in k.get("writes", {}):
                n["unwritten"] += 1
                example(f"no write {path}.{name}")
                continue
            have = kdb_lines(k, name)
            for f, first, last in lines:
                n["lines"] += 1
                how = [same_file(kf, f, k.get("files", []), s.get("files", [])) for kf, kl in have if first <= kl <= last]
                if "path" in how:
                    continue
                if "name" in how:
                    n["byName"] += 1
                else:
                    n["lineMissing"] += 1
                    example(f"no write line {path}.{name} {f}:{first}" + (f"-{last}" if last != first else ""))
        n["kdbOnlyWrites"] += len(set(k.get("writes", {})) - set(writes))
    out.append(f"signals: {n['signals']}, missing in kdb {n['missing']}, other shape {n['shape']}, "
               f"skipped (no width or array) {n['skipped']}{' ' + ', '.join(skipped[:3]) if skipped else ''}; kdb only {n['kdbOnly']}")
    out.append(f"instances with another module, parent or children {n['tree']}, other ports {n['ports']}; kdb interface ports {n['interfacePorts']}")
    out.append(f"written in slang: {n['written']}, without a kdb write {n['unwritten']}; slang write lines {n['lines']}, "
               f"not among the kdb's {n['lineMissing']} ({n['byName']} matched by file name only); written in the kdb only {n['kdbOnlyWrites']}")
    out.append(f"port aliases in slang: {n['aliases']}; instances with other aliases in the kdb {n['aliasDiffs']}")
    for key, what in (("missing", "signals missing"), ("shape", "signals of another shape"), ("tree", "instances of another module, parent or children"),
                      ("ports", "instances with other ports"), ("unwritten", "slang-written signals without a kdb write"),
                      ("lineMissing", "slang write lines not among the kdb's"), ("aliasDiffs", "instances with other port aliases")):
        if n[key]:
            failures.append(f"{n[key]} {what}")
    if n["skipped"] > max_skipped:
        failures.append(f"{n['skipped']} signals skipped (no width or array), more than {max_skipped}")
    if max_kdb_only is not None and n["kdbOnly"] > max_kdb_only:
        failures.append(f"{n['kdbOnly']} kdb-only signals, more than {max_kdb_only}")
    out.extend("  " + e for e in examples[:12])
    return out, failures, n


def mutations(kdb, slang, counts):
    """(name, mutate(model)) for the self-test: each must make the comparison fail."""
    def sigs(m):
        for path in sorted(m["instances"]):
            for name, sig in m["instances"][path]["signals"].items():
                yield path, name, sig

    def first(m, ok):
        return next((s for _, _, s in sigs(m) if ok(s)), None)

    def drop_leaf(m):
        leaf = next(p for p in sorted(m["instances"]) if not m["instances"][p].get("children") and m["instances"][p].get("parent"))
        del m["instances"][leaf]

    def wider(m):
        s = first(m, lambda s: s.get("width") and not s.get("array"))
        s["width"] += 1

    def drop_writes(count):
        # Writes slang has too (a kdb-only one would not count).
        def f(m):
            gone = 0
            for path in sorted(m["instances"]):
                w = m["instances"][path].get("writes", {})
                theirs = slang_writes(slang["instances"].get(path, {}))
                for name in sorted(set(w) & set(theirs)):
                    if gone < count:
                        del w[name]
                        gone += 1
        return f

    def move_lines(m):
        for inst in m["instances"].values():
            for entries in inst.get("writes", {}).values():
                for e in entries:
                    e["loc"] = [e["loc"][0], 99999, 0]

    def arrays(f):
        def g(m):
            for _, _, s in sigs(m):
                if s.get("array"):
                    f(s)
        return g

    def all_ports(f):
        def g(m):
            for inst in m["instances"].values():
                f(inst)
        return g

    def wrong_ports(inst):
        for p in inst.get("ports", []):
            p["width"] = (p.get("width") or 0) + 1
            p["dir"] = "InOut" if p.get("dir") != "InOut" else "In"

    def wipe(field, value):
        def g(m):
            for inst in m["instances"].values():
                inst[field] = copy.deepcopy(value)
        return g

    def unsign(m):
        for _, _, s in sigs(m):
            s.pop("signed", None)

    def dims(m):
        s = first(m, lambda s: s.get("array"))
        s["array"]["dims"] = s["array"].get("dims", 1) + 1

    def conns(f):
        def g(m):
            for inst in m["instances"].values():
                for port in inst.get("ports", []):
                    if port.get("conn"):
                        f(port)
        return g

    def retarget(port):
        c = port["conn"]
        if c.get("leaves"):
            c["leaves"] = [c["leaves"][0] + "_elsewhere"] + c["leaves"][1:]
            c["src"] = c["leaves"][0]

    def copies(m):
        # Every write moved to a file of the same name in another folder (the instance then has two).
        for inst in m["instances"].values():
            files = inst.get("files", [])
            moved = {}
            for i, f in enumerate(list(files)):
                moved[i] = len(files)
                files.append("/elsewhere/copy/" + f.rsplit("/", 1)[-1])
            for entries in inst.get("writes", {}).values():
                for e in entries:
                    if e.get("loc") and e["loc"][0] in moved:
                        e["loc"] = [moved[e["loc"][0]]] + list(e["loc"][1:])

    def extra(m):
        for inst in m["instances"].values():
            inst["signals"]["zz_kdb_only"] = {"width": 1, "kind": "net", "msb": 0, "lsb": 0}

    out = [
        ("drop one leaf instance", drop_leaf),
        ("width+1 on one packed signal", wider),
        ("drop one write", drop_writes(1)),
        ("drop 1% of the writes", drop_writes(max(1, counts["written"] // 100))),
        ("every write moved to line 99999", move_lines),
        ("unpacked arrays to {lo 0, hi 0, elemWidth 1}", arrays(lambda s: s.__setitem__("array", {"lo": 0, "hi": 0, "elemWidth": 1}))),
        ("arrays to scalars of width 0", arrays(lambda s: s.pop("array"))),
        ("every port's width and direction wrong", all_ports(wrong_ports)),
        ("no ports at all", wipe("ports", [])),
        ("children wiped", wipe("children", [])),
        ("parent wiped", wipe("parent", None)),
        ("module wiped", wipe("module", "")),
        ("an array's dims changed", dims),
        ("an extra kdb-only signal in every instance", extra),
        ("every port connection dropped", conns(lambda p: p.pop("conn"))),
        ("every port connection retargeted to another net", conns(retarget)),
        ("every write moved to a same-name file in another folder", copies),
    ]
    if any(s.get("signed") for _, _, s in sigs(kdb)):
        out.append(("signed wiped", unsign))
    return out


def self_test(kdb, slang):
    lines, failures, counts = compare(kdb, slang)
    print("\n".join(lines))
    ok = not failures
    print(("ok   " if ok else "FAIL ") + "the unmutated pair passes" + ("" if ok else ": " + "; ".join(failures)))
    for name, mutate in mutations(kdb, slang, counts):
        m = copy.deepcopy(kdb)
        mutate(m)
        _, got, _ = compare(m, slang, max_kdb_only=counts["kdbOnly"])
        caught = bool(got)
        ok = ok and caught
        print(("ok   " if caught else "FAIL ") + f"mutation caught: {name}" + (f" ({got[0]})" if caught else ""))
    print("TRACE KDB SELF-TEST " + ("PASSED" if ok else "FAILED"))
    return ok


def main():
    args = sys.argv[1:]
    opts = {"max_skipped": 1, "max_kdb_only": None}
    while args and args[0] in ("--max-skipped", "--max-kdb-only"):
        opts[args[0][2:].replace("-", "_")] = int(args[1])
        args = args[2:]
    if args and args[0] == "--self-test":
        sys.exit(0 if self_test(json.load(open(args[1])), json.load(open(args[2]))) else 1)
    failures = []
    try:
        kdb = json.load(open(args[0]))
    except ValueError:
        print("FAIL no model exported: " + (args[2] if len(args) > 2 else ""))
        print("TRACE KDB CHECKS FAILED")
        sys.exit(1)
    slang = json.load(open(args[1]))
    print("slang model", args[1])
    if len(args) > 2:
        print("export", args[2])
    if len(args) > 4:
        print("again ", args[4])
        try:
            again, said = json.load(open(args[3])), json.loads(args[4] or "{}")
        except ValueError:
            again, said = None, {}
        if again != kdb:
            failures.append("the second export is not the same model")
        if said.get("cached") is not True or "load" in said.get("seconds", {}):
            failures.append("the second export did not come from the cache (or loaded the KDB)")
    lines, found, _ = compare(kdb, slang, **opts)
    print("\n".join(lines))
    failures += found
    for f in failures:
        print("FAIL " + f)
    print("TRACE KDB CHECKS " + ("FAILED" if failures else "PASSED"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
