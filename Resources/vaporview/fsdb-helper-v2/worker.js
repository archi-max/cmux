// Part of cmux's FSDB helper v2, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose helper it extends; see ../LICENSE.
// FSDB helper v2 worker: one of a pool forked by helper.js. Opens the dump
// itself and keeps the signals routed to it in the addon's compact store, so
// window/valueAt/edge/search are answered in C++ without re-walking.
// Talks to the coordinator over the Node IPC channel (advanced serialization,
// so Buffers pass as bytes). The coordinator sends one task at a time.
//
// Background tasks (searchScan, searchExpr, warm) run in the addon's
// background mode: they stop early when the coordinator sends SIGUSR2
// (interactive work is waiting) or their deadline passes, and report the
// signals they didn't finish as {signalId, yielded: true}.
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const zlib = require('node:zlib');

const DERIVED_BASE = 1e9;  // as helper.js
const TEMP_ID = 2e9;       // scratch derived store for searchAll expr
const text = require('./text.js');
const addon = require(process.env.FSDB_ADDON || path.join(__dirname, 'addon/build/Release/fsdb_reader.node'));
// Install the SIGUSR2 (yield) handler now: the coordinator may signal a worker
// whose first background task hasn't started yet, and the default action kills.
addon.bgBegin(0);
addon.bgEnd();
let openFile = null;
let cacheLimit = 0;
// Memory bound for this process (store + reader + V8). The reader keeps memory
// after signals are unloaded, so after many loads (searchAll, warm-up) RSS
// creeps up. Over the cap the store is shrunk first; if RSS stays over, the
// reply asks to be recycled (the coordinator replaces the process when it's
// idle) and, at twice the cap, work that would load more fails.
const RSS_CAP = Number(process.env.FSDB_WORKER_RSS_MB || 0) * 1e6;
let recycle = false;
// Floor: never below this worker's own RSS right after open + RSS_HEADROOM. A cap under what an
// idle worker needs would recycle every fresh worker at once, forever (a fork storm). A raised
// cap is reported (state.capRaised) so the coordinator can warn once.
const RSS_HEADROOM = Number(process.env.FSDB_RSS_HEADROOM_MB ?? 16) * 1e6;  // (tests set it negative to defeat the floor)
let rssFloor = 0, capRaised = null;
const rssCap = () => Math.max(RSS_CAP || Math.max(1024e6, 2 * cacheLimit + 512e6), rssFloor);
const NO_FILE_OK = new Set(['open', 'close', 'free']);
const LOADS = new Set(['window', 'windowCold', 'valueAt', 'coldValueAt', 'edge', 'search', 'searchText', 'signals', 'walkSlice', 'load', 'bgLoad', 'export', 'derive', 'searchScan', 'searchExpr', 'warm', 'persist']);
// Hard bounds in the addon (review M2): one signal's store may not exceed this
// worker's store share, and a reader load that leaves the process over twice
// the RSS cap is undone before it is walked (the soft guard above recycles first).
function setBounds() { addon.cacheSetBounds(cacheLimit || 0, 2 * rssCap()); }

function memoryGuard() {
  const cap = rssCap();
  if (process.memoryUsage.rss() <= cap) { return; }
  addon.cacheSetLimit(cacheLimit / 2);  // evicts least recently used
  addon.cacheSetLimit(cacheLimit);
  const rss = process.memoryUsage.rss();
  if (rss > cap) { recycle = true; }
  if (rss > 2 * cap) { throw new Error(`worker memory limit (${Math.round(rss / 1e6)} MB > ${Math.round(2 * cap / 1e6)} MB)`); }
}

