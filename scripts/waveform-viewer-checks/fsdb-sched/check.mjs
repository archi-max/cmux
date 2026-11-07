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
    pid: p.pid,
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

// 16. Removing rows drops their loads: `free` stops the background loads of cancelled
// requests for those signals (nobody waits for them), so the pool goes idle and nothing is
// stored again. (30 cancelled adds then free{} kept 5 workers busy ~24 s and stored 25 signals.)
{
  const costs = Object.fromEntries([1, 2, 3, 4, 5, 6, 7, 8].map((id) => [id, 1500]));
  const h = await start(4, costs);
  const qs = [1, 2, 3, 4, 5, 6, 7, 8].map((id) => h.send('window', win([id])));
  await wait(150);
  for (const q of qs) { h.send('cancel', { target: q.id }); }
  await h.send('free', {}).reply;
  await wait(600);  // the pieces running at the free end (<= 2 x 250 ms)
  const st = (await h.send('stats').reply).result;
  check(st.loads.length === 0 && st.workers.every((w) => !w.busy), `free {} after cancelling 8 loads: no load left, pool idle: ${st.loads.length} loads, busy ${st.workers.map((w) => w.busy)}`);
  await wait(1500);
  const n = await loaded(h);
  check(n === 0, `... and none of them is stored afterwards: ${n}`);
  // free {signalIds} drops only those signals' loads
  const a = h.send('window', win([1])), b = h.send('window', win([2]));
  await wait(150);
  h.send('cancel', { target: a.id }); h.send('cancel', { target: b.id });
  await h.send('free', { signalIds: [1] }).reply;
  await wait(2500);
  const st2 = (await h.send('stats').reply).result;
  const has = (id) => st2.workers.some((w) => w.loaded.includes(id));
  check(!has(1) && has(2), `free {signalIds: [1]} drops 1's load, 2's goes on: 1 ${has(1)}, 2 ${has(2)}`);
  h.close();
}

// 17. Cancelled loads kept in the background are bounded: a burst of cancels (rows removed
// without a free, a file switch) doesn't keep the pool busy for every one of them.
{
  const costs = Object.fromEntries([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14].map((id) => [id, 800]));
  const h = await start(4, costs, { STUB_SIGNALS: '16' });
  const qs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14].map((id) => h.send('window', win([id])));
  await wait(60);
  for (const q of qs) { h.send('cancel', { target: q.id }); }
  for (let t = 0; t < 60; t++) { const st = (await h.send('stats').reply).result; if (!st.loads.length && st.workers.every((w) => !w.busy)) { break; } await wait(100); }
  const n = await loaded(h);
  check(n <= 8, `14 cancelled loads: at most 8 go on in the background: ${n} stored`);
  h.close();
}

// 18. Piece files live in RAM (/dev/shm) where no worker's RSS guard sees them: their total is
// capped (FSDB_SHM_CAP), above it only the started load with the least work left gets more
// pieces until its join deletes them. 48 loads at once: every one started its first piece
// first, so uncapped their pieces peaked at ~730 KB; under a 1-byte cap (each load after
// another) they all answer, and the files hold about two loads plus a piece per worker.
{
  const ids = Array.from({ length: 48 }, (_, k) => k + 1);
  const h = await start(4, Object.fromEntries(ids.map((id) => [id, 400])),
    { STUB_SIGNALS: '48', STUB_COUNTS: JSON.stringify(Object.fromEntries(ids.map((id) => [id, 20000]))), FSDB_SHM_CAP: '1' });
  const root = fs.existsSync('/dev/shm') ? '/dev/shm' : '/tmp';
  const mine = fs.readdirSync(root).filter((n) => n.startsWith('fsdb-helper-v2-')).map((n) => path.join(root, n))
    .find((d) => { try { return fs.readFileSync(path.join(d, 'pid'), 'utf8').trim() === String(h.pid); } catch (e) { return false; } });
  let peak = 0, polling = true;
  (async () => {
    while (polling) {
      let sum = 0;
      try { for (const f of fs.readdirSync(mine)) { if (f !== 'pid') { try { sum += fs.statSync(path.join(mine, f)).size; } catch (e) { /* joined */ } } } } catch (e) { /* gone */ }
      peak = Math.max(peak, sum);
      await wait(2);
    }
  })();
  const rs = await Promise.all(ids.map((id) => h.send('window', win([id])).reply));
  polling = false;
  check(!!mine && rs.every((r) => !r.error), `48 loads of 200 KB of pieces each answer: ${rs.filter((r) => r.error).length} errors`);
  check(peak > 0 && peak < 560000, `... piece files peak at ${Math.round(peak / 1000)} KB under a 1-byte cap (two loads + a piece per worker: < 560; uncapped ~730)`);
  h.close();
}

