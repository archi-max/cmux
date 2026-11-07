// Point reads on warm readers against cold ones, on a real FSDB (by hand, on a host with Verdi;
// not part of run.sh):
//   node warm-point-bench.mjs <install>/cmux-helper-v2.sh <dump.fsdb> <scope> [n] [workers]
// A helper with warm readers (FSDB_WARM=1) and one without (FSDB_WARM=0), both with background
// loads off (FSDB_BG_LOAD=0). The first n BitVector variables under <scope> are viewed at 1%
// windows until the warm set is ready. Then every query goes to both helpers, in alternating
// order, so host load drifts alike:
//   first  valueAt {prev} of the set's rows at a new time
//   point  20 valueAt of the set's rows at nearby times
//   prev   20 valueAt {prev} at the same times
//   trace  8 trace steps: valueAt {prev} at t, then t = the latest previous change - 1
//   mixed  valueAt {prev} of the set's rows plus 6 rows outside the set
// Times are the helper's own (reply ms) and the client's. Peak RSS is the RSS of this
// process's session, sampled every 100 ms. Answers (values and prev) must be equal: exit 1 on any
// difference.
// SOLO=w or SOLO=c runs one helper at a time, for hosts where two side by side is too many
// readers on a big dump. SOLO=w writes the set to SETFILE, SOLO=c reads it, and ANSFILE gets the
// answers of each run (compare the two files). MAXREADERS=k kills the session when more than k
// worker processes (warm readers included) are alive.
import { spawn, execFile, execFileSync } from 'node:child_process';
import fs from 'node:fs';

const [launcher, file, scope, nStr, wStr] = process.argv.slice(2);
if (!launcher || !file || !scope) { console.error('usage: node warm-point-bench.mjs <launcher> <fsdb> <scope> [n] [workers]'); process.exit(2); }
const n = Number(nStr || 16), workers = wStr || '2';

function start(env) {
  const p = spawn('bash', [launcher, '--workers', workers], { stdio: ['pipe', 'pipe', 'ignore'], env: { ...process.env, FSDB_BG_LOAD: '0', ...env } });
  let buf = Buffer.alloc(0), need = null, nid = 1, ready;
  const pend = new Map(), readyP = new Promise((r) => { ready = r; });
  const deliver = (msg) => {
    if (msg.ready) { ready(msg); return; }
    const h = pend.get(msg.id); if (!h || msg.partial) { return; }
    pend.delete(msg.id); h.res({ ...msg, t: performance.now() - h.t0 });
  };
  p.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (need) { if (buf.length < need.n) { break; } buf = buf.subarray(need.n); deliver(need.msg); need = null; continue; }
      const i = buf.indexOf(10); if (i < 0) { break; }
      const line = buf.subarray(0, i).toString(); buf = buf.subarray(i + 1);
      if (!line.trim()) { continue; }
      const msg = JSON.parse(line);
      if (msg.binLength) { need = { msg, n: msg.binLength }; continue; }
      deliver(msg);
    }
  });
  return {
    ready: readyP,
    send(cmd, a = {}) { const id = nid++; const t0 = performance.now(); return new Promise((res) => { pend.set(id, { res, t0 }); p.stdin.write(JSON.stringify({ id, cmd, ...a }) + '\n'); }); },
    close() { p.stdin.end(); },
  };
}

const sid = execFileSync('ps', ['-o', 'sid=', '-p', String(process.pid)]).toString().trim();
const MAXR = Number(process.env.MAXREADERS || 0);
let peak = 0, maxReaders = 0, sampling = false;
// (asynchronous: a synchronous ps here would stall the replies being timed)
const sampler = setInterval(() => {
  if (sampling) { return; }
  sampling = true;
  execFile('ps', ['-eo', 'sid=,rss=,args='], { maxBuffer: 1 << 24 }, (e, out) => {
    sampling = false;
    if (e) { return; }
    const mine = out.split('\n').map((l) => l.trim().split(/\s+/)).filter((x) => x[0] === sid);
    peak = Math.max(peak, Math.round(mine.reduce((a, x) => a + Number(x[1]), 0) / 1024));
    const r = mine.filter((x) => x.slice(2).join(' ').includes('worker.js')).length;
    maxReaders = Math.max(maxReaders, r);
    if (MAXR && r > MAXR) { console.log(JSON.stringify({ abort: `readers ${r} > ${MAXR}` })); process.kill(-Number(sid), 'SIGKILL'); }
  });
}, 100);

const SOLO = process.env.SOLO || '';
const hw = SOLO === 'c' ? null : start({ FSDB_WARM: '1' }), hc = SOLO === 'w' ? null : start({ FSDB_WARM: '0' });
const h0 = hw || hc;
await Promise.all([hw && hw.ready, hc && hc.ready]);
const o = await h0.send('open', { file });
if (o.error) { console.error('open:', o.error); process.exit(2); }
if (hw && hc) { await hc.send('open', { file }); }
const T = o.result.metadata.timeEnd;
for (const h of [hw, hc].filter(Boolean)) {
  for (let k = 0; k < 600; k++) { const st = (await h.send('stats')).result; if (st.kinds && st.kinds.state !== 'pending') { break; } await new Promise((r) => setTimeout(r, 100)); }
}