// Persistent store cache: the coordinator attaches `files` ({signalId: path} of
// .vvz files in the dump's index dir) to tasks that may load. A signal with a
// file is read from it (~20x faster than a walk); a signal that had to be
// walked is reported in the reply's `walked`, and the coordinator then asks
// for it to be written (`persist`, background).
let taskFiles = null;
let walkedNow = [], badNow = [];
function fromFiles(ids, evict = true) {
  const info = new Map();
  if (!taskFiles) { return info; }
  const have = new Set(addon.cacheStats().signals.map((e) => e.signalId));
  for (const id of ids) {
    const f = taskFiles[id];
    if (!f || have.has(id)) { continue; }
    const t0 = performance.now();
    const r = addon.cacheAdoptIndex(id, f, evict);
    if (!r.error) { info.set(id, { signalId: id, cached: false, fromFile: true, count: r.count, bits: r.bits, bytes: r.bytes, loadMs: 0, walkMs: performance.now() - t0 }); }
    else if (r.tooLarge) { info.set(id, { signalId: id, error: r.error }); }  // over this worker's store share: a walk would be too; the file stays
    else {  // walked instead (and rewritten); only a corrupt file is deleted, a missing one is just forgotten
      if (/^bad index file/.test(r.error)) { try { fs.rmSync(f, { force: true }); } catch (e) { /* gone */ } }
      badNow.push(id);
    }
  }
  return info;
}
// A request's signals never evict each other (adopted files included): load
// all without evicting, then evict others once, keeping the whole request.
function load(ids, evict = true) {
  const info = fromFiles(ids, false);
  const rest = ids.filter((id) => !info.has(id));
  if (rest.length) {
    for (const r of addon.cacheLoad(rest, false)) {
      info.set(r.signalId, r);
      if (!r.error && !r.cached) { walkedNow.push(r.signalId); }
    }
  }
  if (evict) { addon.cacheEvict(ids); }
  return ids.map((id) => info.get(id));
}

// Load (walk) what isn't cached yet; returns per-signal load info by id.
// Derived signals can't be walked: if one was evicted, the coordinator
// rebuilds it (DERIVED_EVICTED) and retries.
function ensure(signalIds) {
  const info = new Map();
  const real = signalIds.filter((id) => id < DERIVED_BASE);
  if (real.length) { for (const r of load(real)) { info.set(r.signalId, r); } }
  const der = signalIds.filter((id) => id >= DERIVED_BASE);
  if (der.length) {
    const have = new Set(addon.cacheStats().signals.map((e) => e.signalId));
    for (const id of der) {
      if (!have.has(id)) { throw new Error('DERIVED_EVICTED ' + id); }
      info.set(id, { signalId: id, cached: true, loadMs: 0, walkMs: 0 });
    }
  }
  return info;
}

function background(deadlineMs, fn) {
  addon.bgBegin(deadlineMs > 0 ? deadlineMs : 0);
  try { return fn(); } finally { addon.bgEnd(); }
}

// Interface-port aliases (tb_wrapper.mon_itf.clk -> tb_wrapper.clk, and the
// riscv_formal_checker ports) get a traverse handle with 0 bits and no value
// bytes until the reader has read the var definitions of their scope
// (ffrReadVarByLogUOff, what readVars does); after that they read as their
// target. The coordinator reads every scope for its index, so do the same here
// once per open: ~8 ms for this dump's 3,058 vars.
function readVarTree() {
  const t0 = performance.now();
  let vars = 0;
  const noop = () => {};
  const walk = (scope, p, depth) => {
    addon.readVars(p, scope.scopeOffsetIdx, () => { vars++; }, noop, noop, noop, noop);
    if (depth > 512) { return; }
    for (let start = 0, guard = 256; guard-- > 0;) {
      const r = addon.getScopeChildren(scope.scopeOffsetIdx, start);
      for (const c of r.scopes) { if (!c.name.startsWith('$')) { walk(c, p + '.' + c.name, depth + 1); } }
      start += r.totalReturned;
      if (!r.totalReturned || r.remainingItems <= 0) { break; }
    }
  };
  for (const s of addon.readScopes()) { if (!s.name.startsWith('$')) { walk(s, s.name, 0); } }
  return { vars, ms: +(performance.now() - t0).toFixed(1) };
}

