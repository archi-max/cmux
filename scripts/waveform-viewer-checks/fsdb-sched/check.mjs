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
  check(s && s.split === 4, `a lone signal on an idle pool is split in 4: ${JSON.stringify(s && s.split)}`);
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

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `FSDB SCHED CHECKS FAILED: ${fails}` : 'FSDB SCHED CHECKS PASSED');
process.exit(fails ? 1 : 0);
