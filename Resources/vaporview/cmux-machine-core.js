// cmux's waveform debugger, machine state (status/asm-breakpoints-design.md §1–§3): the core's
// retired-instruction stream found in a dump, replayed into architectural registers and memory at
// any commit, like gdb's `info registers` and `x/` on a recorded run. Pure: no DOM, no host.
//
// The commit stream's roles and their meaning are the RISC-V Formal Interface's (riscv-formal
// docs/rvfi.md, YosysHQ, ISC licence; names and semantics only, no code):
//
//   Copyright (C) 2017  Claire Xenia Wolf <claire@yosyshq.com>
//   Permission to use, copy, modify, and/or distribute this software for any purpose with or
//   without fee is hereby granted, provided that the above copyright notice and this permission
//   notice appear in all copies.
//
// API (window.cmuxMachineCore):
//   detect(scopes) -> [source, ...] ranked; scopes: [{ path: [...], depth, vars: [{ name, width }] }]
//   mapping(source) -> [{ role, channel, path, msb, lsb, width }]     the signals to read
//   sample(changes, edges, width, slices, preEdge) -> [column, ...]  one per slice
//   buildTable(source, columns, edges) -> table                     columns: { 'role/channel': column }
//   new StateIndex(table, options) -> regs/memory/history at any commit (see the class)
//   gdb(text, ctx) -> { lines, tab } | null                         gdb commands (info registers, p, x/)
(function (root) {
  'use strict';

  const ROLES = ['valid', 'order', 'insn', 'trap', 'halt', 'intr', 'mode', 'ixl', 'rs1_addr', 'rs2_addr', 'rs1_rdata',
    'rs2_rdata', 'rd_addr', 'rd_wdata', 'pc_rdata', 'pc_wdata', 'mem_addr', 'mem_rmask', 'mem_wmask', 'mem_rdata', 'mem_wdata'];
  const ROLE_SET = new Set(ROLES);
  // Names some cores and testbenches use for a role.
  const ALIASES = { inst: 'insn', instr: 'insn' };
  const CSR_PARTS = ['rmask', 'wmask', 'rdata', 'wdata'];
  const ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7',
    's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9', 's10', 's11', 't3', 't4', 't5', 't6'];
  const MAX_SCOPES = 400;
  const MAX_NRET = 8;
  const CHECKPOINT = 65536;
  const PAGE = 4096;

  // ---- detection (§1) ----
  // A var name as (role-ish name, channel index or null): `valid[1]` is channel 1 of `valid`.
  function splitIndex(name) {
    const m = /^(.*?)\[(\d+)\]$/.exec(String(name));
    return m ? { base: m[1], index: Number(m[2]) } : { base: String(name), index: null };
  }

  // Array elements come in two reader styles. FSDB and simple VCD readers put `order[0]` in the scope;
  // wellen reads a VCD `order [0]` as a scope `order` holding vars `[0]`, `[1]` (and merges 1-bit
  // elements `valid [0]`, `valid [1]` into one vector valid[1:0], which the packed rule takes).
  // The scan opens only a scope named like a role (mayHoldElements) and, when it holds nothing but
  // `[i]` vars, folds them into the parent scope as `order[i]` (elementVars).
  const ELEMENT_SCOPE = new RegExp('(^|_)(' + ROLES.concat(Object.keys(ALIASES), CSR_PARTS).join('|') + ')$');
  function mayHoldElements(name) { return ELEMENT_SCOPE.test(String(name)); }
  function elementVars(name, children) {
    const list = children || [];
    if (!list.length || list.some((c) => !c || c.kind !== 'var' || !/^\[\d+\]$/.test(String(c.name)))) { return null; }
    return list.map((c) => ({ name: String(name) + String(c.name), width: Number(c.width) || 1, item: c }));
  }

  // objdump's aliases leave the link register out of a call: jal X and jalr X (and RVC c.jal, c.jalr,
  // printed as the same) write ra. The machine state writes it out, jal ra,X, so the text reads as
  // the write it is and a text search for "jal ra" finds every call. j/jr (rd = x0) and forms that
  // already name rd stay as they are.
  function withLink(text, ra) {
    if (text === null || text === undefined) { return text; }
    const m = /^(jalr?) ([^,\s]+)$/.exec(String(text));
    return m ? m[1] + ' ' + (ra || 'ra') + ',' + m[2] : String(text);
  }

  function roleOf(name) {
    if (ROLE_SET.has(name)) { return name; }
    return ALIASES[name] || null;
  }

  // The roles one scope offers under one prefix: { roles: {role: {byChannel|packed}}, csrs }.
  function rolesUnder(vars, prefix) {
    const roles = {};
    const csrs = {};
    for (const v of vars) {
      const { base, index } = splitIndex(v.name);
      if (!base.startsWith(prefix)) { continue; }
      const rest = base.slice(prefix.length);
      const csr = /^csr_([a-z0-9_]+?)_(rmask|wmask|rdata|wdata)$/.exec(rest);
      const target = csr ? (csrs[csr[1]] = csrs[csr[1]] || {}) : roles;
      const role = csr ? csr[2] : roleOf(rest);
      if (!role) { continue; }
      // `insn` wins over `inst` when a scope has both.
      if (!csr && target[role] && rest !== role && ROLE_SET.has(role) && target[role].exactName) { continue; }
      const entry = target[role] && target[role].exactName === (rest === role) ? target[role]
        : (target[role] = { exactName: rest === role, vars: [] });
      entry.vars.push({ v, index });
    }
    return { roles, csrs };
  }

  // Channels of one role: [{ path, msb, lsb, width }] by channel, or null when they don't fit nret.
  function channelsOf(entry, scopePath, nret, packedRole) {
    if (!entry) { return null; }
    const indexed = entry.vars.filter((x) => x.index !== null);
    if (indexed.length) {
      const out = [];
      for (const x of indexed) {
        if (x.index < nret) { out[x.index] = { path: scopePath.concat([x.v.name]), msb: null, lsb: null, width: Number(x.v.width) || 1 }; }
      }
      for (let c = 0; c < nret; c++) { if (!out[c]) { return null; } }
      return out;
    }
    const v = entry.vars[0].v;
    const width = Number(v.width) || 1;
    if (nret === 1) { return [{ path: scopePath.concat([v.name]), msb: null, lsb: null, width }]; }
    if (width % nret !== 0) { return null; }
    const w = width / nret;
    void packedRole;
    return Array.from({ length: nret }, (_, c) => ({ path: scopePath.concat([v.name]), lsb: c * w, msb: c * w + w - 1, width: w }));
  }

  // A source from a scope's vars under `prefix`, or null (family: 'rvfi' | 'fields').
  function sourceFrom(scope, prefix, family) {
    const { roles, csrs } = rolesUnder(scope.vars, prefix);
    if (!roles.valid || !roles.pc_rdata) { return null; }
    if (family === 'fields') {
      const extra = ['order', 'insn', 'rd_addr', 'rd_wdata', 'mem_addr'].filter((r) => roles[r]).length;
      if (extra < 2) { return null; }
    }
    const validIndexed = roles.valid.vars.filter((x) => x.index !== null);
    let nret;
    let why = null;
    if (validIndexed.length) {
      nret = Math.max(...validIndexed.map((x) => x.index)) + 1;
    } else {
      nret = Number(roles.valid.vars[0].v.width) || 1;
    }
    if (nret < 1 || nret > MAX_NRET) { return { rejected: 'nret', scope: scope.path, nret }; }
    const channels = Array.from({ length: nret }, () => ({}));
    for (const role of Object.keys(roles)) {
      const list = channelsOf(roles[role], scope.path, nret, true);
      if (!list) {
        if (role === 'valid' || role === 'pc_rdata') { why = role; break; }
        continue;
      }
      list.forEach((ref, c) => { channels[c][role] = ref; });
    }
    if (why) { return { rejected: 'width', role: why, scope: scope.path, nret }; }
    const csrOut = {};
    for (const name of Object.keys(csrs)) {
      const parts = {};
      for (const part of CSR_PARTS) {
        const list = channelsOf(csrs[name][part], scope.path, nret, true);
        if (list) { parts[part] = list; }
      }
      if (parts.rdata || parts.wdata) { csrOut[name] = parts; }
    }
    const xlen = channels[0].pc_rdata.width;
    if (xlen !== 32 && xlen !== 64) { return { rejected: 'xlen', scope: scope.path, xlen }; }
    const present = Object.keys(channels[0]);
    return { family, scope: scope.path.slice(), prefix, nret, xlen, channels, csrs: csrOut, roles: present,
      depth: scope.depth || 0, label: scope.path.join('.') + (prefix && family !== 'rvfi' ? '.' + prefix + '*' : '') };
  }

  // Ranked commit sources found in `scopes` (§1 detection, rules 2–4).
  function detect(scopes) {
    const found = [];
    const offers = [];
    for (const scope of (scopes || []).slice(0, MAX_SCOPES)) {
      const vars = (scope.vars || []).filter((v) => v && v.name !== undefined);
      // Rule 2: rvfi_ prefixed.
      const rvfi = sourceFrom({ path: scope.path, depth: scope.depth, vars }, 'rvfi_', 'rvfi');
      if (rvfi && !rvfi.rejected) { found.push(rvfi); continue; }
      // Rule 3: the field set, bare or under one common prefix (`monitor_valid`).
      const prefixes = new Set(['']);
      for (const v of vars) {
        const { base } = splitIndex(v.name);
        const m = /^(.*_)valid$/.exec(base);
        if (m && m[1] !== 'rvfi_') { prefixes.add(m[1]); }
      }
      let got = null;
      for (const prefix of prefixes) {
        const s = sourceFrom({ path: scope.path, depth: scope.depth, vars }, prefix, 'fields');
        if (s && !s.rejected && (!got || s.roles.length > got.roles.length)) { got = s; }
      }
      if (got) { found.push(got); continue; }
      // Rule 4: offered only.
      const valid = vars.find((v) => Number(v.width) === 1 && /(commit|retire)\w*valid|valid\w*(commit|retire)/i.test(v.name));
      const pc = vars.find((v) => (Number(v.width) === 32 || Number(v.width) === 64) && /pc/i.test(v.name));
      if (valid && pc) { offers.push({ family: 'offer', scope: scope.path.slice(), valid: scope.path.concat([valid.name]), pc: scope.path.concat([pc.name]), depth: scope.depth || 0 }); }
    }
    found.sort((a, b) => b.roles.length - a.roles.length || a.depth - b.depth || (a.family === 'rvfi' ? 0 : 1) - (b.family === 'rvfi' ? 0 : 1));
    return found.concat(offers);
  }

  // A source picked by hand: { channels: [{ role: path }] } (paths as segments; channel 0 only for now).
  function manualSource(picks, widths) {
    const ch = {};
    for (const role of Object.keys(picks || {})) {
      const p = picks[role];
      if (!p || !ROLE_SET.has(role)) { continue; }
      const path = Array.isArray(p) ? p : p.path;
      const width = Number((p && p.width) || (widths && widths[JSON.stringify(path)]) || 0) || 1;
      ch[role] = { path: path.slice(), msb: p.msb === undefined ? null : p.msb, lsb: p.lsb === undefined ? null : p.lsb, width };
    }
    if (!ch.valid || !ch.pc_rdata) { return null; }
    const xlen = ch.pc_rdata.width === 64 ? 64 : 32;
    return { family: 'manual', scope: ch.valid.path.slice(0, -1), prefix: '', nret: 1, xlen, channels: [ch], csrs: {}, roles: Object.keys(ch), depth: 0,
      label: ch.valid.path.slice(0, -1).join('.') };
  }

  // The signals a source reads: one entry per (role, channel) plus CSR parts.
  function mapping(source) {
    const out = [];
    source.channels.forEach((ch, c) => {
      for (const role of Object.keys(ch)) { out.push(Object.assign({ role, channel: c }, ch[role])); }
    });
    for (const name of Object.keys(source.csrs || {})) {
      for (const part of Object.keys(source.csrs[name])) {
        source.csrs[name][part].forEach((ref, c) => out.push(Object.assign({ role: 'csr_' + name + '_' + part, channel: c }, ref)));
      }
    }
    return out;
  }

  // ---- columns: a role sampled at each posedge ----
  // A column: { w, lo: Uint32Array, hi: Uint32Array | null, xz: Uint8Array } — bit j of xz[k]: byte j of
  // row k has an x or z bit (values wider than 64 bits keep their low 64).
  function newColumn(w, n) {
    return { w, lo: new Uint32Array(n), hi: w > 32 ? new Uint32Array(n) : null, xz: new Uint8Array(n) };
  }

  // A value's bits (MSB first) to [lo, hi, xzMask], for its low min(w, 64) bits.
  function parseBits(bits, w) {
    let lo = 0, hi = 0, xz = 0;
    const n = bits.length;
    const top = n ? bits[0] : '0';
    // A short value extends with its top x or z, else 0 (VCD's rule).
    const fill = top === 'x' || top === 'X' || top === 'z' || top === 'Z' ? top : '0';
    const limit = Math.min(w, 64);
    for (let i = 0; i < limit; i++) {
      const c = i < n ? bits.charCodeAt(n - 1 - i) : fill.charCodeAt(0);
      if (c === 49) { if (i < 32) { lo |= (1 << i); } else { hi |= (1 << (i - 32)); } } else if (c !== 48) { xz |= 1 << (i >> 3); }
    }
    return [lo >>> 0, hi >>> 0, xz];
  }

  function sliceBits(bits, width, msb, lsb) {
    if (msb === null || msb === undefined) { return bits; }
    let s = String(bits);
    if (s.length < width) {
      const top = s[0];
      const fill = top === 'x' || top === 'z' ? top : '0';
      s = fill.repeat(width - s.length) + s;
    }
    const n = s.length;
    return s.slice(Math.max(0, n - 1 - msb), n - lsb);
  }

  // Each slice of one signal sampled at `edges`: the value in effect at the edge (changes at that
  // time included), or just before it with preEdge. Before its first change a value is x.
  // slices: [{ msb, lsb, width }] (msb null: the whole value); width: the signal's.
  function sample(changes, edges, width, slices, preEdge) {
    const cols = slices.map((s) => newColumn(s.width, edges.length));
    let ci = -1;
    const parsed = slices.map(() => [0, 0, 0xff]);
    const nChanges = changes.length;
    for (let k = 0; k < edges.length; k++) {
      const e = edges[k];
      let moved = false;
      while (ci + 1 < nChanges && (preEdge ? Number(changes[ci + 1][0]) < e : Number(changes[ci + 1][0]) <= e)) { ci++; moved = true; }
      if (moved) {
        const bits = String(changes[ci][1]);
        slices.forEach((s, j) => { parsed[j] = parseBits(sliceBits(bits, width, s.msb, s.lsb), s.width); });
      }
      for (let j = 0; j < slices.length; j++) {
        const c = cols[j], p = parsed[j];
        c.lo[k] = p[0];
        if (c.hi) { c.hi[k] = p[1]; }
        c.xz[k] = ci < 0 ? 0xff : p[2];
      }
    }
    return cols;
  }

  // A column's row as a BigInt (null when it has an x or z bit).
  function big(col, k) {
    if (!col || col.xz[k]) { return null; }
    return col.hi ? (BigInt(col.hi[k]) << 32n) | BigInt(col.lo[k]) : BigInt(col.lo[k]);
  }
  // As a Number when it fits (addresses, masks, small fields); null when unknown.
  function num(col, k) {
    if (!col || col.xz[k]) { return null; }
    return col.hi ? col.hi[k] * 4294967296 + col.lo[k] : col.lo[k];
  }

  // ---- the commit table (§2) ----
  // From columns sampled at every edge (key 'role/channel', and 'csr_<name>_<part>/channel'): one row
  // per channel and edge where valid is 1, sorted by order (when present and known), else by
  // (time, channel). The table's columns are gathered per role across channels.
  function buildTable(source, columns, edges, options) {
    const opts = options || {};
    const nret = source.nret;
    let rows = [];
    for (let c = 0; c < nret; c++) {
      const valid = columns['valid/' + c];
      if (!valid) { continue; }
      for (let k = 0; k < edges.length; k++) {
        if (!valid.xz[k] && (valid.lo[k] & 1)) { rows.push(k * MAX_NRET + c); }
      }
    }
    const edgeOf = (r) => Math.floor(r / MAX_NRET);
    const chanOf = (r) => r % MAX_NRET;
    const hasOrder = source.channels.every((ch) => ch.order);
    const orderKnown = hasOrder && rows.every((r) => !columns['order/' + chanOf(r)].xz[edgeOf(r)]);
    const orderOf = (r) => { const col = columns['order/' + chanOf(r)]; const k = edgeOf(r); return col.hi ? col.hi[k] * 4294967296 + col.lo[k] : col.lo[k]; };
    let heldRepeats = 0;
    if (orderKnown && !opts.timeOrder) {
      rows.sort((a, b) => orderOf(a) - orderOf(b) || a - b);
      // order names one retirement (RVFI): a later row with the same order, pc and insn is valid held
      // high over it (a core parked at its halt loop), not another commit. Another pc stays (a gap).
      const same = (role, a, b) => {
        const ca = columns[role + '/' + chanOf(a)], cb = columns[role + '/' + chanOf(b)];
        if (!ca || !cb) { return true; }
        const ka = edgeOf(a), kb = edgeOf(b);
        return !ca.xz[ka] && !cb.xz[kb] && ca.lo[ka] === cb.lo[kb] && (ca.hi ? ca.hi[ka] : 0) === (cb.hi ? cb.hi[kb] : 0);
      };
      const kept = [];
      for (const r of rows) {
        const prev = kept[kept.length - 1];
        if (prev !== undefined && orderOf(prev) === orderOf(r) && same('pc_rdata', prev, r) && same('insn', prev, r)) { heldRepeats++; continue; }
        kept.push(r);
      }
      rows = kept;
    } else {
      rows.sort((a, b) => a - b);
    }
    const count = rows.length;
    const table = { count, nret, xlen: source.xlen, time: new Float64Array(count), edge: new Int32Array(count), channel: new Uint8Array(count),
      cols: {}, csrs: Object.keys(source.csrs || {}), sortedBy: orderKnown && !opts.timeOrder ? 'order' : 'time', source };
    rows.forEach((r, i) => { table.edge[i] = edgeOf(r); table.time[i] = edges[edgeOf(r)]; table.channel[i] = chanOf(r); });
    const roleNames = new Set();
    for (const key of Object.keys(columns)) { roleNames.add(key.slice(0, key.lastIndexOf('/'))); }
    for (const role of roleNames) {
      if (role === 'valid') { continue; }
      const per = Array.from({ length: nret }, (_, c) => columns[role + '/' + c]);
      if (per.some((x) => !x)) { continue; }
      const w = Math.max(...per.map((x) => x.w));
      const col = newColumn(w, count);
      for (let i = 0; i < count; i++) {
        const src = per[table.channel[i]];
        const k = table.edge[i];
        col.lo[i] = src.lo[k];
        if (col.hi) { col.hi[i] = src.hi ? src.hi[k] : 0; }
        col.xz[i] = src.xz[k];
      }
      table.cols[role] = col;
    }
    table.diagnostics = diagnose(table);
    table.diagnostics.heldRepeats = heldRepeats;
    return table;
  }

  // What is wrong with a stream (§1 diagnostics), each a reason a later oddity has.
  function diagnose(table) {
    const out = { orderContiguous: null, orderGaps: 0, pcXZ: 0, silentChannels: [], rdZeroWrites: 0 };
    const order = table.cols.order;
    if (order && table.sortedBy === 'order') {
      let gaps = 0;
      for (let i = 1; i < table.count; i++) { if (num(order, i) !== num(order, i - 1) + 1) { gaps++; } }
      out.orderGaps = gaps;
      out.orderContiguous = gaps === 0;
    }
    const pc = table.cols.pc_rdata;
    for (let i = 0; i < table.count; i++) { if (pc && pc.xz[i]) { out.pcXZ++; } }
    const seen = new Set();
    for (let i = 0; i < table.count; i++) { seen.add(table.channel[i]); }
    for (let c = 0; c < table.nret; c++) { if (!seen.has(c)) { out.silentChannels.push(c); } }
    const rd = table.cols.rd_addr, wd = table.cols.rd_wdata;
    if (rd && wd) { for (let i = 0; i < table.count; i++) { if (num(rd, i) === 0 && big(wd, i) !== null && big(wd, i) !== 0n) { out.rdZeroWrites++; } } }
    return out;
  }

  // ---- binary searches ----
  // First index i with a[i] >= x (a ascending).
  function lowerBound(a, x, n) {
    let lo = 0, hi = n === undefined ? a.length : n;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (a[mid] < x) { lo = mid + 1; } else { hi = mid; } }
    return lo;
  }

  // Growable Int32 lists.
  class List {
    constructor() { this.a = new Int32Array(8); this.n = 0; }
    push(x) { if (this.n === this.a.length) { const b = new Int32Array(this.a.length * 2); b.set(this.a); this.a = b; } this.a[this.n++] = x; }
  }

  // What memory an instruction may touch, from its encoding: { load, store } in bytes (0: none), or
  // null when it can't be told (no insn, x/z, or not a RISC-V encoding we know). Some cores leave
  // rvfi_mem_* set on other instructions (Ibex keeps the last access's fields), so these gate them.
  function memClass(insn, xlen) {
    if (insn === null || insn === undefined) { return null; }
    const x8 = xlen === 64 ? 8 : 4;
    if ((insn & 3) !== 3) {
      const q = insn & 3, f3 = (insn >>> 13) & 7;
      if (q === 1) { return { load: 0, store: 0 }; }
      if (q === 0 && f3 === 4) {  // Zcb: c.lbu, c.lhu/c.lh, c.sb, c.sh
        const f = (insn >>> 10) & 7;
        return ({ 0: { load: 1, store: 0 }, 1: { load: 2, store: 0 }, 2: { load: 0, store: 1 }, 3: { load: 0, store: 2 } })[f] || null;
      }
      if (q === 0 || q === 2) {
        if (f3 === 1 || f3 === 3) { return { load: 8, store: 0 }; }       // c.fld, c.ld / c.flw (and the sp forms)
        if (f3 === 2) { return { load: 4, store: 0 }; }                   // c.lw, c.lwsp
        if (f3 === 5 || f3 === 7) { return { load: 0, store: 8 }; }       // c.fsd, c.sd / c.fsw
        if (f3 === 6) { return { load: 0, store: 4 }; }                   // c.sw, c.swsp
        return { load: 0, store: 0 };
      }
      return null;
    }
    const op = insn & 0x7f, f3 = (insn >>> 12) & 7;
    if (op === 0x03) { return { load: [1, 2, 4, 8, 1, 2, 4, 0][f3] || null, store: 0 }; }
    if (op === 0x23) { return { load: 0, store: [1, 2, 4, 8][f3] || null }; }
    if (op === 0x07) { return { load: [0, 2, 4, 8, 16][f3] || 8, store: 0 }; }
    if (op === 0x27) { return { load: 0, store: [0, 2, 4, 8, 16][f3] || 8 }; }
    if (op === 0x2f) { const size = f3 === 3 ? 8 : 4; const f5 = insn >>> 27; return { load: f5 === 3 ? 0 : size, store: f5 === 2 ? 0 : size }; }
    if (op === 0x0f) { return null; }  // fences and cache-block ops: left as the stream says
    void x8;
    return { load: 0, store: 0 };
  }

  // ---- the state index (§3.1, §3.3) ----
  // options: { memMask: 'auto' | 'byte' | 'word', trapWrites: 'ignore' | 'apply', image: [{ addr, bytes }],
  //            mmio: [[lo, hi], ...] (hi exclusive), symbols: [{ name, addr, size }] }
  // State "at k" is the state before commit k executes (gdb's convention); k = count is after the last.
  class StateIndex {
    constructor(table, options) {
      const opts = options || {};
      this.table = table;
      this.count = table.count;
      this.xlen = table.xlen;
      this.wordBytes = table.xlen / 8;
      this.trapWrites = opts.trapWrites === 'apply' ? 'apply' : 'ignore';
      this.mmio = (opts.mmio || []).map(([a, b]) => [Number(a), Number(b)]);
      // Mapping symbols ($x, $d) and local labels (.L*) name no object.
      this.symbols = (opts.symbols || []).filter((s) => s && s.name && !/^(\$|\.L)/.test(String(s.name)))
        .map((s) => ({ name: String(s.name), addr: Number(s.addr), size: Number(s.size) || 0 }))
        .sort((a, b) => a.addr - b.addr || (a.size ? 0 : 1) - (b.size ? 0 : 1));
      this.setImage(opts.image || []);
      const c = table.cols;
      this.c = c;
      this.gate(opts.gateByInsn !== false);
      this.memMask = opts.memMask === 'byte' || opts.memMask === 'word' ? opts.memMask : this.detectMask();
      this.build();
    }

    setImage(image) {
      // Byte address -> value, from the ELF's PT_LOAD segments (p_filesz bytes, then zeros to p_memsz).
      this.image = new Map();
      for (const seg of image) {
        const base = Number(seg.addr);
        const bytes = seg.bytes || [];
        const size = Math.max(Number(seg.memsz) || 0, bytes.length);
        for (let i = 0; i < size; i++) { this.image.set(base + i, i < bytes.length ? bytes[i] : 0); }
      }
    }

    // Per commit, the read and write masks to use: the stream's, unless the instruction can't access
    // memory (then none) or accesses fewer bytes than the mask has (then the access's lowest bytes).
    gate(enabled) {
      const c = this.table.cols;
      const n = this.table.count;
      this.rmasks = new Int16Array(n);
      this.wmasks = new Int16Array(n);
      this.gated = { nonMemory: 0, narrowed: 0 };
      const narrow = (m, size) => {
        if (!m || !size || size >= 8) { return m; }
        const lowest = m & -m;
        const keep = (((1 << size) - 1) * lowest) & m;
        return keep;
      };
      for (let k = 0; k < n; k++) {
        let r = num(c.mem_rmask, k) || 0, w = num(c.mem_wmask, k) || 0;
        const cls = enabled && c.insn ? memClass(num(c.insn, k), this.table.xlen) : null;
        if (cls) {
          if ((r && !cls.load) || (w && !cls.store)) { this.gated.nonMemory++; }
          const r2 = cls.load ? narrow(r, cls.load) : 0, w2 = cls.store ? narrow(w, cls.store) : 0;
          if ((cls.load && r2 !== r) || (cls.store && w2 !== w)) { this.gated.narrowed++; }
          r = r2; w = w2;
        }
        this.rmasks[k] = r; this.wmasks[k] = w;
      }
    }

    trapped(k) { const t = this.c.trap; return !!t && !t.xz[k] && (t.lo[k] & 1) === 1; }
    ignored(k) { return this.trapWrites === 'ignore' && this.trapped(k); }

    // Byte- or word-relative masks (§3.1): from the first 10k accesses at an unaligned address.
    detectMask() {
      const { mem_addr: addr } = this.c;
      if (!addr) { return 'byte'; }
      let word = 0, byte = 0, seen = 0;
      for (let k = 0; k < this.count && seen < 10000; k++) {
        const a = num(addr, k);
        for (const m of [this.wmasks[k], this.rmasks[k]]) {
          if (a === null || !m) { continue; }
          seen++;
          const off = a % this.wordBytes;
          if (off === 0) { continue; }
          const lowest = 31 - Math.clz32(m & -m);
          if (lowest === off) { word++; } else if (lowest === 0) { byte++; }
        }
      }
      this.maskEvidence = { word, byte, seen };
      return word > byte ? 'word' : 'byte';
    }

    // The bytes commit k's access touches: [[address, j]] (j: the byte lane in data).
    lanes(k, mask) {
      const a = num(this.c.mem_addr, k);
      if (a === null || !mask) { return []; }
      const base = this.memMask === 'word' ? a - (a % this.wordBytes) : a;
      const out = [];
      for (let j = 0; j < this.wordBytes; j++) { if (mask & (1 << j)) { out.push([base + j, j]); } }
      return out;
    }

    static byteOf(col, k, j) {
      if (col.xz[k] & (1 << j)) { return -1; }
      const word = j < 4 ? col.lo[k] : (col.hi ? col.hi[k] : 0);
      return (word >>> ((j & 3) * 8)) & 0xff;
    }

    build() {
      const c = this.c;
      const n = this.count;
      const t0 = Date.now();
      // Registers: per register, the commits that write it (rd_addr known and nonzero, not ignored).
      this.regWrites = Array.from({ length: 32 }, () => new List());
      this.regReads = Array.from({ length: 32 }, () => new List());
      this.uncertain = new List();  // commits whose rd_addr is x/z: later state is uncertain until rewritten
      const csrNames = this.table.csrs || [];
      this.csrEvents = new Map();
      // Memory: word address -> commits writing (k * 256 + byte mask within the word), and reading.
      this.memWrites = new Map();
      this.memReads = new Map();
      const wb = this.wordBytes;
      const addTo = (map, addr, k) => {
        const word = Math.floor(addr / wb);
        let l = map.get(word);
        if (!l) { l = []; map.set(word, l); }
        const last = l.length ? l[l.length - 1] : -1;
        const bit = 1 << (addr - word * wb);
        if (last >= 0 && Math.floor(last / 256) === k) { l[l.length - 1] = last | bit; } else { l.push(k * 256 + bit); }
      };
      const rd = c.rd_addr, wd = c.rd_wdata;
      for (let k = 0; k < n; k++) {
        const ignore = this.ignored(k);
        for (const [ra, rv] of [[c.rs1_addr, c.rs1_rdata], [c.rs2_addr, c.rs2_rdata]]) {
          const r = num(ra, k);
          if (r !== null && r > 0 && r < 32 && rv && !rv.xz[k]) { this.regReads[r].push(k); }
        }
        if (rd && !ignore) {
          if (rd.xz[k]) { this.uncertain.push(k); } else {
            const r = rd.lo[k] & 31;
            if (r !== 0 && wd) { this.regWrites[r].push(k); }
          }
        }
        if (c.mem_addr && !ignore) {
          const wm = this.wmasks[k];
          if (wm) { for (const [a] of this.lanes(k, wm)) { addTo(this.memWrites, a, k); } }
        }
        if (c.mem_addr) {
          const rmk = this.rmasks[k];
          if (rmk) { for (const [a] of this.lanes(k, rmk)) { addTo(this.memReads, a, k); } }
        }
      }
      // CSRs: a forward pass, since RVFI's wdata holds only the bits under wmask (and rdata under
      // rmask): each event (a read or a write) keeps the value and which bits of it are known after it.
      const full = (1n << BigInt(this.xlen)) - 1n;
      for (const name of csrNames) {
        const col = (p) => c['csr_' + name + '_' + p];
        const ev = { k: new List(), value: [], mask: [], write: [] };
        let cur = 0n, known = 0n;
        for (let k = 0; k < n; k++) {
          const rm = big(col('rmask'), k), rv = big(col('rdata'), k);
          const wm = this.ignored(k) ? 0n : big(col('wmask'), k), wv = big(col('wdata'), k);
          let changed = false, wrote = false;
          if (rm && rv !== null) { const fresh = rm & ~known; if (fresh) { cur = (cur & ~fresh) | (rv & fresh); known |= fresh; changed = true; } }
          if (wm && wv !== null) { cur = (cur & ~wm) | (wv & wm); known |= wm; changed = true; wrote = true; }
          if (wm && wv === null) { known &= ~wm; changed = true; wrote = true; }
          if (changed) { ev.k.push(k); ev.value.push(cur & full); ev.mask.push(known & full); ev.write.push(wrote); }
        }
        this.csrEvents.set(name, ev);
      }
      // Checkpoints every CHECKPOINT commits: which 4 KiB pages were written since the previous one.
      this.checkpoints = [];
      let dirty = new Set();
      for (let k = 0; k < n; k++) {
        if (k % CHECKPOINT === 0) { this.checkpoints.push({ k, pages: dirty }); dirty = new Set(); }
        if (c.mem_addr && !this.ignored(k)) {
          const wm = this.wmasks[k];
          if (wm) { for (const [a] of this.lanes(k, wm)) { dirty.add(Math.floor(a / PAGE)); } }
        }
      }
      this.checkpoints.push({ k: n, pages: dirty });
      this.buildMs = Date.now() - t0;
      this.findDisagreements();
    }

    // ---- registers ----
    // The value of xN before commit k: { value: BigInt | null (x), known, writer: k' | null, from:
    // 'write' | 'read' | 'zero' | null, uncertain }. Unknown (never written, never read before its
    // first write) is { known: false }.
    reg(r, k) {
      if (r === 0) { return { value: 0n, known: true, writer: null, from: 'zero', uncertain: false }; }
      const w = this.regWrites[r];
      const i = lowerBound(w.a, k, w.n) - 1;
      const u = this.uncertain;
      const lastUncertain = u.n ? u.a[lowerBound(u.a, k, u.n) - 1] : undefined;
      if (i >= 0) {
        const writer = w.a[i];
        const uncertain = lastUncertain !== undefined && lastUncertain > writer;
        return { value: big(this.c.rd_wdata, writer), known: true, writer, from: 'write', uncertain };
      }
      const uncertain = lastUncertain !== undefined;
      // Never written before k: a read before its first write saw the value it held since reset.
      const first = w.n ? w.a[0] : Infinity;
      const reads = this.regReads[r];
      if (reads.n && reads.a[0] < first) {
        const j = reads.a[0];
        return { value: this.readValue(r, j), known: true, writer: null, reader: j, from: 'read', uncertain };
      }
      return { value: null, known: false, writer: null, from: null, uncertain };
    }

    readValue(r, j) {
      const c = this.c;
      if (num(c.rs1_addr, j) === r && c.rs1_rdata && !c.rs1_rdata.xz[j]) { return big(c.rs1_rdata, j); }
      return big(c.rs2_rdata, j);
    }

    regs(k) { return Array.from({ length: 32 }, (_, r) => this.reg(r, k)); }

    // The commit before k that wrote xN last / the first at or after k (null: none).
    lastRegWrite(r, k) { const w = this.regWrites[r]; const i = lowerBound(w.a, k, w.n) - 1; return i >= 0 ? w.a[i] : null; }
    nextRegWrite(r, k) { const w = this.regWrites[r]; const i = lowerBound(w.a, k, w.n); return i < w.n ? w.a[i] : null; }

    // What commit k writes (shown as pending): { regs: [{ r, value }], mem: [{ addr, value }], csrs, trap }.
    pending(k) {
      const out = { regs: [], mem: [], csrs: [], trap: false, k };
      if (k < 0 || k >= this.count) { return out; }
      const c = this.c;
      out.trap = this.trapped(k);
      if (this.ignored(k)) { return out; }
      const r = num(c.rd_addr, k);
      if (r !== null && r !== 0 && c.rd_wdata) { out.regs.push({ r, value: big(c.rd_wdata, k) }); }
      const wm = this.wmasks[k];
      if (wm && c.mem_wdata) { for (const [a, j] of this.lanes(k, wm)) { const b = StateIndex.byteOf(c.mem_wdata, k, j); out.mem.push({ addr: a, value: b < 0 ? null : b }); } }
      for (const name of this.table.csrs || []) {
        const wmk = big(c['csr_' + name + '_wmask'], k);
        if (!wmk) { continue; }
        const ev = this.csrEvents.get(name);
        const i = ev ? lowerBound(ev.k.a, k, ev.k.n) : -1;
        out.csrs.push({ name, value: ev && i < ev.k.n && ev.k.a[i] === k ? ev.value[i] : big(c['csr_' + name + '_wdata'], k) });
      }
      return out;
    }

    // ---- CSRs (only where the stream carries them) ----
    // { value, mask (known bits), known (every bit), writer, from }: the state after the last event
    // before k; before any event, what the first one (a read) observed.
    csr(name, k) {
      const ev = this.csrEvents.get(name);
      if (!ev) { return null; }
      const full = (1n << BigInt(this.xlen)) - 1n;
      let i = lowerBound(ev.k.a, k, ev.k.n) - 1;
      let from = 'write';
      if (i < 0) {
        if (!ev.k.n || ev.write[0]) { return { value: null, mask: 0n, known: false, writer: null, from: null }; }
        i = 0;
        from = 'read';
      } else if (!ev.write[i]) {
        from = 'read';
      }
      let writer = null;
      for (let j = i; j >= 0; j--) { if (ev.write[j]) { writer = ev.k.a[j]; break; } }
      return { value: ev.value[i], mask: ev.mask[i], known: ev.mask[i] === full, writer, from, at: ev.k.a[i] };
    }
    lastCsrWrite(name, k) { const ev = this.csrEvents.get(name); if (!ev) { return null; } for (let i = lowerBound(ev.k.a, k, ev.k.n) - 1; i >= 0; i--) { if (ev.write[i]) { return ev.k.a[i]; } } return null; }
    nextCsrWrite(name, k) { const ev = this.csrEvents.get(name); if (!ev) { return null; } for (let i = lowerBound(ev.k.a, k, ev.k.n); i < ev.k.n; i++) { if (ev.write[i]) { return ev.k.a[i]; } } return null; }
    csrNames() { return (this.table.csrs || []).slice(); }

    // ---- memory ----
    // Byte at `addr` before commit k: { value: 0..255 | null (x), known, writer, from: 'write' | 'elf' | 'read' | null }.
    byte(addr, k) {
      const wb = this.wordBytes;
      const word = Math.floor(addr / wb);
      const bit = 1 << (addr - word * wb);
      const writes = this.memWrites.get(word);
      if (writes) {
        // Entries are k * 256 + mask, ascending in k.
        let i = lowerBound(writes, k * 256) - 1;
        for (; i >= 0; i--) {
          const e = writes[i];
          if (e & bit) {
            const writer = Math.floor(e / 256);
            return { value: this.writtenByte(writer, addr), known: true, writer, from: 'write' };
          }
        }
      }
      if (this.image.has(addr)) { return { value: this.image.get(addr), known: true, writer: null, from: 'elf' }; }
      // Never written before k and not in the image: a read before its first write saw it.
      let first = Infinity;
      if (writes) { for (const e of writes) { if (e & bit) { first = Math.floor(e / 256); break; } } }
      const reads = this.memReads.get(word);
      if (reads) {
        for (const e of reads) {
          const j = Math.floor(e / 256);
          if (j >= first) { break; }
          if (e & bit) {
            const v = this.readByte(j, addr);
            if (v !== null) { return { value: v, known: true, writer: null, reader: j, from: 'read' }; }
          }
        }
      }
      return { value: null, known: false, writer: null, from: null };
    }

    laneOf(k, addr) {
      const a = num(this.c.mem_addr, k);
      const base = this.memMask === 'word' ? a - (a % this.wordBytes) : a;
      return addr - base;
    }
    writtenByte(k, addr) { const b = StateIndex.byteOf(this.c.mem_wdata, k, this.laneOf(k, addr)); return b < 0 ? null : b; }
    readByte(k, addr) { const b = StateIndex.byteOf(this.c.mem_rdata, k, this.laneOf(k, addr)); return b < 0 ? null : b; }

    bytes(addr, n, k) { return Array.from({ length: n }, (_, i) => this.byte(addr + i, k)); }

    // A little-endian value of `size` bytes at addr before k: { value: BigInt | null, known, bytes }.
    load(addr, size, k) {
      const bytes = this.bytes(addr, size, k);
      if (bytes.some((b) => !b.known)) { return { value: null, known: false, bytes }; }
      if (bytes.some((b) => b.value === null)) { return { value: null, known: true, x: true, bytes }; }
      let v = 0n;
      for (let i = size - 1; i >= 0; i--) { v = (v << 8n) | BigInt(bytes[i].value); }
      return { value: v, known: true, bytes };
    }

    lastMemWrite(addr, k) {
      const wb = this.wordBytes, word = Math.floor(addr / wb), bit = 1 << (addr - word * wb);
      const w = this.memWrites.get(word);
      if (!w) { return null; }
      for (let i = lowerBound(w, k * 256) - 1; i >= 0; i--) { if (w[i] & bit) { return Math.floor(w[i] / 256); } }
      return null;
    }
    nextMemWrite(addr, k) {
      const wb = this.wordBytes, word = Math.floor(addr / wb), bit = 1 << (addr - word * wb);
      const w = this.memWrites.get(word);
      if (!w) { return null; }
      for (let i = lowerBound(w, k * 256); i < w.length; i++) { if (w[i] & bit) { return Math.floor(w[i] / 256); } }
      return null;
    }

    // Pages written in [k0, k1) (checkpoints bound the scan; §3.3).
    changedPages(k0, k1) {
      const out = new Set();
      const c = this.c;
      if (!c.mem_addr) { return out; }
      for (const cp of this.checkpoints) {
        // A checkpoint's pages were dirtied in [previous k, cp.k).
        const prev = this.checkpoints[this.checkpoints.indexOf(cp) - 1];
        if (!prev) { continue; }
        if (prev.k >= k0 && cp.k <= k1) { cp.pages.forEach((p) => out.add(p)); continue; }
        if (cp.k <= k0 || prev.k >= k1) { continue; }
        for (let k = Math.max(k0, prev.k); k < Math.min(k1, cp.k); k++) {
          if (this.ignored(k)) { continue; }
          const wm = this.wmasks[k];
          if (wm) { for (const [a] of this.lanes(k, wm)) { out.add(Math.floor(a / PAGE)); } }
        }
      }
      return out;
    }

    // Registers written in [k0, k1).
    changedRegs(k0, k1) {
      const out = [];
      for (let r = 1; r < 32; r++) {
        const w = this.regWrites[r];
        const i = lowerBound(w.a, k0, w.n);
        if (i < w.n && w.a[i] < k1) { out.push(r); }
      }
      return out;
    }

    inMmio(addr) { return this.mmio.some(([lo, hi]) => addr >= lo && addr < hi); }

    // A forward replay that checks each read against the state replayed so far (§3.1): rs1/rs2_rdata
    // that disagree with the register's known value (a forwarding bug) and mem_rdata that disagrees
    // with a known write or the image (MMIO, a core bug, or the wrong ELF).
    findDisagreements() {
      const c = this.c;
      const regs = new Array(32).fill(null);  // { value, from }
      regs[0] = { value: 0n, from: 'zero' };
      const mem = new Map();  // addr -> value (null: x)
      this.regDisagreements = [];
      this.memDisagreements = [];
      this.elfMismatch = null;
      const LIMIT = 10000;
      for (let k = 0; k < this.count; k++) {
        for (const [ra, rv, which] of [[c.rs1_addr, c.rs1_rdata, 1], [c.rs2_addr, c.rs2_rdata, 2]]) {
          const r = num(ra, k);
          if (r === null || !rv || rv.xz[k] || r >= 32) { continue; }
          const v = big(rv, k);
          const known = regs[r];
          if (known && known.value !== null && known.value !== v && this.regDisagreements.length < LIMIT) {
            this.regDisagreements.push({ k, reg: r, which, observed: v, expected: known.value, writer: known.writer });
          }
          if (!known) { regs[r] = { value: v, from: 'read', writer: null }; }
        }
        const rmk = this.rmasks[k];
        if (rmk && c.mem_rdata) {
          for (const [a, j] of this.lanes(k, rmk)) {
            const v = StateIndex.byteOf(c.mem_rdata, k, j);
            if (v < 0) { continue; }
            const fromWrite = mem.has(a);
            const expected = fromWrite ? mem.get(a) : (this.image.has(a) ? this.image.get(a) : undefined);
            if (expected !== undefined && expected !== null && expected !== v && !this.inMmio(a)) {
              if (this.memDisagreements.length < LIMIT) { this.memDisagreements.push({ k, addr: a, observed: v, expected, from: fromWrite ? 'write' : 'elf' }); }
              if (!fromWrite && !this.elfMismatch) { this.elfMismatch = { k, addr: a }; }
            }
          }
        }
        if (this.ignored(k)) { continue; }
        const r = num(c.rd_addr, k);
        if (r !== null && r !== 0 && c.rd_wdata) { regs[r] = { value: big(c.rd_wdata, k), from: 'write', writer: k }; }
        if (r === null && c.rd_addr) { for (let i = 1; i < 32; i++) { regs[i] = null; } }
        const wm = this.wmasks[k];
        if (wm && c.mem_wdata) { for (const [a, j] of this.lanes(k, wm)) { const b = StateIndex.byteOf(c.mem_wdata, k, j); mem.set(a, b < 0 ? null : b); } }
      }
    }

    // ---- commits and times ----
    pc(k) {
      if (k < this.count) { return big(this.c.pc_rdata, k); }
      if (this.count && this.c.pc_wdata) { return big(this.c.pc_wdata, this.count - 1); }
      return null;
    }
    insn(k) { return k >= 0 && k < this.count ? num(this.c.insn, k) : null; }
    order(k) { return k >= 0 && k < this.count && this.c.order ? big(this.c.order, k) : null; }
    timeOf(k) { return k >= 0 && k < this.count ? this.table.time[k] : null; }

    // The current commit for a marker on the posedge at `edgeTime`: the first at or after it (§3.1).
    // Times are per (time, channel) sorted only when sorted by time; by order they are nearly so:
    // the first commit in program order whose time is >= edgeTime.
    commitAt(edgeTime) {
      if (edgeTime === null || edgeTime === undefined) { return 0; }
      if (!this.timeIndex) {
        // Program-order indices sorted by time (stable), for out-of-order NRET > 1 streams.
        const idx = Array.from({ length: this.count }, (_, i) => i);
        if (this.table.sortedBy === 'order') { idx.sort((a, b) => this.table.time[a] - this.table.time[b] || a - b); }
        this.timeIndex = Int32Array.from(idx);
        this.timeSorted = Float64Array.from(idx.map((i) => this.table.time[i]));
      }
      const i = lowerBound(this.timeSorted, edgeTime);
      if (i >= this.count) { return this.count; }
      // The earliest in program order among those at that time.
      const t = this.timeSorted[i];
      let best = this.timeIndex[i];
      for (let j = i; j < this.count && this.timeSorted[j] === t; j++) { best = Math.min(best, this.timeIndex[j]); }
      return best;
    }

    // Commits in the cycle at `edgeTime` (program order).
    commitsAt(edgeTime) {
      const out = [];
      const k0 = this.commitAt(edgeTime);
      for (let k = k0; k < this.count && this.table.time[k] === edgeTime; k++) { out.push(k); }
      return out;
    }

    symbolFor(addr) {
      const s = this.symbols;
      let lo = 0, hi = s.length - 1, at = -1;
      while (lo <= hi) { const mid = (lo + hi) >> 1; if (s[mid].addr <= addr) { at = mid; lo = mid + 1; } else { hi = mid - 1; } }
      if (at < 0) { return null; }
      while (at > 0 && s[at - 1].addr === s[at].addr) { at--; }
      const sym = s[at];
      const off = addr - sym.addr;
      if (sym.size && off >= sym.size) {
        // Past its end: only labels (size 0) at the same address still name it.
        return off === 0 ? { name: sym.name, offset: 0 } : null;
      }
      return { name: sym.name, offset: off };
    }
    symbolAddr(name) { const s = this.symbols.find((x) => x.name === name); return s ? s.addr : null; }

    // A commit that fetched the instruction at `pc` (for x/i without an image): its insn, or null.
    fetchedAt(pc) {
      if (!this.fetchMap) {
        this.fetchMap = new Map();
        for (let k = 0; k < this.count; k++) {
          const p = num(this.c.pc_rdata, k);
          const i = num(this.c.insn, k);
          if (p !== null && i !== null && !this.fetchMap.has(p)) { this.fetchMap.set(p, i); }
        }
      }
      return this.fetchMap.has(pc) ? this.fetchMap.get(pc) : null;
    }
  }

  // ---- names: $x5, $a0, $pc, CSR names ----
  function regNumber(name) {
    const n = String(name).replace(/^\$/, '').toLowerCase();
    let m = /^x(\d{1,2})$/.exec(n);
    if (m && Number(m[1]) < 32) { return Number(m[1]); }
    if (n === 'fp') { return 8; }
    const i = ABI.indexOf(n);
    return i >= 0 ? i : null;
  }

  // ---- formatting ----
  const hex = (v, digits) => (v === null || v === undefined ? null : '0x' + BigInt(v).toString(16).padStart(digits || 0, '0'));
  function signedOf(v, bits) { const b = BigInt(bits); const top = 1n << (b - 1n); return v >= top ? v - (1n << b) : v; }

  // ---- gdb commands (§3.6) ----
  // ctx: { index (StateIndex), k, xlen, evaluate(exprText) -> { value: BigInt|null, error } ,
  //        disasm(word) -> text | null, pendingOf?, last: { fmt, unit } (kept between calls), history }
  // `info registers`, `p/x …`, `x/8xw …` always; `p …` and `x …` only when the text is not a
  // SystemVerilog expression (so `x + 1` and `p` are signals).
  const GDB_RE = /^(?:(?:info|i)\s+(?:r|reg|registers|all-registers|symbol)\b|(?:p|print|output)\/\w+|x\/\w*)/;
  const GDB_BARE = /^(?:p|print|output|x)\s+\S/;
  function isGdb(text) {
    const t = String(text || '').trim();
    if (GDB_RE.test(t)) { return true; }
    if (!GDB_BARE.test(t)) { return false; }
    const parser = root.cmuxExpr;
    return !parser || !!parser.parse(t).error;
  }

  // gdb-style C/hex literals and symbols to cmux-expr's SystemVerilog: 0x10 -> 64'h10, sym -> address.
  function gdbExpr(text, ctx) {
    return String(text).replace(/&?\b([A-Za-z_.][A-Za-z0-9_.$]*)\b|0x([0-9a-fA-F]+)\b|\b(\d+)\b(?!')/g, (all, name, hx, dec, offset, whole) => {
      if (hx !== undefined) { return "64'h" + hx; }
      if (dec !== undefined) { return all; }
      // Not after `$` (a register) or `'` (a literal's base).
      const before = whole[offset - 1];
      if (before === '$' || before === "'") { return all; }
      const addr = ctx.index && ctx.index.symbolAddr(name.replace(/^&/, ''));
      return addr !== null && addr !== undefined ? "64'h" + addr.toString(16) : all;
    });
  }

  function gdb(text, ctx) {
    const t = String(text || '').trim();
    if (!isGdb(t)) { return null; }
    const ix = ctx.index;
    const xl = ix ? ix.xlen : 32;
    const digits = xl / 4;
    const lines = [];
    let m;
    if ((m = /^(?:info|i)\s+symbol\s+(.+)$/.exec(t))) {
      const r = ctx.evaluate(gdbExpr(m[1], ctx));
      if (r.error) { return { lines: [r.error], tab: null, error: true }; }
      const s = ix && r.value !== null ? ix.symbolFor(Number(r.value)) : null;
      return { lines: [s ? s.name + (s.offset ? ' + ' + s.offset : '') : 'No symbol matches ' + m[1].trim() + '.'], tab: 'memory' };
    }
    if ((m = /^(?:info|i)\s+(?:r|reg|registers|all-registers)\b\s*(.*)$/.exec(t))) {
      if (!ix) { return { lines: [ctx.noState || 'No commit stream.'], tab: null, error: true }; }
      const k = ctx.k;
      const want = m[1].trim() ? m[1].trim().split(/\s+/) : null;
      const pend = ix.pending(k);
      const names = want || ABI.slice(1).concat(['pc']);
      for (const raw of names) {
        const name = raw.replace(/^\$/, '');
        let text;
        if (name === 'pc') {
          const pc = ix.pc(k);
          const sym = pc !== null ? ix.symbolFor(Number(pc)) : null;
          text = pc === null ? '—' : hex(pc, digits).padEnd(19) + (sym ? '<' + sym.name + (sym.offset ? '+' + sym.offset : '') + '>' : '');
        } else {
          const r = regNumber(name);
          if (r === null) {
            const csr = ix.csr(name, k);
            if (!csr) { lines.push('Invalid register `' + name + "'"); continue; }
            text = !csr.known ? '—' : hex(csr.value, digits).padEnd(19) + csr.value.toString(10);
          } else {
            const v = ix.reg(r, k);
            const p = pend.regs.find((x) => x.r === r);
            text = !v.known ? '—' : (v.value === null ? 'x' : hex(v.value, digits).padEnd(19) + (['sp', 'gp', 'tp', 'ra'].includes(ABI[r]) ? hex(v.value) : signedOf(v.value, xl).toString(10)));
            if (v.uncertain) { text += ' ?'; }
            if (p) { text += '  → ' + (p.value === null ? 'x' : hex(p.value, digits)); }
          }
        }
        const label = regNumber(name) !== null ? ABI[regNumber(name)] : name;
        lines.push(label.padEnd(15) + text);
      }
      return { lines, tab: 'registers' };
    }
    if ((m = /^(p|print|output)(?:\/(\w+))?\s*(.*)$/.exec(t))) {
      const fmt = (m[2] || '').replace(/\d+/g, '').slice(-1) || null;
      if (!m[3].trim()) { return { lines: ['The history is empty.'], tab: null, error: true }; }
      const r = ctx.evaluate(gdbExpr(m[3], ctx));
      if (r.error) { return { lines: [r.error], tab: null, error: true }; }
      const width = r.width || xl;
      const text = r.value === null ? (r.text || 'x') : formatScalar(r.value, fmt || 'd', width);
      ctx.history = (ctx.history || 0) + 1;
      return { lines: [m[1] === 'output' ? text : '$' + ctx.history + ' = ' + text], tab: /\$/.test(m[3]) ? 'registers' : null, history: ctx.history };
    }
    if ((m = /^x(?:\/(\d*)([xduotacsi]?)([bhwg]?)([xduotacsi]?))?\s*(.*)$/.exec(t))) {
      if (!ix) { return { lines: [ctx.noState || 'No commit stream.'], tab: null, error: true }; }
      const last = ctx.last || (ctx.last = { fmt: 'x', unit: 'w', addr: null });
      const count = m[1] ? Math.min(4096, Number(m[1])) : 1;
      const fmt = m[2] || m[4] || last.fmt;
      let unit = m[3] || (fmt === 'a' ? (xl === 64 ? 'g' : 'w') : (fmt === 'c' ? 'b' : last.unit));
      let addr;
      if (m[5].trim()) {
        const r = ctx.evaluate(gdbExpr(m[5], ctx));
        if (r.error) { return { lines: [r.error], tab: null, error: true }; }
        if (r.value === null) { return { lines: ['Cannot access memory at an unknown address.'], tab: null, error: true }; }
        addr = Number(r.value);
      } else if (last.addr !== null) {
        addr = last.addr;
      } else {
        return { lines: ['Argument required (starting display address).'], tab: null, error: true };
      }
      last.fmt = fmt;
      if (fmt !== 'i' && fmt !== 's') { last.unit = unit; }
      const out = memoryLines(ix, ctx, addr, count, fmt, unit);
      last.addr = out.next;
      return { lines: out.lines, tab: 'memory', addr, fmt, unit, count };
    }
    return null;
  }

  const UNIT_BYTES = { b: 1, h: 2, w: 4, g: 8 };
  function formatScalar(v, fmt, bits) {
    const width = BigInt(bits || 64);
    const mask = (1n << width) - 1n;
    const u = BigInt(v) & mask;
    switch (fmt) {
      case 'x': return '0x' + u.toString(16);
      case 'o': return '0' + u.toString(8);
      case 't': return u.toString(2);
      case 'u': return u.toString(10);
      case 'c': { const c = Number(u & 0xffn); return c + " '" + (c >= 32 && c < 127 ? String.fromCharCode(c) : '\\' + c.toString(8).padStart(3, '0')) + "'"; }
      case 'a': return '0x' + u.toString(16);
      default: return signedOf(u, bits || 64).toString(10);
    }
  }

  function label(ix, addr) {
    const s = ix.symbolFor(addr);
    return '0x' + addr.toString(16) + (s ? ' <' + s.name + (s.offset ? '+' + s.offset : '') + '>' : '') + ':';
  }

  // x/ output as gdb prints it; unknown bytes are `??` (or `—` for a whole unknown unit).
  function memoryLines(ix, ctx, start, count, fmt, unit) {
    const lines = [];
    const k = ctx.k;
    if (fmt === 'i') {
      let a = start;
      const pc = ix.pc(k);
      for (let n = 0; n < count; n++) {
        const lo = ix.load(a, 2, k);
        let word = null, size = 4;
        if (lo.known && lo.value !== null) {
          size = (Number(lo.value) & 3) === 3 ? 4 : 2;
          const full = size === 4 ? ix.load(a, 4, k) : lo;
          if (full.known && full.value !== null) { word = Number(full.value); }
        }
        if (word === null) {
          const f = ix.fetchedAt(a);
          if (f !== null) { word = f; size = (f & 3) === 3 ? 4 : 2; }
        }
        const text = word === null ? '??' : ((ctx.disasm && ctx.disasm(size === 2 ? word & 0xffff : word >>> 0)) || '.word 0x' + (word >>> 0).toString(16));
        lines.push((pc !== null && Number(pc) === a ? '=> ' : '   ') + label(ix, a) + '\t' + text);
        a += size;
      }
      return { lines, next: a };
    }
    if (fmt === 's') {
      let a = start;
      for (let n = 0; n < count; n++) {
        let s = '';
        const begin = a;
        for (let i = 0; i < 200; i++, a++) {
          const b = ix.byte(a, k);
          if (!b.known || b.value === null) { s += '?'; continue; }
          if (b.value === 0) { a++; break; }
          s += b.value >= 32 && b.value < 127 ? String.fromCharCode(b.value) : '\\' + b.value.toString(8).padStart(3, '0');
        }
        lines.push(label(ix, begin) + '\t"' + s + '"');
      }
      return { lines, next: a };
    }
    const size = UNIT_BYTES[unit] || 4;
    const perLine = fmt === 'c' ? 8 : ({ 1: 8, 2: 8, 4: 4, 8: 2 })[size];
    let a = start;
    let row = [];
    let rowStart = a;
    const flush = () => { if (row.length) { lines.push(label(ix, rowStart) + '\t' + row.join('\t')); row = []; } };
    for (let n = 0; n < count; n++) {
      if (row.length === perLine) { flush(); }
      if (!row.length) { rowStart = a; }
      const v = ix.load(a, size, k);
      if (!v.known) {
        row.push(v.bytes.every((b) => !b.known) ? '—' : v.bytes.slice().reverse().map((b) => (!b.known ? '??' : (b.value === null ? 'xx' : b.value.toString(16).padStart(2, '0')))).join(''));
      } else if (v.value === null) {
        row.push('x');
      } else {
        row.push(fmt === 'x' ? '0x' + v.value.toString(16).padStart(size * 2, '0') : formatScalar(v.value, fmt, size * 8));
      }
      a += size;
    }
    flush();
    return { lines, next: a };
  }

  root.cmuxMachineCore = Object.freeze({
    ROLES, ABI, CHECKPOINT, memClass, withLink, mayHoldElements, elementVars, detect, manualSource, mapping, sample, parseBits, sliceBits, buildTable, diagnose, StateIndex,
    regNumber, hex, signedOf, gdb, isGdb, gdbExpr, formatScalar, memoryLines, big, num,
  });
})(typeof window !== 'undefined' ? window : globalThis);
