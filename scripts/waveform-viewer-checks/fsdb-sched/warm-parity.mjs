// Warm-reader parity on a real FSDB (by hand, on a host with Verdi; not part of run.sh):
//   node warm-parity.mjs <install>/cmux-helper-v2.sh <dump.fsdb> <scope> [n] [frac]
// Two helpers on the same dump, one with warm readers (FSDB_WARM=1) and one without
// (FSDB_WARM=0), both with background loads off (FSDB_BG_LOAD=0) so every row stays on ranged
// reads. The first n BitVector variables under <scope> (or PARITY_IDS=a,b,c) are viewed at 0.5
// until the warm set is ready, then read at windows of frac (default 0.01) of the dump at six
// positions plus the first again; every warm answer must equal the cold one change for change
// (count and records), and valueAt / valueAt {prev} of all rows at six times must equal the cold
// answers. Exit 1 on any difference or when nothing was answered warm.
import { spawn } from 'node:child_process';

const [launcher, file, scope, nStr, fracStr] = process.argv.slice(2);
if (!launcher || !file || !scope) { console.error('usage: node warm-parity.mjs <launcher> <fsdb> <scope> [n] [frac]'); process.exit(2); }
const n = Number(nStr || 16), frac = Number(fracStr || 0.01);

function start(env) {
  const p = spawn('bash', [launcher, '--workers', '2'], { stdio: ['pipe', 'pipe', 'ignore'], env: { ...process.env, FSDB_BG_LOAD: '0', ...env } });
  let buf = Buffer.alloc(0), need = null, nid = 1, ready;
  const pend = new Map(), readyP = new Promise((r) => { ready = r; });
  const deliver = (msg, bin) => {
    if (msg.ready) { ready(msg); return; }
    const h = pend.get(msg.id); if (!h || msg.partial) { return; }
    pend.delete(msg.id); h({ ...msg, bin });
  };
  p.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (need) { if (buf.length < need.n) { break; } const bin = buf.subarray(0, need.n); buf = buf.subarray(need.n); deliver(need.msg, bin); need = null; continue; }
      const i = buf.indexOf(10); if (i < 0) { break; }
      const line = buf.subarray(0, i).toString(); buf = buf.subarray(i + 1);
      if (!line.trim()) { continue; }
      const msg = JSON.parse(line);
      if (msg.binLength) { need = { msg, n: msg.binLength }; continue; }
      deliver(msg, null);
    }
  });
  return {
    ready: readyP,
    send(cmd, a = {}) { const id = nid++; return new Promise((res) => { pend.set(id, res); p.stdin.write(JSON.stringify({ id, cmd, ...a }) + '\n'); }); },
    close() { p.stdin.end(); },
  };
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const warm = start({ FSDB_WARM: '1' }), cold = start({ FSDB_WARM: '0' });
await Promise.all([warm.ready, cold.ready]);
const o = await warm.send('open', { file }); await cold.send('open', { file });
if (o.error) { console.error('open:', o.error); process.exit(2); }
const T = o.result.metadata.timeEnd;

let sigs;
if (process.env.PARITY_IDS) {
  sigs = process.env.PARITY_IDS.split(',').map((x) => ({ signalId: Number(x), width: 1, path: x }));
} else {
  const parts = scope.split('.');
  let cur = o.result.top.find((t) => t.name === parts[0]), p = parts[0];
  for (const q of parts.slice(1)) { const c = await warm.send('children', { scopeOffsetIdx: cur.scopeOffsetIdx, scopePath: p }); cur = c.result.scopes.find((s) => s.name === q); p += '.' + q; }
  const vars = [], queue = [[cur, p]];
  while (queue.length && vars.length < 4 * n) {
    const [s, sp] = queue.shift();
    const c = await warm.send('children', { scopeOffsetIdx: s.scopeOffsetIdx, scopePath: sp });
    const flat = (r) => { for (const v of r.vars) { vars.push({ ...v, path: sp + '.' + v.name }); } for (const k of r.scopes) { if (k.inline) { flat(k.inline); } else { queue.push([k, sp + '.' + k.name]); } } };
    flat(c.result);
  }
  const seen = new Set();
  sigs = vars.filter((v) => v.encoding === 'BitVector' && v.width > 0 && !seen.has(v.signalId) && seen.add(v.signalId)).slice(0, n);
}
const W = (at) => ({ signals: sigs.map((s) => ({ signalId: s.signalId, width: s.width })), t0: Math.floor(T * at), t1: Math.floor(T * at) + Math.floor(T * frac), buckets: 1024 });
const split = (r) => {
  const m = new Map(); let off = 0;
  for (const s of r.result.signals) { m.set(s.signalId, { ...s, rec: r.bin ? r.bin.subarray(off, off + (s.bytes || 0)) : null }); off += (s.bytes || 0) + (s.bucketBytes || 0); }
  return m;
};

