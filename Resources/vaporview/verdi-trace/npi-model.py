#!/usr/bin/env python3
# cmux driver tracing: the design model from a VCS KDB (simv.daidir/kdb.elab++) through the host's
# Verdi Python NPI (ours; it runs the user's installed Verdi and ships nothing of it). It writes the
# model cmux-sv-model's `--once '*'` writes ({"tops", "instances": {path: model}}), from what VCS
# elaborated: the instance tree, each instance's ports and signals (widths, ranges, arrays), and
# where each signal is written (continuous assigns and procedural assignments: file and line), each
# instance's parameters and localparams (their elaborated values), and when the KDB was compiled
# (`"compiled"`: its newest file's time, ms since 1970; none for a KDB with no files) and the
# compile's parameter overrides (`"overrides"`: -pvalue/-parameters/-gv/-gfile options from the
# daidir's vcs_rebuild, VCS's record of the compile command, and the -f files it names; none when
# that can't be read: NPI reports an overridden parameter's declared value), as
# `"source": "kdb"` models without statement trees (`"partial": true`: the engine's statements still
# come from slang). NPI holds a Verdi licence seat from load_design to its end: everything is read
# first, NPI is ended, then the JSON is written, so the seat is held for the load and the walk only.
# Usage: npi-model.py <simv.daidir> <out.json>; prints one JSON line: {"ok", "seconds": {...},
# "instances", "signals", "error"?}.
import json
import os
import shlex
import sys
import time

MODEL_VERSION = 1
# Instances walked at most (a bound for a runaway hierarchy; the model says when it was cut).
MAX_INSTANCES = 200000
INSTANCE_TYPES = ("npiModule", "npiInterface", "npiProgram")
# The inner statements of a statement, by its kind (any other kind: all of them).
ALL_INNER = ("stmt_handles", "stmt_handle", "else_stmt_handle", "case_item_handles", "for_init_stmt_handles", "for_inc_stmt_handles")
INNER = {
    "npiBegin": ("stmt_handles",), "npiNamedBegin": ("stmt_handles",),
    "npiFork": ("stmt_handles",), "npiNamedFork": ("stmt_handles",),
    "npiIf": ("stmt_handle",), "npiIfElse": ("stmt_handle", "else_stmt_handle"),
    "npiCase": ("case_item_handles",), "npiCaseItem": ("stmt_handle",),
    "npiFor": ("for_init_stmt_handles", "for_inc_stmt_handles", "stmt_handle"),
    "npiEventControl": ("stmt_handle",), "npiDelayControl": ("stmt_handle",),
    "npiWhile": ("stmt_handle",), "npiDoWhile": ("stmt_handle",), "npiRepeat": ("stmt_handle",),
    "npiForever": ("stmt_handle",), "npiForeachStmt": ("stmt_handle",),
}


def fail(code, message, seconds=None):
    print(json.dumps({"ok": False, "error": code, "message": str(message)[:400], "seconds": seconds or {}}), flush=True)
    sys.exit(0)


def main():
    if len(sys.argv) != 3:
        fail("usage", "npi-model.py <simv.daidir> <out.json>")
    daidir, out = sys.argv[1], sys.argv[2]
    if not os.path.isdir(os.path.join(daidir, "kdb.elab++")):
        fail("noKDB", daidir)
    home = os.environ.get("VERDI_HOME")
    if not home:
        fail("noVerdi", "VERDI_HOME is not set")
    sys.path.insert(0, os.path.join(home, "share", "NPI", "python"))
    seconds = {}
    t0 = time.time()
    try:
        from pynpi import npisys, lang
        try:
            from pynpi import lang_l1
        except Exception:  # noqa: BLE001
            lang_l1 = None
    except Exception as error:  # noqa: BLE001 (any import failure: no usable NPI)
        fail("noVerdi", error)
    if not npisys.init([sys.argv[0]]):
        fail("start", "npisys.init failed")
    seconds["init"] = round(time.time() - t0, 3)
    t1 = time.time()
    if not npisys.load_design(["-dbdir", daidir]):
        npisys.end()
        fail("licence", "load_design failed (no licence seat, or an unreadable KDB)", seconds)
    seconds["load"] = round(time.time() - t1, 3)
    t2 = time.time()
    try:
        model = Walker(lang, lang_l1).walk()
    except Exception as error:  # noqa: BLE001
        npisys.end()
        fail("walk", repr(error), seconds)
    npisys.end()
    compiled = compiled_at(daidir)
    if compiled is not None:
        model["compiled"] = compiled
    found = overrides(daidir)
    if found is not None:
        model["overrides"] = found
    seconds["walk"] = round(time.time() - t2, 3)
    t3 = time.time()
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(model, f, separators=(",", ":"))
    os.replace(tmp, out)
    seconds["write"] = round(time.time() - t3, 3)
    signals = sum(len(m["signals"]) for m in model["instances"].values())
    print(json.dumps({"ok": True, "seconds": seconds, "instances": len(model["instances"]), "signals": signals,
                      "cut": model.get("cut", False)}), flush=True)