const ops = {
  open({ file, cacheBytes }) {
    sizesKey = '';  // the coordinator dropped its copy: send them with this reply
    if (openFile) { addon.cacheFree(); addon.unload(); openFile = null; }
    addon.openFsdb(file);
    openFile = file;
    if (cacheBytes) { cacheLimit = cacheBytes; addon.cacheSetLimit(cacheBytes); }
    const varTree = readVarTree();
    rssFloor = process.memoryUsage.rss() + RSS_HEADROOM;
    capRaised = RSS_CAP && RSS_CAP < rssFloor ? { configuredMB: Math.round(RSS_CAP / 1e6), usedMB: Math.round(rssFloor / 1e6) } : null;
    setBounds();
    return { varTree };
  },

  // -> [{signalId, exact, count, records (deflated), counts?, cached, loadMs, walkMs} | {signalId, error}]
  window({ signalIds, t0, t1, buckets }) {
    const info = ensure(signalIds);  // throws DERIVED_EVICTED for an evicted derived signal
    return signalIds.map((signalId) => {
      const l = info.get(signalId);
      if (l.error) { return { signalId, error: l.error }; }
      const w = addon.cacheWindow(signalId, t0, t1, buckets);
      return { signalId, exact: w.exact, count: w.count, records: zlib.deflateRawSync(w.records, { level: 1 }),
        counts: w.counts || null, cached: l.cached, loadMs: l.loadMs, walkMs: l.walkMs, total: w.total, ...(l.fromFile ? { file: true } : {}) };
    });
  },

  valueAt({ signalIds, t }) {
    const info = ensure(signalIds);
    return signalIds.map((id) => (info.get(id).error ? null : addon.cacheValueAt(id, t)));
  },

  // Signals that aren't stored: a [t, t] view-window read each (one goto, one
  // value; ~2 ms, nothing walked or kept). Unreadable ones give null.
  coldValueAt({ signalIds, t }) {
    return addon.coldValueAt(signalIds, t).map((v) => (typeof v === 'string' ? v : null));
  },

  // A short range of signals that aren't stored: load and walk only [t0 - 1, t1]
  // into a scratch store (same answer as the whole signal; nothing kept).
  windowCold({ signalIds, t0, t1, buckets }) {
    return addon.cacheWindowCold(signalIds, t0, t1, buckets).map((w) => (w.error ? { signalId: w.signalId, error: w.error }
      : { signalId: w.signalId, exact: w.exact, count: w.count, records: zlib.deflateRawSync(w.records, { level: 1 }),
        counts: w.counts || null, cached: false, ranged: true, loadMs: w.loadMs, walkMs: w.walkMs }));
  },

  // Background whole walk after a ranged first draw: yields to interactive work.
  bgLoad({ signalIds }) {
    return background(0, () => load(signalIds).map((r) => ({ signalId: r.signalId, ...(r.error ? { error: r.error } : { count: r.count }) })));
  },

  // Write stored signals to the persistent cache (dir/<id>.vvz, via a temp name).
  persist({ signalIds, dir }) {
    const have = new Set(addon.cacheStats().signals.map((e) => e.signalId));
    let stopped = false;  // a yield (interactive work arrived) leaves the rest for later
    return background(0, () => signalIds.map((id) => {
      if (stopped) { return { signalId: id, error: 'yielded', yielded: true }; }
      if (!have.has(id)) { return { signalId: id, error: 'not stored' }; }
      const tmp = path.join(dir, `.${id}.${process.pid}.tmp`), dst = path.join(dir, `${id}.vvz`);
      try { fs.rmSync(tmp, { force: true }); } catch (e) { /* none */ }
      const r = addon.cacheWriteIndex(id, tmp);
      if (r.error) { fs.rmSync(tmp, { force: true }); if (r.yielded) { stopped = true; } return { signalId: id, error: r.error, yielded: !!r.yielded }; }
      fs.renameSync(tmp, dst);
      let stamp;  // the coordinator's count manifest: header facts without reading the file
      try { const st = fs.lstatSync(dst); stamp = [st.size, st.mtimeMs, st.ino, st.ctimeMs]; } catch (e) { stamp = undefined; }
      return { signalId: id, bytes: r.bytes, rawBytes: r.rawBytes, count: r.count, bits: r.bits, xz: !!r.xz, stamp };
    }));
  },

  edge({ signalId, t, dir, kind }) {
    const l = ensure([signalId]).get(signalId);
    if (l.error) { throw new Error(l.error); }
    return { t: addon.cacheEdge(signalId, t, dir, { any: 0, rise: 1, fall: 2 }[kind || 'any'] ?? 0) };
  },

  search({ signalId, t, dir, value }) {
    const l = ensure([signalId]).get(signalId);
    if (l.error) { throw new Error(l.error); }
    return { t: addon.cacheSearch(signalId, t, dir, String(value)) };
  },

  // searchText: the first change from t (as search) whose value, formatted the way the
  // viewer formats it, matches the pattern. Texts and verdicts are memoized per distinct
  // value (text.js); the addon maps changes to distinct values and scans.
  searchText(p) {
    // Stoppable: a cancel sends SIGUSR2 (helper.js `stoppable` tasks) and the judging loop
    // polls the flag. bgEnd() clears a stale flag now; a cancel landing during the load below
    // is kept (bgBegin keepYield). Background mode only for the scan, so the load is a normal
    // interactive one (16-signal batches, never yields).
    addon.bgEnd();
    const l = ensure([p.signalId]).get(p.signalId);
    if (l.error) { throw new Error(l.error); }
    addon.bgBegin(0, true);
    try { return text.search(addon, p, () => addon.bgPoll()); } finally { addon.bgEnd(); }
  },

  // v1 `signals`: whole signals through the reader's own traversal
  // (getValueChangesPacked), independent of the store. Deflated records.
  // maxChanges (count first): a signal with more raw changes comes back as {count, overCap}
  // without its records, and the walk stops copying past the cap (bounded memory).
  signals({ signalIds, widths, maxChanges }) {
    addon.loadSignals(signalIds);
    const capped = typeof maxChanges === 'number';
    const out = signalIds.map((signalId, k) => {
      const raw = widths ? (capped ? addon.getValueChangesPacked(signalId, maxChanges) : addon.getValueChangesPacked(signalId)) : undefined;
      let r;
      if (typeof raw === 'number') {
        r = { signalId, width: widths[k], count: raw, overCap: true };
      } else if (raw && raw.length % (8 + widths[k]) === 0) {
        r = { signalId, width: widths[k], count: raw.length / (8 + widths[k]), records: zlib.deflateRawSync(raw, { level: 1 }) };
      } else {
        const d = addon.getValueChanges(signalId);
        r = capped && d.valueChanges && d.valueChanges.length > maxChanges
          ? { signalId, count: d.valueChanges.length, overCap: true }
          : { signalId, valueChanges: d.valueChanges, min: d.min, max: d.max };
      }
      addon.unloadSignal(signalId);
      return r;
    });
    return out;
  },

  // Split walk: this worker walks one time slice of a wide signal into a
  // store file; the owner then adopts all slices into its store.
  walkSlice({ signalId, s, e, path: file }) { return addon.cacheWalkSlice(signalId, s, e, file); },
  adopt({ signalId, paths }) { const r = addon.cacheAdopt(signalId, paths); walkedNow.push(signalId); return r; },

  // Derived signals: operands are loaded here ('load') or loaded and written to
  // files for the worker that builds the result ('export'), then 'derive' merges.
  load({ signalIds }) { return [...ensure(signalIds).values()]; },
  // A searchAll's fixed operand: loaded without evicting anything (freed when the search ends),
  // with its store bytes so the coordinator can tell where a copy fits.
  loadTemp({ signalIds }) {
    const info = load(signalIds, false);
    const bytes = new Map(addon.cacheStats().signals.map((e) => [e.signalId, e.bytes]));
    return signalIds.map((id, k) => ({ signalId: id, error: info[k] && info[k].error, bytes: bytes.get(id) || 0 }));
  },
  export({ signalIds, paths }) {
    const info = [...ensure(signalIds).values()];
    signalIds.forEach((id, k) => addon.cacheExport(id, paths[k]));
    return info;
  },
  derive({ signalId, program, operands, deadlineMs }) {
    ensure(operands.filter((o) => !o.path).map((o) => o.id));
    return addon.cacheDerive(signalId, program, operands, true, { deadlineMs: deadlineMs || 60000 });
  },

  // searchAll on values: stored signals are searched in the store, indexed
  // ones in their index file, the rest scanned straight off the reader
  // (nothing kept), all stopping past `bound`.
  searchScan({ signalIds, t, dir, pattern, bound, deadlineMs, index }) {
    return background(deadlineMs, () => {
      const have = new Set(addon.cacheStats().signals.map((e) => e.signalId));
      const out = [];
      const fromIndex = [], cold = [];
      for (const id of signalIds) {
        if (have.has(id)) { out.push({ signalId: id, t: addon.cacheSearch(id, t, dir, pattern, bound), walked: false }); }
        else if (index && index[id]) { fromIndex.push(id); }
        else { cold.push(id); }
      }
      if (fromIndex.length) {
        for (const r of addon.indexSearch(fromIndex.map((id) => index[id]), fromIndex, t, dir, pattern, bound)) {
          if (r.error) { cold.push(r.signalId); continue; }  // index file gone or bad: scan instead
          out.push({ ...r, walked: false, indexed: true });
        }
      }
      if (cold.length) { for (const r of addon.searchScan(cold, t, dir, pattern, bound)) { out.push({ ...r, walked: !r.yielded }); } }
      return out;
    });
  },

  // searchAll on an expression: per candidate, walk it (not evicting the
  // viewer's signals), build the boolean result in a scratch store, search,
  // free both. One failing candidate fails only itself. `fixed` (the
  // expression's other signals) were put on this worker by the coordinator.
  searchExpr({ signalIds, t, dir, programs, fixed, deadlineMs }) {
    // fixed operands are already here (loadTemp / adopt): never evict the viewer's signals for them
    load(fixed.filter((id) => id < DERIVED_BASE), false);
    ensure(fixed.filter((id) => id >= DERIVED_BASE));
    const started = Date.now();
    return background(deadlineMs, () => signalIds.map((id, k) => {
      if (deadlineMs > 0 && Date.now() - started > deadlineMs) { return { signalId: id, yielded: true }; }
      let walked = false;
      try {
        const l = load([id], false)[0];
        walked = !l.cached;
        if (l.error) { return l.error === 'yielded' ? { signalId: id, yielded: true } : { signalId: id, t: null, error: l.error }; }
        const prog = programs[k];
        if (!prog) { return { signalId: id, t: null, error: 'expression does not fit this signal' }; }
        const cand = prog.find((n) => n.op === 0 && n.k === 0);  // the `$` operand node
        if (cand && cand.w !== l.bits) {
          return { signalId: id, t: null, error: `reader width ${l.bits} differs from the hierarchy` };
        }
        addon.cacheDerive(TEMP_ID, prog, [{ id }, ...fixed.map((f) => ({ id: f }))], false,
          { deadlineMs: Math.max(1, (deadlineMs || 60000) - (Date.now() - started)) });
        return { signalId: id, t: addon.cacheSearch(TEMP_ID, t, dir, '1'), walked };
      } catch (e) {
        return { signalId: id, t: null, error: String((e && e.message) || e) };
      } finally {
        addon.cacheFree(TEMP_ID);
        if (walked && !fixed.includes(id)) { addon.cacheFree(id); walkedNow = walkedNow.filter((x) => x !== id); }  // scratch: not persisted
      }
    }));
  },

  // Index warm-up: walk each signal into a compressed dir/<id>.vvz (via a temp
  // name and rename, so readers never see a partial file).
  warm({ signalIds, dir }) {
    return background(0, () => signalIds.map((id) => {
      const tmp = path.join(dir, `.${id}.${process.pid}.tmp`), dst = path.join(dir, `${id}.vvz`);
      try { fs.rmSync(tmp, { force: true }); } catch (e) { /* none */ }
      const r = addon.indexWrite(id, tmp);
      if (r.error) { fs.rmSync(tmp, { force: true }); return { signalId: id, ...(r.error === 'yielded' ? { yielded: true } : { error: r.error }) }; }
      fs.renameSync(tmp, dst);
      return { signalId: id, bytes: r.bytes, rawBytes: r.rawBytes, count: r.count, bits: r.bits };
    }));
  },

  free({ signalIds }) {
    if (!signalIds) { addon.cacheFree(); return {}; }
    for (const id of signalIds) { addon.cacheFree(id); }
    return {};
  },

  close() {
    if (openFile) { addon.cacheFree(); addon.unload(); openFile = null; }
    return {};
  },
};

