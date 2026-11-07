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
  const p = spawn(process.execPath, [path.join(dir, 'helper.js'), '--workers', String(workers)], {
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

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `FSDB SCHED CHECKS FAILED: ${fails}` : 'FSDB SCHED CHECKS PASSED');
process.exit(fails ? 1 : 0);