def compiled_at(daidir):
    """The newest modification time of the KDB's files (ms since 1970): when VCS compiled it; None
    when it has none to tell."""
    newest = None
    for root, _, names in os.walk(os.path.join(daidir, "kdb.elab++")):
        for name in names:
            try:
                mtime = os.stat(os.path.join(root, name)).st_mtime
            except OSError:
                continue
            newest = mtime if newest is None else max(newest, mtime)
    return None if newest is None else int(newest * 1000)


# VCS options that set a parameter's value from outside the source (with the file they take, if any).
# Any other token naming pvalue/parameters/gfile counts too: the scan fails toward "overridden".
# defparam and #(.P(v)) are not compile options: they are in the source, which slang elaborates too.
OVERRIDE_WITH_FILE = ("-parameters", "-gfile")
OVERRIDE_EXACT = ("-gv",)
OVERRIDE_WORDS = ("pvalue", "parameters", "gfile")
FILE_LISTS = ("-f", "-F", "-file")


def unresolved(text):
    """True when shell text has an expansion the scan can't resolve ($VAR, ${...}, $(...), `...`)."""
    return "$" in text or "`" in text


def overrides(daidir):
    """The compile's parameter override options, from the daidir's vcs_rebuild (the vcs command VCS
    recorded) and the -f files it names (relative to the daidir's folder, where VCS ran by default).
    Fails closed: None (unknown) when the command or one of its files can't be read, when it holds
    an expansion the scan can't resolve, or when no vcs command is found in it."""
    try:
        with open(os.path.join(daidir, "vcs_rebuild")) as f:
            lines = [line for line in f.read().splitlines() if line.strip() and not line.lstrip().startswith("#")]
        if unresolved("\n".join(lines)):
            return None
        args = shlex.split(" ".join(lines))
    except (OSError, ValueError):
        return None
    at = next((i for i, a in enumerate(args) if os.path.basename(a) == "vcs"), None)
    if at is None:
        return None
    base = os.path.dirname(os.path.abspath(daidir.rstrip("/")))
    found = []
    return found if scan(args[at + 1:], base, found, 0) else None


def is_override(arg):
    return arg in OVERRIDE_EXACT or arg.startswith(tuple(o + "+" for o in OVERRIDE_EXACT)) \
        or any(w in arg.lower() for w in OVERRIDE_WORDS)


def scan(args, base, found, depth):
    """Adds the override options in `args` to `found`; False when a file list can't be read or holds
    an expansion the scan can't resolve."""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in FILE_LISTS:
            if i + 1 >= len(args) or depth > 8:
                return False
            path = args[i + 1] if os.path.isabs(args[i + 1]) else os.path.join(base, args[i + 1])
            try:
                with open(path) as f:
                    text = "\n".join(line.split("//")[0] for line in f.read().splitlines())
                if unresolved(text):
                    return False
                inner = shlex.split(text, comments=True)
            except (OSError, ValueError):
                return False
            # Paths in a -F file are relative to it; in a -f file, to where VCS ran.
            if not scan(inner, os.path.dirname(path) if arg == "-F" else base, found, depth + 1):
                return False
            i += 2
            continue
        if arg in OVERRIDE_WITH_FILE:
            found.append(arg + (" " + args[i + 1] if i + 1 < len(args) else ""))
            i += 2
            continue
        if is_override(arg):
            found.append(arg)
        i += 1
    return True


def call(handle, method, *args):
    """handle.method(*args), or None when the handle has no such property (NPI raises or returns junk)."""
    f = getattr(handle, method, None)
    if f is None:
        return None
    try:
        return f(*args)
    except Exception:  # noqa: BLE001
        return None