// 19. A load's first piece shrinks on a bigger dump, as its load costs more: on a 10 GB dump a
// 1/16 probe of a 10 s signal held a worker 5-7 s. A 10 GB (sparse) dump, four 16 s loads on
// four workers, then a cheap signal: it waits for one short piece, not for a 1 s probe.
{
  fs.truncateSync(dump, 10e9);
  const h = await start(4, { 1: 16000, 2: 16000, 3: 16000, 4: 16000 });
  const heavy = [1, 2, 3, 4].map((id) => h.send('window', win([id])));
  await wait(30);
  const r = await h.send('window', win([5])).reply;
  check(!r.error && r.at < 450, `a cheap signal added while four 16 s loads start: ${Math.round(r.at)} ms (behind 1/16 probes: ~1000)`);
  for (const q of heavy) { h.send('cancel', { target: q.id }); }
  await h.send('free', {}).reply;
  h.close();
  fs.writeFileSync(dump, 'stub');
}

// 20. Stored (primary) and rebuilt (secondary) signals are told apart once per file with
// fsdbdebug -top_n_var 0 (it lists only stored vars, by idcode), cached next to the index;
// without the tool every signal is loaded as before.
const DEBUG = path.join(here, 'fsdbdebug-stub.cjs');
const kindsOf = async (h) => { for (let t = 0; t < 100; t++) { const k = (await h.send('stats').reply).result.kinds; if (k && k.state !== 'pending') { return k; } await wait(20); } return null; };
{
  const log = path.join(tmp, 'debug.log');
  const env = { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[1,2,3]', STUB_DEBUG_LOG: log };
  const h = await start(2, {}, env);
  const k = await kindsOf(h);
  check(k && k.state === 'ready' && k.primaries === 3 && k.source === 'fsdbdebug', `the stored signals are listed by fsdbdebug: ${JSON.stringify(k)}`);
  h.close();
  const h2 = await start(2, {}, env);
  const k2 = await kindsOf(h2);
  const runs = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').length : 0;
  check(k2 && k2.primaries === 3 && k2.source === 'cache' && runs === 1, `... and read from the index dir on the next open (fsdbdebug ran ${runs}x): ${JSON.stringify(k2)}`);
  h2.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
  const h3 = await start(2, { 1: 50 }, { FSDB_FSDBDEBUG: path.join(tmp, 'no-such-tool') });
  const k3 = await kindsOf(h3);
  const r3 = await h3.send('window', win([1])).reply;
  check(k3 && k3.state === 'none' && !r3.error, `without the tool, no kinds and loads as before: ${JSON.stringify(k3)} ${r3.error || 'ok'}`);
  h3.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 21. Primaries cost a reader floor per load call (its navigation data, ~110 ms on 1.7 GB,
// ~650 ms on 10 GB, whatever the range): cheap ones are loaded several in one call, and none
// is cut in pieces shorter than a few floors. Eight 100 ms primaries with a 300 ms floor,
// one request each, four workers: each in its own pieces paid the floor per piece.
{
  const ids = [1, 2, 3, 4, 5, 6, 7, 8];
  const h = await start(4, Object.fromEntries(ids.map((id) => [id, 100])), { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: JSON.stringify(ids), STUB_FLOOR_MS: '300' });
  await kindsOf(h);
  const rs = await Promise.all(ids.map((id) => h.send('window', win([id])).reply));
  const last = Math.max(...rs.map((r) => r.at));
  check(rs.every((r) => !r.error) && last < 900, `8 cheap primaries with a 300 ms floor: last at ${Math.round(last)} ms (two per call on four workers: ~500)`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
  // (its change count says what it costs: 20.8M changes of 1 bit ~ 3 s)
  const h2 = await start(4, { 1: 3000 }, { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[1]', STUB_FLOOR_MS: '300', STUB_COUNTS: '{"1": 20800000}' });
  await kindsOf(h2);
  const r = await h2.send('window', win([1])).reply;
  const sp = r.result && r.result.signals[0].split;
  check(!r.error && sp <= 6 && r.at < 1500, `a 3 s primary with a 300 ms floor: ${sp} pieces, ${Math.round(r.at)} ms (pieces of >= 4 floors: ~4, ~1.1 s)`);
  h2.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 22. A secondary costs its worker a setup the first time (~190 ms: the reader builds the
// signal's network), so with other loads waiting a secondary's pieces stay on few workers
// (setup <= 1/4 of its work); on an idle pool a lone one still spreads.
{
  const ids = [1, 2, 3, 4, 5, 6, 7, 8];
  const h = await start(4, Object.fromEntries(ids.map((id) => [id, 600])), { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[16]', STUB_FIRST_MS: '200' });
  await kindsOf(h);
  const rs = await Promise.all(ids.map((id) => h.send('window', win([id])).reply));
  const last = Math.max(...rs.map((r) => r.at));
  check(rs.every((r) => !r.error) && last < 2200, `8 secondaries of 600 ms with a 200 ms setup per worker: last at ${Math.round(last)} ms (each on one worker: ~1600; on all four: ~2800)`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
  const h2 = await start(4, { 1: 1200 }, { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[16]', STUB_FIRST_MS: '200' });
  await kindsOf(h2);
  const r2 = await h2.send('window', win([1])).reply;
  check(!r2.error && r2.at < 1000, `... a lone 1.2 s secondary on an idle pool still spreads: ${Math.round(r2.at)} ms (one worker: ~1400)`);
  h2.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 23. A ranged cold read (the visible window, nothing stored) of several primaries pays the
// reader floor once per call, so the primaries of one request go to one worker in one call and
// the secondaries (whose cost scales with the window) are spread over the other free workers.
// 8 primaries (300 ms floor) + 3 secondaries of 400 ms over the window, four workers: spread
// round-robin, three workers each paid a floor and a secondary (~700 ms).
{
  const ps = [1, 2, 3, 4, 5, 6, 7, 8], ss = [9, 10, 11];
  const h = await start(4, { ...Object.fromEntries(ps.map((id) => [id, 100])), 9: 4000, 10: 4000, 11: 4000 },
    { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: JSON.stringify(ps), STUB_FLOOR_MS: '300' });
  await kindsOf(h);
  const near = { signals: [...ps, ...ss].map((signalId) => ({ signalId, width: 1 })), t0: 0, t1: 100000, buckets: 1024 };  // 10% of the dump
  const r = await h.send('window', near).reply;
  const sg = (r.result && r.result.signals) || [];
  check(!r.error && sg.length === 11 && sg.every((s) => s.ranged) && r.at < 550,
    `a ranged read of 8 primaries + 3 secondaries: ${Math.round(r.at)} ms, ${sg.filter((s) => s.ranged).length} ranged (primaries in one call: ~400; spread: ~700)`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 24. trace-X's point read: valueAt {prev: true} also gives each signal's last real change at or
// before t ({t, value} | null). Stored signals answer from the store; the others from view
// windows [t - span, t] that grow x8 until the change is found or the window reaches 0, with
// the primaries of a round in one call (one floor) and the secondaries (cost ~ span) apart.
{
  const log = path.join(tmp, 'near.log');
  fs.rmSync(log, { force: true });
  const h = await start(4, { 1: 100, 2: 400, 3: 400, 4: 50, 5: 100 }, { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[1,4,5]', STUB_FLOOR_MS: '100',
    STUB_CHANGE_AT: JSON.stringify({ 1: 900000, 2: 10, 4: 500000, 5: 940000 }), STUB_NEAR_LOG: log });
  await kindsOf(h);
  await h.send('window', win([4])).reply;
  for (let k = 0; k < 50 && (await loaded(h)) < 1; k++) { await wait(20); }
  const r = await h.send('valueAt', { signalIds: [1, 2, 3, 4, 5], t: 950000, prev: true }).reply;
  const prev = r.result && r.result.prev, vals = r.result && r.result.values;
  const want = [{ t: 900000, value: '1' }, { t: 10, value: '1' }, null, { t: 500000, value: '1' }, { t: 940000, value: '1' }];
  check(!r.error && JSON.stringify(prev) === JSON.stringify(want), `valueAt prev: ${r.error || JSON.stringify(prev)}`);
  check(vals && vals[0] === '1' && vals[1] === '1' && vals[2] === 'x', `... and the cold values from the same reads: ${JSON.stringify(vals)}`);
  const calls = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
  const prim = (id) => id === 1 || id === 5;
  check(calls.length > 0 && calls.every((c) => c.ids.every(prim) || !c.ids.some(prim)) && calls.some((c) => c.ids.includes(1) && c.ids.includes(5))
    && !calls.some((c) => c.ids.includes(4)), `... primaries together, apart from secondaries, stored ones not read: ${JSON.stringify(calls)}`);
  const s2 = calls.filter((c) => c.ids.includes(2)).map((c) => c.span);
  check(s2.length >= 2 && s2.every((x, k) => !k || x === s2[k - 1] * 8), `... a change far back is found by growing windows: spans ${JSON.stringify(s2)}`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 25. Aliases (a port rebuilt on every load that equals a stored net): the app names candidate
// pairs (aliasHints). A pair whose sampled windows match is used at once: the rebuilt signal is
// answered from the stored one (alias: its id). The whole streams are then compared in the
// background: equal -> verified (kept for the next open), different -> dropped, and the next
// reply with rows says so (aliasDropped) so the page asks again. Sampled windows that differ:
// never used.
{
  const env = { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[1]', STUB_DIFFER: '[4]', STUB_DIFFER_FULL: '[3]' };
  const costs = { 1: 50, 2: 3000, 3: 3000, 4: 3000 };
  const al = async (h) => (await h.send('stats').reply).result.aliases;
  const has = (list, id) => !!list && list.some(([x]) => x === id);
  const h = await start(4, costs, env);
  await kindsOf(h);
  const a = await h.send('aliasHints', { pairs: [[2, 1], [3, 1], [4, 1], [1, 2], [5, 5]] }).reply;
  check(!a.error && a.result.accepted === 3 && a.result.refused.length === 2, `aliasHints takes rebuilt -> stored pairs only: ${a.error || JSON.stringify(a.result)}`);
  let st = null;
  for (let k = 0; k < 100; k++) { st = await al(h); if (st && has(st.bad, 4) && [2, 3].every((id) => has(st.on, id) || has(st.verified, id))) { break; } await wait(30); }
  check(st && has(st.bad, 4) && [2, 3].every((id) => has(st.on, id) || has(st.verified, id)), `... sampled windows decide: ${JSON.stringify(st)}`);
  const r = await h.send('window', win([2])).reply;
  const s0 = r.result && r.result.signals[0];
  check(!r.error && s0 && s0.signalId === 2 && s0.alias === 1 && r.at < 1000, `a rebuilt signal with a matching alias is answered from the stored one: ${r.error || JSON.stringify(s0)} in ${Math.round(r.at)} ms (its own load: ~3 s)`);
  const r4 = await h.send('window', win([4])).reply;
  check(!r4.error && !r4.result.signals[0].alias, `... one whose windows differ is not: ${r4.error || JSON.stringify(r4.result.signals[0])}`);
  for (let k = 0; k < 300; k++) { st = await al(h); if (!st || (has(st.verified, 2) && has(st.bad, 3))) { break; } await wait(50); }
  check(st && has(st.verified, 2) && has(st.bad, 3), `... the whole streams verify one and drop the other: ${JSON.stringify(st)}`);
  const r3 = await h.send('window', win([3])).reply;
  check(!r3.error && r3.result && JSON.stringify(r3.result.aliasDropped) === '[3]' && !r3.result.signals[0].alias, `... the next reply with rows reports the drop: ${r3.error || JSON.stringify(r3.result)}`);
  h.close();
  const h2 = await start(4, costs, env);
  await kindsOf(h2);
  await h2.send('aliasHints', { pairs: [[2, 1]] }).reply;
  const st2 = await al(h2);
  check(st2 && has(st2.verified, 2), `... a verified pair is used at once on the next open: ${JSON.stringify(st2)}`);
  h2.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 26. aliasHints from the app's model: pairs may name paths; pairs sent before the stored
// signals are known wait for them (not refused); `free` of a rebuilt signal drops its alias
// (a later hint checks it again).
{
  const al = async (h) => (await h.send('stats').reply).result.aliases;
  const has = (list, id) => !!list && list.some(([x]) => x === id);
  const h = await start(4, { 1: 50, 2: 3000, 3: 3000 }, { FSDB_FSDBDEBUG: DEBUG, STUB_PRIMARY: '[1]', STUB_DEBUG_MS: '600' });
  const a = await h.send('aliasHints', { pairs: [['tb.s2', 'tb.s1'], [3, 1]] }).reply;
  check(!a.error && a.result.refused.length === 0 && a.result.pending === 2, `pairs sent before the stored signals are known wait: ${a.error || JSON.stringify(a.result)}`);
  let st = null;
  for (let k = 0; k < 100; k++) { st = await al(h); if (st && has(st.on, 2) && has(st.on, 3)) { break; } await wait(30); }
  check(st && has(st.on, 2) && has(st.on, 3), `... and are checked once they are, paths resolved: ${JSON.stringify(st)}`);
  await h.send('free', { signalIds: [2] }).reply;
  st = await al(h);
  const r = await h.send('window', win([2])).reply;
  check(st && !has(st.on, 2) && !has(st.verified, 2) && has(st.on, 3) && !r.error && !r.result.signals[0].alias,
    `free of a rebuilt signal drops its alias: ${JSON.stringify(st)} ${r.error || JSON.stringify(r.result.signals[0])}`);
  const b = await h.send('aliasHints', { pairs: [[2, 1]] }).reply;
  check(!b.error && b.result.accepted === 1, `... and a later hint is taken again: ${b.error || JSON.stringify(b.result)}`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
}

// 27. Warm workers (the reader's navDB-once mode: navigation kept, but every signal must be in
// the process's first load): the rows being viewed get a warm worker in the background, and
// ranged reads of them then cost a short warm cycle instead of a cold read each. A row outside
// the set is read cold at once and never sent to the warm worker.
{
  const log = path.join(tmp, 'warm.log');
  fs.rmSync(log, { force: true });
  const ids = [1, 2, 3, 4, 5, 6, 7, 8];
  const h = await start(4, Object.fromEntries([...ids, 9].map((id) => [id, 20000])),
    { STUB_COLD_MS: '150', STUB_WARM_LOAD_MS: '600', STUB_WARM_MS: '15', STUB_WARM_LOG: log, FSDB_WARM: '1' });
  const near = (list, t0) => ({ signals: list.map((signalId) => ({ signalId, width: 1 })), t0, t1: t0 + 10000, buckets: 1024 });  // 1% of the dump
  await Promise.all(ids.map((id) => h.send('window', near([id], 0)).reply));  // the rows' first draws, one request each
  let st = null;
  for (let k = 0; k < 100; k++) { st = (await h.send('stats').reply).result.warm; if (st && st.ready && ids.every((id) => st.ready.includes(id))) { break; } await wait(50); }
  check(st && st.ready && ids.every((id) => st.ready.includes(id)), `the rows being viewed get a warm worker: ${JSON.stringify(st)}`);
  const lat = [];
  for (let k = 1; k <= 8; k++) { const r = await h.send('window', near(ids, k * 10000)).reply; lat.push(r.error ? 1e9 : r.at); }
  lat.sort((a, b) => a - b);
  check(lat[4] < 80, `pans over 8 warm rows: p50 ${Math.round(lat[4])} ms (cold reads: 8 x 150 ms over the free workers, ~300+)`);
  const r9 = await h.send('window', near([...ids, 9], 90000)).reply;
  const calls = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
  check(!r9.error && r9.result.signals.length === 9 && r9.result.signals.every((x) => !x.error) && !calls.some((c) => c.op === 'window' && c.ids.includes(9)),
    `... a row outside the set is read cold, not sent to the warm worker: ${r9.error || JSON.stringify(r9.result.signals.map((x) => x.error || 'ok'))}`);
  check(calls.length > 0 && calls.every((c) => c.op !== 'window' || calls.some((l) => l.op === 'load' && l.pid === c.pid && c.ids.every((id) => l.ids.includes(id)))),
    `... and a warm worker only ever reads signals of its first load: ${calls.length} warm calls`);
  h.close();
  fs.rmSync(path.join(tmp, 'idx'), { recursive: true, force: true });
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