let st = null;
for (let k = 0; k < 300; k++) {
  await warm.send('window', W(0.5));
  st = (await warm.send('stats', {})).result.warm;
  if (st && st.ready.length && !st.building) { break; }
  await sleep(200);
}
let same = 0, differ = 0, warmServed = 0;
const lat = [];
for (const at of [0.05, 0.2, 0.35, 0.62, 0.8, 0.93, 0.05]) {
  const t = performance.now();
  const a = split(await warm.send('window', W(at)));
  lat.push(performance.now() - t);
  const b = split(await cold.send('window', W(at)));
  for (const s of sigs) {
    const x = a.get(s.signalId), z = b.get(s.signalId);
    if (!x || !z || x.error || z.error) { continue; }
    if (x.warm) { warmServed++; }
    if (x.count === z.count && Buffer.compare(x.rec, z.rec) === 0) { same++; continue; }
    differ++;
    console.log(`DIFF ${s.path} at ${at}: warm ${x.warm ? 'yes' : 'no'} count ${x.count} vs ${z.count}`);
  }
}
// trace-X's fan-in point reads: valueAt and valueAt {prev} at change times and around them
let pSame = 0, pDiffer = 0;
const pLat = [], cLat = [];
for (const at of [0.051, 0.2, 0.35, 0.62, 0.8, 0.93]) {
  const t = Math.floor(T * at);
  for (const prev of [false, true]) {
    await warm.send('window', W(at - 0.001));  // (the rows stay the ones being viewed)
    const q = { signalIds: sigs.map((s) => s.signalId), t, ...(prev ? { prev: true } : {}) };
    const s0 = performance.now();
    const a = await warm.send('valueAt', q);
    if (prev) { pLat.push(performance.now() - s0); }
    const s1 = performance.now();
    const b = await cold.send('valueAt', q);
    if (prev) { cLat.push(performance.now() - s1); }
    const eq = !a.error && !b.error && JSON.stringify(a.result.values) === JSON.stringify(b.result.values) && JSON.stringify(a.result.prev || null) === JSON.stringify(b.result.prev || null);
    if (eq) { pSame++; } else { pDiffer++; console.log(`DIFF valueAt${prev ? ' prev' : ''} at ${t}: ${JSON.stringify(a.error || a.result).slice(0, 300)} vs ${JSON.stringify(b.error || b.result).slice(0, 300)}`); }
  }
}
pLat.sort((x, y) => x - y); cLat.sort((x, y) => x - y);
differ += pDiffer;
lat.sort((x, y) => x - y);
console.log(JSON.stringify({ signals: sigs.length, warmSet: st ? st.ready.length : 0, compared: same + differ - pDiffer, warmServed, same, differ, warmWindowMs: { p50: Math.round(lat[3]), max: Math.round(lat[6]) },
  pointReads: { same: pSame, differ: pDiffer, prevMs: { p50: Math.round(pLat[3]), max: Math.round(pLat[5]) }, coldPrevMs: { p50: Math.round(cLat[3]), max: Math.round(cLat[5]) } } }));
warm.close(); cold.close();
setTimeout(() => process.exit(differ || !warmServed ? 1 : 0), 300);
