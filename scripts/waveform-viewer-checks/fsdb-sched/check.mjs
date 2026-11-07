// run.sh fsdb-sched: how fsdb-helper-v2 schedules first loads over its worker pool, against a
// stand-in addon (stub-addon.cjs) whose per-signal load costs are set per case. No FSDB.
// On a 1.7 GB dump one reader load costs 1 ms to 10 s, so the pool must balance work, not
// signal counts, and keep what a cancelled request had asked for.
// Usage: node check.mjs <fsdb-helper-v2 folder>
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const dir = path.resolve(process.argv[2]);
const here = path.dirname(new URL(import.meta.url).pathname);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fsdb-sched-'));
const dump = path.join(tmp, 'stub.fsdb'); fs.writeFileSync(dump, 'stub');
let fails = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) { fails++; } };

function helper(workers, env = {}) {
  const p = spawn(process.execPath, [path.join(dir, 'helper.js'), '--workers', String(workers), ...(env.ARGS ? env.ARGS.split(' ') : [])], {
    stdio: ['pipe', 'ignore', 'ignore', 'pipe'],
    env: { ...process.env, FSDB_ADDON: path.join(here, 'stub-addon.cjs'), FSDB_STORE_CACHE: '0', FSDB_INDEX_DIR: path.join(tmp, 'idx'), TMPDIR: tmp, ...env },
  });
  let buf = Buffer.alloc(0), need = null, nid = 1, ready;
  const pend = new Map();
  const readyP = new Promise((r) => { ready = r; });
  p.stdio[3].on('data', (d) => {
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
  function deliver(m) {
    if (m.id === 0) { if (m.ready) { ready(m); } return; }
    const h = pend.get(m.id); if (!h) { return; }
    pend.delete(m.id); h({ ...m, at: performance.now() - h.t0 });
  }
  return {
    ready: readyP,
    send(cmd, a = {}) { const id = nid++; const t0 = performance.now(); return { id, reply: new Promise((res) => { res.t0 = t0; pend.set(id, Object.assign(res, { t0 })); p.stdin.write(JSON.stringify({ id, cmd, ...a }) + '\n'); }) }; },
    close() { p.stdin.end(); p.kill(); },
  };
}
const win = (ids) => ({ signals: ids.map((signalId) => ({ signalId, width: 1 })), t0: 0, t1: 1048576, buckets: 1024 });
const loaded = async (h) => { const s = (await h.send('stats').reply).result; return s.workers.reduce((a, w) => a + w.loaded.length, 0); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function start(workers, costs, env = {}) {
  const h = helper(workers, { STUB_COSTS: JSON.stringify(costs), ...env });
  await h.ready;
  const o = await h.send('open', { file: dump }).reply;
  if (o.error) { throw new Error(o.error); }
  await wait(200);  // the workers' own opens
  return h;
}

// 1. Twelve signals added at once, two of them heavy. Round-robin on first sight put both
// heavy ones (and two more) on worker 0: ~1.3 s while three workers idled after 60 ms.
{
  const costs = { 1: 600, 5: 600 };
  const h = await start(4, costs);
  const r = await h.send('window', win([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])).reply;
  check(!r.error && r.result.signals.length === 12, `one request for 12 cold signals answers all: ${r.error || r.result.signals.length}`);
  check(r.at < 1000, `the pool takes them as workers free up, so the two heavy loads run side by side: ${Math.round(r.at)} ms (round-robin ~1300)`);
  h.close();
}

// 2. One request per added signal, sent together (adding signals one by one): coverage
// (every one answers, in bounded time); an idle pool still splits the first.
{
  const costs = { 1: 600, 5: 600 };
  const h = await start(4, costs);
  const rs = await Promise.all([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map((id) => h.send('window', win([id])).reply));
  const last = Math.max(...rs.map((r) => r.at));
  check(rs.every((r) => !r.error), 'every per-signal request answers');
  check(last < 1000, `the last of 12 per-signal requests: ${Math.round(last)} ms (both heavy ones on one worker: ~1300)`);
  h.close();
}

// 3. A lone cold signal on an idle pool is still split over every worker.
{
  const h = await start(4, { 3: 800 });
  const r = await h.send('window', win([3])).reply;
  const s = r.result && r.result.signals[0];
  check(s && s.split >= 4, `a lone signal on an idle pool is split over every worker: ${JSON.stringify(s && s.split)} pieces`);
  check(r.at < 600, `... and drawn in about a quarter of its load: ${Math.round(r.at)} ms`);
  h.close();
}

// 4. A cancelled request (the viewer's 10 s window timeout, or the user zoomed away) keeps
// its first loads that had not started: they finish in the background, so asking again
// finds them stored instead of queueing them again at the back.
{
  const costs = { 1: 300, 2: 300, 3: 300, 4: 300, 5: 300, 6: 300 };
  const h = await start(2, costs, { FSDB_SPLIT_SINGLE: '0' });
  const reqs = [1, 2, 3, 4, 5, 6].map((id) => h.send('window', win([id])));
  await wait(60);
  for (const q of reqs) { h.send('cancel', { target: q.id }); }
  await wait(1500);
  const n = await loaded(h);
  check(n === 6, `after cancelling 6 first loads (2 running), all 6 are stored a little later: ${n}`);
  const again = await h.send('window', win([1, 2, 3, 4, 5, 6])).reply;
  check(!again.error && again.at < 150 && again.result.signals.every((s) => s.cached), `asking again is answered from the store: ${Math.round(again.at)} ms`);
  h.close();
}

// 5. A signal another request already placed is not floated again (no second load).
{
  const h = await start(4, { 7: 400 });
  const a = h.send('window', win([7, 8, 9, 10, 11]));
  const b = h.send('valueAt', { signalIds: [7], t: 10 });
  const [ra, rb] = await Promise.all([a.reply, b.reply]);
  check(!ra.error && !rb.error, `a window and a valueAt of the same first-load signal both answer: ${ra.error || rb.error || 'ok'}`);
  const st = (await h.send('stats').reply).result;
  const owners = st.workers.filter((w) => w.loaded.includes(7)).length;
  check(owners <= 1, `signal 7 is stored on one worker: ${owners}`);
  h.close();
}

// 6. A cheap signal added right after a heavy one draws at once. A lone split put a slice of
// the heavy load on every worker, so each cheap signal waited for a slice (~500 ms here,
// 2.3 s on a 1.7 GB dump).
{
  const h = await start(4, { 1: 2000 });
  const heavy = h.send('window', win([1]));
  await wait(20);
  const cheap = [2, 3, 4, 5].map((id) => h.send('window', win([id])));
  const rs = await Promise.all(cheap.map((q) => q.reply));
  const worst = Math.max(...rs.map((r) => r.at));
  check(rs.every((r) => !r.error) && worst < 250, `4 cheap signals added after a 2 s one answer within 250 ms: ${Math.round(worst)} ms`);
  const rh = await heavy.reply;
  check(!rh.error && rh.at < 900, `... and the heavy one is still spread over the pool: ${Math.round(rh.at)} ms (alone on one worker: 2000)`);
  h.close();
}

// 7. Two heavy signals among ten, one request each: the pool shares both heavy loads (~800 ms
// of work per worker), instead of one worker per heavy signal (1600 ms).
{
  const h = await start(4, { 1: 1600, 2: 1600 });
  const rs = await Promise.all([1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((id) => h.send('window', win([id])).reply));
  const heavyLast = Math.max(rs[0].at, rs[1].at), cheapLast = Math.max(...rs.slice(2).map((r) => r.at));
  check(rs.every((r) => !r.error), 'every one of the ten answers');
  check(heavyLast < 1300, `both heavy loads are spread over the pool: last at ${Math.round(heavyLast)} ms (one worker each: ~1600)`);
  check(cheapLast < 300, `the eight cheap ones draw first: last at ${Math.round(cheapLast)} ms`);
  h.close();
}

// 8. Panning while the whole walks behind ranged first draws run: a background load is cut in
// pieces, so an interactive request waits for one piece, not for a whole 3 s load.
{
  const h = await start(2, { 1: 3000, 2: 3000 });
  const near = { t0: 0, t1: 100000, buckets: 1024 };  // 10% of the dump: ranged first draws
  const r1 = await Promise.all([1, 2].map((id) => h.send('window', { signals: [{ signalId: id, width: 1 }], ...near }).reply));
  check(r1.every((r) => !r.error && r.result.signals[0].ranged), `two ranged first draws: ${r1.map((r) => r.error || r.result.signals[0].ranged)}`);
  await wait(100);  // their whole walks are now running in the background
  const r = await h.send('window', win([3])).reply;
  check(!r.error && r.at < 600, `a new signal added meanwhile answers within 600 ms: ${Math.round(r.at)} ms (behind a whole 3 s load: ~2900)`);
  h.close();
}

// 9. A signal the reader can't read fails once: asking again answers the same error at once,
// without loading it again.
{
  const h = await start(4, { 4: 400 }, { STUB_BAD: '[4]' });
  const a = await h.send('window', win([4])).reply;
  const e1 = a.result && a.result.signals[0].error;
  check(!a.error && /unsupported/.test(e1 || ''), `an unreadable signal answers its error: ${a.error || e1}`);
  const b = await h.send('window', win([4])).reply;
  const e2 = b.result && b.result.signals[0].error;
  check(!b.error && /unsupported/.test(e2 || '') && b.at < 60, `asking again answers the same error without a reload: ${Math.round(b.at)} ms`);
  h.close();
}

// 11. A first load per worker that costs extra (the reader's per-process setup for a signal)
// must not read as a per-load floor: the rest of a heavy signal still goes out in ~250 ms
// pieces. Taking it as a floor gave one worker the last 3/4 of a clock (7.5 s on a 1.7 GB dump).
{
  const h = await start(4, { 1: 4000 }, { STUB_FIRST_MS: '150' });
  const r = await h.send('window', win([1])).reply;
  const s = r.result && r.result.signals[0];
  check(!r.error && r.at < 1900, `a 4 s signal with a 150 ms first load per worker: ${Math.round(r.at)} ms, ${s && s.split} pieces (one worker for the rest: ~3200)`);
  h.close();
}

// 12. A cheap signal whose first piece is done finishes before the first pieces of later heavy
// signals: 50 signals added at once drew nothing for 2 s while every job's first piece ran.
{
  const costs = Object.fromEntries([5, 6, 7, 8, 9, 10, 11, 12].map((id) => [id, 1600]));
  for (const id of [1, 2, 3, 4]) { costs[id] = 40; }
  const h = await start(4, costs);
  const rs = await Promise.all([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].map((id) => h.send('window', win([id])).reply));
  const cheap = Math.max(...rs.slice(0, 4).map((r) => r.at));
  check(rs.every((r) => !r.error) && cheap < 120, `4 cheap signals ahead of 8 heavy ones are done within 120 ms: ${Math.round(cheap)} ms (after every first piece: ~200)`);
  h.close();
}


// 14. Panning while background whole loads run: one worker is kept free of background pieces,
// and ranged reads go to free workers, so a pan never waits for a piece (~250-500 ms).
{
  const h = await start(3, { 1: 3000, 2: 3000, 3: 3000, 4: 200 });
  const near = (id, t0) => ({ signals: [{ signalId: id, width: 1 }], t0, t1: t0 + 10000, buckets: 1024 });  // 1% of the dump
  await Promise.all([1, 2, 3].map((id) => h.send('window', near(id, 0)).reply));
  await wait(150);  // their whole loads now run in the background
  const lat = [];
  for (let k = 1; k <= 6; k++) {
    const r = await h.send('window', { signals: [1, 2, 3, 4].map((signalId) => ({ signalId, width: 1 })), t0: k * 10000, t1: k * 10000 + 10000, buckets: 1024 }).reply;
    lat.push(r.error ? 1e9 : r.at);
    await wait(40);
  }
  const worst = Math.max(...lat);
  check(worst < 250, `pan steps over 4 signals while 3 whole loads run: worst ${Math.round(worst)} ms (behind a 250-500 ms piece: ~485)`);
  h.close();
}

// 15. One unreadable signal in a multi-signal request doesn't make the others load again whole:
// the request waits for each signal's own load, and only a failed one falls back.
// (Promise.all settled at the first failure, then loaded the 2 s signal whole on one worker
// while its pieces went on, and stored it twice.)
{
  const h = await start(4, { 1: 2000 }, { STUB_BAD: '[4]' });
  const r = await h.send('window', win([4, 1])).reply;
  const sig = r.result ? r.result.signals : [];
  check(!r.error && /unsupported/.test(sig[0] && sig[0].error || '') && sig[1] && !sig[1].error, `an unreadable and a 2 s signal in one request: ${r.error || JSON.stringify(sig.map((x) => x.error || 'ok'))}`);
  check(r.at < 1100, `... the 2 s one still loads in pieces over the pool: ${Math.round(r.at)} ms (whole on one worker: ~2000)`);
  await wait(300);
  const st = (await h.send('stats').reply).result;
  const holders = st.workers.filter((w) => w.loaded.includes(1)).length;
  check(holders === 1, `... and is stored once: ${holders} holders`);
  h.close();
}

// 10. `--workers auto` (what cmux asks for) sizes the pool from the host: half its cores, at most
// 8, and only as many as fit in its available memory minus 4 GB at ~600 MB each. Each worker
// keeps a store share of at least 256 MB, so more workers don't shrink the largest signal that
// can be stored (clk of a 1.7 GB dump is 130 MB).
{
  const pool = async (env) => {
    const h = helper('auto', { STUB_COSTS: '{}', ...env });
    const r = await h.ready;
    await h.send('open', { file: dump }).reply;
    await wait(200);
    const st = (await h.send('stats').reply).result;
    h.close();
    return { ready: r.workers, n: st.workers.length, limits: st.workers.map((w) => w.limit) };
  };
  const big = await pool({ FSDB_HOST_CPUS: '12', FSDB_HOST_AVAIL_MB: '14000' });
  check(big.n === 6 && big.ready === 6, `12 cores, 14 GB available: 6 workers: ${JSON.stringify(big.n)}`);
  check(big.limits.every((l) => l >= 256e6), `... each with a store share of at least 256 MB: ${big.limits.map((l) => Math.round(l / 1e6))}`);
  const many = await pool({ FSDB_HOST_CPUS: '64', FSDB_HOST_AVAIL_MB: '200000' });
  check(many.n === 8, `64 cores: at most 8 workers: ${many.n}`);
  const tight = await pool({ FSDB_HOST_CPUS: '12', FSDB_HOST_AVAIL_MB: '5500' });
  check(tight.n === 2, `12 cores but 5.5 GB available: 2 workers: ${tight.n}`);
  const small = await pool({ FSDB_HOST_CPUS: '2', FSDB_HOST_AVAIL_MB: '14000' });
  check(small.n === 1, `2 cores: 1 worker: ${small.n}`);
  const fixed = helper(4, { STUB_COSTS: '{}', FSDB_HOST_CPUS: '12', FSDB_HOST_AVAIL_MB: '14000' });
  check((await fixed.ready).workers === 4, 'an explicit --workers 4 is kept');
  const o = await fixed.send('open', { file: dump, workers: 6 }).reply;
  check(!o.error && o.result.workers === 6, `open {workers: 6} gives 6 (the old cap was 4): ${o.error || o.result.workers}`);
  fixed.close();
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `FSDB SCHED CHECKS FAILED: ${fails}` : 'FSDB SCHED CHECKS PASSED');
process.exit(fails ? 1 : 0);
