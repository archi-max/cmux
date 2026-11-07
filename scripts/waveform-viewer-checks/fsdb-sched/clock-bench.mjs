// clock-bench.mjs: fsdb-helper-v2's clock descriptors (FSDB_CLOCK_DESC=1) against the reader, on a real dump.
// Needs an installed helper (its cmux-helper-v2.sh) built with clockseg; runs one worker per helper.
//   node clock-bench.mjs exact   <launcher> <fsdb> <ids,comma> [queries per row]
//       edge/search answers, descriptors off vs on (after clockVerify of each id), same random queries
//   node clock-bench.mjs windows <launcher> <fsdb> <ids,comma> [max level]
//       window replies (exact, count, deflated records + counts), off vs on: the page's tiles at every level
//   node clock-bench.mjs ab      <launcher> <fsdb> <clock id> [rounds]
//       pans with a background verify (A) vs none (B), ABBA order, fresh helpers, FSDB_WARM=0 FSDB_BG_LOAD=0;
//       SCOPE=<dotted scope> (required) gives the panned rows (NR, default 8), PANS per arm (24), SPAN (0.01)
import { spawn } from 'node:child_process';
const mode = process.argv[2];
process.argv.splice(2, 1);
function helper(env) {
  const p = spawn('bash', [process.argv[2], '--workers', '1'], { stdio: ['pipe', 'pipe', 'ignore'], env: { ...process.env, ...env } });
  let bb = Buffer.alloc(0), need = null, nid = 1, ready; const pend = new Map(), readyP = new Promise((r) => { ready = r; });
  const deliver = (m) => { if (m.ready) { ready(m); return; } const h = pend.get(m.id); if (h && !m.partial) { pend.delete(m.id); h(m); } };
  p.stdout.on('data', (d) => { bb = Buffer.concat([bb, d]); for (;;) {
    if (need) { if (bb.length < need.n) break; const bin = Buffer.from(bb.subarray(0, need.n)); bb = bb.subarray(need.n); deliver({ ...need.m, bin }); need = null; continue; }
    const i = bb.indexOf(10); if (i < 0) break; const l = bb.subarray(0, i).toString(); bb = bb.subarray(i + 1); if (!l.trim()) continue;
    const m = JSON.parse(l); if (m.binLength) { need = { m, n: m.binLength }; continue; } deliver(m); } });
  const send = (cmd, a = {}) => new Promise((res) => { const id = nid++; pend.set(id, res); p.stdin.write(JSON.stringify({ id, cmd, ...a }) + '\n'); });
  return { readyP, send, close: () => new Promise((r) => { p.on('exit', r); p.stdin.end(); setTimeout(() => { try { p.kill('SIGKILL'); } catch (e) { /* gone */ } }, 5000); }) };
}
async function exact() {
  const [launcher, file, list, nq] = process.argv.slice(2);
  const ids = list.split(',').map(Number), NQ = Number(nq || 200);
  let seed = 7; const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  async function run(env, verify, qs) {
    const h = helper(env); await h.readyP;
    const o = await h.send('open', { file }); if (o.error) { throw new Error(o.error); }
    const info = {};
    if (verify) {
      for (const id of ids) {
        const t0 = performance.now();
        await h.send('clockVerify', { signalId: id });
        let i; for (;;) { i = (await h.send('clockInfo', { signalId: id })).result; if (i.state !== 'verifying') break; await wait(500); }
        info[id] = { wallMs: Math.round(performance.now() - t0), ...i };
        console.log(JSON.stringify({ id, ...info[id] }));
      }
    }
    const out = [], ms = [];
    for (const [cmd, a] of qs) { const t0 = performance.now(); const r = await h.send(cmd, a); ms.push(performance.now() - t0); out.push(r.error ? { error: r.error } : { t: r.result.t }); }
    const st = (await h.send('stats')).result;
    h.close();
    return { out, ms, served: st.clock ? st.clock.served : null, T: o.result.metadata.timeEnd };
  }
  // queries: random times, near the start and end, every kind and value, both directions
  const probe = helper({}); await probe.readyP; const po = await probe.send('open', { file }); const T = po.result.metadata.timeEnd; probe.close();
  const qs = [];
  for (const id of ids) {
    const ts = [0, 1, T, T - 1, Math.floor(T / 2)];
    for (let k = 0; k < NQ; k++) { ts.push(Math.floor(rnd() * (T + 1))); }
    for (const t of ts) { const dir = rnd() < 0.5 ? 1 : -1;
      qs.push(['edge', { signalId: id, t, dir, kind: ['any', 'rise', 'fall', 'posedge', 'negedge', 'edge'][Math.floor(rnd() * 6)] }]);
      qs.push(['search', { signalId: id, t, dir, value: ['1', '0', 'x', 'z'][Math.floor(rnd() * 4)] }]); }
  }
  const ref = await run({}, false, qs);
  const got = await run({ FSDB_CLOCK_DESC: '1' }, true, qs);
  const diff = qs.map((q, k) => [q, ref.out[k], got.out[k]]).filter(([, a, b]) => JSON.stringify(a) !== JSON.stringify(b));
  const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))] * 100) / 100; };
  console.log(JSON.stringify({ queries: qs.length, differ: diff.length, served: got.served, first: diff.slice(0, 5),
    refMs: { p50: pct(ref.ms, 0.5), p95: pct(ref.ms, 0.95) }, descMs: { p50: pct(got.ms, 0.5), p95: pct(got.ms, 0.95) } }));

}
async function windows() {
  const [launcher, file, list, maxL] = process.argv.slice(2);
  const ids = list.split(',').map(Number);
  let seed = 11; const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const ri = (a, b) => a + Math.floor(rnd() * (b - a + 1));
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  async function run(env, verify, reqs) {
    const h = helper(env); await h.readyP;
    const o = await h.send('open', { file }); if (o.error) { throw new Error(o.error); }
    if (verify) {
      for (const id of ids) {
        await h.send('clockVerify', { signalId: id });
        let i; for (;;) { i = (await h.send('clockInfo', { signalId: id })).result; if (i.state !== 'verifying') break; await wait(500); }
        console.log(JSON.stringify({ id, state: i.state, segments: i.segments, peakMB: i.peakMB, ms: i.ms }));
      }
    }
    const out = [], ms = [];
    for (const q of reqs) {
      const t0 = performance.now();
      const r = await h.send('window', q);
      ms.push(performance.now() - t0);
      if (r.error) { out.push({ error: r.error }); continue; }
      const s = r.result.signals[0];
      out.push(s.error ? { error: s.error } : { exact: s.exact, count: s.count, bytes: s.bytes, bucketBytes: s.bucketBytes, clock: !!s.clock, bin: r.bin ? r.bin.toString('base64') : '' });
    }
    h.close();
    return { out, ms };
  }
  const probe = helper({}); await probe.readyP; const T = (await probe.send('open', { file })).result.metadata.timeEnd; probe.close();
  const reqs = [];
  for (const id of ids) {
    for (let L = 0; 1024 * 2 ** L <= 2 * T && L <= Number(maxL || 64); L++) {
      const span = 1024 * 2 ** L, tiles = Math.ceil((T + 1) / span);
      for (let r = 0; r < 2; r++) { const i = ri(0, tiles - 1), m = ri(1, 3); reqs.push({ signals: [{ signalId: id, width: 1 }], t0: i * span, t1: (i + m) * span, buckets: 1024 * m }); }
    }
    reqs.push({ signals: [{ signalId: id, width: 1 }], t0: 0, t1: 1024, buckets: 1024 }, { signals: [{ signalId: id, width: 1 }], t0: 7, t1: 7 + ri(1, 99999), buckets: ri(1, 40) });
  }
  const ref = await run({}, false, reqs);
  const got = await run({ FSDB_CLOCK_DESC: '1' }, true, reqs);
  let same = 0, differ = 0, refErr = 0, bucketed = 0, fromDesc = 0; const first = [];
  reqs.forEach((q, k) => {
    const a = ref.out[k], b = got.out[k];
    if (b.clock) { fromDesc++; }
    if (a.error) { refErr++; return; }
    if (!a.exact) { bucketed++; }
    const eq = a.exact === b.exact && a.count === b.count && a.bin === b.bin;
    if (eq) { same++; } else { differ++; if (first.length < 3) { first.push({ t0: q.t0, t1: q.t1, buckets: q.buckets, ref: { ...a, bin: a.bin.length }, got: { ...b, bin: b.bin.length } }); } }
  });
  const pct = (xs, p) => { const s = [...xs].sort((x, y) => x - y); return Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))] * 100) / 100; };
  console.log(JSON.stringify({ windows: reqs.length, compared: same + differ, same, differ, bucketed, refErrors: refErr, fromDesc, first,
    refMs: { p50: pct(ref.ms, 0.5), p95: pct(ref.ms, 0.95) }, descMs: { p50: pct(got.ms, 0.5), p95: pct(got.ms, 0.95) } }));

}
async function ab() {
  const [launcher, file, cidArg, roundsArg] = process.argv.slice(2);
  const CID = Number(cidArg), ROUNDS = Number(roundsArg || 3), PANS = Number(process.env.PANS || 24), NR = Number(process.env.NR || 8);
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  async function rowsOf(h, o) {
    if (!process.env.SCOPE) { throw new Error('ab: set SCOPE to the dotted scope of the rows to pan'); }
    const parts = process.env.SCOPE.split('.');
    let cur = o.result.top.find((t) => t.name === parts[0]), sp = parts[0];
    for (const q of parts.slice(1)) { const c = await h.send('children', { scopeOffsetIdx: cur.scopeOffsetIdx, scopePath: sp }); cur = c.result.scopes.find((s) => s.name === q); sp += '.' + q; }
    const c = await h.send('children', { scopeOffsetIdx: cur.scopeOffsetIdx, scopePath: sp });
    return [...new Map(c.result.vars.filter((v) => v.encoding === 'BitVector' && v.signalId !== CID).map((v) => [v.signalId, v.width])).entries()].slice(0, NR);
  }
  async function arm(name) {
    const A = name === 'A';
    const h = helper({ FSDB_WARM: '0', FSDB_BG_LOAD: '0', ...(A ? { FSDB_CLOCK_DESC: '1' } : {}) }); await h.readyP;
    const o = await h.send('open', { file }); const T = o.result.metadata.timeEnd;
    const rows = await rowsOf(h, o);
    const span = Math.floor(T * Number(process.env.SPAN || 0.01));
    if (A) { await h.send('clockVerify', { signalId: CID }); }
    const lat = [];
    let during = 0;
    for (let k = 0; k < PANS; k++) {
      const t0 = Math.floor(T * 0.2) + k * span, t = performance.now();
      const rs = await Promise.all(rows.map(([id, w]) => h.send('window', { signals: [{ signalId: id, width: w || 1 }], t0, t1: t0 + span, buckets: 1024 })));
      const ms = performance.now() - t;
      if (rs.some((r) => r.error || r.result.signals.some((x) => x.error))) { console.log('ERR', JSON.stringify(rs.find((r) => r.error || r.result.signals.some((x) => x.error))).slice(0, 300)); }
      let verifying = false;
      if (A) { const i = (await h.send('clockInfo', { signalId: CID })).result; verifying = i.state === 'verifying'; }
      if (!A || verifying) { lat.push(ms); during += A ? 1 : 0; }
      await wait(200);
    }
    const info = A ? (await h.send('clockInfo', { signalId: CID })).result : null;
    await h.close();
    return { name, rows: rows.map((r) => r[0]), lat, during, info: info && { state: info.state, segments: info.segments } };
  }
  const pct = (xs, p) => { if (!xs.length) { return null; } const s = [...xs].sort((a, b) => a - b); return Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))]); };
  const all = { A: [], B: [] };
  const order = []; for (let r = 0; r < ROUNDS; r++) { order.push(...(r % 2 ? ['B', 'A'] : ['A', 'B'])); }
  for (const [k, name] of order.entries()) {
    const r = await arm(name);
    all[name].push(...r.lat);
    console.log(JSON.stringify({ arm: k, name, n: r.lat.length, during: r.during, p50: pct(r.lat, 0.5), p95: pct(r.lat, 0.95), info: r.info, rows: k === 0 ? r.rows : undefined }));
  }
  console.log(JSON.stringify({ final: true, A: { n: all.A.length, p50: pct(all.A, 0.5), p95: pct(all.A, 0.95) }, B: { n: all.B.length, p50: pct(all.B, 0.5), p95: pct(all.B, 0.95) } }));


}
const run = { exact, windows, ab }[mode];
if (!run) { console.error('mode: exact | windows | ab'); process.exit(2); }
await run();
process.exit(0);