// Every reply carries the store state so the coordinator can answer `stats`
// and prioritise queries on cached signals without asking.
let sizesKey = '';  // what the last reply's sizes described ('' = send them)
function state() {
  const s = addon.cacheStats();
  const rss = process.memoryUsage.rss();
  if (openFile && rss > rssCap()) { recycle = true; }
  // sizes: [id, count, bits, xz] per stored signal, for the coordinator's count
  // op; sent only when the store changed since the last reply (absent = unchanged).
  const cached = s.signals.map((e) => e.signalId);
  const key = `${s.bytes}:${cached.join(',')}`;
  const sizes = key === sizesKey ? undefined : s.signals.map((e) => [e.signalId, e.count, e.bits, e.xz ? 1 : 0]);
  sizesKey = key;
  return { bytes: s.bytes, limit: s.limit, cached, ...(sizes ? { sizes } : {}), rss, ...(recycle ? { recycle: true } : {}), ...(capRaised ? { capRaised } : {}) };
}

process.on('message', (task) => {
  const t0 = process.hrtime.bigint();
  let reply;
  try {
    const fn = ops[task.op];
    if (!fn) { throw new Error('unknown op ' + task.op); }
    if (!openFile && !NO_FILE_OK.has(task.op)) { throw new Error('no file open'); }  // the addon needs a reader
    if (LOADS.has(task.op)) { memoryGuard(); }
    taskFiles = task.files || null;
    walkedNow = []; badNow = [];
    reply = { tid: task.tid, result: fn(task) };
    if (walkedNow.length) { reply.walked = walkedNow; }
    if (badNow.length) { reply.badFiles = badNow; }
  } catch (e) {
    reply = { tid: task.tid, error: String((e && e.message) || e) };
  }
  reply.ms = Number(process.hrtime.bigint() - t0) / 1e6;
  reply.state = state();
  process.send(reply);
});
process.on('disconnect', () => process.exit(0));
process.send({ ready: true, pid: process.pid, state: state() });
