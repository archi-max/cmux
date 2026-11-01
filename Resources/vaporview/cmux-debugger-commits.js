// Commit breakpoints for cmux's waveform debugger (written for cmux; design: status/asm-breakpoints-
// design.md §4, §3.6): stop where the dump's commit stream (RVFI and the like; the commit index of
// cmux-machine.js, window.cmuxWaveform.commits) commits
//   pc          an instruction at one of `pcs` (on `channel`, when pinned): Break at Address…, the
//               listing's gutter (cmux sets those, each with its `key`)
//   commitText  an instruction whose text (the viewer's RISC-V format) matches `pattern`:
//               Break When Next Instruction Matches…
//   write       an instruction that writes `loc` (a register, a CSR, or memory bytes): Break When Written…
// cmux-debugger.js owns the list, the search and the landing; this file gives a commit breakpoint's
// fields, label and hit times (commit times are posedges, so a hit lands on its own cycle).
//
// Each index (the same object until it is rebuilt) is scanned once for all PC breakpoints together
// (pc -> commits) and once for the instruction words (word -> commits); a breakpoint's times are kept
// until the index changes.
//
// window.cmuxWaveform.debuggerCommits:
//   isKind(kind) -> bool
//   fields(kind, item) -> the fields a breakpoint of `kind` keeps (and cmux saves)
//   check(kind, fields) -> null | 'address' | 'location' | 'pattern' | 'patternTooLong'
//   parseAddress(text) -> '0x…' | null        parseLocation(text) -> 'a0' | 'csr:mstatus' | 'mem:0x…/4' | null
//   label(bp) -> string                       errorText(error) -> string
//   times(bp, warn) -> Promise<Float64Array | null | undefined>   (undefined: the index is still building)
//   kAt(bp, time) -> the first of bp's commits at `time` (program order), or null
//   landed(bp, time): after a hit, the Machine section's current commit is that one
//   scopeOf(bp) -> the commit source's instance path (a condition's names), or null
// and for cmux's listings (WaveformDebuggerAsmBreakpoints.swift):
//   postCurrent(edgeTime): posts { event: 'commitPcs', pcs, current } for the commits at that posedge
//                          (null: none, after Stop), when it changed
//   currentPc(edgeTime) -> '0x…' | null     sample(limit) -> Promise<[{ pc, insn }] | null> (distinct PCs)
//   and posts { event: 'commitsReady' } each time the commit index is (re)built.
(function () {
  const waveform = window.cmuxWaveform;
  const S = () => waveform.strings || {};
  const TB = waveform.debuggerText;
  const T = window.cmuxTextMatch;
  const KINDS = new Set(['pc', 'commitText', 'write']);
  const MAX_PCS = 64;          // addresses per PC breakpoint
  const MEMORY_BYTES = 4;      // a memory location without a size: one word
  const ABI = ['zero', 'ra', 'sp', 'gp', 'tp', 't0', 't1', 't2', 's0', 's1', 'a0', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7',
    's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9', 's10', 's11', 't3', 't4', 't5', 't6'];
  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }
  const isKind = (kind) => KINDS.has(kind);

  // '0x80000010', '80000010', '8000_0010' (addresses are hex, as objdump prints them): '0x80000010'.
  function parseAddress(text) {
    const s = String(text === undefined || text === null ? '' : text).trim().toLowerCase().replace(/_/g, '');
    const m = /^(?:0x)?([0-9a-f]{1,16})$/.exec(s);
    return m ? '0x' + BigInt('0x' + m[1]).toString(16) : null;
  }

  const isRegister = (n) => /^x([0-9]|[12][0-9]|3[01])$/.test(n) || n === 'fp' || ABI.includes(n);
  // 'a0', 'x5', 'fp': that register; '[0x80001000]' (a word) or '[0x80001000]/1' (bytes): memory;
  // 'mstatus', 'csr mstatus': a CSR, by the name the commit stream gives it.
  function parseLocation(text) {
    const s = String(text === undefined || text === null ? '' : text).trim().toLowerCase();
    const mem = /^(?:mem\s*)?\[\s*([^\]\s]+)\s*\](?:\s*\/\s*(\d+))?$/.exec(s);
    if (mem) {
      const addr = parseAddress(mem[1]);
      const size = mem[2] === undefined ? MEMORY_BYTES : Number(mem[2]);
      if (!addr || !(size >= 1 && size <= 64)) { return null; }
      return 'mem:' + addr + '/' + size;
    }
    const reg = s.replace(/^\$/, '');
    if (isRegister(reg)) { return reg; }
    if (/^x\d+$/.test(reg)) { return null; }
    const csr = /^(?:csr\s+)?([a-z][a-z0-9_]*)$/.exec(s);
    return csr && !isRegister(csr[1]) ? 'csr:' + csr[1] : null;
  }

  function fields(kind, item) {
    const q = item || {};
    if (kind === 'pc') {
      const pcs = (Array.isArray(q.pcs) ? q.pcs : (q.pc !== undefined ? [q.pc] : [])).map(parseAddress);
      return { pcs: pcs.every(Boolean) ? Array.from(new Set(pcs)).slice(0, MAX_PCS) : [],
        channel: Number.isInteger(q.channel) && q.channel >= 0 ? q.channel : null,
        key: q.key ? String(q.key) : null, listingLabel: q.listingLabel ? String(q.listingLabel) : null };
    }
    if (kind === 'commitText') {
      return { pattern: String(q.pattern === undefined || q.pattern === null ? '' : q.pattern), caseSensitive: !!q.caseSensitive,
        anyRegisterNames: q.anyRegisterNames !== false };
    }
    return { loc: parseLocation(String(q.loc || '').replace(/^mem:(0x[0-9a-f]+)\/(\d+)$/, '[$1]/$2').replace(/^csr:/, 'csr ')) };
  }

  function check(kind, f) {
    if (kind === 'pc') { return f.pcs && f.pcs.length ? null : 'address'; }
    if (kind === 'write') { return f.loc ? null : 'location'; }
    if (!f.pattern) { return 'pattern'; }
    return f.pattern.length > T.MAX_PATTERN ? 'patternTooLong' : null;
  }

  const locationText = (loc) => (loc.startsWith('mem:')
    ? (loc.endsWith('/' + MEMORY_BYTES) ? '[' + loc.slice(4, loc.lastIndexOf('/')) + ']' : '[' + loc.slice(4).replace('/', ']/'))
    : loc.replace(/^csr:/, ''));

  function label(bp) {
    const s = S();
    if (bp.kind === 'pc') {
      const where = bp.pcs.join(', ');
      return bp.listingLabel ? format(s.debuggerBreakpointPcAt, bp.listingLabel, where) : format(s.debuggerBreakpointPc, where);
    }
    if (bp.kind === 'commitText') { return format(s.debuggerBreakpointCommitText, bp.pattern); }
    return format(s.debuggerBreakpointWritten, locationText(bp.loc || '?'));
  }

  function errorText(error) {
    const s = S();
    return { address: s.debuggerCommitBadAddress, location: s.debuggerCommitBadLocation, pattern: s.debuggerTextNoPattern,
      patternTooLong: format(s.debuggerTextPatternTooLong, T.MAX_PATTERN) }[error] || error;
  }

  // ---- the index's tables, built once per index ----
  let tablesFor = null;
  let tables = null;
  function tablesOf(ix) {
    if (tablesFor !== ix) { tablesFor = ix; tables = {}; }
    return tables;
  }
  // value -> commits (ascending), for a column.
  function postings(values, skip) {
    const lists = new Map();
    for (let k = 0; k < values.length; k++) {
      const v = values[k];
      if (skip && skip(k)) { continue; }
      let l = lists.get(v);
      if (!l) { l = []; lists.set(v, l); }
      l.push(k);
    }
    return lists;
  }
  function byPc(ix) {
    const t = tablesOf(ix);
    if (!t.pc) { t.pc = postings(ix.pc); }  // an x pc (NaN) is a key no address asks for
    return t.pc;
  }
  function byInsn(ix) {
    const t = tablesOf(ix);
    if (!t.insn) { t.insn = postings(ix.insn, (k) => Number.isNaN(ix.pc[k])); }
    return t.insn;
  }

  // ---- hits ----
  const commitsApi = () => waveform.commits || null;

  async function indexOf(bp, warn) {
    subscribe();
    const api = commitsApi();
    if (!api) { warn(format(S().debuggerCommitsNone, label(bp))); return null; }
    let ix = null;
    try { ix = await api.index(); } catch (error) { ix = null; }
    if (!ix) { warn(format(S().debuggerCommitsNone, label(bp))); return null; }
    return ix;
  }

  async function commitsOf(bp, ix, warn) {
    if (bp.kind === 'pc') {
      const table = byPc(ix);
      let ks = [];
      for (const pc of bp.pcs) { ks = ks.concat(table.get(Number(BigInt(pc))) || []); }
      return bp.channel === null ? ks : ks.filter((k) => ix.channel[k] === bp.channel);
    }
    if (bp.kind === 'commitText') {
      if (!ix.insn) { warn(format(S().debuggerCommitsNoInsn, label(bp))); return null; }
      const table = byInsn(ix);
      const words = Array.from(table.keys());
      const bits = words.map((w) => (w >>> 0).toString(2).padStart(32, '0'));
      const spec = { format: 'riscv', pattern: bp.pattern, caseSensitive: bp.caseSensitive, anyRegisterNames: bp.anyRegisterNames };
      const verdicts = await TB.verdicts('\u0000commits', spec, bits, (text) => warn(format(S().debuggerTextError, label(bp), text)));
      if (!verdicts) { return null; }
      let ks = [];
      words.forEach((w, i) => { if (verdicts.get(bits[i])) { ks = ks.concat(table.get(w)); } });
      return ks;
    }
    const api = commitsApi();
    const loc = bp.loc;
    if (loc.startsWith('mem:')) {
      const addr = BigInt(loc.slice(4, loc.lastIndexOf('/')));
      const size = Number(loc.slice(loc.lastIndexOf('/') + 1));
      let ks = [];
      for (let i = 0; i < size; i++) { ks = ks.concat((await api.writesOf({ loc: { addr: Number(addr + BigInt(i)) } })) || []); }
      return ks;
    }
    const query = loc.startsWith('csr:') ? { csr: loc.slice(4) } : loc;
    return (await api.writesOf({ loc: query })) || [];
  }

  // bp.commitHits: { ix, times (unique, ascending), at: [[time, k]] by time then k }.
  async function times(bp, warn) {
    const error = check(bp.kind, bp);
    if (error) { warn(format(S().debuggerCommitError, label(bp), errorText(error))); return null; }
    const ix = await indexOf(bp, warn);
    if (!ix) { return null; }
    const key = JSON.stringify([bp.kind, bp.pcs, bp.channel, bp.pattern, bp.caseSensitive, bp.anyRegisterNames, bp.loc]);
    if (bp.commitHits && bp.commitHits.ix === ix && bp.commitHits.key === key) { return bp.commitHits.times; }
    const ks = await commitsOf(bp, ix, warn);
    if (!ks) { return null; }
    const at = Array.from(new Set(ks)).map((k) => [ix.time[k], k]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const out = [];
    for (const [time] of at) { if (!out.length || out[out.length - 1] !== time) { out.push(time); } }
    bp.commitHits = { ix, key, times: Float64Array.from(out), at };
    return bp.commitHits.times;
  }

  function kAt(bp, time) {
    const at = bp.commitHits ? bp.commitHits.at : null;
    if (!at) { return null; }
    let lo = 0, hi = at.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (at[mid][0] < time) { lo = mid + 1; } else { hi = mid; } }
    return lo < at.length && at[lo][0] === time ? at[lo][1] : null;
  }

  // The commit source's instance (the index's `scope`, when it names one) for a condition's names; null: from the top.
  function scopeOf(bp) {
    const ix = bp.commitHits ? bp.commitHits.ix : null;
    return ix && Array.isArray(ix.scope) && ix.scope.length ? ix.scope.map(String) : null;
  }

  // ---- the commits at the marker, for cmux's listings ----
  const hexOf = (pc) => '0x' + pc.toString(16);
  function byTime(ix) {
    const t = tablesOf(ix);
    if (!t.byTime) {
      const ks = Array.from({ length: ix.count }, (_, k) => k);
      if (ix.sortedBy === 'order') { ks.sort((a, b) => ix.time[a] - ix.time[b] || a - b); }
      t.byTime = Int32Array.from(ks);
    }
    return t.byTime;
  }
  // The commits at `time`, in program order.
  function commitsAt(ix, time) {
    const order = byTime(ix);
    let lo = 0, hi = order.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (ix.time[order[mid]] < time) { lo = mid + 1; } else { hi = mid; } }
    const out = [];
    for (let i = lo; i < order.length && ix.time[order[i]] === time; i++) { out.push(order[i]); }
    return out.sort((a, b) => a - b);
  }
  function currentAt(time) {
    subscribe();
    const api = commitsApi();
    const ix = api && typeof api.current === 'function' ? api.current() : null;
    if (!ix || time === null || time === undefined) { return { pcs: [], current: null }; }
    const ks = commitsAt(ix, time).filter((k) => !Number.isNaN(ix.pc[k]));
    // The Machine section's own commit, when it is one of these (stepping by commit within a cycle).
    const own = api.currentK ? api.currentK() : null;
    const k = ks.includes(own) ? own : (ks.length ? ks[0] : null);
    return { pcs: ks.map((j) => hexOf(ix.pc[j])), current: k === null ? null : hexOf(ix.pc[k]) };
  }
  let lastPosted = null;
  function postCurrent(time) {
    const now = currentAt(time);
    const key = JSON.stringify(now);
    if (key === lastPosted || (lastPosted === null && !now.pcs.length)) { return; }
    lastPosted = key;
    waveform.host.toNative(Object.assign({ type: 'debugger', event: 'commitPcs' }, now));
  }
  const currentPc = (time) => currentAt(time).current;

  async function sample(limit) {
    subscribe();
    const api = commitsApi();
    let ix = null;
    try { ix = api ? await api.index() : null; } catch (error) { ix = null; }
    if (!ix || !ix.insn) { return null; }
    const max = Math.max(1, Math.min(Number(limit) || 1000, 100000));
    const seen = new Set();
    const out = [];
    for (let k = 0; k < ix.count && out.length < max; k++) {
      const pc = ix.pc[k];
      if (Number.isNaN(pc) || seen.has(pc)) { continue; }
      seen.add(pc);
      out.push({ pc: hexOf(pc), insn: ix.insn[k] >>> 0 });
    }
    return out;
  }

  // cmux checks its listings against the stream each time it is built.
  let subscribedTo = null;
  function subscribe() {
    const api = commitsApi();
    if (!api || api === subscribedTo || typeof api.onChange !== 'function') { return; }
    subscribedTo = api;
    api.onChange((change) => {
      if (change && change.reason === 'ready') { waveform.host.toNative({ type: 'debugger', event: 'commitsReady' }); }
    });
  }
  // cmux-machine.js loads after this file.
  if (typeof setTimeout === 'function') { setTimeout(subscribe, 0); }

  function landed(bp, time) {
    const k = kAt(bp, time);
    const machine = waveform.machine;
    if (k === null || !machine || typeof machine.goToCommit !== 'function') { return null; }
    try { machine.goToCommit({ k }); } catch (error) { return null; }
    return k;
  }

  waveform.debuggerCommits = Object.freeze({ isKind, fields, check, parseAddress, parseLocation, label, errorText, times, kAt, landed,
    scopeOf, locationText, MAX_PCS, postCurrent, currentPc, sample, subscribe });
})();
