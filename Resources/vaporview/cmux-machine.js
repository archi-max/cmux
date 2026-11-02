// cmux's waveform debugger, machine state at the cursor (status/asm-breakpoints-design.md §1–§3):
// the core's commit stream found in the dump (cmux-machine-core.js), replayed into architectural
// registers and memory before the current commit, shown in a Machine section under the netlist
// pane's Breakpoints and Watches: Registers, Memory (x/), CSRs, History and a gdb console. The
// debugger's Evaluate, watches and conditions take $a0 / $x5 / $pc / $mem32(addr) and gdb commands;
// F10 / Shift-F10 step by commit in Instruction mode.
//
// window.cmuxWaveform.machine (cmux and the checks call it):
//   state() -> { source, count, k, mode, instructionMode, building, error, tab, ... }
//   sources() -> the commit streams found (ranked), and useSource({ index }) / forget()
//   pick({ role, path }) the user's own mapping (Use as Commit ▸ …); build() -> state()
//   setImage({ path, segments: [{ addr, memsz, bytes (base64) }], symbols }) the ELF's PT_LOAD image
//   show({ tab }) / hide() / toggle(), setTab({ tab }), setMode({ mode: 'auto' | 'cycle' | 'instruction' })
//   stepCommit({ by }), goToCommit({ k }), gdb({ text }) -> { lines, tab, error }
//   registers(), csrs(), memoryRows(), history(), console(), rowAction({ action, loc })
(function () {
  const waveform = window.cmuxWaveform;
  const host = waveform.host;
  const C = window.cmuxMachineCore;
  const X = window.cmuxExpr;
  const S = () => waveform.strings || {};
  const disasm = (word, pc) => {
    const d = window.cmuxRiscvDisasm;
    try { return d ? C.withLink(d.disassembleRiscv(word >>> 0, pc === undefined || pc === null ? {} : { pc: Number(pc) })) : null; } catch (error) { return null; }
  };

  // A role may hold this many changes; all roles together this many (FSDB v1's budget, §2).
  const MAX_ROLE_CHANGES = 4000000;
  const MAX_TOTAL_CHANGES = 12000000;
  const MAX_SCOPE_DEPTH = 3;
  // Built commit tables by dump identity (C.tableKey), newest last; kept across reloads of the page's dump.
  const TABLE_CACHE_SIZE = 2;
  const tableCache = new Map();
  const MAX_SCOPES = 400;
  const HISTORY = 20;
  const CONSOLE_LINES = 200;

  const st = {
    backend: null,         // what the scan and index were made for
    sources: null,         // detect()'s ranking for st.backend
    sourceIndex: 0,        // the one used (index into sources)
    picks: null,           // the user's own roles: { role: { path, width } } (session; §1 rule 1)
    vars: new Map(),       // JSON path -> netlist var, from the scan
    index: null,           // StateIndex
    edges: null,
    building: null,        // the build in progress (a promise)
    error: null,           // why there is no index: 'noSource' | 'noClock' | 'tooManyChanges' | 'budget' | 'offer'
    errorDetail: '',
    image: null,           // { path, segments, symbols }
    k: null, kTime: null,  // the current commit and the posedge it was set for
    prevK: null,           // the commit before the last move (light "changed")
    strong: null,          // [k0, k1): the commits just stepped over (strong "changed")
    mode: 'auto',
    focused: false,
    shown: false,
    tab: 'registers',
    mem: { expr: '$sp', unit: 'w', count: 32, fmt: 'x' },
    seq: { query: '', result: null, land: 'end' },  // the Sequences tab (§3A)
    console: [],
    gdbLast: { fmt: 'x', unit: 'w', addr: null },
    gdbHistory: 0,
    buildMs: null,
  };

  // ---- the scan: scopes under the tops, three levels down, at most 400 ----
  // A var's name as the dump has it; an element named valid[0] keeps its index.
  function varName(v) { return String(v.name); }

  async function scan() {
    const tops = host.doc.netlist.filter((t) => t.kind === 'scope');
    const queue = tops.map((t) => ({ item: t, path: [t.name], depth: 0 }));
    const scopes = [];
    st.vars = new Map();
    while (queue.length && scopes.length < MAX_SCOPES) {
      const { item, path, depth } = queue.shift();
      let children;
      try { children = await host.getChildren(item); } catch (error) { host.log(error); continue; }
      const vars = [];
      for (const c of children) {
        if (c.kind === 'var') {
          const name = varName(c);
          vars.push({ name, width: Number(c.width) || 1 });
          st.vars.set(JSON.stringify(path.concat([name])), c);
        } else if (c.kind === 'scope' && c.array) {
          // cmux: an FSDB array node: its elements are this scope's vars already.
        } else if (c.kind === 'scope') {
          // wellen's array element scope (`order` holding `[0]`, `[1]`) reads as order[0], order[1] here.
          let elements = null;
          if (C.mayHoldElements(c.name)) {
            try { elements = C.elementVars(c.name, await host.getChildren(c)); } catch (error) { host.log(error); }
          }
          if (elements) {
            for (const e of elements) {
              vars.push({ name: e.name, width: e.width });
              st.vars.set(JSON.stringify(path.concat([e.name])), e.item);
            }
          } else if (depth < MAX_SCOPE_DEPTH) {
            queue.push({ item: c, path: path.concat([c.name]), depth: depth + 1 });
          }
        }
      }
      if (vars.length) { scopes.push({ path, depth, vars }); }
    }
    return C.detect(scopes);
  }

  async function sources() {
    const backend = host.currentBackend;
    if (!backend || !host.doc.metadata) { return []; }
    if (st.backend !== backend || !st.sources) {
      st.sources = await scan();
      st.backend = backend;
    }
    return st.sources;
  }

  function currentSource() {
    if (st.picks) {
      const widths = {};
      for (const [key, v] of st.vars) { widths[key] = Number(v.width) || 1; }
      return C.manualSource(st.picks, widths);
    }
    const list = (st.sources || []).filter((s) => s.family !== 'offer');
    return list[Math.min(st.sourceIndex, list.length - 1)] || null;
  }

  // ---- building the index ----
  async function varFor(path) {
    const key = JSON.stringify(path);
    if (st.vars.has(key)) { return st.vars.get(key); }
    const v = await host.findLinkItem(path, true);
    if (v && v.kind !== 'scope') { st.vars.set(key, v); return v; }
    return null;
  }

  function fail(error, detail) {
    st.error = error;
    st.errorDetail = detail || '';
    if (st.index) { changed('cleared'); }
    st.index = null;
    render();
    return null;
  }

  async function ensureIndex() {
    const backend = host.currentBackend;
    if (!backend || !host.doc.metadata) { return null; }
    // The clock's posedges are the debugger's (a clock change gives a new array): built again for new ones.
    if (st.index && st.backend === backend) {
      const edges = waveform.debugger.edges ? await waveform.debugger.edges().catch(() => null) : st.edges;
      if (edges === st.edges) { return st.index; }
      changed('cleared');
      st.index = null;
    }
    if (st.building && st.buildingFor === backend) { return st.building; }
    st.buildingFor = backend;
    const build = st.building = (async () => {
      try { return await buildIndex(backend); } catch (error) {
        if (error && error.cmuxClosed || host.currentBackend !== backend) { return null; }
        host.log(error);
        return fail('readFailed', String(error && error.message || error));
      } finally {
        if (st.building === build) { st.building = null; }
        render();
      }
    })();
    render();
    return build;
  }

  async function buildIndex(backend) {
    const t0 = Date.now();
    await sources();
    if (host.currentBackend !== backend) { return null; }
    const source = currentSource();
    if (!source) {
      const offer = (st.sources || []).find((s) => s.family === 'offer');
      return fail(offer ? 'offer' : 'noSource', offer ? offer.valid.join('.') + ', ' + offer.pc.join('.') : '');
    }
    const edges = waveform.debugger.edges ? await waveform.debugger.edges() : null;
    if (host.currentBackend !== backend) { return null; }
    if (!edges || !edges.length) { return fail('noClock'); }
    // A dump the page has read already (same file, size, mtime and helper; same mapping and clock):
    // its table again, nothing read. Only with an identity (the FSDB helper's); VCD/FST build fast.
    const clock = waveform.debugger.clockPath ? waveform.debugger.clockPath() : null;
    const key = C.tableKey(host.dumpIdentity ? host.dumpIdentity() : null, source, edges, source.sample === 'preEdge' ? 'preEdge' : 'edge', clock);
    let table = key ? tableCache.get(key) : null;
    st.cacheHit = !!table;
    if (table) {
      tableCache.delete(key);
      tableCache.set(key, table);
      // The columns are the same; the source is this request's (its label, its CSR names).
      table = Object.assign({}, table, { source });
    } else {
      table = await readTable(backend, source, edges);
      if (!table) { return null; }
      if (key) {
        tableCache.set(key, table);
        while (tableCache.size > TABLE_CACHE_SIZE) { tableCache.delete(tableCache.keys().next().value); }
      }
    }
    const index = new C.StateIndex(table, imageOptions());
    if (host.currentBackend !== backend) { return null; }
    st.index = index;
    st.edges = edges;
    st.error = null;
    st.errorDetail = '';
    st.k = null;
    st.kTime = null;
    st.buildMs = Date.now() - t0;
    st.view = null;
    changed('ready');
    host.toNative({ type: 'debugger', event: 'machine', status: 'ready', count: table.count, source: source.label, ms: st.buildMs });
    return index;
  }

  // The source's roles read and sampled at the edges into a commit table, or null (failed or gone: fail() says).
  async function readTable(backend, source, edges) {
    // One read per signal; a packed role's channels are slices of the same changes.
    const byPath = new Map();
    for (const ref of C.mapping(source)) {
      const key = JSON.stringify(ref.path);
      if (!byPath.has(key)) { byPath.set(key, []); }
      byPath.get(key).push(ref);
    }
    const columns = {};
    let total = 0;
    for (const [key, refs] of byPath) {
      const path = JSON.parse(key);
      const v = await varFor(path);
      if (!v) { return fail('signalGone', path.join('.')); }
      const changes = await host.signalChanges(v, MAX_ROLE_CHANGES);
      if (host.currentBackend !== backend) { return null; }
      if (changes === undefined) { return fail('loading'); }
      if (!changes) { return fail('tooManyChanges', path.join('.')); }
      total += changes.length;
      if (total > MAX_TOTAL_CHANGES) { return fail('budget', path.join('.')); }
      const cols = C.sample(changes, edges, Number(v.width) || 1, refs, source.sample === 'preEdge');
      refs.forEach((ref, i) => { columns[ref.role + '/' + ref.channel] = cols[i]; });
    }
    if (host.currentBackend !== backend) { return null; }
    return C.buildTable(source, columns, edges);
  }

  function imageOptions() {
    const img = st.image;
    return img ? { image: img.segments, symbols: img.symbols } : {};
  }

  function decodeBytes(b) {
    if (Array.isArray(b)) { return b; }
    const s = atob(String(b || ''));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) { out[i] = s.charCodeAt(i); }
    return out;
  }

  function setImage(query) {
    const q = query || {};
    const segments = (q.segments || []).map((s) => ({ addr: Number(s.addr), memsz: Number(s.memsz) || 0, bytes: decodeBytes(s.bytes) }));
    st.image = { path: q.path ? String(q.path) : null, segments, symbols: Array.isArray(q.symbols) ? q.symbols : [] };
    // The same commit table, indexed again with the image and symbols (milliseconds; §3.1).
    if (st.index) { st.index = new C.StateIndex(st.index.table, imageOptions()); st.view = null; changed('ready'); }
    render();
    return { segments: segments.length, symbols: st.image.symbols.length, bytes: segments.reduce((n, s) => n + Math.max(s.memsz, s.bytes.length), 0) };
  }

  // ---- the cursor ----
  // The debugger's marker: where it last sent it until the viewer reports otherwise.
  function markerTime() {
    if (waveform.debugger && waveform.debugger.markerTime) { return waveform.debugger.markerTime(); }
    const w = host.viewerContext.webview;
    return w && w.markerTime !== undefined && w.markerTime !== null ? Number(w.markerTime) : null;
  }
  function edgeAt(time) {
    const edges = st.edges;
    if (!edges || time === null) { return null; }
    let lo = 0, hi = edges.length - 1, at = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (edges[mid] <= time) { at = mid; lo = mid + 1; } else { hi = mid - 1; } }
    return at >= 0 ? edges[at] : null;
  }

  // The current commit: kept while the marker stays on the cycle it was set for (stepping inside
  // a cycle with several commits), else the first commit at or after the marker's posedge (§3.1).
  function currentK(time) {
    const ix = st.index;
    if (!ix) { return null; }
    const t = time === undefined ? markerTime() : time;
    const edge = edgeAt(t);
    if (time === undefined && st.k !== null && st.kTime === edge) { return st.k; }
    return edge === null ? 0 : ix.commitAt(edge);
  }

  function noteMove(k, stepped) {
    if (st.k !== null && st.k !== k) {
      st.prevK = st.k;
      st.strong = stepped ? [Math.min(st.k, k), Math.max(st.k, k)] : null;
    }
    st.k = k;
  }

  async function stepCommit(query) {
    const by = Math.trunc(Number((query || {}).by)) || 1;
    const ix = await ensureIndex();
    if (!ix) { toastError(); return state(); }
    const k0 = currentK();
    return goToCommit({ k: Math.max(0, Math.min(ix.count, k0 + by)), stepped: true });
  }

  // The marker on commit k's cycle (k = count: the posedge after the last commit).
  async function goToCommit(query) {
    const q = query || {};
    const ix = await ensureIndex();
    if (!ix) { return state(); }
    const k = Math.max(0, Math.min(ix.count, Math.trunc(Number(q.k)) || 0));
    let time = ix.timeOf(k);
    if (k === ix.count && ix.count) {
      const last = ix.timeOf(ix.count - 1);
      const next = Array.prototype.find.call(st.edges, (e) => e > last);
      time = next === undefined ? last : next;
    }
    if (time === null || time === undefined) { return state(); }
    noteMove(k, !!q.stepped);
    st.kTime = edgeAt(time);
    if (markerTime() !== time) {
      if (waveform.debugger.moveTo) { await waveform.debugger.moveTo({ time }); } else { waveform.link.setMarker(time); }
    } else if (waveform.debugger.commitMoved) {
      waveform.debugger.commitMoved();
    }
    render();
    return state();
  }

  function instructionMode() { return st.mode === 'instruction' || (st.mode === 'auto' && st.focused); }

  // ---- values for Evaluate, watches and conditions ----
  const MACHINE_NAME = /^\$/;
  function nameValue(ix, k, name) {
    const n = String(name).replace(/^\$/, '').toLowerCase();
    const bits = (v, w) => (v === null ? 'x'.repeat(w) : BigInt.asUintN(w, v).toString(2).padStart(w, '0'));
    if (n === 'pc') { const pc = ix.pc(k); return pc === null && k >= ix.count ? { missing: true } : { width: ix.xlen, value: X.fromBits(bits(pc, ix.xlen), ix.xlen) }; }
    const r = C.regNumber(n);
    if (r !== null) {
      const v = ix.reg(r, k);
      if (!v.known) { return { missing: true }; }
      return { width: ix.xlen, value: X.fromBits(bits(v.value, ix.xlen), ix.xlen) };
    }
    const csr = ix.csr(n, k);
    if (csr) {
      if (!csr.known) { return { missing: true }; }
      return { width: ix.xlen, value: X.fromBits(bits(csr.value, ix.xlen), ix.xlen) };
    }
    return null;
  }

  // A sync env for one time: env.value(name) -> { width, value } | { missing } | null (not a name),
  // env.memory(bytes, addrValue) -> { value } | null (records which read had no value).
  function envFor(ix, time) {
    const k = currentK(time);
    const env = { k, missing: null };
    env.value = (name) => nameValue(ix, k, name);
    env.memory = (bytes, addr) => {
      if (addr.b !== 0n) { return { value: X.fromBits('x'.repeat(bytes * 8), bytes * 8) }; }
      const a = Number(addr.a);
      const v = ix.load(a, bytes, k);
      if (!v.known) { env.missing = '$mem' + bytes * 8 + '(0x' + a.toString(16) + ')'; return null; }
      const w = bytes * 8;
      return { value: X.fromBits(v.value === null ? 'x'.repeat(w) : v.value.toString(2).padStart(w, '0'), w) };
    };
    return env;
  }

  // For cmux-debugger.js: the env at `time` (null: no commit stream; the reason is toasted once).
  async function envAt(time) {
    const ix = await ensureIndex();
    if (!ix) { return null; }
    return envFor(ix, time === undefined || time === null ? markerTime() : time);
  }
  async function prepare() {
    const ix = await ensureIndex();
    return ix ? { envAt: (time) => envFor(ix, time) } : null;
  }

  // ---- gdb commands ----
  function evaluateForGdb(ix, k) {
    return (text) => {
      const p = X.parse(text);
      if (p.error) { return { error: exprError(p.error, p.at) }; }
      const env = envFor(ix, k === ix.count ? null : ix.timeOf(k));
      // Evaluate at commit k exactly (several commits may share a cycle).
      env.value = (name) => nameValue(ix, k, name);
      const fn = (path) => {
        if (!MACHINE_NAME.test(path[0])) { return null; }
        const v = env.value(path[0]);
        if (!v || v.missing) { env.missing = path[0]; return null; }
        return v;
      };
      fn.memory = (bytes, addr) => {
        if (addr.b !== 0n) { return { value: X.fromBits('x'.repeat(bytes * 8), bytes * 8) }; }
        const v = ix.load(Number(addr.a), bytes, k);
        if (!v.known) { env.missing = '$mem' + bytes * 8 + '(0x' + Number(addr.a).toString(16) + ')'; return null; }
        const w = bytes * 8;
        return { value: X.fromBits(v.value === null ? 'x'.repeat(w) : v.value.toString(2).padStart(w, '0'), w) };
      };
      const r = X.evaluate(p.ast, fn);
      if (r.error) {
        if (env.missing) { return { error: format(S().debuggerExprNoValue, env.missing) }; }
        return { error: exprError(r.error, r.at) };
      }
      return { value: r.value.b !== 0n ? null : r.value.a, width: r.value.w, text: r.value.b !== 0n ? X.format(r.value, 'hex') : null };
    };
  }

  function exprError(error, at) {
    const s = S();
    const reason = format(s['debuggerExpr' + error[0].toUpperCase() + error.slice(1)] || error, '');
    return at === null || at === undefined ? reason : format(s.debuggerExprError, reason, Number(at + 1).toLocaleString());
  }

  async function gdb(query) {
    const text = String((query || {}).text || '').trim();
    if (!C.isGdb(text)) { return null; }
    const ix = await ensureIndex();
    const k = ix ? (query && query.k !== undefined ? Number(query.k) : currentK(query && query.time !== undefined ? query.time : undefined)) : 0;
    const ctx = { index: ix, k, evaluate: ix ? evaluateForGdb(ix, k) : () => ({ error: S().machineNoStream || '' }),
      disasm, last: st.gdbLast, history: st.gdbHistory, noState: problemText() || S().machineNoStream || '' };
    const r = C.gdb(text, ctx) || { lines: [], tab: null };
    if (r.history) { st.gdbHistory = r.history; }
    say('(gdb) ' + text, r.lines);
    if (r.tab && ix) {
      st.shown = true;
      st.tab = r.tab;
      if (r.tab === 'memory' && r.addr !== undefined) {
        st.mem = { expr: '0x' + r.addr.toString(16), unit: r.unit || st.mem.unit, count: Math.max(1, r.count || st.mem.count), fmt: r.fmt || st.mem.fmt };
      }
    }
    render();
    return { lines: r.lines, tab: r.tab || null, error: !!r.error };
  }

  function say(head, lines) {
    st.console.push(head, ...lines);
    if (st.console.length > CONSOLE_LINES) { st.console.splice(0, st.console.length - CONSOLE_LINES); }
  }

  // ---- what the pane shows (also the checks' view) ----
  const digitsOf = (ix) => ix.xlen / 4;
  function regText(ix, v) {
    if (!v.known) { return '—'; }
    if (v.value === null) { return 'x'; }
    return C.hex(v.value, digitsOf(ix));
  }

  function registers() {
    const ix = st.index;
    if (!ix) { return null; }
    const k = currentK();
    const pend = ix.pending(k);
    const light = st.prevK !== null && st.prevK !== k ? new Set(ix.changedRegs(Math.min(st.prevK, k), Math.max(st.prevK, k))) : new Set();
    const strong = st.strong ? new Set(ix.changedRegs(st.strong[0], st.strong[1])) : new Set();
    const regs = ix.regs(k).map((v, r) => {
      const p = pend.regs.find((x) => x.r === r);
      return { r, name: 'x' + r, abi: C.ABI[r], value: regText(ix, v), from: v.from, writer: v.writer, reader: v.reader === undefined ? null : v.reader,
        uncertain: !!v.uncertain, pending: p ? (p.value === null ? 'x' : C.hex(p.value, digitsOf(ix))) : null,
        changed: strong.has(r) ? 'strong' : (light.has(r) ? 'light' : null) };
    });
    const pc = ix.pc(k);
    const insn = ix.insn(k);
    const sym = pc !== null ? ix.symbolFor(Number(pc)) : null;
    return { k, count: ix.count, order: orderText(ix, k), pc: pc === null ? '—' : C.hex(pc, digitsOf(ix)),
      symbol: sym ? sym.name + (sym.offset ? '+' + sym.offset : '') : null,
      insn: insn === null ? null : disasm((insn & 3) === 3 ? insn : insn & 0xffff, pc), trap: pend.trap, regs };
  }

  function orderText(ix, k) { const o = ix.order(k); return o === null ? null : o.toString(10); }

  function csrs() {
    const ix = st.index;
    if (!ix) { return null; }
    const k = currentK();
    const pend = ix.pending(k);
    return ix.csrNames().map((name) => {
      const v = ix.csr(name, k);
      const p = pend.csrs.find((x) => x.name === name);
      return { name, value: !v.known ? (v.mask ? C.hex(v.value, digitsOf(ix)) + '?' : '—') : C.hex(v.value, digitsOf(ix)),
        writer: v.writer, pending: p ? (p.value === null ? 'x' : C.hex(p.value, digitsOf(ix))) : null };
    });
  }

  function memoryAddress(ix, k) {
    const text = String(st.mem.expr || '').trim();
    if (!text) { return null; }
    const r = evaluateForGdb(ix, k)(C.gdbExpr(text, { index: ix }));
    return r.error || r.value === null ? { error: r.error || format(S().debuggerExprNoValue, text) } : { addr: Number(r.value) };
  }

  // Rows of 16 bytes from the Memory tab's address: [{ addr, label, cells: [{ addr, text, from, pending, changed }], ascii }].
  function memoryRows() {
    const ix = st.index;
    if (!ix) { return null; }
    const k = currentK();
    const at = memoryAddress(ix, k);
    if (!at || at.error) { return { error: at ? at.error : null, rows: [] }; }
    if (st.mem.fmt === 'i' || st.mem.fmt === 's') {
      const out = C.memoryLines(ix, { k, disasm }, at.addr, Math.min(256, st.mem.count), st.mem.fmt, st.mem.unit);
      return { addr: at.addr, lines: out.lines, rows: [] };
    }
    const size = { b: 1, h: 2, w: 4, g: 8 }[st.mem.unit] || 4;
    const bytes = Math.min(4096, st.mem.count * size);
    const pend = new Map(ix.pending(k).mem.map((m) => [m.addr, m.value]));
    const prev = st.prevK !== null && st.prevK !== k ? st.prevK : null;
    const rows = [];
    for (let off = 0; off < bytes; off += 16) {
      const base = at.addr + off;
      const units = [];
      for (let u = 0; u < 16 && off + u < bytes; u += size) {
        const a = base + u;
        const cells = ix.bytes(a, size, k);
        const known = cells.every((c) => c.known);
        const value = known && cells.every((c) => c.value !== null) ? cells.reduceRight((acc, c) => (acc << 8n) | BigInt(c.value), 0n) : null;
        const text = !cells.some((c) => c.known) ? '—'.padEnd(size * 2, ' ') : (st.mem.fmt === 'x' || value === null
          ? cells.slice().reverse().map((c) => (!c.known ? '??' : (c.value === null ? 'xx' : c.value.toString(16).padStart(2, '0')))).join('')
          : C.formatScalar(value, st.mem.fmt, size * 8));
        const froms = new Set(cells.map((c) => c.from));
        const pending = cells.some((_, j) => pend.has(a + j));
        let changed = null;
        if (prev !== null) {
          for (let j = 0; j < size && !changed; j++) {
            const w = ix.lastMemWrite(a + j, k);
            if (w !== null && w >= Math.min(prev, k)) { changed = st.strong && w >= st.strong[0] ? 'strong' : 'light'; }
          }
        }
        units.push({ addr: a, text, from: froms.size === 1 ? Array.from(froms)[0] : 'mixed', pending, changed,
          pendingText: pending ? cells.map((_, j) => (pend.has(a + j) ? (pend.get(a + j) === null ? 'xx' : pend.get(a + j).toString(16).padStart(2, '0')) : '..')).reverse().join('') : null });
      }
      let ascii = '';
      for (let j = 0; j < 16 && off + j < bytes; j++) {
        const b = ix.byte(base + j, k);
        ascii += !b.known || b.value === null ? '·' : (b.value >= 32 && b.value < 127 ? String.fromCharCode(b.value) : '.');
      }
      const sym = ix.symbolFor(base);
      rows.push({ addr: base, label: '0x' + base.toString(16) + (sym ? ' <' + sym.name + (sym.offset ? '+' + sym.offset : '') + '>' : ''), units, ascii });
    }
    return { addr: at.addr, rows };
  }

  function history() {
    const ix = st.index;
    if (!ix) { return null; }
    const k = currentK();
    const from = Math.max(0, k - Math.floor(HISTORY / 2));
    const to = Math.min(ix.count, from + HISTORY);
    const out = [];
    for (let j = from; j < to; j++) {
      const pc = ix.pc(j);
      const insn = ix.insn(j);
      const p = ix.pending(j);
      const writes = p.regs.map((x) => C.ABI[x.r] + '=' + (x.value === null ? 'x' : C.hex(x.value)))
        .concat(p.mem.length ? ['[0x' + p.mem[0].addr.toString(16) + (p.mem.length > 1 ? '+' + p.mem.length : '') + ']'] : [])
        .concat(p.csrs.map((x) => x.name + '=' + (x.value === null ? 'x' : C.hex(x.value))));
      out.push({ k: j, current: j === k, order: orderText(ix, j), time: ix.timeOf(j), channel: ix.table.channel[j], pc: pc === null ? '—' : C.hex(pc, digitsOf(ix)),
        insn: insn === null ? null : (disasm((insn & 3) === 3 ? insn : insn & 0xffff, pc) || C.hex(insn)), trap: p.trap, writes });
    }
    return out;
  }

  // ---- row actions (registers, memory, CSRs, history) ----
  // loc: 'x5' | { addr } | { csr } | { k }
  async function rowAction(query) {
    const q = query || {};
    const ix = await ensureIndex();
    if (!ix) { return null; }
    const k = currentK();
    const loc = q.loc;
    const reg = typeof loc === 'string' ? C.regNumber(loc) : null;
    const addr = loc && typeof loc === 'object' && loc.addr !== undefined ? Number(loc.addr) : null;
    const csr = loc && typeof loc === 'object' && loc.csr ? String(loc.csr) : null;
    let target = null;
    if (q.action === 'goTo' && loc && loc.k !== undefined) { target = Number(loc.k); }
    if (q.action === 'lastWrite' || q.action === 'previousWrite') {
      target = reg !== null ? ix.lastRegWrite(reg, k) : (addr !== null ? ix.lastMemWrite(addr, k) : (csr ? ix.lastCsrWrite(csr, k) : null));
    }
    if (q.action === 'nextWrite') {
      target = reg !== null ? ix.nextRegWrite(reg, k + 1) : (addr !== null ? ix.nextMemWrite(addr, k + 1) : (csr ? ix.nextCsrWrite(csr, k + 1) : null));
    }
    if (q.action === 'addWatch') {
      const expr = reg !== null ? '$' + C.ABI[reg] : (addr !== null ? '$mem' + ({ b: 8, h: 16, w: 32, g: 64 }[st.mem.unit] || 32) + "(" + ix.xlen + "'h" + addr.toString(16) + ')' : (csr ? '$' + csr : null));
      if (expr) { waveform.debugger.addWatch({ expr }); }
      return { expr };
    }
    if (q.action === 'copy') {
      const text = String(q.text || '');
      host.toNative({ type: 'copy', text });
      return { text };
    }
    if (target === null || target === undefined) {
      window.cmuxUI.toast(q.action === 'nextWrite' ? (S().machineNoNextWrite || '') : (S().machineNoWriter || ''), 'info');
      return { k: null };
    }
    if (q.action === 'lastWrite') {
      const pc = ix.pc(target);
      window.cmuxUI.toast(format(S().machineWrittenBy, locName(loc), orderText(ix, target) === null ? String(target) : orderText(ix, target), pc === null ? '—' : C.hex(pc)), 'info');
    }
    await goToCommit({ k: target });
    return { k: target };
  }

  function locName(loc) {
    if (typeof loc === 'string') { const r = C.regNumber(loc); return r === null ? loc : C.ABI[r]; }
    if (loc && loc.addr !== undefined) { return '0x' + Number(loc.addr).toString(16); }
    if (loc && loc.csr) { return loc.csr; }
    return '';
  }

  // ---- state ----
  function problemText() {
    const s = S();
    const why = { noSource: s.machineNoStream, offer: format(s.machineOffer, st.errorDetail), noClock: s.debuggerNoClock,
      tooManyChanges: format(s.debuggerTooManyChanges, st.errorDetail), budget: format(s.machineBudget, st.errorDetail),
      signalGone: format(s.debuggerBreakpointSignalGone, st.errorDetail), loading: s.debuggerLoading, readFailed: format(s.machineReadFailed, st.errorDetail) };
    return st.error ? (why[st.error] || st.error) : null;
  }

  function state() {
    const ix = st.index;
    const source = st.index ? st.index.table.source : null;
    const d = ix ? ix.table.diagnostics : null;
    return { shown: st.shown, tab: st.tab, mode: st.mode, instructionMode: instructionMode(), building: !!st.building,
      error: st.error, problem: problemText(), source: source ? source.label : null, family: source ? source.family : null,
      nret: source ? source.nret : null, xlen: ix ? ix.xlen : null, count: ix ? ix.count : null, k: ix ? currentK() : null,
      memMask: ix ? ix.memMask : null, diagnostics: d, gated: ix ? ix.gated : null,
      disagreements: ix ? { regs: ix.regDisagreements.length, mem: ix.memDisagreements.length, elf: ix.elfMismatch } : null,
      image: st.image ? { path: st.image.path, segments: st.image.segments.length, symbols: st.image.symbols.length } : null, buildMs: st.buildMs, cacheHit: !!st.cacheHit,
      sources: (st.sources || []).map((s) => ({ label: s.label || (s.valid ? s.valid.join('.') : ''), family: s.family, nret: s.nret || null })) };
  }

  // The warnings the header shows: one line each (§1 diagnostics, §3.1 disagreements).
  function warnings() {
    const ix = st.index;
    if (!ix) { return []; }
    const s = S();
    const d = ix.table.diagnostics;
    const out = [];
    if (d.orderContiguous === false) { out.push(format(s.machineOrderGaps, d.orderGaps.toLocaleString())); }
    if (d.pcXZ) { out.push(format(s.machinePcXZ, d.pcXZ.toLocaleString())); }
    if (d.silentChannels.length) { out.push(format(s.machineSilentChannels, d.silentChannels.join(', '))); }
    if (d.rdZeroWrites) { out.push(format(s.machineRdZero, d.rdZeroWrites.toLocaleString())); }
    if (ix.regDisagreements.length) { const x = ix.regDisagreements[0]; out.push(format(s.machineRegDisagree, ix.regDisagreements.length.toLocaleString(), C.ABI[x.reg], orderText(ix, x.k) || String(x.k))); }
    if (ix.memDisagreements.length) { const x = ix.memDisagreements[0]; out.push(format(s.machineMemDisagree, ix.memDisagreements.length.toLocaleString(), '0x' + x.addr.toString(16), orderText(ix, x.k) || String(x.k))); }
    if (ix.elfMismatch) { out.push(s.machineWrongElf || ''); }
    if (ix.gated.nonMemory) { out.push(format(s.machineGated, ix.gated.nonMemory.toLocaleString())); }
    return out.filter(Boolean);
  }

  // ---- rendering: the Machine section under Breakpoints and Watches ----
  let section = null;
  let renderQueued = false;
  let lastRender = 0;
  function render() {
    if (renderQueued) { return; }
    renderQueued = true;
    // While playing, at most every 100 ms (§3.4).
    const wait = window.cmuxDebugger && window.cmuxDebugger.isPlaying() ? Math.max(0, 100 - (Date.now() - lastRender)) : 0;
    setTimeout(() => { renderQueued = false; lastRender = Date.now(); try { draw(); } catch (error) { host.log(error); } }, wait);
  }

  const css = (el, text) => { el.style.cssText = text; return el; };
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) { e.className = cls; } if (text !== undefined) { e.textContent = text; } return e; };
  const MONO = 'font-family: var(--vscode-editor-font-family, monospace);';
  const FROM_COLOR = { write: '', elf: 'color: var(--vscode-charts-blue, #4fc1ff);', read: 'color: var(--vscode-charts-purple, #c586c0);', zero: '', mixed: '', null: 'opacity: 0.55;' };

  function ensureSection() {
    const pane = document.getElementById('netlist');
    if (!pane) { return null; }
    if (!section) {
      section = el('div');
      section.id = 'cmux-machine';
      css(section, 'flex: none; max-height: 55%; overflow: auto; border-top: 1px solid var(--vscode-widget-border); padding-bottom: 4px;');
      section.addEventListener('focusin', () => { st.focused = true; });
      section.addEventListener('mousedown', () => { st.focused = true; });
      document.addEventListener('mousedown', (e) => { if (section && !section.contains(e.target)) { st.focused = false; } }, true);
      document.addEventListener('focusin', (e) => { if (section && !section.contains(e.target)) { st.focused = false; } }, true);
    }
    if (section.parentElement !== pane) { pane.appendChild(section); }
    // Last: under the breakpoints and watches.
    if (pane.lastElementChild !== section) { pane.appendChild(section); }
    return section;
  }

  function draw() {
    const box = ensureSection();
    if (!box) { return; }
    box.hidden = !st.shown;
    if (!st.shown) { return; }
    const s = S();
    box.textContent = '';
    const head = css(el('div'), 'display: flex; align-items: center; gap: 6px; padding: 6px 10px 4px;');
    const title = css(el('h2', null, s.machineTitle || ''), 'margin: 0; font-weight: 600; text-transform: uppercase; font-size: 11px; color: var(--vscode-descriptionForeground); flex: none;');
    const source = css(el('span', 'source'), 'flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--vscode-descriptionForeground); cursor: pointer;');
    const ix = st.index;
    source.textContent = st.building ? (s.machineBuilding || '') : (ix ? format(s.machineSource, ix.table.source.label, ix.table.nret.toLocaleString(), ix.count.toLocaleString()) : (problemText() || ''));
    source.title = ix ? format(s.machineSourceTooltip, ix.memMask, st.image && st.image.path ? st.image.path : (s.machineNoImage || '')) : source.textContent;
    source.addEventListener('click', (e) => window.cmuxUI.showMenu(sourceMenuItems(), e.clientX, e.clientY));
    const mode = css(el('span', 'mode'), 'flex: none; cursor: pointer; padding: 0 4px; border: 1px solid var(--vscode-widget-border); border-radius: 2px;');
    const modeName = instructionMode() ? (s.machineModeInstruction || '') : (s.machineModeCycle || '');
    mode.textContent = st.mode === 'auto' ? format(s.machineModeAuto, modeName) : modeName;
    mode.title = s.machineModeTooltip || '';
    mode.addEventListener('click', () => setMode({ mode: st.mode === 'auto' ? (instructionMode() ? 'cycle' : 'instruction') : (st.mode === 'instruction' ? 'cycle' : 'auto') }));
    const close = el('span', 'remove codicon codicon-close');
    close.style.cursor = 'pointer';
    close.title = s.machineHide || '';
    close.addEventListener('click', hide);
    head.append(title, source, mode, close);
    box.appendChild(head);
    for (const w of warnings()) {
      box.appendChild(css(el('div', 'warning', w), 'padding: 0 10px; color: var(--vscode-editorWarning-foreground, #cca700); white-space: normal;'));
    }
    if (!ix) { drawConsole(box); return; }
    const tabs = css(el('div', 'tabs'), 'display: flex; gap: 8px; padding: 2px 10px;');
    const names = [['registers', s.machineRegisters], ['memory', s.machineMemory]].concat(ix.csrNames().length ? [['csrs', s.machineCsrs]] : [])
      .concat([['history', s.machineHistory], ['sequences', s.machineSequences]]);
    if (st.tab === 'csrs' && !ix.csrNames().length) { st.tab = 'registers'; }
    for (const [id, label] of names) {
      const t = css(el('span', 'tab' + (st.tab === id ? ' active' : ''), label || ''), 'cursor: pointer;' + (st.tab === id ? ' font-weight: 600; border-bottom: 1px solid var(--vscode-focusBorder);' : ' opacity: 0.75;'));
      t.dataset.tab = id;
      t.addEventListener('click', () => setTab({ tab: id }));
      tabs.appendChild(t);
    }
    box.appendChild(tabs);
    if (st.tab === 'registers') { drawRegisters(box); } else if (st.tab === 'memory') { drawMemory(box); } else if (st.tab === 'csrs') { drawCsrs(box); } else if (st.tab === 'sequences') { drawSequences(box); } else { drawHistory(box); }
    drawConsole(box);
  }

  function changedStyle(changed) {
    return changed === 'strong' ? ' background: rgba(255, 166, 0, 0.30);' : (changed === 'light' ? ' background: rgba(255, 166, 0, 0.12);' : '');
  }

  function drawRegisters(box) {
    const r = registers();
    const s = S();
    const top = css(el('div', 'pc'), 'padding: 2px 10px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;' + MONO);
    top.textContent = 'pc ' + r.pc + (r.symbol ? ' <' + r.symbol + '>' : '') + (r.insn ? '  ' + r.insn : '') + (r.trap ? '  ' + (s.machineTrap || '') : '');
    top.title = format(s.machineCommitTooltip, (r.order === null ? r.k : r.order).toLocaleString(), r.count.toLocaleString());
    box.appendChild(top);
    const grid = css(el('div', 'regs'), 'display: grid; grid-template-columns: 1fr 1fr; column-gap: 8px; padding: 0 10px;' + MONO);
    // Two columns: x0–x15 left, x16–x31 right.
    for (let i = 0; i < 16; i++) {
      for (const reg of [r.regs[i], r.regs[i + 16]]) {
        const row = css(el('div', 'reg' + (reg.changed ? ' changed-' + reg.changed : '') + (reg.pending ? ' pending' : '')),
          'display: flex; gap: 4px; white-space: nowrap; line-height: 18px;' + changedStyle(reg.changed));
        row.dataset.reg = reg.name;
        const name = css(el('span', 'name', reg.abi), 'width: 3.2em; color: var(--vscode-descriptionForeground);');
        name.title = reg.name;
        const value = css(el('span', 'value', reg.value + (reg.uncertain ? '?' : '')), FROM_COLOR[reg.from === null ? 'null' : reg.from] || '');
        value.title = provenance(reg);
        row.append(name, value);
        if (reg.pending) { row.appendChild(css(el('span', 'pending', '→ ' + reg.pending), 'color: var(--vscode-charts-green, #89d185);')); }
        row.addEventListener('contextmenu', (e) => { e.preventDefault(); window.cmuxUI.showMenu(locMenuItems(reg.name, reg.value), e.clientX, e.clientY); });
        grid.appendChild(row);
      }
    }
    box.appendChild(grid);
  }

  function provenance(reg) {
    const s = S();
    const ix = st.index;
    if (reg.from === 'write') { return format(s.machineFromWrite, orderText(ix, reg.writer) || String(reg.writer)); }
    if (reg.from === 'read') { return format(s.machineFromRead, orderText(ix, reg.reader) || String(reg.reader)); }
    if (reg.from === 'elf') { return s.machineFromElf || ''; }
    if (reg.from === 'zero') { return ''; }
    return s.machineUnknown || '';
  }

  function drawCsrs(box) {
    const grid = css(el('div', 'csrs'), 'padding: 0 10px;' + MONO);
    for (const c of csrs()) {
      const row = css(el('div', 'csr'), 'display: flex; gap: 6px; white-space: nowrap; line-height: 18px;');
      row.dataset.csr = c.name;
      row.append(css(el('span', 'name', c.name), 'width: 8em; color: var(--vscode-descriptionForeground);'), el('span', 'value', c.value));
      if (c.pending) { row.appendChild(css(el('span', 'pending', '→ ' + c.pending), 'color: var(--vscode-charts-green, #89d185);')); }
      row.addEventListener('contextmenu', (e) => { e.preventDefault(); window.cmuxUI.showMenu(locMenuItems({ csr: c.name }, c.value), e.clientX, e.clientY); });
      grid.appendChild(row);
    }
    box.appendChild(grid);
  }

  function drawMemory(box) {
    const s = S();
    const bar = css(el('div', 'membar'), 'display: flex; gap: 4px; padding: 2px 10px; align-items: center;');
    const input = css(el('input'), 'flex: 1 1 auto; min-width: 6em; height: 16px; padding: 0 4px; font: inherit; color: inherit; border-radius: 2px;'
      + ' background: var(--vscode-input-background, transparent); border: 1px solid var(--vscode-input-border, var(--vscode-widget-border));' + MONO);
    input.type = 'text';
    input.spellcheck = false;
    input.className = 'addr';
    input.value = st.mem.expr;
    input.placeholder = s.machineAddressPlaceholder || '';
    input.title = s.machineAddressTooltip || '';
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); st.mem.expr = input.value; render(); } });
    const select = (cls, values, current, apply) => {
      const sel = css(el('select', cls), 'font: inherit; color: inherit; background: var(--vscode-input-background, transparent); border: 1px solid var(--vscode-widget-border);');
      for (const [v, label] of values) { const o = el('option', null, label); o.value = v; o.selected = v === current; sel.appendChild(o); }
      sel.addEventListener('change', () => { apply(sel.value); render(); });
      return sel;
    };
    const unit = select('unit', [['b', 'b'], ['h', 'h'], ['w', 'w'], ['g', 'g']], st.mem.unit, (v) => { st.mem.unit = v; });
    unit.title = s.machineUnitTooltip || '';
    const fmt = select('fmt', [['x', 'x'], ['d', 'd'], ['u', 'u'], ['c', 'c'], ['i', 'i'], ['s', 's']], st.mem.fmt, (v) => { st.mem.fmt = v; });
    fmt.title = s.machineFormatTooltip || '';
    bar.append(input, unit, fmt);
    box.appendChild(bar);
    const m = memoryRows();
    if (m.error) { box.appendChild(css(el('div', 'error', m.error), 'padding: 0 10px; color: var(--vscode-editorWarning-foreground, #cca700);')); return; }
    const list = css(el('div', 'mem'), 'padding: 0 10px; white-space: pre;' + MONO);
    if (m.lines) {
      for (const line of m.lines) { list.appendChild(el('div', 'line', line)); }
      box.appendChild(list);
      return;
    }
    for (const row of m.rows) {
      const line = css(el('div', 'row'), 'display: flex; gap: 6px; line-height: 18px;');
      line.appendChild(css(el('span', 'addr', row.label), 'color: var(--vscode-descriptionForeground); min-width: 6em;'));
      for (const u of row.units) {
        const cell = css(el('span', 'cell' + (u.pending ? ' pending' : '') + (u.changed ? ' changed-' + u.changed : ''), u.text),
          (FROM_COLOR[u.from === null ? 'null' : u.from] || '') + changedStyle(u.changed) + (u.pending ? ' text-decoration: underline; text-decoration-color: var(--vscode-charts-green, #89d185);' : ''));
        cell.dataset.addr = String(u.addr);
        cell.title = u.pending ? format(s.machinePendingBytes, u.pendingText) : '';
        cell.addEventListener('contextmenu', (e) => { e.preventDefault(); window.cmuxUI.showMenu(locMenuItems({ addr: u.addr }, u.text), e.clientX, e.clientY); });
        line.appendChild(cell);
      }
      line.appendChild(css(el('span', 'ascii', row.ascii), 'color: var(--vscode-descriptionForeground);'));
      list.appendChild(line);
    }
    box.appendChild(list);
  }

  // ---- instruction-sequence search (cmux-sequence.js, §3A) ----
  const SEQUENCE_MS = 2000;  // a search's time budget
  function seqMessage(r) {
    const s = S();
    const code = r.error;
    const own = { empty: s.machineSeqEmpty, emptyStep: s.machineSeqEmptyStep, badDelay: s.machineSeqBadDelay, badRegex: s.machineSeqBadRegex,
      badAssign: s.machineSeqBadAssign, unknownCapture: format(s.machineSeqUnknownCapture, r.detail || ''), tooManySteps: s.machineSeqTooManySteps };
    if (own[code] !== undefined) { return own[code] || code; }
    if (code === 'unknownName') { return format(s.debuggerExprUnknownName, r.step || ''); }
    const reason = s['debuggerExpr' + code[0].toUpperCase() + code.slice(1)];
    return (reason ? format(reason, '') : code) + (r.step ? ' (' + r.step + ')' : '');
  }

  // sequence({ query, from, limit, budget, budgetMs }) -> { matches: [{ start, end, ks, startTime, endTime, order }], incomplete,
  //   reason ('limit' | 'budget' | 'time' | 'threads' | null), next, evaluated, ms } | { error, message }.
  // The search pauses as it goes (the page stays responsive) and stops after budgetMs (default 2 s, §3A).
  async function sequence(query) {
    const q = query || {};
    const ix = await ensureIndex();
    if (!ix) { return { error: 'noStream', message: problemText() || S().machineNoStream || '' }; }
    const Q = window.cmuxSequence;
    const t0 = performance.now();
    const r = await Q.searchAsync(Q.streamOf(ix), String(q.query || ''), { from: q.from, limit: q.limit, budget: q.budget,
      budgetMs: q.budgetMs > 0 ? q.budgetMs : SEQUENCE_MS });
    if (r.error) { return { error: r.error, message: seqMessage(r) }; }
    const matches = r.matches.map((m) => ({ start: m.start, end: m.end, ks: m.ks, startTime: ix.timeOf(m.start), endTime: ix.timeOf(m.end),
      order: orderText(ix, m.start) }));
    return { matches, incomplete: r.incomplete, reason: r.reason, next: r.next, evaluated: r.evaluated, ms: Math.round(performance.now() - t0) };
  }

  let seqRun = 0;
  async function runSequence(more) {
    const prev = more ? st.seq.result : null;
    const run = ++seqRun;
    const r = await sequence({ query: st.seq.query, from: prev ? prev.next : 0 });
    // A newer search (Enter again while this one paused) shows its own.
    if (run !== seqRun) { return; }
    st.seq.result = prev && !r.error ? Object.assign({}, r, { matches: prev.matches.concat(r.matches) }) : r;
    render();
  }

  function drawSequences(box) {
    const s = S();
    const ix = st.index;
    const bar = css(el('div', 'seqbar'), 'display: flex; gap: 4px; padding: 2px 10px; align-items: center;');
    const input = css(el('input'), 'flex: 1 1 auto; min-width: 8em; height: 16px; padding: 0 4px; font: inherit; color: inherit; border-radius: 2px;'
      + ' background: var(--vscode-input-background, transparent); border: 1px solid var(--vscode-input-border, var(--vscode-widget-border));' + MONO);
    input.type = 'text';
    input.spellcheck = false;
    input.className = 'query';
    input.value = st.seq.query;
    input.placeholder = s.machineSeqPlaceholder || '';
    input.title = s.machineSeqTooltip || '';
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); st.seq.query = input.value; runSequence(false); } });
    const land = css(el('span', 'land', st.seq.land === 'end' ? (s.machineSeqLandEnd || '') : (s.machineSeqLandStart || '')), 'cursor: pointer; flex: none; opacity: 0.8;');
    land.title = s.machineSeqLandTooltip || '';
    land.addEventListener('click', () => { st.seq.land = st.seq.land === 'end' ? 'start' : 'end'; render(); });
    bar.append(input, land);
    // Break Here: a sequence breakpoint of the query as typed, landing where Go to says (cmux-debugger-commits.js).
    const D = waveform.debugger;
    if (D && typeof D.breakpointKinds === 'function' && D.breakpointKinds().includes('sequence')) {
      const brk = css(el('span', 'break', s.machineSeqBreakHere || ''), 'cursor: pointer; flex: none; text-decoration: underline;');
      brk.title = s.machineSeqBreakHereTooltip || '';
      brk.addEventListener('click', () => {
        st.seq.query = input.value;
        if (!input.value.trim()) { return; }
        // Said: added, already there, or enabled again (the list may be out of sight).
        const before = new Map(D.breakpoints().map((b) => [b.id, b.enabled]));
        Promise.resolve(D.addBreakpoint({ kind: 'sequence', query: input.value, land: st.seq.land })).then((bp) => {
          if (!bp) { return; }  // refused: the debugger said why
          const was = before.get(bp.id);
          const text = was === undefined ? s.machineSeqBreakAdded : was ? s.machineSeqBreakExists : s.machineSeqBreakEnabled;
          window.cmuxUI.toast(format(text, bp.label), 'info');
        }).catch((error) => host.log(error));
      });
      bar.appendChild(brk);
    }
    box.appendChild(bar);
    const r = st.seq.result;
    if (!r) { return; }
    if (r.error) { box.appendChild(css(el('div', 'error', r.message), 'padding: 0 10px; color: var(--vscode-editorWarning-foreground, #cca700);')); return; }
    const head = css(el('div', 'seqcount'), 'padding: 0 10px; color: var(--vscode-descriptionForeground); display: flex; gap: 8px;');
    head.appendChild(el('span', null, format(r.incomplete ? s.machineSeqCountMore : s.machineSeqCount, r.matches.length.toLocaleString(), r.ms.toLocaleString())));
    if (r.incomplete && r.next !== null) {
      const more = css(el('span', 'more', s.machineSeqContinue || ''), 'cursor: pointer; text-decoration: underline;');
      more.addEventListener('click', () => runSequence(true));
      head.appendChild(more);
    }
    const copy = css(el('span', 'copy', s.machineSeqCopyCsv || ''), 'cursor: pointer; text-decoration: underline;');
    copy.addEventListener('click', () => host.toNative({ type: 'copy', text: sequenceCsv(r) }));
    head.appendChild(copy);
    box.appendChild(head);
    const list = css(el('div', 'seqlist'), 'padding: 0 10px; max-height: 16em; overflow: auto;' + MONO);
    const k = currentK();
    // At most 500 rows drawn (the count is exact).
    for (const m of r.matches.slice(0, 500)) {
      const at = st.seq.land === 'end' ? m.end : m.start;
      const row = css(el('div', 'match' + (at === k ? ' current' : '')), 'display: flex; gap: 6px; white-space: nowrap; line-height: 18px; cursor: pointer;'
        + (at === k ? ' background: rgba(137, 209, 133, 0.22);' : ''));
      row.dataset.k = String(at);
      const steps = m.ks.map((j) => { const pc = ix.pc(j); const insn = ix.insn(j); return (pc === null ? '—' : C.hex(pc, digitsOf(ix))) + ' ' + (insn === null ? '' : (disasm((insn & 3) === 3 ? insn : insn & 0xffff, pc) || '')); });
      row.append(css(el('span', 'order', m.order === null ? String(m.start) : m.order), 'min-width: 3em; text-align: right; color: var(--vscode-descriptionForeground);'),
        css(el('span', 'steps', steps.join('  ⟶  ')), 'overflow: hidden; text-overflow: ellipsis;'));
      row.addEventListener('click', () => goToCommit({ k: at }));
      list.appendChild(row);
    }
    box.appendChild(list);
  }

  function sequenceCsv(r) {
    const ix = st.index;
    const lines = ['start,end,start_time,end_time,' + 'pcs'];
    for (const m of r.matches) {
      lines.push([m.start, m.end, m.startTime, m.endTime, m.ks.map((j) => { const pc = ix.pc(j); return pc === null ? '' : C.hex(pc); }).join(' ')].join(','));
    }
    return lines.join('\n') + '\n';
  }

  function drawHistory(box) {
    const list = css(el('div', 'history'), 'padding: 0 10px;' + MONO);
    for (const h of history()) {
      const row = css(el('div', 'commit' + (h.current ? ' current' : '')), 'display: flex; gap: 6px; white-space: nowrap; line-height: 18px; cursor: pointer;'
        + (h.current ? ' background: rgba(137, 209, 133, 0.22); box-shadow: inset 3px 0 0 rgb(137, 209, 133);' : ''));
      row.dataset.k = String(h.k);
      row.append(css(el('span', 'order', h.order === null ? String(h.k) : h.order), 'min-width: 3em; text-align: right; color: var(--vscode-descriptionForeground);'),
        el('span', 'pc', h.pc), css(el('span', 'insn', (h.insn || '') + (h.trap ? ' (' + (S().machineTrap || '') + ')' : '')), 'flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis;'),
        css(el('span', 'writes', h.writes.join(' ')), 'color: var(--vscode-charts-green, #89d185);'));
      row.addEventListener('click', () => goToCommit({ k: h.k }));
      list.appendChild(row);
    }
    box.appendChild(list);
  }

  function drawConsole(box) {
    if (!st.console.length) { return; }
    const out = css(el('div', 'console'), 'margin: 4px 10px 0; padding: 2px 4px; max-height: 12em; overflow: auto; white-space: pre; border-top: 1px dashed var(--vscode-widget-border);' + MONO);
    for (const line of st.console.slice(-60)) { out.appendChild(css(el('div', null, line), line.startsWith('(gdb) ') ? 'color: var(--vscode-descriptionForeground);' : '')); }
    box.appendChild(out);
    out.scrollTop = out.scrollHeight;
  }

  function locMenuItems(loc, valueText) {
    const s = S();
    return [
      { label: s.machineWhoLastWrote || '', run: () => rowAction({ action: 'lastWrite', loc }) },
      { label: s.machinePreviousWrite || '', run: () => rowAction({ action: 'previousWrite', loc }) },
      { label: s.machineNextWrite || '', run: () => rowAction({ action: 'nextWrite', loc }) },
      { separator: true },
      { label: s.debuggerAddWatch || '', run: () => rowAction({ action: 'addWatch', loc }) },
    ].concat(writeBreakpointItem(loc)).concat([
      { label: s.machineCopy || '', run: () => rowAction({ action: 'copy', loc, text: valueText }) },
    ]);
  }

  // Break When Written… (the debugger's write breakpoints, where it has them): loc 'a0' | 'csr:mstatus' | 'mem:0x…/bytes'.
  function writeBreakpointItem(loc) {
    const d = waveform.debugger;
    if (!d.breakpointKinds || !d.breakpointKinds().includes('write')) { return []; }
    const size = { b: 1, h: 2, w: 4, g: 8 }[st.mem.unit] || 4;
    const spec = typeof loc === 'string' ? (C.regNumber(loc) === null ? loc : C.ABI[C.regNumber(loc)])
      : (loc.csr ? 'csr:' + loc.csr : 'mem:0x' + Number(loc.addr).toString(16) + '/' + size);
    return [{ label: S().machineBreakWhenWritten || '', run: () => d.addBreakpoint({ kind: 'write', loc: spec }) }];
  }

  function sourceMenuItems() {
    const s = S();
    const items = [];
    const list = (st.sources || []).filter((x) => x.family !== 'offer');
    list.forEach((src, i) => items.push({ label: src.label + ' (NRET ' + src.nret + ')', checked: !st.picks && i === st.sourceIndex, run: () => useSource({ index: i }) }));
    if (items.length) { items.push({ separator: true }); }
    items.push({ label: s.machineRebuild || '', run: () => { st.index = null; st.sources = null; ensureIndex(); } });
    if (st.picks) { items.push({ label: s.machineForgetPicks || '', run: forget }); }
    items.push({ label: s.machineLoadElf || '', run: () => host.toNative({ type: 'debugger', event: 'machineLoadELF' }) });
    return items;
  }

  // The waveform row's menu: Use as Commit ▸ role (the user's own mapping, §1 rule 1).
  const PICK_ROLES = ['valid', 'pc_rdata', 'insn', 'order', 'rd_addr', 'rd_wdata', 'mem_addr', 'mem_rmask', 'mem_wmask', 'mem_rdata', 'mem_wdata', 'trap'];
  function rowMenuItems(context) {
    const c = context || {};
    if (c.webviewSection !== 'signal' || c.netlistId === undefined) { return []; }
    const v = host.netlistItem(c.netlistId);
    if (!v) { return []; }
    const path = host.pathOf(v);
    const s = S();
    // Without its string (a page cmux opened without the machine's strings) there is no entry to show.
    if (!s.machineUseAsCommit) { return []; }
    return [{ label: s.machineUseAsCommit, items: PICK_ROLES.map((role) => ({ label: role, run: () => pick({ role, path, width: Number(v.width) || 1 }) })) }];
  }

  // ---- the commit index for other page code (asm breakpoints, sequence search) ----
  const listeners = [];
  function changed(reason) {
    for (const fn of listeners.slice()) { try { fn({ reason, backend: st.backend, count: st.index ? st.index.count : null }); } catch (error) { host.log(error); } }
  }
  // { backend, count, nret, xlen, sortedBy, time, edge, channel, pc, insn, order } — typed arrays in program order.
  // pc and order are Float64Array (exact below 2^53); insn Uint32Array (null without the role).
  function view(ix) {
    if (st.view && st.view.index === ix) { return st.view.value; }
    const t = ix.table;
    const asF64 = (col) => {
      if (!col) { return null; }
      const out = new Float64Array(t.count);
      for (let k = 0; k < t.count; k++) { out[k] = col.xz[k] ? NaN : (col.hi ? col.hi[k] * 4294967296 + col.lo[k] : col.lo[k]); }
      return out;
    };
    const value = { backend: st.backend, scope: (t.source.scope || []).slice(), count: t.count, nret: t.nret, xlen: t.xlen, sortedBy: t.sortedBy, time: t.time, edge: t.edge,
      channel: t.channel, pc: asF64(t.cols.pc_rdata), insn: t.cols.insn ? t.cols.insn.lo : null, order: asF64(t.cols.order) };
    st.view = { index: ix, value };
    return value;
  }
  // loc: 'x5' | 'a0' | { addr } | { csr }: commit indices that write it, ascending.
  function writesOf(ix, loc) {
    const r = typeof loc === 'string' ? C.regNumber(loc) : null;
    const out = [];
    const next = r !== null ? (k) => ix.nextRegWrite(r, k) : (loc && loc.addr !== undefined ? (k) => ix.nextMemWrite(Number(loc.addr), k)
      : (loc && loc.csr ? (k) => ix.nextCsrWrite(String(loc.csr), k) : null));
    if (!next) { return out; }
    for (let k = next(0); k !== null && k !== undefined; k = next(k + 1)) { out.push(k); }
    return out;
  }
  const commitsApi = Object.freeze({
    // The index for host.currentBackend (built on first use); null without a commit stream.
    index: async () => { const ix = await ensureIndex(); return ix ? view(ix) : null; },
    // Sync: the built index or null (no build started).
    current: () => (st.index && st.backend === host.currentBackend ? view(st.index) : null),
    currentK: () => (st.index ? currentK() : null),
    writesOf: async (query) => { const ix = await ensureIndex(); return ix ? writesOf(ix, (query || {}).loc) : null; },
    lastWrite: async (query) => { const ix = await ensureIndex(); const q = query || {}; if (!ix) { return null; } const w = writesOf(ix, q.loc); let a = null; for (const k of w) { if (k < Number(q.k)) { a = k; } else { break; } } return a; },
    nextWrite: async (query) => { const ix = await ensureIndex(); const q = query || {}; if (!ix) { return null; } return writesOf(ix, q.loc).find((k) => k >= Number(q.k)) ?? null; },
    // A sequence breakpoint's hits: the match commits' times (land 'end' or 'start'), ascending; or { error, message }.
    sequenceTimes: async (query) => {
      const q = query || {};
      const r = await sequence({ query: q.query, limit: q.limit || 1000000, budget: q.budget, budgetMs: q.budgetMs });
      if (r.error) { return r; }
      const times = r.matches.map((m) => (q.land === 'start' ? m.startTime : m.endTime));
      return { times: Float64Array.from(times).sort(), incomplete: r.incomplete, reason: r.reason, count: r.matches.length };
    },
    // fn({ reason: 'ready' | 'cleared', backend, count }) on each rebuild or clear (reload, source change, picks).
    onChange: (fn) => { listeners.push(fn); return () => { const i = listeners.indexOf(fn); if (i >= 0) { listeners.splice(i, 1); } }; },
  });
  Object.defineProperty(waveform, 'commits', { value: commitsApi, writable: false, configurable: false, enumerable: true });

  // ---- the API ----
  function show(query) {
    st.shown = true;
    if (query && query.tab) { st.tab = String(query.tab); }
    ensureIndex();
    render();
    return state();
  }
  function hide() { st.shown = false; render(); return state(); }
  function toggle() { return st.shown ? hide() : show(); }
  function setTab(query) { st.tab = String((query || {}).tab || 'registers'); render(); return state(); }
  function setMode(query) {
    const m = String((query || {}).mode || 'auto');
    st.mode = m === 'cycle' || m === 'instruction' ? m : 'auto';
    render();
    return state();
  }
  async function useSource(query) {
    st.picks = null;
    st.sourceIndex = Math.max(0, Number((query || {}).index) || 0);
    st.index = null;
    await ensureIndex();
    return state();
  }
  async function pick(query) {
    const q = query || {};
    if (!q.role || !Array.isArray(q.path)) { return state(); }
    st.picks = Object.assign({}, st.picks || {}, { [q.role]: { path: q.path.map(String), width: Number(q.width) || null } });
    st.index = null;
    st.shown = true;
    if (st.picks.valid && st.picks.pc_rdata) { await ensureIndex(); } else { render(); }
    return state();
  }
  async function forget() { st.picks = null; st.index = null; await ensureIndex(); return state(); }
  function toastError() { const t = problemText(); if (t) { window.cmuxUI.toast(t, 'warning'); } }

  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }

  // The marker moved: the current commit follows it, and the pane is redrawn.
  host.viewerEventListeners.push((m) => {
    if (m.eventType !== 'markerSet' || !st.index) { return; }
    const time = m.eventData && Number(m.eventData.time);
    const k = currentK(Number.isFinite(time) ? time : undefined);
    if (Number.isFinite(time) && st.kTime !== edgeAt(time)) { noteMove(k, false); st.kTime = edgeAt(time); }
    if (st.shown) { render(); }
  });

  const api = Object.freeze({
    state, sources: async () => { await sources(); return state().sources; }, useSource, pick, forget,
    build: async () => { await ensureIndex(); return state(); }, setImage, show, hide, toggle, setTab, setMode,
    stepCommit, goToCommit, gdb, registers, csrs, memoryRows, history, rowAction, sequence,
    setSequence: async (q) => { Object.assign(st.seq, { query: String((q || {}).query || ''), land: (q || {}).land === 'start' ? 'start' : 'end' }); st.tab = 'sequences'; await runSequence(false); return st.seq.result; },
    console: () => st.console.slice(),
    // Commits [from, from + count) in program order: { pc, insn, rd, rdv, time } (hex text; the checks' bulk view).
    commits: (q) => {
      const ix = st.index;
      if (!ix) { return null; }
      const from = Math.max(0, Number((q || {}).from) || 0);
      const to = Math.min(ix.count, from + Math.max(0, Number((q || {}).count) || 0));
      const out = [];
      for (let k = from; k < to; k++) {
        const p = ix.pending(k);
        const pc = ix.pc(k), insn = ix.insn(k);
        out.push({ pc: pc === null ? null : pc.toString(16), insn: insn === null ? null : (insn >>> 0).toString(16), time: ix.timeOf(k),
          rd: p.regs.length ? p.regs[0].r : null, rdv: p.regs.length && p.regs[0].value !== null ? p.regs[0].value.toString(16) : null });
      }
      return out;
    },
    // cmux: a message about the machine state (an ELF that could not be read).
    say: (q) => { window.cmuxUI.toast(String((q || {}).message || ''), (q || {}).kind === 'warning' ? 'warning' : 'info'); return true; },
    setMemory: (q) => { Object.assign(st.mem, q || {}); render(); return Object.assign({}, st.mem); },
    // host.js: a reload's new backend: everything is found and built again on the next use.
    backendChanged: () => { changed('cleared'); st.index = null; st.sources = null; st.backend = null; st.k = null; st.kTime = null; st.prevK = null; st.strong = null; if (st.shown) { ensureIndex(); } },
  });
  Object.defineProperty(waveform, 'machine', { value: api, writable: false, configurable: false, enumerable: true });
  // For cmux-debugger.js.
  // For the debugger's cycle post (§6): { commits: [{ k, pc, channel, order }], current, last } for the
  // posedge at `edgeTime`, from a built index only (null otherwise: a post never starts a build).
  function cycleCommits(edgeTime) {
    const ix = st.index;
    if (!ix || st.backend !== host.currentBackend || edgeTime === null || edgeTime === undefined) { return null; }
    const ks = ix.commitsAt(edgeTime);
    const current = currentK();
    return { commits: ks.map((k) => ({ k, pc: ix.pc(k) === null ? null : Number(ix.pc(k)), channel: ix.table.channel[k], order: ix.order(k) === null ? null : Number(ix.order(k)) })),
      current: current < ix.count ? current : null, last: current > 0 ? current - 1 : null };
  }
  window.cmuxMachine = { isGdb: (t) => C.isGdb(t), gdb, envAt, prepare, instructionMode, stepCommit, rowMenuItems, problem: problemText, cycleCommits,
    isName: (path) => Array.isArray(path) && path.length === 1 && MACHINE_NAME.test(String(path[0])),
    backendChanged: () => api.backendChanged() };
})();
