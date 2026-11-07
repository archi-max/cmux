// run.sh fsdb-sched: a stand-in for fsdb-helper-v2's FSDB reader addon (no FSDB, no reader
// library). Signals 1..N are 1-bit vars of one scope `tb`; loading signal k takes
// STUB_COSTS[k] ms (default 10), as a reader load of a real dump costs 1 ms to 10 s per
// signal. A time slice (split walk) or a view-window load costs its share of the dump's time
// range (plus STUB_SLICE_MS); signals in STUB_BAD can't be read (as the reader's unsupported
// encodings). Only what the helper's open, window, count, stats and split paths call is here.
'use strict';
const fs = require('node:fs');
const COSTS = JSON.parse(process.env.STUB_COSTS || '{}');
const N = Number(process.env.STUB_SIGNALS || 16);
const TIME_END = 1000000;
const cost = (id) => Number(COSTS[id] ?? 10);
const COUNTS_ = JSON.parse(process.env.STUB_COUNTS || '{}');
const BAD = new Set(JSON.parse(process.env.STUB_BAD || '[]'));
const SLICE_MS = Number(process.env.STUB_SLICE_MS || 0);
// STUB_FIRST_MS: a signal's first load in a worker process costs that much more (the reader
// reads the signal's block index once per process: ~120-200 ms for a clock on a 1.7 GB dump).
const FIRST_MS = Number(process.env.STUB_FIRST_MS || 0);
// STUB_PRIMARY + STUB_FLOOR_MS: a reader call that loads a stored (primary) signal costs a floor
// once per call whatever it loads (the reader re-reads its navigation data: ~110 ms on 1.7 GB,
// ~650 ms on 10 GB), so batching primaries in one call pays it once.
const PRIMARY = new Set(JSON.parse(process.env.STUB_PRIMARY || '[]'));
const FLOOR_MS = Number(process.env.STUB_FLOOR_MS || 0);
const floorOf = (ids) => (FLOOR_MS && ids.some((id) => PRIMARY.has(id)) ? FLOOR_MS : 0);
// STUB_CHANGE_AT {id: time}: the signal's one real change (to '1') for the last-change reads
// (valueAt {prev: true}); STUB_NEAR_LOG gets a line per coldValueNear call: span and ids.
const CHANGE_AT = JSON.parse(process.env.STUB_CHANGE_AT || '{}');
// STUB_COLD_MS: a ranged cold read costs each signal that much more (the reader's per-call
// navigation and rebuild setup on a big dump). A navDB-once process (readerNavOnce, warm
// workers) pays STUB_WARM_LOAD_MS once for its first load (its first warmWindow, as the real
// reader: warmLoad only fixes the list), then STUB_WARM_MS per window of that set; naming a signal outside its first load throws, as the reader
// documents that it must not happen. STUB_WARM_LOG gets a line per warm call.
const COLD_MS = Number(process.env.STUB_COLD_MS || 0);
const WARM_LOAD_MS = Number(process.env.STUB_WARM_LOAD_MS || 0), WARM_MS = Number(process.env.STUB_WARM_MS || 0);
let navOnce = false, warmSet = null, warmFirst = false;
const held = [];  // memory a warm reader keeps (STUB_WARM_MB_PER_SIG, STUB_WARM_BLOCK)
const warmLog = (o) => { if (process.env.STUB_WARM_LOG) { fs.appendFileSync(process.env.STUB_WARM_LOG, JSON.stringify({ pid: process.pid, ...o }) + '\n'); } };
const changeOf = (id) => (CHANGE_AT[id] === undefined ? null : Number(CHANGE_AT[id]));
const seen = new Set();
const first = (id) => (seen.has(id) ? 0 : (seen.add(id), FIRST_MS));
const share = (id, s, e) => SLICE_MS + first(id) + cost(id) * Math.max(0, Math.min(Number(e), TIME_END) - Number(s)) / TIME_END;
// STUB_DIFFER: these signals' values differ from the others' in every window; STUB_DIFFER_FULL:
// only their whole streams differ (cacheRecords), as an alias wrong outside the sampled windows.
const DIFFER = new Set(JSON.parse(process.env.STUB_DIFFER || '[]'));
const DIFFER_FULL = new Set(JSON.parse(process.env.STUB_DIFFER_FULL || '[]'));
const win1 = (id) => { const rec = Buffer.alloc(9); rec.writeBigUInt64LE(0n, 0); rec[8] = DIFFER.has(id) ? 0x31 : 0x30; return { signalId: id, exact: true, count: 1, records: rec, counts: null }; };
const sleep = (ms) => { if (ms > 0) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } };
const store = new Map();  // signalId -> true
let limit = 0;
const entry = (id) => ({ signalId: id, count: 2, bits: 1, xz: false, bytes: 16 });
module.exports = {
  bgBegin() { process.removeAllListeners('SIGUSR2'); process.on('SIGUSR2', () => {}); },
  bgEnd() {}, bgPoll: () => false,
  openFsdb() {}, unload() {},
  // STUB_TIME_START: the dump's first time (the reader's min tag), passed as the addon does.
  readMetadata(meta, chunk) { meta(1, 0, 1, 'ns'); chunk(500, TIME_END, Number(process.env.STUB_TIME_START || 0)); },
  readScopes: () => [{ name: 'tb', type: 'module', netlistId: 0, scopeOffsetIdx: 0 }],
  getScopeChildren: () => ({ scopes: [], totalReturned: 0, remainingItems: 0 }),
  readVars(p, idx, onVar) { for (let id = 1; id <= N; id++) { onVar('s' + id, 'reg', 'BitVector', p, id, id, 1, 0, 0); } },
  cacheSetLimit(n) { limit = n; }, cacheSetBounds() {},
  cacheStats: () => ({ bytes: 16 * store.size, limit, signals: [...store.keys()].map(entry) }),
  cacheLoad(ids) {
    if (process.env.STUB_LOAD_LOG) { fs.appendFileSync(process.env.STUB_LOAD_LOG, JSON.stringify({ op: 'load', pid: process.pid, ids: ids.filter((id) => !store.has(id)) }) + '\n'); }
    sleep(floorOf(ids.filter((id) => !store.has(id))));
    return ids.map((id) => {
      if (store.has(id)) { return { ...entry(id), cached: true, loadMs: 0, walkMs: 0 }; }
      sleep(cost(id));
      if (BAD.has(id)) { return { signalId: id, error: 'unsupported encoding' }; }
      store.set(id, true);
      return { ...entry(id), cached: false, loadMs: cost(id), walkMs: 0 };
    });
  },
  cacheEvict() {},
  coldValueAt: (ids) => ids.map(() => '0'),
  cacheValueAt: () => '0',
  cacheLastChange(id, t) { const c = changeOf(id); return c !== null && c <= t ? { t: c, value: '1' } : null; },
  coldValueNear(ids, t, span) {
    const lo = Math.max(0, t - span);
    if (process.env.STUB_NEAR_LOG) { fs.appendFileSync(process.env.STUB_NEAR_LOG, JSON.stringify({ span, ids }) + '\n'); }
    sleep(floorOf(ids));
    return ids.map((id) => {
      sleep(share(id, lo, t));
      const c = changeOf(id), value = c !== null && c <= t ? '1' : 'x';
      return c !== null && c <= t && c >= lo ? { t: c, value } : { none: true, value };
    });
  },
  cacheFree(id) { if (id === undefined) { store.clear(); } else { store.delete(id); } },
  cacheWindow(id, t0) {
    const rec = Buffer.alloc(9); rec.writeBigUInt64LE(0n, 0); rec[8] = 0x30;  // the value at t0: '0'
    return { exact: true, count: 1, records: rec, counts: null, total: 2 };
  },
  cacheRecords: (id) => Buffer.from(DIFFER.has(id) || DIFFER_FULL.has(id) ? `other ${id}` : 'same'),
  // STUB_WARM_NAV_FAIL: a warm reader's init fails. Each start is logged ({op: 'nav'}).
  readerNavOnce() { warmLog({ op: 'nav' }); if (process.env.STUB_WARM_NAV_FAIL) { throw new Error('navigation retention failed'); } navOnce = true; },
  warmLoad(ids) {
    if (!navOnce || warmSet) { throw new Error('warmLoad: not a fresh navDB-once reader'); }
    // STUB_WARM_LOAD_FAIL [ids]: a first load naming one of them fails (a set that backs off)
    if (JSON.parse(process.env.STUB_WARM_LOAD_FAIL || '[]').some((id) => ids.includes(id))) { warmLog({ op: 'loadFail', ids }); throw new Error('warm load failed (stub)'); }
    warmSet = new Set(ids); warmLog({ op: 'load', ids });
    // STUB_WARM_MB_PER_SIG: resident memory the reader keeps per signal of its set (its navigation).
    const mb = Number(process.env.STUB_WARM_MB_PER_SIG || 0) * ids.length;
    if (mb) { held.push(Buffer.alloc(mb * 1048576).fill(1)); }
    return ids.map((id) => (BAD.has(id) ? { signalId: id, error: 'unsupported encoding' } : { signalId: id }));
  },
  warmWindow(ids, t0, t1) {
    warmLog({ op: 'window', ids });
    // STUB_WARM_BLOCK {mb, ms}: the first window takes mb of memory and blocks ms (a native call
    // that can't yield, so only a watchdog outside the process sees it).
    if (process.env.STUB_WARM_BLOCK && !warmFirst) { const b = JSON.parse(process.env.STUB_WARM_BLOCK); held.push(Buffer.alloc(b.mb * 1048576).fill(1)); sleep(b.ms); }
    if (!warmSet || ids.some((id) => !warmSet.has(id))) { throw new Error('warmWindow: signal not in the first load'); }
    // STUB_WARM_SIG_COST {id: ms}: a row that costs that much more per warm window (one rebuilt per window)
    const sigCost = JSON.parse(process.env.STUB_WARM_SIG_COST || '{}');
    sleep(ids.reduce((a, id) => a + (sigCost[id] || 0), 0));
    sleep(WARM_MS + Number(process.env.STUB_WARM_SIG_MS || 0) * ids.length + (warmFirst ? 0 : WARM_LOAD_MS)); warmFirst = true;  // (the first window is the reader's first load; STUB_WARM_SIG_MS: the walk, per signal)
    return ids.map((id) => (BAD.has(id) ? { signalId: id, error: 'unsupported encoding' } : { ...win1(id), loadMs: WARM_MS, walkMs: 0 }));
  },
  warmNear(ids, t, span) {
    warmLog({ op: 'near', ids });
    if (!warmSet || ids.some((id) => !warmSet.has(id))) { throw new Error('warmNear: signal not in the first load'); }
    sleep(WARM_MS + (warmFirst ? 0 : WARM_LOAD_MS)); warmFirst = true;
    const lo = Math.max(0, t - span);
    return ids.map((id) => { const c = changeOf(id), value = c !== null && c <= t ? '1' : 'x'; return c !== null && c <= t && c >= lo ? { signalId: id, t: c, value } : { signalId: id, none: true, value }; });
  },
  cacheWindowCold(ids, t0, t1) { if (navOnce) { throw new Error('cold read in a navDB-once reader'); } sleep(floorOf(ids) + COLD_MS * ids.length); return ids.map((id) => { const ms = share(id, t0, t1); sleep(ms); return BAD.has(id) ? { signalId: id, error: 'unsupported encoding' } : { ...win1(id), loadMs: ms, walkMs: 0 }; }); },
  cacheWalkSlice(id, s, e, path) {
    if (process.env.STUB_LOAD_LOG) { fs.appendFileSync(process.env.STUB_LOAD_LOG, JSON.stringify({ op: 'slice', ids: [id] }) + '\n'); }
    const ms = share(id, s, e) + floorOf([id]);
    sleep(ms);
    if (BAD.has(id)) { throw new Error('unsupported encoding'); }
    // STUB_COUNTS: a signal's whole change count, spread evenly over the dump (default 1 per slice);
    // the piece file holds 10 bytes per change, as a 1-bit signal's store file
    const n = COUNTS_[id] ? Math.round(COUNTS_[id] * (Math.min(Number(e), TIME_END) - Number(s)) / TIME_END) : 1;
    fs.writeFileSync(path, Buffer.alloc(Math.min(10 * n, 1048576), 120));  // (at most 1 MB a piece)
    return { count: n, xz: false, loadMs: ms, walkMs: 0 };
  },
  cacheAdopt(id) { sleep(Number(process.env.STUB_ADOPT_MS || 0)); store.set(id, true); return { count: 2, bytes: 16 }; },  // STUB_ADOPT_MS: a join's cost
};
