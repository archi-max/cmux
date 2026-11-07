// run.sh fsdb-sched: a stand-in for fsdb-helper-v2's native clockseg (one clock-verify segment as
// its own process), over stub-addon.cjs's clockScan model. Same arguments and output:
//   stub-clockseg.cjs <fsdb> <id> <P> <H> <R0> <maxRecords> <a> <b> [<a> <b> ...]
// one JSON line per range (plus rssMB); maxRecords counts over all the ranges, as clockseg's.
'use strict';
const addon = require('./stub-addon.cjs');
const [, , , id, P, H, R0, maxRec, ...rs] = process.argv;
let records = 0;
for (let k = 0; k + 1 < rs.length; k += 2) {
  const r = addon.clockScan(Number(id), Number(rs[k]), Number(rs[k + 1]), Number(P), Number(H), Number(R0), Number(maxRec) - records);
  const rssMB = Math.round(process.memoryUsage().rss / 1048576);
  process.stdout.write(JSON.stringify({ ...r, ...(r.over ? { records: records + r.records } : {}), rssMB }) + '\n');
  if (r.error || r.over) { break; }
  if (r.intervals) { for (const iv of r.intervals) { records += iv[2].length; } }
}
