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
const changeOf = (id) => (CHANGE_AT[id] === undefined ? null : Number(CHANGE_AT[id]));
const seen = new Set();
const first = (id) => (seen.has(id) ? 0 : (seen.add(id), FIRST_MS));
const share = (id, s, e) => SLICE_MS + first(id) + cost(id) * Math.max(0, Math.min(Number(e), TIME_END) - Number(s)) / TIME_END;
const win1 = (id) => { const rec = Buffer.alloc(9); rec.writeBigUInt64LE(0n, 0); rec[8] = 0x30; return { signalId: id, exact: true, count: 1, records: rec, counts: null }; };
const sleep = (ms) => { if (ms > 0) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } };
const store = new Map();  // signalId -> true
let limit = 0;
const entry = (id) => ({ signalId: id, count: 2, bits: 1, xz: false, bytes: 16 });
module.exports = {
  bgBegin() { process.removeAllListeners('SIGUSR2'); process.on('SIGUSR2', () => {}); },
  bgEnd() {}, bgPoll: () => false,
  openFsdb() {}, unload() {},
  readMetadata(meta, chunk) { meta(1, 0, 1, 'ns'); chunk(500, TIME_END); },
  readScopes: () => [{ name: 'tb', type: 'module', netlistId: 0, scopeOffsetIdx: 0 }],
  getScopeChildren: () => ({ scopes: [], totalReturned: 0, remainingItems: 0 }),
  readVars(p, idx, onVar) { for (let id = 1; id <= N; id++) { onVar('s' + id, 'reg', 'BitVector', p, id, id, 1, 0, 0); } },
  cacheSetLimit(n) { limit = n; }, cacheSetBounds() {},
  cacheStats: () => ({ bytes: 16 * store.size, limit, signals: [...store.keys()].map(entry) }),
  cacheLoad(ids) {
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
  cacheWindowCold(ids, t0, t1) { sleep(floorOf(ids)); return ids.map((id) => { const ms = share(id, t0, t1); sleep(ms); return BAD.has(id) ? { signalId: id, error: 'unsupported encoding' } : { ...win1(id), loadMs: ms, walkMs: 0 }; }); },
  cacheWalkSlice(id, s, e, path) {
    const ms = share(id, s, e) + floorOf([id]);
    sleep(ms);
    if (BAD.has(id)) { throw new Error('unsupported encoding'); }
    // STUB_COUNTS: a signal's whole change count, spread evenly over the dump (default 1 per slice);
    // the piece file holds 10 bytes per change, as a 1-bit signal's store file
    const n = COUNTS_[id] ? Math.round(COUNTS_[id] * (Math.min(Number(e), TIME_END) - Number(s)) / TIME_END) : 1;
    fs.writeFileSync(path, Buffer.alloc(Math.min(10 * n, 1048576), 120));  // (at most 1 MB a piece)
    return { count: n, xz: false, loadMs: ms, walkMs: 0 };
  },
  cacheAdopt(id) { store.set(id, true); return { count: 2, bytes: 16 }; },
};
