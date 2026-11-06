// run.sh fsdb-sched: a stand-in for fsdb-helper-v2's FSDB reader addon (no FSDB, no reader
// library). Signals 1..N are 1-bit vars of one scope `tb`; loading signal k takes
// STUB_COSTS[k] ms (default 10), as a reader load of a real dump costs 1 ms to 10 s per
// signal. A time slice (split walk) costs a quarter. Only what the helper's open, window,
// count, stats and split paths call is here.
'use strict';
const fs = require('node:fs');
const COSTS = JSON.parse(process.env.STUB_COSTS || '{}');
const N = Number(process.env.STUB_SIGNALS || 16);
const TIME_END = 1000000;
const cost = (id) => Number(COSTS[id] ?? 10);
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
    return ids.map((id) => {
      if (store.has(id)) { return { ...entry(id), cached: true, loadMs: 0, walkMs: 0 }; }
      sleep(cost(id));
      store.set(id, true);
      return { ...entry(id), cached: false, loadMs: cost(id), walkMs: 0 };
    });
  },
  cacheEvict() {},
  coldValueAt: (ids) => ids.map(() => '0'),
  cacheValueAt: () => '0',
  cacheFree(id) { if (id === undefined) { store.clear(); } else { store.delete(id); } },
  cacheWindow(id, t0) {
    const rec = Buffer.alloc(9); rec.writeBigUInt64LE(0n, 0); rec[8] = 0x30;  // the value at t0: '0'
    return { exact: true, count: 1, records: rec, counts: null, total: 2 };
  },
  cacheWalkSlice(id, s, e, path) { sleep(cost(id) / 4); fs.writeFileSync(path, 'x'); return { count: 1, xz: false, loadMs: cost(id) / 4, walkMs: 0 }; },
  cacheAdopt(id) { store.set(id, true); return { count: 2, bytes: 16 }; },
};