class Walker:
    def __init__(self, lang, l1=None):
        self.lang = lang
        self.l1 = l1
        self.files = {}
        self.instances = {}
        self.cut = False

    # A file's index in its instance's `files`, as cmux-sv-model numbers them.
    def loc(self, files, handle):
        name = call(handle, "file")
        line = call(handle, "line_no")
        if not name or not isinstance(line, int) or line <= 0:
            return None
        if name not in files:
            files.append(name)
        return [files.index(name), line, 0]

    def walk(self):
        tops = []
        for top in self.lang.get_top_inst_list() or []:
            path = call(top, "full_name") or call(top, "name")
            # Packages are listed with the tops; they are no instances.
            if not path or str(call(top, "type") or "") not in INSTANCE_TYPES:
                continue
            tops.append(path)
            self.instance(top, path, None)
        model = {"tops": sorted(tops), "instances": self.instances, "source": "kdb"}
        if self.cut:
            model["cut"] = True
        return model

    def instance(self, handle, path, parent):
        if len(self.instances) >= MAX_INSTANCES:
            self.cut = True
            return
        files = []
        m = {
            "version": MODEL_VERSION, "source": "kdb", "partial": True, "path": path,
            "module": call(handle, "def_name") or "", "parent": parent,
            "ports": [], "signals": {}, "assigns": [], "procs": [], "children": [], "files": files, "writes": {},
            "params": {},
        }
        where = self.loc(files, handle)
        if where:
            m["loc"] = where
        self.instances[path] = m
        for port in call(handle, "port_handles") or []:
            high = call(port, "high_conn_handle")
            entry = {"name": call(port, "name"), "dir": direction(call(port, "direction")), "width": call(port, "size")}
            if entry["dir"] is None and str(call(high, "type") or "") in ("npiRefObj", "npiInterface"):
                # An interface port (slang's model lists none).
                entry["interface"] = True
            conn = connection(high, parent)
            if conn:
                entry["conn"] = conn
            m["ports"].append(entry)
        # Parameters and localparams of the instance itself (not its generate blocks', as slang's
        # model): numbers as numbers, anything else as its text.
        for param in call(handle, "parameter_handles") or []:
            name = call(param, "name")
            if not name:
                continue
            value = call(param, "value")
            m["params"][name] = value if isinstance(value, (int, float)) and not isinstance(value, bool) else str(value)
        self.scope(handle, m, files, "", path)
        for entry in m["ports"]:
            # An unpacked-array port: NPI's size is its element count; width 0 as its signal's (and slang's).
            if (m["signals"].get(entry["name"]) or {}).get("array"):
                entry["width"] = 0

    # The signals, writes and child instances of a scope: the instance itself (prefix "") or a
    # generate block inside it (prefix "g_blk." / "g[0].": its signals are the instance's, dotted).
    def scope(self, handle, m, files, prefix, path):
        for kind, method in (("net", "net_handles"), ("var", "variables_handles"), ("net", "array_net_handles")):
            for sig in call(handle, method) or []:
                name = call(sig, "name")
                if name:
                    m["signals"][prefix + name] = self.signal(sig, kind, files)
        for assign in call(handle, "cont_assign_handles") or []:
            self.write(m, files, prefix, call(assign, "lhs_handle"), assign, "assign")
        for proc in call(handle, "process_handles") or []:
            self.statements(m, files, prefix, call(proc, "stmt_handle"), proc)
        # NPI lists child instances, interface instances and generate blocks as the scope's internal scopes.
        for inner in call(handle, "internal_scope_handles") or []:
            name = call(inner, "name")
            typ = str(call(inner, "type") or "")
            if not name:
                continue
            if typ in INSTANCE_TYPES:
                child_path = call(inner, "full_name") or (path + "." + prefix + name)
                if child_path in self.instances:
                    continue
                m["children"].append({"path": child_path, "name": prefix + name, "module": call(inner, "def_name") or ""})
                self.instance(inner, child_path, m["path"])
            elif typ == "npiGenScope":
                self.scope(inner, m, files, prefix + name + ".", path)

    def signal(self, sig, kind, files):
        out = {"width": 0, "kind": kind}
        spec = call(sig, "typespec_handle")
        typ = str(call(sig, "type") or "")
        if typ.startswith("npiArray") and spec is not None:
            # An unpacked array: its first unpacked range; elements of the element type's width.
            dims = ranges(spec)
            elem = call(spec, "elem_typespec_handle")
            if dims:
                lo, hi = dims[0]
                out["array"] = {"lo": min(lo, hi), "hi": max(lo, hi), "elemWidth": self.bits(elem) or span(ranges(elem)) if elem is not None else 1}
                if len(dims) > 1:
                    out["array"]["dims"] = len(dims)
        else:
            # The elaborated type's bits (a type parameter's actual, a struct's); the handle's size is
            # the declaration's (a type parameter's default) there.
            size = self.bits(spec) if spec is not None else None
            if not size:
                size = call(sig, "size")
            out["width"] = size if isinstance(size, int) and size > 0 else 0
            dims = ranges(spec) if spec is not None else []
            if len(dims) == 1 and span(dims) == out["width"]:
                out["msb"], out["lsb"] = dims[0]
            elif out["width"]:
                # A scalar, a struct, several packed ranges: [width-1:0], as cmux-sv-model gives them.
                out["msb"], out["lsb"] = out["width"] - 1, 0
        # The variable's own signedness, else its type's (an `integer`'s is the typespec's).
        signed = call(sig, "signed")
        if signed not in (0, 1) and spec is not None:
            signed = call(spec, "signed")
        if signed == 1:
            out["signed"] = True
        where = self.loc(files, sig)
        if where:
            out["loc"] = where
        return out

    def bits(self, spec):
        """A typespec's elaborated bits (NPI's typespec size), or None."""
        if self.l1 is None or spec is None:
            return None
        try:
            n = self.l1.get_typespec_size(spec.cps_obj)
        except Exception:  # noqa: BLE001
            return None
        return n if isinstance(n, int) and n > 0 else None

    # Where a signal is written: {name: [{kind, loc}]} (the whole target's name, dotted in a generate block).
    def write(self, m, files, prefix, lhs, stmt, kind):
        handle = target(lhs)
        where = self.loc(files, stmt)
        if handle is None or not where:
            return
        # The target's name in the instance: from its full name (a generate block's statement may
        # write the instance's own signal, or a block's `g_blk.x`), else the block's prefix + name.
        full = call(handle, "full_name") or ""
        name = full[len(m["path"]) + 1:] if full.startswith(m["path"] + ".") else prefix + (call(handle, "name") or "")
        if not name or name == prefix:
            return
        entry = {"kind": kind, "loc": where}
        listed = m["writes"].setdefault(name, [])
        if entry not in listed:
            listed.append(entry)

    def statements(self, m, files, prefix, stmt, proc, depth=0):
        if stmt is None or depth > 64:
            return
        typ = str(call(stmt, "type") or "")
        if typ in ("npiAssignment", "Assignment"):
            self.write(m, files, prefix, call(stmt, "lhs_handle"), stmt, "nb" if call(stmt, "blocking") == 0 else "proc")
            return
        if typ == "npiSysTaskCall":
            # $readmemh/$readmemb(file, mem, ...) write their second argument.
            args = call(stmt, "argument_handles") or []
            if call(stmt, "name") in ("$readmemh", "$readmemb") and len(args) > 1:
                self.write(m, files, prefix, args[1], stmt, "call")
            return
        # Each NPI call costs; a known statement kind asks for its own inner statements only.
        for method in INNER.get(typ, ALL_INNER):
            got = call(stmt, method)
            for inner in (got if isinstance(got, list) else [got] if got is not None else []):
                if inner is not stmt:
                    self.statements(m, files, prefix, inner, proc, depth + 1)


