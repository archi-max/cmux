// run.sh fsdb-sched: a stand-in for fsdb-helper-v2's native clockseg (one clock-verify segment as
// its own process), over stub-addon.cjs's clockScan model. Same arguments and output:
//   stub-clockseg.cjs <fsdb> <id> <P> <H> <R0> <maxRecords> <a> <b> [<a> <b> ...]
// one JSON line per range (plus rssMB); maxRecords counts over all the ranges, as clockseg's.
'use strict';
const addon = require('./stub-addon.cjs');
const [, , , id, P, H, R0, maxRec, ...rs] = process.argv;
// STUB_CLOCK_OPEN_MB: memory the open takes (the reader's ~185 MB on a 10 GB dump); STUB_CLOCK_BPC:
// bytes each change read keeps (the reader's ~9 B on a rebuilt row), for the life of the process.
const held = [];
if (process.env.STUB_CLOCK_OPEN_MB) { held.push(Buffer.alloc(Number(process.env.STUB_CLOCK_OPEN_MB) * 1048576).fill(1)); }
const openMB = Math.round(process.memoryUsage().rss / 1048576);
// STUB_CLOCK_LOAD_MB: memory the first load takes whatever it reads (the reader's per-load setup).
if (process.env.STUB_CLOCK_LOAD_MB) { held.push(Buffer.alloc(Number(process.env.STUB_CLOCK_LOAD_MB) * 1048576).fill(1)); }
let records = 0;
for (let k = 0; k + 1 < rs.length; k += 2) {
  const r = addon.clockScan(Number(id), Number(rs[k]), Number(rs[k + 1]), Number(P), Number(H), Number(R0), Number(maxRec) - records);
  if (process.env.STUB_CLOCK_BPC && r.changes) { held.push(Buffer.alloc(Math.round(r.changes * Number(process.env.STUB_CLOCK_BPC))).fill(1)); }
  const rssMB = Math.round(process.memoryUsage().rss / 1048576);
  process.stdout.write(JSON.stringify({ ...r, ...(r.over ? { records: records + r.records } : {}), rssMB, openMB }) + '\n');
  if (r.error || r.over) { break; }
  if (r.intervals) { for (const iv of r.intervals) { records += iv[2].length; } }
}