const parts = scope.split('.');
let cur = o.result.top.find((t) => t.name === parts[0]), path = parts[0];
for (const q of parts.slice(1)) { const c = await h0.send('children', { scopeOffsetIdx: cur.scopeOffsetIdx, scopePath: path }); cur = c.result.scopes.find((s) => s.name === q); path += '.' + q; }
const vars = [], queue = [[cur, path]];
while (queue.length && vars.length < 4 * n + 40) {
  const [s, sp] = queue.shift();
  const c = await h0.send('children', { scopeOffsetIdx: s.scopeOffsetIdx, scopePath: sp });
  const flat = (r) => { for (const v of r.vars) { vars.push(v); } for (const k of r.scopes) { if (k.inline) { flat(k.inline); } else { queue.push([k, sp + '.' + k.name]); } } };
  flat(c.result);
}
const seen = new Set();
const all = vars.filter((v) => v.encoding === 'BitVector' && v.type !== 'unknown_var_type' && v.width > 0 && !seen.has(v.signalId) && seen.add(v.signalId)).map((v) => v.signalId);
const viewIds = all.slice(0, n), outIds = all.slice(n, n + 6);
const W = (ids, at) => ({ signals: ids.map((signalId) => ({ signalId, width: 1 })), t0: Math.floor(T * at), t1: Math.floor(T * (at + 0.01)), buckets: 1024 });

const t0 = performance.now();
let set;
if (hw) {
  let st = null;
  for (let k = 0; k < 600; k++) { await hw.send('window', W(viewIds, 0.5)); st = (await hw.send('stats')).result.warm; if (st && st.ready && st.ready.length && !st.building) { break; } await new Promise((r) => setTimeout(r, 200)); }
  set = [...((st && st.ready) || [])];
  if (process.env.SETFILE) { fs.writeFileSync(process.env.SETFILE, JSON.stringify(set)); }
} else {
  set = JSON.parse(fs.readFileSync(process.env.SETFILE, 'utf8'));
}
const readyMs = Math.round(performance.now() - t0);
if (hc) { await hc.send('window', W(viewIds, 0.5)); }

let differ = 0, turn = 0;
const answers = [], lat = { w: {}, c: {} };
const both = async (name, ids, t, prev) => {
  const a = { signalIds: ids, t, ...(prev ? { prev: true } : {}) };
  const order = (turn++ % 2 ? [['c', hc], ['w', hw]] : [['w', hw], ['c', hc]]).filter((x) => x[1]);
  const r = {};
  for (const [k, h] of order) {
    r[k] = await h.send('valueAt', a);
    (lat[k][name] ||= []).push(r[k].ms || 0);
    (lat[k][name + 'Client'] ||= []).push(r[k].t);
  }
  const key = (x) => JSON.stringify(x.error || [x.result.values, x.result.prev || null]);
  if (r.w && r.c && (r.w.error || r.c.error || key(r.w) !== key(r.c))) { differ++; console.error('DIFF', name, t, key(r.w).slice(0, 200), key(r.c).slice(0, 200)); }
  const one = r.w || r.c;
  answers.push([name, t, JSON.parse(key(one))]);
  return one.result;
};
await both('first', set, Math.floor(T * 0.37), true);
for (let k = 0; k < 20; k++) { const t = Math.floor(T * 0.37) + (k + 1) * 997; await both('point', set, t, false); await both('prev', set, t, true); }
let tt = Math.floor(T * 0.45);
for (let k = 0; k < 8; k++) {
  const r = await both('trace', set, tt, true);
  const latest = Math.max(...((r && r.prev) || []).filter(Boolean).map((x) => x.t));
  if (!(latest > 0)) { break; }
  tt = latest - 1;
}
await both('mixed', [...set, ...outIds], Math.floor(T * 0.41), true);
const ws = hw ? (await hw.send('stats')).result.warm : null;
clearInterval(sampler);

const pct = (a) => { const s = [...a].sort((x, y) => x - y); return { n: s.length, p50: Math.round(s[Math.floor(s.length / 2)]), p95: Math.round(s[Math.min(s.length - 1, Math.floor(s.length * 0.95))]), max: Math.round(s[s.length - 1]) }; };
const sum = (k) => Object.fromEntries(Object.entries(lat[k]).map(([nm, a]) => [nm, /^(first|mixed)/.test(nm) ? Math.round(a[0]) : pct(a)]));
console.log(JSON.stringify({ set: set.length, setIds: set, readyMs, differ, warm: hw ? sum('w') : null, cold: hc ? sum('c') : null, peakRssMB: peak, maxReaders,
  warmStats: ws && { ready: ws.ready.length, procs: ws.procs, peakRssMB: Math.round((ws.peakRss || 0) / 1048576) } }));
if (process.env.ANSFILE) { fs.writeFileSync(process.env.ANSFILE + '.' + (SOLO || 'pair'), JSON.stringify(answers)); }
if (hw) { hw.close(); }
if (hc) { hc.close(); }
setTimeout(() => process.exit(differ ? 1 : 0), 500);