def target(lhs):
    """The signal (handle) an lvalue writes: `q` of q, q[i], q[i].f, q[7:0] (a select's or member's parent, up to
    the variable or net); None for a concatenation and the like."""
    for _ in range(16):
        if lhs is None:
            return None
        parent = call(lhs, "parent_handle")
        if parent is None or str(call(parent, "type") or "") in INSTANCE_TYPES + ("npiGenScope",):
            name = call(lhs, "name")
            return lhs if name and "[" not in name and "." not in name else None
        lhs = parent
    return None


def connection(high, parent):
    """A port's connection in the parent when it is one whole net or variable of the parent (`.clk(clk)`):
    {"leaves": [name], "src": name, "width"}, as cmux-sv-model gives it; None for a select, a concatenation,
    an expression, a constant or an interface."""
    if high is None or not parent:
        return None
    typ = str(call(high, "type") or "")
    if not (typ.startswith("npiNet") or typ.endswith("Var") or typ in ("npiReg",)) or typ in ("npiNetBit", "npiVarBit"):
        return None
    full = call(high, "full_name") or ""
    if not full.startswith(parent + "."):
        return None
    name = full[len(parent) + 1:]
    if not name or "[" in name:
        return None
    width = call(high, "size")
    return {"leaves": [name], "src": name, "width": width if isinstance(width, int) and width > 0 else 0}


def ranges(spec):
    """[(left, right)] of a typespec's ranges (NPI's npiRange handles), the constant ones."""
    out = []
    for r in call(spec, "range_handles") or []:
        left, right = int_of(call(r, "left_range_handle")), int_of(call(r, "right_range_handle"))
        if left is None or right is None:
            return out
        out.append((left, right))
    return out


def span(dims):
    """The bits of a packed type with these ranges (1 without any: a scalar)."""
    bits = 1
    for left, right in dims:
        bits *= abs(left - right) + 1
    return bits


def int_of(handle):
    if handle is None:
        return None
    v = call(handle, "int_value")
    return v if isinstance(v, int) and v > -2 ** 31 else None


def direction(d):
    text = str(d or "")
    return "In" if "Input" in text else "Out" if "Output" in text else "InOut" if "Inout" in text else None


if __name__ == "__main__":
    main()
