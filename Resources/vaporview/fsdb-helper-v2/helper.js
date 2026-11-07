// Part of cmux's FSDB helper v2. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), which it is adapted from; see ../LICENSE.
// FSDB helper v2: runs next to the dump (on the remote host) and answers the viewer over a
// single ssh stdio channel. Requests are newline-delimited JSON on stdin;
// replies go to fd 3 as a JSON line plus `binLength` raw bytes (v1 framing),
// because Verdi's FsdbReader prints to stdout. Start it through helper-v2.sh.
//
// v2: a pool of worker processes (worker.js), each with the file open. A
// signal sticks to one worker, which keeps its walked changes in the addon's
// compact store; multi-signal requests are split across workers and merged.
// Replies can come back out of order; every request carries an `id`.
// open/children are answered here (this process has the hierarchy), so the
// netlist stays responsive while workers walk signals.
//
// Protocol (WINDOWING.md "Protocol v2", as built). Times are integers in the
// file's unit. Every reply is {id, result, ms, workerMs?} or {id, error};
// `ms` is time in the helper, `workerMs` the slowest worker part.
// Changes are normalized (WINDOWING.md "Change normalization") in everything below
// except v1 `signals`: changes at one time collapse to the last, a change to the value
// already in effect is dropped, and before the first change the value is all x.
//   open {file, workers? (<= 8; default: the --workers count, auto = sized from the host), warm?, reload?}
//     -> {metadata, top, workers, index, reused?} (warm: start
//     the search-index warm-up, see warm below; index = its state). Reopening the open file
//     unchanged (same real path, device, inode, size, mtime, ctime; same pool) keeps all
//     stores, derived signals and queued work and replies {reused: true}; reload: true forces
//     a real reopen (a new epoch, as below).
//   children {scopeOffsetIdx, scopePath} -> {scopes, vars}
//   window {signals: [{signalId, width}], t0, t1, buckets, deflateCounts?}
//     -> {signals: [{signalId, exact, count, bytes, bucketBytes, cached, walkMs, split?, ranged?, file?, total?} | {signalId, error}]}
//     (total: the signal's whole normalized change count, when it came from the store;
//     absent for ranged answers. Same number as `count`'s.)
//     (ranged: a cold signal over a range <= FSDB_COLD_RANGE (0.25) of the file was answered
//     from a view-window load of just that range, and its whole walk then runs in the
//     background; file: read from the persistent store cache. The bytes are the same.)
//     + binary: per signal `bytes` of deflate-raw records [u64 LE delta][width chars]
//     (first record = value in effect at t0, time t0; deltas start from 0), then,
//     when not exact, `bucketBytes` of u32 LE change counts per bucket (deflate-raw
//     too if deflateCounts). Half-open [t0, t1): a change at t is in bucket
//     floor((t - t0) * buckets / (t1 - t0)); changes exactly at t0 are counted (in
//     count and bucket 0) but folded into the t0 record, not sent. exact when
//     count <= 2 * buckets; otherwise per bucket its first and last sent change.
//   aliasHints {pairs: [[rebuilt, stored], ...]} -> {accepted, refused: [{pair, why}], pending}: candidate
//     aliases from the app's design model (single-net port bindings), as signal ids or full
//     paths. Pairs sent while the stored signals are still being listed wait (pending; refusals
//     then go to stats.aliases.log). free of the rebuilt signal drops its alias. A pair whose 16 short
//     windows match has its whole streams compared in the background; only once they are equal
//     (verified) are window, valueAt, count, edge and search of the rebuilt id answered from the
//     stored one (window and count entries say alias: storedId). Until then the rebuilt id answers
//     its own data. A verified pair dropped later makes the next window/valueAt/count reply carry
//     aliasDropped: [rebuiltIds] (ask for those rows again). Verified pairs are kept per file.
//   valueAt {signalIds, t}         -> {values: [string | null], cold} (all 'x' before the first
//     change; null = unreadable). Signals that aren't stored are read cold: a [t, t] view
//     window, one value, ~2-16 ms each, nothing walked or kept (`cold` = how many).
//     prev: true (trace-X) adds prev: [{t, value} | null], each signal's last real change at or
//     before t (null: none yet). Cold ones are read from windows [t - span, t] growing x8 until
//     the change is in one; stored (primary) signals go in one call per round, rebuilt ones apart.
//   count {signalIds, exact?}     -> {counts: [{signalId, count, bits, xz, bytes, source} | {signalId, unknown: true}]}
//     whole-signal normalized change count (= a [0, T+1) window's count), bytes = count * (8 + bits)
//     (v1 packed size). source store | derived | file (.vvz header). Answered in the coordinator,
//     never queued; unknown unless exact: true, which loads (walks) them first.
//   edge {signalId, t, dir: 1|-1, kind: any|rise|fall} -> {t} | {t: null}
//     first change after t (or last before t); rise/fall (1-bit signals) = new
//     value '1' / '0' (x->1 is a rise); wider signals treat them as any.
//   search {signalId, t, dir, value, wildcard?} -> {t} | {t: null}: first change after t (or
//     last before t) whose new value matches `value` (MSB first, 'x' and '?' wildcards,
//     short patterns left-padded with 0). wildcard: '?' -> only '?' is a wildcard,
//     x and z are literal. All answers use the normalized change stream (see below).
//   searchText {signalId, t, dir, inclusive?, format, pattern, caseSensitive?, alias?, budgetMs = 5000}
//     -> {t, value, text, distinct, formatted} | {t: null}
//        | {t: null, incomplete: {timedOut | cancelled, at, resume: {t: at, inclusive: true}}}
//        | {t: null, incomplete: {tooLarge, reason}}:
//     as search (inclusive: >= t / <= t), but the value is formatted the way the viewer formats
//     it (format riscv*, alias, ascii; text.js) and the pattern is matched against the text.
//     Numeric formats (hex/bin/dec/sdec) are refused: they are value searches (`search`).
//   cancel {id}                    -> the target's reply becomes {id, cancelled: true};
//     queued parts are dropped, running ones finish and are discarded (background
//     ones are told to stop). A whole load (jobs) it waited for goes on in the background. If `id` isn't running, one {id, cancelled: false} line.
//     cancel {id, target} always replies under its own id {cancelled, dropped, running}.
//     Clients must ignore lines for ids they no longer have pending.
//   stats {}                       -> {workers: [{worker, pid, loaded, bytesCached, limit, queue, background, busy, rss}],
//                                      coordinatorRss, recycled, splitting, derived, index, searching,
//                                      loads: [{signalId, waiting, pieces, running, done}], coldWalks}
//   free {signalIds?}, close {}    -> {}
//   signals {signalIds, widths, maxChanges?} -> v1 whole-signal reply (reader traversal, not the
//     store). maxChanges (count first): a signal with more changes is {signalId, width, count,
//     overCap: true, bytes: 0} with no records (countKind 'normalized' when answered from the store).
// Unsolicited {id: 0, ready|error} lines report startup and worker deaths. A dead
// worker is restarted (and reopens the file); its queued and running parts fail
// with an error, so no request waits forever. Requests other than open/stats/
// cancel/close before a successful open fail with `no file open`; ids that the
// file doesn't have fail with `unknown signal #id`. A reopen fails everything
// still queued for the old file (`file reopened`).
//
// Additions (derived signals, searchAll):
//   derive {expr, name?} -> {signalId, width, signed, name, operands, refs, count, materialized,
//     materializeMs, loadMs, mergeMs, steps}. A virtual signal (id >= 1e9) usable in
//     window/valueAt/edge/search/derive like a real one. Expression language and its
//     SystemVerilog sizing (IEEE 1800 sec. 11.6: context-determined widths, $signed/$unsigned,
//     === !==, * / % << >> <<< >>>) in expr.js; paths (generate scopes like gen[0].x too),
//     unique suffixes, #id, or a derive `name` (which may not hide a real signal). Results change
//     only when the value changes, evaluated once per distinct operand change time (after
//     all changes at that time; glitches inside one time step collapse). The same compiled
//     program over the same signals -> the same id. Evicted results are rebuilt on demand
//     (real signals are evicted before derived ones). Limits: 65536 bits per node, 64 KB of
//     text, a result of at most half the worker's store budget, 60 s of merge, and an
//     up-front cost estimate. Errors: unknown/ambiguous signal, syntax, width, size, time.
//   searchAll {value | expr, t, dir, scope?, names?, limit = 50, budgetMs = 30000 (max 60000), listCandidates?}
//     candidates: BitVector signals under `scope` (a path prefix), leaf name (or full path
//     if the glob has a '.') matching `names` (* ?), one per signal id. value: binary with
//     x wildcards (a string of only 0/1/x/z/? is binary: "10" = 2'b10) or a literal
//     (32'h12xx, 'd5, 12); only signals of exactly that width; `wildcard: '?'` as for
//     search (x/z literal). Ties in time are ordered by signalId. expr: true (any bit 1) with
//     `$` = the candidate (any width); without `$` it is one temporary derived signal.
//     Per candidate the nearest matching change after t (dir 1) / before t (dir -1).
//     Streams {id, partial: true, result: {matches: [{signalId, path, t}], searched, total}}
//     as matches are found, then {id, final: true, result: {matches (nearest first, <= limit),
//     found, searched, walked, indexed, errors, unreadable, retried, total, timedOut, yields,
//     firstMatchMs, complete, incomplete: null | {timedOut, cancelled, unsearched, errors,
//     failedSignals}}}. A relay must keep the request pending until the line without
//     `partial`. Once `limit` matches are known, later scans stop at the limit-th nearest
//     time, so `found` counts only matches that could still rank. One searchAll runs at a
//     time: a new one ends the old with {id, cancelled: true, reason: 'superseded'}. Its
//     work is background work: interactive requests go first and make a running chunk stop
//     early (the rest is requeued); the budget is enforced inside chunks too.
//   warm {on?, clear?} -> index state {on, dir, indexed, bytes, rawBytes, todo, inflight, failed, yields,
//     stopped, ms}: the opt-in background search index (see "search index warm-up" below).
//
// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0),
// src/extension_core/fsdb_worker.ts@59107c6: same addon calls, stdio framing
// instead of Node IPC, and the scope/var walk done here instead of in the host.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const zlib = require('node:zlib');
const { fork } = require('node:child_process');
const crypto = require('node:crypto');
const expr = require('./expr.js');
const { scopeTree } = require('./tree.js');

const OUT = 3;
const addonPath = process.env.FSDB_ADDON || path.join(__dirname, 'addon/build/Release/fsdb_reader.node');
const arg = (name, env, dflt) => { const k = process.argv.indexOf(name); return Number(k > 0 ? process.argv[k + 1] : process.env[env] || dflt) || dflt; };
// Workers: `--workers auto` (what cmux asks for) sizes the pool from the host. Whole loads run
// in pieces over every worker (jobs below), so more workers mean faster first draws, but each
// costs memory (its store share plus ~300 MB of reader and V8) and the host is shared: half the
// cores, at most MAX_WORKERS, and only as many as fit in the available memory minus 4 GB at
// ~600 MB each (FSDB_HOST_CPUS / FSDB_HOST_AVAIL_MB stand in for the host in tests).
const MAX_WORKERS = 8;
function autoWorkers() {
  const os = require('node:os');
  const cpus = Number(process.env.FSDB_HOST_CPUS) || (os.availableParallelism ? os.availableParallelism() : os.cpus().length);
  let availMB = Number(process.env.FSDB_HOST_AVAIL_MB);
  if (!availMB) {
    try { availMB = Number(/MemAvailable:\s+(\d+) kB/.exec(fs.readFileSync('/proc/meminfo', 'utf8'))[1]) / 1024; } catch (e) { availMB = os.freemem() / 1048576; }
  }
  return Math.max(1, Math.min(MAX_WORKERS, Math.floor(cpus / 2), Math.floor((availMB - 4096) / 600)));
}
const workersArg = (() => { const k = process.argv.indexOf('--workers'); return k > 0 ? process.argv[k + 1] : process.env.FSDB_WORKERS; })();
const DEFAULT_WORKERS = workersArg === 'auto' ? autoWorkers() : Math.max(1, Math.min(MAX_WORKERS, Number(workersArg) || 4));
// LRU budget, split evenly across workers; without an explicit size, no worker's share (which is
// also the largest signal it can store) drops below 256 MB as the pool grows.
const CACHE_SET = process.argv.includes('--cache-mb') || !!process.env.FSDB_CACHE_MB;
const CACHE_BYTES = arg('--cache-mb', 'FSDB_CACHE_MB', 1024) * 1e6;
const storeShare = (n) => (CACHE_SET ? CACHE_BYTES / n : Math.max(CACHE_BYTES / n, 256e6));
// Store files handed between workers (split walks, derived operands) live in a
// private 0700 directory (mkdtemp); the addon creates them O_EXCL 0600, checks
// owner and size on read, and deletes them. Directories left by dead helpers
// (their pid file names a gone process) are swept at startup.
const SHM_ROOT = fs.existsSync('/dev/shm') ? '/dev/shm' : '/tmp';
const SHM = makeTmpDir();
let tmpSeq = 0;
const tmpPath = (tag) => path.join(SHM, `${tag}-${++tmpSeq}`);
function makeTmpDir() {
  const uid = process.getuid();
  for (const name of fs.readdirSync(SHM_ROOT)) {
    if (!name.startsWith('fsdb-helper-v2-')) { continue; }
    const dir = path.join(SHM_ROOT, name);
    try {
      const st = fs.lstatSync(dir);
      if (!st.isDirectory() || st.uid !== uid) { continue; }
      const pid = Number(fs.readFileSync(path.join(dir, 'pid'), 'utf8'));
      try { process.kill(pid, 0); continue; } catch (e) { if (e.code !== 'ESRCH') { continue; } }
      fs.rmSync(dir, { recursive: true, force: true });
    } catch (e) { /* not ours or racing another sweep */ }
  }
  const dir = fs.mkdtempSync(path.join(SHM_ROOT, 'fsdb-helper-v2-'));  // mode 0700
  fs.writeFileSync(path.join(dir, 'pid'), String(process.pid), { mode: 0o600, flag: 'wx' });
  return dir;
}
function removeTmpDir() { try { fs.rmSync(SHM, { recursive: true, force: true }); } catch (e) { /* exiting */ } }
const DERIVED_BASE = 1e9;  // derived signal ids start here (FSDB ids are small)
const SEARCH_CHUNK = 16;   // signals per searchAll task (one batched reader load)
const COLD_CHUNK = 4;      // cold-scan pool chunk (small, so the pool balances across workers)
const MAX_BUCKETS = 1 << 22; // per signal in a window request (16 MB of counts)
const MAX_LINE = 1 << 20;    // request line bytes

function send(obj, bin) {
  if (bin) { obj.binLength = bin.length; }
  writeAll(Buffer.from(JSON.stringify(obj) + '\n'));
  if (bin) { writeAll(bin); }
}
const pause = new Int32Array(new SharedArrayBuffer(4));
function writeAll(buf) {
  let off = 0;
  while (off < buf.length) {
    try {
      off += fs.writeSync(OUT, buf, off, buf.length - off);
    } catch (e) {
      if (e.code === 'EPIPE') { shutdown(0); }   // the ssh channel is gone
      if (e.code !== 'EAGAIN') { throw e; }
      Atomics.wait(pause, 0, 0, 1);  // pipe full: wait 1 ms instead of spinning
    }
  }
}
function shutdown(code) {
  try { flushManifest(); } catch (e) { /* best effort (L8) */ }
  for (const w of workers) { w.proc.kill(); }
  removeTmpDir();
  process.exit(code);
}

let addon;
try { addon = require(addonPath); } catch (e) {
  send({ id: 0, error: 'failed to load FSDB reader: ' + e.message });
  process.exit(1);
}
// One netlist node per scope path (tree.js): port trees that re-enter a path are merged.
const scopes = scopeTree(addon);

// ---- worker pool ----
// Each worker has a FIFO queue and at most one task in flight, so `cancel`
// can drop queued work. Tasks touching only cached signals jump the queue.
// Background tasks (searchAll chunks, index warm-up; `bg: true`) wait in a
// separate queue and run only when the worker has no interactive work; one
// that is running when interactive work arrives gets SIGUSR2 and returns
// early (unfinished signals come back as `yielded` and are requeued).
let workers = [];
let nextTid = 1;
const route = new Map();  // signalId -> worker index (sticky, round-robin on first sight)
let rr = 0;
// Bumped by every open: replies to tasks from an older epoch are failed and
// their store state ignored, so a reopen never serves the previous file.
let epoch = 0;
const restarts = [];  // times of recent worker restarts (crash-loop guard)

function failTasks(tasks, error) {
  for (const t of tasks) { if (t && t.done) { t.done({ tid: t.tid, error, ms: 0 }); } }
}

function startWorker(i) {
  const proc = fork(path.join(__dirname, 'worker.js'), [], { stdio: ['ignore', 2, 2, 'ipc'], serialization: 'advanced' });
  const w = { i, proc, queue: [], bgQueue: [], busy: null, state: { bytes: 0, cached: [], rss: 0 }, ready: false };
  proc.on('message', (m) => onWorkerMessage(w, m));
  // A send to a worker that just died raises 'error' (EPIPE / channel closed);
  // its 'exit' handler fails and replaces whatever it held.
  proc.on('error', (e) => { if (DEBUG) { process.stderr.write(`[helper] worker ${i}: ${e.message}\n`); } });
  proc.on('exit', (code, signal) => {
    if (workers[i] !== w) { return; }  // replaced or pool resized
    const lost = [w.busy, ...w.queue, ...w.bgQueue];
    w.busy = null; w.queue = []; w.bgQueue = [];
    const now = performance.now();
    restarts.push(now);
    while (restarts[0] < now - 30000) { restarts.shift(); }
    if (restarts.length > 5) {
      send({ id: 0, error: `worker ${i} exited (${code ?? signal}); too many restarts, giving up` });
      failTasks(lost, `worker ${i} exited`);
      shutdown(1);
    }
    send({ id: 0, error: `worker ${i} exited (${code ?? signal}), restarted` });
    const nw = startWorker(i);
    workers[i] = nw;
    if (openFile) { enqueue(nw, { op: 'open', file: openFile, cacheBytes: storeShare(workers.length), barrier: true }).done = () => {}; }
    failTasks(lost, `worker ${i} exited (${code ?? signal})`);
  });
  return w;
}

function spawnPool(n) {
  const old = workers;
  workers = [];
  for (const w of old) { const lost = [w.busy, ...w.queue, ...w.bgQueue]; w.busy = null; w.queue = []; w.bgQueue = []; w.proc.kill(); failTasks(lost, 'worker pool resized'); }
  clearFloats('worker pool resized');
  route.clear(); rr = 0;
  for (let i = 0; i < n; i++) { workers.push(startWorker(i)); }
}

function workerFor(signalId) {
  if (floating.has(signalId)) { pinFloat(floating.get(signalId)); }
  let i = route.get(signalId);
  if (i === undefined || i >= workers.length) { i = rr++ % workers.length; route.set(signalId, i); }
  return workers[i];
}

// ---- first loads go to the first free worker ----
// A signal's worker is fixed the first time it is asked for. Round-robin at that moment
// balanced counts, not work: one reader load costs 1 ms to 10 s on a big dump (clk 6.8 s,
// a 4-bit valid 10 s, most 0.2-0.6 s), so with 20 signals added at once one worker drew
// for 26 s while others idled after 3 s. A whole-dump window of a signal no worker has
// seen yet waits in one shared queue instead, and the first worker with nothing queued
// takes it (and becomes its owner). Anything else that needs the signal's worker first
// (workerFor) places it at once, on the least busy worker. A cancelled request's first
// loads that haven't started become background walks (scheduleBgLoad: they yield to
// interactive work), so asking again (the viewer's retry after its window timeout)
// often finds the signal stored; one already walking finishes and is kept.
const floatQueue = [];          // tasks, oldest first
const floating = new Map();     // signalId -> its queued task
const FLOAT = { i: -1, queue: floatQueue, bgQueue: [], busy: null, state: { cached: [] } };  // dequeue()'s view
const FLOAT_FIRST = process.env.FSDB_FLOAT !== '0';
const idleWorker = (w) => w.ready && !w.busy && !w.queue.length && !w.recycle && workers[w.i] === w;
function bindFloat(task, w) {
  for (const id of task.floatIds) { if (floating.get(id) === task) { floating.delete(id); } route.set(id, w.i); }
  if (task.part) { task.part.w = w; }
}
function pinFloat(task) {
  const k = floatQueue.indexOf(task);
  if (k >= 0) { floatQueue.splice(k, 1); }
  const w = leastBusy();
  bindFloat(task, w);
  if (task.req && task.req.cancelled) { failTasks([task], 'cancelled'); return; }
  enqueue(w, task);
}
function pullFloat(w) {
  if (!floatQueue.length || !idleWorker(w)) { return; }
  const task = floatQueue.shift();
  bindFloat(task, w);
  w.queue.push(task);
}
function addFloat(task, ids) {
  task.tid = nextTid++;
  task.epoch = epoch;
  task.floatIds = ids;
  for (const id of ids) { floating.set(id, task); }
  floatQueue.push(task);
  let idle = false;
  for (const w of workers) { if (idleWorker(w)) { idle = true; pump(w); } }
  if (!idle) {  // make room as enqueue does: a background task stops early
    for (const w of workers) {
      if (w.busy && w.busy.bg && !w.busy.yieldSent && w.pid && !w.queue.length) {
        w.busy.yieldSent = true;
        try { process.kill(w.pid, 'SIGUSR2'); } catch (e) { /* exiting */ }
      }
    }
  }
  return task;
}
function clearFloats(error) {
  const lost = floatQueue.splice(0);
  floating.clear();
  failTasks(lost, error);
}

// `barrier` tasks (open) stay ahead of everything queued after them, including
// fast and `front` tasks.
function enqueue(w, task, front = false) {
  task.tid = nextTid++;
  task.epoch = epoch;
  // A part of a cancelled request (the cancel landed while its handler was between awaits, before
  // it scattered): never queued, and failed so its promise settles. The handler's error is not sent.
  if (task.req && task.req.cancelled) { setImmediate(() => failTasks([task], 'cancelled')); return task; }
  // Callers may hold a worker that has since died or been recycled: its
  // replacement (same index) takes the task; with no replacement it fails.
  if (workers[w.i] !== w) {
    if (!workers[w.i]) { setImmediate(() => failTasks([task], 'worker pool resized')); return task; }
    w = workers[w.i];
  }
  const ids = task.signalIds || (task.signalId !== undefined ? [task.signalId] : null);
  const cached = ids && ids.length && ids.every((id) => w.state.cached.includes(id));
  if (task.bg) {
    w.bgQueue.push(task);
    pump(w);
    return task;
  }
  if (w.busy && w.busy.bg && !w.busy.yieldSent && w.pid) {  // make room: the background task stops early
    w.busy.yieldSent = true;
    try { process.kill(w.pid, 'SIGUSR2'); } catch (e) { /* exiting */ }
  }
  if (front) {
    let k = 0;
    while (k < w.queue.length && w.queue[k].barrier) { k++; }
    w.queue.splice(k, 0, task);
  } else if (cached) {
    let k = 0;
    while (k < w.queue.length && (w.queue[k].fast || w.queue[k].barrier)) { k++; }
    task.fast = true;
    w.queue.splice(k, 0, task);
  } else {
    w.queue.push(task);
  }
  pump(w);
  return task;
}

const DEBUG = process.argv.includes('--debug');
// A worker over its memory cap (state.recycle) is replaced by a fresh process
// once idle; its queued work moves over, behind a reopen. Its store goes with
// it (signals are re-walked on demand; derived results rebuilt).
// The replacement reloads what the old worker held from store-cache files
// (one background bgLoad, which yields to interactive work), so a recycle
// doesn't turn a debugger's warm signals cold. Only signals with a file: a
// re-walk would push the new worker straight back over its RSS cap.
// A replacement recycled before it served any request (its reload alone was
// over the cap) does not reload again: that would loop (a fork storm).
function recycleWorker(w) {
  const held = w.reloaded ? [] : w.state.cached.filter((id) => id < DERIVED_BASE && warm.epoch === epoch && warm.files.has(id));
  const nw = startWorker(w.i);
  nw.queue = w.queue; nw.bgQueue = w.bgQueue; nw.warming = w.warming;
  w.queue = []; w.bgQueue = [];
  workers[w.i] = nw;
  recycled++;
  if (openFile) { enqueue(nw, { op: 'open', file: openFile, cacheBytes: storeShare(workers.length), barrier: true }, true).done = () => {}; }
  if (openFile && held.length) { nw.reloaded = true; enqueue(nw, { op: 'bgLoad', signalIds: held, bg: true }).done = () => {}; }
  w.proc.kill();
}
let recycled = 0, rssCapRaised = null;
// Backoff (defence in depth against a storm): a slot recycled 3 times within 10 s waits 1 s,
// 2 s, 4 s ... (max 60 s) before its next recycle; it keeps serving meanwhile (the addon's hard
// bound still refuses loads over twice the cap).
const slotRecycles = new Map();  // slot -> {times: [], backoff, until}
function recycleAllowed(i) {
  const now = Date.now(), r = slotRecycles.get(i) || { times: [], backoff: 0, until: 0, last: 0 };
  slotRecycles.set(i, r);
  if (now < r.until) { return false; }
  r.times = r.times.filter((t) => now - t < 10e3);
  if (r.times.length >= 3) { r.backoff = Math.min(60e3, r.backoff ? 2 * r.backoff : 1e3); r.until = now + r.backoff; return false; }
  if (now - r.last > 60e3) { r.backoff = 0; }  // calm for a minute: start over
  r.times.push(now); r.last = now;
  return true;
}

function pump(w) {
  if (!w.busy && w.recycle && workers[w.i] === w) {
    // Write what is queued for the store cache first: it needs this store.
    const k = w.bgQueue.findIndex((t) => t.op === 'persist');
    if (k >= 0 && !w.queue.length) {
      w.bgQueue.unshift(...w.bgQueue.splice(k, 1));
    } else if (w.forceRecycle || recycleAllowed(w.i)) {
      recycleWorker(w); return;
    } else if (!w.recycleTimer) {  // backing off: keep serving, look again when the backoff ends
      w.recycleTimer = setTimeout(() => { w.recycleTimer = null; pump(w); }, Math.max(0, slotRecycles.get(w.i).until - Date.now()) + 10);
    }
  }
  if (workers[w.i] !== w) { return; }  // replaced: its queues moved over or were failed
  pullFloat(w);  // before background work: a first load is interactive
  // With nothing of its own queued: a piece of a whole load some request waits for, then the
  // worker's background work, then a piece of a background whole load.
  // Background pieces leave one worker free (of 3 or more), so a pan or a new signal never waits for one.
  if (!w.busy && w.ready && !w.queue.length && !w.recycle && !w.hold) { pullPiece(w, true) || (!w.bgQueue.length && bgRoom() && pullPiece(w, false)); }
  if (w.busy || !w.ready || !(w.queue.length || w.bgQueue.length)) { return; }
  const task = w.queue.length ? w.queue.shift() : w.bgQueue.shift();
  w.busy = task;
  if (DEBUG) { task.startedAt = performance.now(); }
  const { done, fast, req, startedAt, prepare, epoch: _e, barrier, bg, yieldSent, part: _p, floatIds: _f, ...msg } = task;
  if (prepare) { Object.assign(msg, prepare()); }  // fields computed at dispatch (searchAll bound)
  if (STORE_CACHE && CACHE_FILE_OPS.has(msg.op) && !msg.files) {  // persistent store cache files for what it may load
    const ids = msg.signalIds || (msg.signalId !== undefined ? [msg.signalId] : (msg.operands || []).map((o) => o.id));
    msg.files = indexFor(ids.concat(msg.fixed || []));
  }
  w.proc.send(msg, (e) => { if (e && DEBUG) { process.stderr.write(`[helper] send to worker ${w.i}: ${e.message}\n`); } });
}

function onWorkerMessage(w, m) {
  if (workers[w.i] !== w) { return; }
  if (m.ready) { w.ready = true; w.pid = m.pid; pump(w); return; }
  const task = w.busy;
  w.busy = null;
  const stale = task && task.epoch !== epoch;
  if (m.state && !stale) {
    w.state = m.state;
    if (m.state.sizes) { w.sizes = new Map(m.state.sizes.map((e) => [e[0], e])); }  // absent: unchanged
  }
  if (m.state && m.state.recycle) { w.recycle = true; }
  if (m.state && m.state.capRaised && !rssCapRaised) {  // warn once
    rssCapRaised = m.state.capRaised;
    process.stderr.write(`helper-v2: FSDB_WORKER_RSS_MB=${rssCapRaised.configuredMB} is below what an idle worker needs; using ${rssCapRaised.usedMB} MB\n`);
  }
  if (task && !task.bg && task.op !== 'open') { w.reloaded = false; }  // it has served real work since its reload
  if (m.badFiles) {  // a stale reply still drops entries whose file is gone (L7: a reopen may have listed it first)
    let changed = false;
    for (const id of m.badFiles) {
      const f = warm.files.get(id);
      if (f && (!stale || !fs.existsSync(f.path))) { warm.bytes -= f.bytes; warm.files.delete(id); changed = true; }
    }
    if (changed) { scheduleManifest(); }
  }
  if (m.walked && !stale) { persistLater(w, m.walked); }
  if (DEBUG && task) { process.stderr.write(`[w${w.i}] ${task.op} ${JSON.stringify(task.signalIds || task.signalId)}${task.piece ? ` [${task.s}, ${task.e})` : ''} wait->done ${(performance.now() - task.startedAt).toFixed(1)} ms, worker ${m.ms.toFixed(1)} ms, queue ${w.queue.length}\n`); }
  const memErr = (e) => /worker memory limit/.test(String(e || ''));
  if (task && task.tid === m.tid && task.done && !stale && !task.bg && !task.memRetried && workers[w.i] === w
      && (memErr(m.error) || (Array.isArray(m.result) && m.result.some((r) => r && memErr(r.error))))) {
    // Refused by the hard memory bound (the worker's RSS is near twice its cap): run it once
    // more, first, on a recycled worker. A second refusal is the answer.
    task.memRetried = true;
    w.recycle = true; w.forceRecycle = true;  // tied to a refused request, not idle: no backoff
    enqueue(w, task, true);
  } else if (task && task.tid === m.tid && task.done) { task.done(stale ? { tid: m.tid, error: 'file reopened', ms: m.ms } : m); }
  pump(w);
}

const asBuf = (u8) => (u8 ? Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength) : null);

// Remove a queued task (either queue); -> true if it was still queued.
function dequeue(w, task) {
  if (w === FLOAT) {
    const k = floatQueue.indexOf(task);
    if (k < 0) { return false; }
    floatQueue.splice(k, 1);
    for (const id of task.floatIds) { if (floating.get(id) === task) { floating.delete(id); } }
    return true;
  }
  for (const x of new Set([w, workers[w.i]])) {  // queues move to the replacement when a worker is recycled
    if (!x) { continue; }
    for (const q of [x.queue, x.bgQueue]) { const k = q.indexOf(task); if (k >= 0) { q.splice(k, 1); return true; } }
  }
  return false;
}

// Split signalIds across their workers; resolves with per-id results in order.
// float: signals no worker has been chosen for yet go to the shared queue (one task each).
function scatter(req, op, signalIds, extra, pick, float = false) {
  return new Promise((resolve, reject) => {
    const groups = new Map();
    for (const id of signalIds) {
      if (float && FLOAT_FIRST && workers.length > 1 && !route.has(id) && !floating.has(id) && !derived.has(id)) {
        groups.set({ float: id }, [id]);
        continue;
      }
      const w = workerFor(id);
      if (!groups.has(w)) { groups.set(w, []); }
      groups.get(w).push(id);
    }
    const byId = new Map();
    const parts = [];
    let left = groups.size;
    if (!left) { resolve([]); return; }
    for (const [w, ids] of groups) {
      const fl = w.float !== undefined;
      const part = { w: fl ? FLOAT : w, task: null };
      if (fl && req.cancelled) { part.task = enqueue(workers[0], { op, signalIds: ids, ...extra, req }); } else {
        part.task = fl ? { op, signalIds: ids, ...extra, req, part } : enqueue(w, { op, signalIds: ids, ...extra, req });
      }
      const task = part.task;
      parts.push(part);
      task.done = (m) => {
        if (m.error) { reject(new Error(m.error)); return; }
        pick(m, ids).forEach((r, k) => byId.set(ids[k], r));
        req.workerMs = Math.max(req.workerMs || 0, m.ms);
        if (--left === 0) { resolve(signalIds.map((id) => byId.get(id))); }
      };
    }
    req.parts = [...(req.parts || []), ...parts];  // a request may scatter more than once (window: warm + cold)
    for (const [w, ids] of groups) { if (w.float !== undefined && !req.cancelled) { addFloat(parts.find((x) => x.task.signalIds === ids).task, ids); } }
  });
}

function single(req, op, signalId, extra) {
  return new Promise((resolve, reject) => {
    const w = workerFor(signalId);
    const task = enqueue(w, { op, signalId, ...extra, req });
    req.parts = [{ w, task }];
    task.done = (m) => { req.workerMs = m.ms; if (m.error) { reject(new Error(m.error)); } else { resolve(m.result); } };
  });
}

function broadcast(op, extra) {
  return Promise.all(workers.map((w) => new Promise((resolve) => {
    enqueue(w, { op, ...extra }).done = resolve;
  })));
}

// ---- split walks ----
const widthOf = new Map();  // signalId -> bits, learned from children and window requests
const splitting = new Map();  // signalId -> Promise<{ms, slices}>
let timeEnd = 0;

function runTask(w, task, front) {
  return new Promise((resolve, reject) => {
    enqueue(w, task, front).done = (m) => (m.error ? reject(new Error(m.error)) : resolve(m.result));
  });
}

// ---- stored and rebuilt signals (kinds) ----
// The reader stores some signals' changes (primaries) and rebuilds the others on load by
// re-simulating a gate network from the stored ones (secondaries: port aliases, interface
// members, combinational wires). They cost differently (status "Reader profile"):
// - a primary pays a floor per reader load call (its navigation data is read and inflated again:
//   ~110 ms on a 1.7 GB dump, ~650 ms on 10 GB, whatever the time range), then ~0.14-0.4 us per
//   change: loaded several per call, and cut in pieces only of several floors;
// - a secondary costs a worker a setup the first time (~190 ms), then is linear in its time
//   range with no floor: cut in pieces, kept on few workers while other loads wait.
// The reader API doesn't tell them apart; Verdi's `fsdbdebug -top_n_var 0 <file>` lists only the
// stored vars, by idcode, with their change counts (1.7 GB: 4 s / 0.5 GB RSS; 10 GB: 27 s /
// 2.5 GB). It runs once per file in the background (nice, an RSS watchdog) and is cached in the
// index dir; without it (no tool, too little memory, it failed) signals load as one kind.
// Never -with_computed_signal: it loads every secondary (> 6 GB on 1.7 GB).
const KINDS_FILE = 'kinds.v1.json';
const SEC_SETUP_MS = Number(process.env.FSDB_SEC_SETUP_MS || 190);
const kinds = { state: 'none', source: null, primaries: null, error: null, ms: 0, proc: null };
function kindOf(id) { return kinds.state === 'ready' ? (kinds.primaries.has(id) ? 'p' : 's') : null; }
function stopKinds() {
  if (kinds.proc) { try { kinds.proc.kill('SIGKILL'); } catch (e) { /* gone */ } }
  if (kinds.timer) { clearInterval(kinds.timer); }
  Object.assign(kinds, { state: 'none', source: null, primaries: null, error: null, ms: 0, proc: null, timer: null });
}
function startKinds(file) {
  stopKinds();
  const ep = epoch, t0 = performance.now();
  const done = (map, source) => {
    if (epoch !== ep) { return; }
    Object.assign(kinds, { state: 'ready', source, primaries: map, ms: Math.round(performance.now() - t0), proc: null });
    if (kinds.timer) { clearInterval(kinds.timer); kinds.timer = null; }
    const held = aliasPending.splice(0);
    for (const [, s, p] of held) { const why = addAlias(s, p); if (why) { aliasNote(s, p, `refused: ${why}`); } }
  };
  const fail = (error) => {
    if (epoch !== ep) { return; }
    if (kinds.timer) { clearInterval(kinds.timer); kinds.timer = null; }
    Object.assign(kinds, { state: 'none', error, proc: null });
    for (const [, s, p] of aliasPending.splice(0)) { aliasNote(s, p, 'refused: stored signals not known'); }
  };
  const dir = warm.dir;
  if (dir) {
    try {
      const j = JSON.parse(fs.readFileSync(path.join(dir, KINDS_FILE), 'utf8'));
      if (j && j.v === 1 && Array.isArray(j.p)) { done(new Map(j.p), 'cache'); return; }
    } catch (e) { /* none yet */ }
  }
  const tool = process.env.FSDB_FSDBDEBUG || (process.env.VERDI_HOME ? path.join(process.env.VERDI_HOME, 'bin', 'fsdbdebug') : '');
  if (!tool || !fs.existsSync(tool)) { fail('no fsdbdebug'); return; }
  // memory: min(4 GB, available - 4 GB), not run under 3 GB (Linux; elsewhere no watchdog)
  let availMB = Number(process.env.FSDB_HOST_AVAIL_MB) || 0;
  if (!availMB) { try { availMB = Number(/MemAvailable:\s+(\d+) kB/.exec(fs.readFileSync('/proc/meminfo', 'utf8'))[1]) / 1024; } catch (e) { availMB = 0; } }
  const capMB = availMB ? Math.min(4096, availMB - 4096) : 0;
  if (availMB && capMB < 3072) { fail(`not enough memory for fsdbdebug (${Math.round(availMB)} MB available)`); return; }
  let cwd;
  try { cwd = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'fsdb-helper-kinds-')); } catch (e) { fail('no temp dir'); return; }  // (it writes a log dir in its cwd)
  const { spawn } = require('node:child_process');
  let proc;
  try { proc = spawn('nice', ['-n', '10', tool, '-top_n_var', '0', file], { cwd, stdio: ['ignore', 'ignore', 'pipe'] }); } catch (e) { fail(String(e.message)); return; }
  kinds.state = 'pending'; kinds.proc = proc;
  const map = new Map();
  let buf = '', killed = null;
  proc.stderr.setEncoding('utf8');
  proc.stderr.on('data', (d) => {
    buf += d;
    let k;
    while ((k = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, k); buf = buf.slice(k + 1);
      const m = /^(\d+)\s+\S.*?\s(\d+)\([\d.]+%\)\s*$/.exec(line);
      if (m) { map.set(Number(m[1]), Number(m[2])); }
    }
  });
  const limitMs = Number(process.env.FSDB_FSDBDEBUG_TIMEOUT_MS || 300000);
  kinds.timer = setInterval(() => {
    if (performance.now() - t0 > limitMs) { killed = 'timed out'; } else if (capMB) {
      try { const kb = Number(/VmRSS:\s+(\d+) kB/.exec(fs.readFileSync(`/proc/${proc.pid}/status`, 'utf8'))[1]); if (kb / 1024 > capMB) { killed = `over ${capMB} MB`; } } catch (e) { /* exited */ }
    }
    if (killed) { try { proc.kill('SIGKILL'); } catch (e) { /* gone */ } }
  }, 200);
  proc.on('error', (e) => { fs.rmSync(cwd, { recursive: true, force: true }); fail(String(e.message)); });
  proc.on('close', (code) => {
    fs.rmSync(cwd, { recursive: true, force: true });
    if (killed || code !== 0 || !map.size) { fail(killed || `fsdbdebug exited ${code} with ${map.size} vars`); return; }
    done(map, 'fsdbdebug');
    if (dir && epoch === ep) {
      try {
        privateDir(dir);
        const tmp = path.join(dir, `${KINDS_FILE}.${process.pid}.tmp`);
        fs.writeFileSync(tmp, JSON.stringify({ v: 1, p: [...map] }), { mode: 0o600 });
        fs.renameSync(tmp, path.join(dir, KINDS_FILE));
      } catch (e) { /* not cached: run again next open */ }
    }
  });
}
// Cost of a primary's whole load before any piece ran: the per-call floor (learned from loads,
// first ~65 ms per GB of file) and ~0.14 us + 4 ns per bit per change (reader traversal, value
// decode and the store walk; clk of a 1.7 GB dump: 13M changes, 1.8 s).
// Both are learned from batched loads (batchDone), per file (reset on open):
// - walkScale: measured / estimated walk of a batch, after the floor (the per-change cost
//   differs by host and dump; it was ~3x the estimate on a busy 1.7 GB host);
// - the floor only from one-signal calls (a many-signal call's overrun is walk, not floor),
//   clamped to twice the per-GB estimate.
let primFloorMs = null, walkScale = 1;
const floorGuess = () => 65 * fileBytes / 1e9;
const primFloor = () => (primFloorMs !== null ? primFloorMs : floorGuess());
const primWalkMs = (id) => walkScale * ((kinds.primaries && kinds.primaries.get(id)) || 0) * (0.14 + 0.004 * (widthOf.get(id) || 1)) / 1000;
function learnFloor(ms, walkMs, n) {
  const est = walkMs / walkScale;  // (walkMs: the batch's scaled estimate)
  if (n === 1) {
    const f = Math.min(2 * floorGuess(), Math.max(0, ms - walkMs));
    primFloorMs = primFloorMs === null ? f : 0.7 * primFloorMs + 0.3 * f;
  }
  if (est > 20) {
    const k = Math.min(8, Math.max(0.5, (ms - primFloor()) / est));
    walkScale = 0.7 * walkScale + 0.3 * k;
  }
}
function resetLearned() { primFloorMs = null; walkScale = 1; }

// ---- aliases: rebuilt signals that are copies of stored ones ----
// A port bound to a single net is rebuilt by the reader on every load (u_cluster.clk: 6.8 s
// against 0.43 s for the stored clk it equals). The app names candidate pairs from its design
// model (aliasHints: port bindings only; the dump has no alias map for them). A pair is used
// once ALIAS_SAMPLES short windows (1/1024 of the dump each) of the rebuilt one equal the stored
// one's, the rebuilt one loads whole in the background and the two whole streams are compared:
// equal -> verified (kept in the index dir, used at once next time, the rebuilt copy freed), and
// requests for the rebuilt one are then answered from the stored one (alias: its id on each
// answer); different -> dropped and logged. Until the verdict the rebuilt row answers its own
// data. A verified pair that is dropped later (a stale file entry) makes the next replies carry
// aliasDropped: [ids] so the page asks for those rows again.
const ALIASES_FILE = 'aliases.v1.json';
const ALIAS_SAMPLES = 16;
const aliases = new Map();  // rebuilt id -> {p, state: 'checking' | 'on' (samples match, comparing) | 'verified' | 'bad', why?}
const aliasLog = [];        // the last few drops and refusals, for stats
let aliasDropped = [];      // ids to report on the next replies
let aliasKnown = new Map(); // verified pairs from the index dir: rebuilt id -> stored id
let aliasPending = [];      // [pair, s, p] sent while the stored signals were being listed
// A pair (ids) is taken: checked, or used at once if verified before. -> null, or why not.
function addAlias(s, p) {
  const width = (id) => widthOf.get(id) ?? (getIndex().byId.get(id) || {}).width;
  if (aliases.has(s)) { return aliases.get(s).p !== p ? 'has another candidate' : null; }
  if (!width(s) || width(s) !== width(p)) { return 'widths differ'; }
  if (derived.has(s) || derived.has(p)) { return 'derived'; }
  if (kindOf(p) !== 'p' || kindOf(s) !== 's') { return 'not a rebuilt and a stored signal'; }
  if (aliasKnown.get(s) === p) { aliases.set(s, { p, state: 'verified' }); return null; }
  aliases.set(s, { p, state: 'checking' });
  checkAlias(s, p);
  return null;
}
// Only a verified pair is used: until the whole streams are compared, the rebuilt row answers its
// own data (ranged reads are cheap), never another signal's.
const aliasFor = (id) => { const a = aliases.get(id); return a && a.state === 'verified' ? a.p : null; };
function aliasNote(s, p, why) {
  aliasLog.push({ s, p, why }); if (aliasLog.length > 16) { aliasLog.shift(); }
  if (DEBUG) { process.stderr.write(`[helper] alias ${s} -> ${p}: ${why}\n`); }
}
function loadAliases() {
  aliases.clear(); aliasDropped = []; aliasKnown = new Map(); aliasPending = [];
  if (!warm.dir) { return; }
  try {
    const j = JSON.parse(fs.readFileSync(path.join(warm.dir, ALIASES_FILE), 'utf8'));
    if (j && Array.isArray(j.pairs)) { for (const [s, p] of j.pairs) { if (Number.isInteger(s) && Number.isInteger(p)) { aliasKnown.set(s, p); } } }
  } catch (e) { /* none yet */ }
}
function saveAliases() {
  if (!warm.dir) { return; }
  const pairs = [...aliases].filter(([, a]) => a.state === 'verified').map(([s, a]) => [s, a.p]);
  try {
    const tmp = path.join(warm.dir, `${ALIASES_FILE}.${process.pid}.tmp`);
    fs.writeFileSync(tmp, JSON.stringify({ v: 1, pairs }), { mode: 0o600 });
    fs.renameSync(tmp, path.join(warm.dir, ALIASES_FILE));
  } catch (e) { /* best effort */ }
}
function dropAlias(s, why) {
  const a = aliases.get(s);
  if (!a) { return; }
  const was = a.state;
  Object.assign(a, { state: 'bad', why });
  aliasNote(s, a.p, why);
  if (was === 'on' || was === 'verified') { aliasDropped.push(s); }
  if (was === 'verified') { saveAliases(); }
}
const sameWin = (x, y) => !!x && !!y && !x.error && !y.error && x.count === y.count && x.exact === y.exact
  && Buffer.compare(zlib.inflateRawSync(asBuf(x.records)), zlib.inflateRawSync(asBuf(y.records))) === 0;
async function checkAlias(s, p) {
  const ep = epoch, a = aliases.get(s);
  const req = { id: `alias-${s}`, cmd: 'alias', internal: true };
  const live = () => epoch === ep && aliases.get(s) === a && a.state !== 'bad';
  try {
    const sp = splitWalks(req, [p]);  // the stored one, whole (needed to answer for both)
    if (sp) { await sp; }
    if (!live()) { return; }
    if (a.state !== 'verified') {
      const T = Math.max(1, timeEnd), len = Math.max(1, Math.floor(T / 1024));
      for (let k = 0; k < ALIAS_SAMPLES && live(); k++) {
        const t0 = Math.floor((k + 0.5) * T / ALIAS_SAMPLES), range = { t0, t1: t0 + len, buckets: MAX_BUCKETS };
        const [[x], [y]] = await Promise.all([coldTask(req, 'windowCold', [s], range, true), scatter(req, 'window', [p], range, (m) => m.result)]);
        if (!sameWin(x, y)) { dropAlias(s, `differs in [${t0}, ${t0 + len})`); return; }
      }
      if (!live()) { return; }
      a.state = 'on';
    }
    // The whole comparison, in the background: the rebuilt one loads as any background load.
    const j = startJob(s, null);
    await j.promise;
    if (!live()) { return; }
    const [ds, dp] = await Promise.all([single(req, 'digest', s, {}), single(req, 'digest', p, {})]);
    if (!live()) { return; }
    if (!ds || !dp || ds.error || dp.error || ds.hash !== dp.hash || ds.count !== dp.count) { dropAlias(s, `whole streams differ (${ds && ds.count} vs ${dp && dp.count} changes)`); return; }
    if (a.state !== 'verified') { a.state = 'verified'; saveAliases(); }
    if (!aliases.has(p)) { runTask(workerFor(s), { op: 'free', signalIds: [s] }).catch(() => {}); }
  } catch (e) {
    const m = String(e && e.message);
    // (the rebuilt row's load was dropped under the check: no verdict, so the pair goes, unused,
    // and a later hint checks it again)
    if (live() && /freed/.test(m)) { aliases.delete(s); aliasNote(s, p, 'freed during the comparison'); } else if (live() && !/reopened|closed/.test(m)) { dropAlias(s, `check failed: ${m}`); }
  } finally {
    for (const sp of req.splits || []) { sp.reqs.delete(req); }
  }
}
// Requests name rebuilt signals; with an alias in use they are read as the stored one. -> fix(r)
function aliasRewrite(req) {
  if (!aliases.size) { return null; }
  const map = (id) => aliasFor(id) ?? id;
  const tell = req.cmd === 'window' || req.cmd === 'valueAt' || req.cmd === 'count';  // (replies that carry rows)
  const notice = (r) => { if (tell && aliasDropped.length && r) { const o = r.bin !== undefined ? r.result : r; if (o && typeof o === 'object') { o.aliasDropped = aliasDropped; aliasDropped = []; } } return r; };
  if (req.cmd === 'window' && Array.isArray(req.signals)) {
    const orig = req.signals.map((x) => x && x.signalId);
    if (!orig.some((id) => aliasFor(id) !== null)) { return notice; }
    req.signals = req.signals.map((x) => (x && aliasFor(x.signalId) !== null ? { ...x, signalId: aliasFor(x.signalId) } : x));
    return (r) => {
      const sg = r && r.result && r.result.signals;
      if (sg) { sg.forEach((x, k) => { if (x && orig[k] !== x.signalId) { x.alias = x.signalId; x.signalId = orig[k]; } }); }
      return notice(r);
    };
  }
  if ((req.cmd === 'valueAt' || req.cmd === 'count') && Array.isArray(req.signalIds)) {
    const orig = req.signalIds;
    req.signalIds = orig.map(map);
    return (r) => {
      if (r && Array.isArray(r.counts)) { r.counts.forEach((x, k) => { if (x && orig[k] !== x.signalId) { x.alias = x.signalId; x.signalId = orig[k]; } }); }
      return notice(r);
    };
  }
  if ((req.cmd === 'edge' || req.cmd === 'search' || req.cmd === 'searchText') && req.signalId !== undefined) { req.signalId = map(req.signalId); }
  return tell ? notice : null;
}

// ---- whole loads in pieces (jobs) ----
// On a big dump one reader load of a whole signal costs up to ~10 s (clk 6.6 s, a 4-bit valid
// 10.6 s on 1.7 GB), cannot be interrupted, and costs about the same whether it is done in one
// go or in time slices (8 slices of clk: 8.9 s against 8.3 s; slice overhead ~1 ms, a ~110 ms
// floor for some signals). So every whole load of a signal that isn't stored is a job of time
// pieces, handed out one at a time from one shared pool: any worker with nothing of its own
// queued takes the next piece (pump), so a cheap signal added behind a heavy one waits for at
// most one piece, a heavy one is spread over the whole pool, and interactive requests on a
// worker wait for at most one piece. The pieces are then adopted (joined) into the owner's store.
// - Order: jobs some request waits for (interactive) before background ones (whole walks
//   behind ranged first draws, cancelled requests' loads); then measured jobs with at most one
//   piece of work left, jobs not started yet (oldest first), the other measured jobs (least
//   remaining work first), and last more pieces of jobs whose first piece is still running.
// - Piece length: a job's first piece covers 1/16 of a 1.7 GB dump, less on a bigger one (1/16 x
//   1.7 GB / size, down to 1/256); while it runs, idle workers take pieces 8x shorter. (Shorter
//   probes on every dump cost more: each piece pays the reader's per-load floor and a worker's
//   first load of the signal; 10 signals on 1.7 GB: last 7.5 -> 10.9 s.) Then about PIECE_MS of work, from a fit of the job's pieces to ms = floor +
//   rate * length: some signals cost ~110 ms per load whatever the range (big reader blocks),
//   so a piece cheaper than PIECE_MS is followed by one 4x longer, and a job whose floor is
//   over PIECE_MS / 2 takes the rest in one piece, but no piece is longer than 2 * PIECE_MS at
//   the plain rate of the job's longest piece (and of its newest one). Background jobs aim at
//   BG_PIECE_MS instead.
// - Cancelling every request of a job keeps it going in the background (asking again finds it
//   done or further along), at most CANCEL_KEEP such loads (the furthest along); `free` of the
//   signal (or free {}) drops a load nobody waits for. A job over the store cap is stopped as soon as its pieces say so.
//   A signal the reader can't read fails once and is remembered (bgFailed), not loaded again.
const PIECE_MS = Number(process.env.FSDB_PIECE_MS || 250);
// Background pieces are shorter: a request for a signal stored on that worker waits for one.
const BG_PIECE_MS = Number(process.env.FSDB_BG_PIECE_MS || 100);
// (probe sizes scale with the dump's size, as a whole load's cost does: on a 1.7 GB dump a 1/16
// probe of a 10 s load is ~600 ms, on a 10 GB one the same share would be 5-7 s)
const PROBE_REF_BYTES = 1.7e9, MIN_PARTS = 1024;
let fileBytes = 0;
const probeParts = () => Math.round(Math.min(256, Math.max(16, 16 * fileBytes / PROBE_REF_BYTES)));
const smallParts = () => Math.min(MIN_PARTS, 8 * probeParts());
const jobs = new Map();  // signalId -> job
let jobSeq = 0;
const transient = (e) => /exited|pool resized|memory limit|cancelled/.test(String(e || ''));
const permanent = (e) => /larger than|0 bits|unsupported|not a bit signal|no traverse handle/.test(String(e || ''));
const storeCap = () => storeShare(Math.max(1, workers.length));
function capErrorOf(cap) { return `signal larger than ${Math.floor(cap / 1048576)} MB (worker store limit)`; }

function startJob(id, req) {
  let j = jobs.get(id);
  if (!j) {
    let resolve, reject;
    const promise = new Promise((a, b) => { resolve = a; reject = b; });
    promise.catch(() => {});  // a background job may have no waiter
    j = { id, seq: ++jobSeq, epoch, end: timeEnd + 1, next: 0, pieces: [], redo: [], running: 0, doneMs: 0, doneLen: 0, doneCount: 0,
      retries: 0, done: [], adopting: false, failed: false, reqs: new Set(), t0: performance.now(), promise, resolve, reject,
      kind: kindOf(id), workers: new Set(), maxW: 1, walkMs: 0, small: false };
    if (j.kind === 'p') { j.walkMs = primWalkMs(id); j.small = j.walkMs < 2 * PIECE_MS; }
    promise.sp = j;
    jobs.set(id, j);
    splitting.set(id, promise);
  }
  if (req) { j.reqs.add(req); (req.splits || (req.splits = [])).push(j); }
  scheduleKick(!!req);
  return j;
}
// (after the request lines that arrived together have started their jobs: cheap primaries batch)
let kickPending = null;
function scheduleKick(interactive) {
  if (kickPending) { kickPending.interactive ||= interactive; return; }
  kickPending = { interactive };
  setImmediate(() => { const k = kickPending; kickPending = null; kickPool(k.interactive); });
}
// Idle workers take pieces now; a worker in background work is asked to stop early (as enqueue).
function kickPool(interactive) {
  for (const w of workers) {
    if (idleWorker(w)) { pump(w); } else if (interactive && w.busy && w.busy.bg && !w.busy.yieldSent && w.pid && !w.queue.length) {
      w.busy.yieldSent = true;
      try { process.kill(w.pid, 'SIGUSR2'); } catch (e) { /* exiting */ }
    }
  }
}
function pickJob(interactive, w = null, limit = false) {
  let best = null, bk = null;
  const over = shmBytes >= SHM_CAP;
  if (over) {  // (the started load with the least work left, interactive or not)
    for (const j of jobs.values()) {
      if (j.failed || j.adopting || j.batching || j.epoch !== epoch || !j.shm || (!j.redo.length && j.next >= j.end)) { continue; }
      const rest = (j.doneMs / Math.max(1, j.doneLen)) * (j.end - j.next);
      if (!best || rest < bk) { best = j; bk = rest; }
    }
    return best && (best.reqs.size > 0) === interactive ? best : null;
  }
  for (const j of jobs.values()) {
    if (j.failed || j.adopting || j.batching || j.epoch !== epoch || (j.reqs.size > 0) !== interactive) { continue; }
    if (!j.redo.length && j.next >= j.end) { continue; }  // every piece handed out
    // (a secondary's pieces stay on few workers while other loads can use the rest)
    if (limit && w && j.kind === 's' && !j.workers.has(w.i) && j.workers.size >= j.maxW) { continue; }
    const rest = j.doneLen > 0 ? (j.doneMs / j.doneLen) * (j.end - j.next) : 0;  // est. ms still to hand out
    // (a measured job with at most one piece of work left finishes first: that is a draw)
    const cls = !j.pieces.length ? 0 : j.doneLen > 0 ? (rest <= PIECE_MS ? -1 : 1) : 2;
    const k = [cls, cls === 1 || cls === -1 ? rest : 0, j.seq];
    if (!best || k[0] < bk[0] || (k[0] === bk[0] && (k[1] < bk[1] || (k[1] === bk[1] && k[2] < bk[2])))) { best = j; bk = k; }
  }
  return best;
}
function nextPiece(j, target) {
  if (j.redo.length) { return j.redo.shift(); }
  const left = j.end - j.next;
  let len = Math.ceil(j.end / (j.pieces.length ? smallParts() : probeParts()));
  if (j.done.length) {
    let S = j.done[0], L = j.done[0];
    for (const d of j.done) { if (d.len < S.len) { S = d; } if (d.len > L.len) { L = d; } }
    if (L.len >= 2 * S.len) {
      const rate = Math.max(1e-12, (L.ms - S.ms) / (L.len - S.len)), floor = Math.max(0, S.ms - rate * S.len);
      len = floor >= target / 2 ? left : (target - floor) / rate;
    } else {
      len = target * L.len / Math.max(1e-3, L.ms);
      if (L.ms <= target) { len = Math.max(len, 4 * L.len); }  // tells a per-load floor from a per-time cost
    }
    // Never more than 2 * target at the longest piece's plain rate (an upper bound on the
    // cost): a worker's first load of a signal costs ~150-200 ms extra, which the fit can take
    // for a floor, and one piece must never hold a worker for seconds.
    len = Math.min(len, 2 * target * L.len / Math.max(1e-3, L.ms));
    // (and at the newest comparable piece's: the rate changes along the dump)
    const N = j.done[j.done.length - 1];
    if (N !== L && N.len >= L.len / 2) { len = Math.min(len, 2 * target * N.len / Math.max(1e-3, N.ms)); }
    len = Math.max(Math.ceil(j.end / MIN_PARTS), Math.floor(len));
  }
  if (j.kind === 'p') {  // a primary: equal pieces of several floors each, no probe
    if (!j.plen) {
      const n = Math.max(1, Math.min(workers.length, Math.round(j.walkMs / Math.max(4 * primFloor(), PIECE_MS))));
      j.plen = Math.ceil(j.end / n);
    }
    len = j.plen;
  }
  if (left - len < len / 2) { len = left; }  // no tiny tail
  const p = { s: j.next, e: j.next + len, path: tmpPath(`s${j.id}`), state: 'queued', count: 0 };
  j.next = p.e;
  j.pieces.push(p);
  return p;
}
const bgRoom = () => workers.length < 3 || workers.filter((x) => x.busy && x.busy.bgPiece).length < workers.length - 1;
// pump(w): w has nothing of its own queued; give it the next piece of `interactive` jobs.
function pullPiece(w, interactive) {
  const j = pickJob(interactive, w, true) || pickJob(interactive, w, false);
  if (!j) { return false; }
  if (j.kind === 'p' && j.small && !j.pieces.length) { return pullBatch(w, j, interactive); }
  j.workers.add(w.i);
  const p = nextPiece(j, interactive ? PIECE_MS : BG_PIECE_MS);
  p.state = 'running';
  j.running++;
  const task = { op: 'walkSlice', signalId: j.id, s: p.s, e: p.e >= j.end ? 1.8e19 : p.e, path: p.path, tid: nextTid++, epoch, piece: true, bgPiece: !interactive };
  task.done = (m) => pieceDone(j, p, m, w);
  w.queue.push(task);
  return true;
}
// Piece files are in /dev/shm (RAM, outside every worker's RSS guard): their total is capped.
// Above SHM_CAP only the started load with the least work left gets more pieces (its join
// deletes its files), so the total stays under the cap plus one load and a piece per worker.
const SHM_CAP = Number(process.env.FSDB_SHM_CAP || 512 * 1048576);
let shmBytes = 0, shmPeak = 0;
// Cheap primaries are loaded several in one reader call on one worker, which stores them (no
// piece files): the call's floor is paid once. As many per call as spread them over the idle
// workers, at most min(store share / 2, 128 MB) of estimated store and 4 x PIECE_MS of work.
const estBytes = (id) => ((kinds.primaries && kinds.primaries.get(id)) || 0) * (8 + 2 * Math.ceil((widthOf.get(id) || 1) / 8));
function pullBatch(w, j, interactive) {
  const cands = [...jobs.values()].filter((x) => x !== j && x.kind === 'p' && x.small && !x.pieces.length && !x.batching && !x.failed && !x.adopting
    && x.epoch === epoch && (x.reqs.size > 0) === interactive).sort((a, b) => a.seq - b.seq);
  const idle = Math.max(1, workers.filter((x) => x === w || idleWorker(x)).length);
  const per = Math.ceil((cands.length + 1) / idle);
  const byteCap = Math.min(storeCap() / 2, 128 * 1048576);
  const batch = [j];
  let bytes = estBytes(j.id), ms = j.walkMs;
  for (const x of cands) {
    if (batch.length >= per) { break; }
    if (bytes + estBytes(x.id) > byteCap || ms + x.walkMs > 4 * PIECE_MS) { continue; }
    batch.push(x); bytes += estBytes(x.id); ms += x.walkMs;
  }
  for (const x of batch) { x.batching = true; x.running++; x.workers.add(w.i); }
  const task = { op: 'load', signalIds: batch.map((x) => x.id), tid: nextTid++, epoch, piece: true, bgPiece: !interactive, s: 0, e: 'all' };
  task.done = (m) => batchDone(batch, m, w);
  w.queue.push(task);
  return true;
}
function batchDone(batch, m, w) {
  for (const x of batch) { x.running--; x.batching = false; }
  const live = batch.filter((x) => x.epoch === epoch);
  if (m.error) {
    for (const x of live) {
      if (x.dropped) { x.reject(new Error('freed')); continue; }
      if (x.failed) { continue; }
      if (transient(m.error) && x.retries < 3) { x.retries++; } else { failJob(x, m.error); }
    }
    scheduleKick(true);
    return;
  }
  learnFloor(m.ms, batch.reduce((a, x) => a + x.walkMs, 0), batch.length);
  const owner = workers[w.i] === w ? w : null;
  batch.forEach((x, k) => {
    if (x.epoch !== epoch) { return; }
    const r = m.result && m.result[k];
    if (x.dropped) {  // freed while it loaded: drop what it stored
      if (owner && r && !r.error) { runTask(owner, { op: 'free', signalIds: [x.id] }).catch(() => {}); }
      x.reject(new Error('freed'));
      return;
    }
    if (x.failed) { return; }
    if (!owner) { if (x.retries < 3) { x.retries++; } else { failJob(x, 'worker exited'); } return; }
    if (!r || r.error) {
      const e = r ? r.error : 'no result';
      if (transient(e) && x.retries < 3) { x.retries++; } else { failJob(x, e); }
      return;
    }
    if (floating.has(x.id)) { pinFloat(floating.get(x.id)); }
    route.set(x.id, owner.i);
    endJob(x);
    x.resolve({ ms: performance.now() - x.t0, slices: [r.count || 0], batch: batch.length });
  });
  if (owner) {  // the waiters ask the owner next (as finishJob)
    owner.hold = true;
    setImmediate(() => { owner.hold = false; pump(owner); });
  }
  scheduleKick(true);
}
function rmPiece(p) {
  if (p.bytes) { shmBytes -= p.bytes; p.bytes = 0; }
  try { fs.rmSync(p.path, { force: true }); } catch (e) { /* gone */ }
}
function pieceDone(j, p, m, w) {
  j.running--;
  if (j.failed || j.epoch !== epoch) { rmPiece(p); return; }
  if (m.error) {
    rmPiece(p);
    if (transient(m.error) && j.retries < 3) { j.retries++; p.state = 'queued'; j.redo.push(p); kickPool(j.reqs.size > 0); return; }
    failJob(j, m.error);
    return;
  }
  p.state = 'done';
  p.count = (m.result && m.result.count) || 0;
  try { p.bytes = fs.statSync(p.path).size; } catch (e) { p.bytes = 0; }
  shmBytes += p.bytes; j.shm = (j.shm || 0) + p.bytes;
  if (shmBytes > shmPeak) { shmPeak = shmBytes; }
  j.doneMs += m.ms;
  j.doneLen += Math.min(p.e, j.end) - p.s;
  j.done.push({ len: Math.min(p.e, j.end) - p.s, ms: m.ms });
  if (j.kind === 's') {  // as many workers as keep their setup under 1/4 of the work
    // (a worker's first piece of the signal includes its setup: not part of the work's rate)
    j.firstOn = j.firstOn || new Set();
    const first = !j.firstOn.has(w.i);
    j.firstOn.add(w.i);
    j.workMs = (j.workMs || 0) + Math.max(0, m.ms - (first ? SEC_SETUP_MS : 0));
    const est = (j.workMs / Math.max(1, j.doneLen)) * j.end;
    j.maxW = Math.max(1, Math.min(workers.length, Math.floor(est / (4 * SEC_SETUP_MS))));
  }
  j.doneCount += p.count;
  const bits = widthOf.get(j.id) || 1;
  // (the bound adopt checks: slice counts before normalization, both planes)
  if (j.doneCount * (8 + 2 * Math.ceil(bits / 8)) > storeCap()) { failJob(j, capErrorOf(storeCap())); return; }
  if (j.next >= j.end && !j.redo.length && !j.running) { finishJob(j, w); }
}
// The worker that walked the last piece adopts them: it is free right now (any other may be in
// the middle of a piece) and becomes the signal's owner (nothing of it is stored anywhere yet).
function finishJob(j, w) {
  j.adopting = true;
  if (floating.has(j.id)) { pinFloat(floating.get(j.id)); }
  const owner = workers[w.i] === w ? w : leastBusy();
  route.set(j.id, owner.i);
  const pieces = [...j.pieces].sort((a, b) => a.s - b.s);
  const task = enqueue(owner, { op: 'adopt', signalId: j.id, paths: pieces.map((p) => p.path) }, j.reqs.size > 0);
  task.done = (m) => {
    for (const p of pieces) { rmPiece(p); }
    setImmediate(() => kickPool(false));  // (pieces held back by the RAM cap)
    if (j.epoch !== epoch) { return; }
    // freed while it was being joined: drop what it stored
    if (j.dropped) { if (!m.error) { runTask(owner, { op: 'free', signalIds: [j.id] }).catch(() => {}); } j.reject(new Error('freed')); return; }
    if (m.error) { failJob(j, m.error); return; }
    endJob(j);
    // The requests waiting for it ask the owner next (promise callbacks, before setImmediate):
    // don't let it start a piece of another load first.
    owner.hold = true;
    setImmediate(() => { owner.hold = false; pump(owner); });
    j.resolve({ ms: performance.now() - j.t0, slices: pieces.map((p) => p.count) });
  };
}
function endJob(j) {
  if (jobs.get(j.id) === j) { jobs.delete(j.id); }
  if (splitting.get(j.id) === j.promise) { splitting.delete(j.id); }
}
function failJob(j, error) {
  j.failed = true;
  for (const p of j.pieces) { if (p.state !== 'running') { rmPiece(p); } }
  endJob(j);
  if (permanent(error) && j.epoch === epoch) { bgFailed.set(j.id, error); }
  j.reject(new Error(error));
}
// A load nobody waits for any more (free of its signal, or too many cancelled ones): queued
// pieces are dropped, running ones end and delete their files, nothing is stored.
function dropJob(j) {
  if (j.reqs.size || j.dropped) { return false; }
  j.dropped = true;
  if (j.adopting || j.batching) { endJob(j); return true; }  // finishJob / batchDone drop what it stores
  j.failed = true;
  for (const p of j.pieces) { if (p.state !== 'running') { rmPiece(p); } }
  endJob(j);
  j.reject(new Error('freed'));
  return true;
}
// Cancelled loads kept going in the background (asking again finds them further along): at
// most CANCEL_KEEP, the furthest along first, so a burst of cancels can't keep the pool busy.
const CANCEL_KEEP = Number(process.env.FSDB_CANCEL_KEEP ?? 8);
let demoteSeq = 0;
function capDemoted() {
  const kept = [...jobs.values()].filter((j) => j.demoted && !j.reqs.size && !j.adopting && !j.dropped);
  if (kept.length <= CANCEL_KEEP) { return; }
  kept.sort((a, b) => (b.doneLen / b.end) - (a.doneLen / a.end) || b.demoted - a.demoted);
  for (const j of kept.slice(CANCEL_KEEP)) { dropJob(j); }
}
function clearJobs() {
  for (const j of jobs.values()) { j.failed = true; for (const p of j.pieces) { if (p.state !== 'running') { rmPiece(p); } } j.reject(new Error('file reopened')); }
  jobs.clear();
}

// Before a query: start (or join) the whole load of every signal that isn't stored, has no
// store-cache file and hasn't failed for good. Resolves when they are stored (req.split: per
// signal {ms, slices}); null when nothing has to wait.
function splitWalks(req, ids) {
  const waits = [];
  // (no workerFor here: it would fix the worker of a signal still waiting for the first free one)
  const stored = (id) => route.has(id) && !floating.has(id) && workerFor(id).state.cached.includes(id);
  for (const id of ids) {
    if (!jobs.has(id)) {
      if (!timeEnd || stored(id) || bgFailed.has(id)) { continue; }
      if (STORE_CACHE && warm.epoch === epoch && warm.files.has(id)) { continue; }  // read from the store cache instead
    }
    const j = startJob(id, req);
    waits.push(j.promise.then((r) => [id, r]));
  }
  if (!waits.length) { return null; }
  // Every signal's own load settles before this does: a load that failed must not send the
  // others, still loading in pieces, to a whole load on one worker (stored twice). Rejects
  // with the first failure once all are settled; the ones that loaded are stored by then.
  return Promise.allSettled(waits).then((rs) => {
    req.split = new Map(rs.filter((r) => r.status === 'fulfilled').map((r) => r.value));
    const bad = rs.find((r) => r.status === 'rejected');
    if (bad) { throw bad.reason; }
  });
}

// Before a query: load signals that aren't stored (jobs above) and (re)materialize derived
// ones. Returns null when nothing has to wait, so callers only await then
// (an unconditional await would let later request lines enqueue first).
function prep(req, ids) {
  const a = splitWalks(req, ids.filter((id) => !derived.has(id)));
  const b = ensureDerived(ids.filter((id) => derived.has(id)));
  return a || b ? Promise.all([a, b]) : null;
}

// ---- cold reads (reader view windows; WINDOWING.md "Cold reads") ----
// valueAt of a signal that isn't stored reads one value through a [t, t] view
// window (~2 ms) instead of walking and caching the whole signal. A window over
// a short range (<= COLD_RANGE of the file) of signals that aren't stored loads
// and walks only that range (a 1% range of spike_rvfi: ~40 ms instead of ~1.5 s),
// and the whole walk then runs in the background on the signal's worker, so
// later pans are served from the store.
const COLD_RANGE = Number(process.env.FSDB_COLD_RANGE || 0.25);
const busyness = (w) => (w.busy && !w.busy.bg ? 1 : 0) + w.queue.length;
const leastBusy = () => workers.reduce((b, w) => (busyness(w) < busyness(b) ? w : b));
// (a signal whose whole load is still in pieces is cold too: a ranged read or one value is far
// cheaper than waiting for the rest of its load)
const isCold = (id) => !derived.has(id) && !workerFor(id).state.cached.includes(id);
// One task on the least busy worker (cheap reads); with spread spread over the free
// workers in parallel (ranged walks); with spread 'even' split over the workers,
// least busy first, at least COLD_SPREAD signals per part (cold reads keep
// nothing, so any worker will do: a debugger's 200-signal step). Resolves with
// results in ids order.
const COLD_SPREAD = Number(process.env.FSDB_COLD_SPREAD ?? 16);  // 0: never split
const COLD_PRIM_GROUP = 64;  // stored signals per ranged cold call (one reader floor each)
function coldTask(req, op, ids, extra, spread = false) {
  const groups = new Map();
  if (spread === 'even' && COLD_SPREAD > 0 && ids.length >= 2 * COLD_SPREAD) {
    const ws = [...workers].sort((a, b) => busyness(a) - busyness(b));
    const k = Math.min(ws.length, Math.floor(ids.length / COLD_SPREAD));
    for (let j = 0; j < k; j++) { groups.set(ws[j], ids.slice(Math.floor(j * ids.length / k), Math.floor((j + 1) * ids.length / k))); }
  } else if (spread === true) {
    // Ranged walks keep nothing either: over the workers with nothing to do (in parallel), else
    // the least busy one, not the signals' owners, which may be in the middle of a load piece.
    // Stored (primary) signals pay the reader's floor once per call whatever the range, so they
    // go together, up to COLD_PRIM_GROUP per call; rebuilt ones cost by the range and are spread
    // over the other free workers (all of them if the primaries took the only one).
    const free = workers.filter((w) => w.ready && !w.busy && !w.queue.length && !w.recycle);
    const add = (w, id) => { if (!groups.has(w)) { groups.set(w, []); } groups.get(w).push(id); };
    const prim = ids.filter((id) => kindOf(id) === 'p'), rest = ids.filter((id) => kindOf(id) !== 'p');
    const pg = [];
    for (let k = 0; k < prim.length; k += COLD_PRIM_GROUP) { pg.push(prim.slice(k, k + COLD_PRIM_GROUP)); }
    const pool = free.length ? free.slice(0, pg.length + rest.length) : [leastBusy()];
    pg.forEach((g, k) => { for (const id of g) { add(pool[k % pool.length], id); } });
    const others = pool.length > pg.length ? pool.slice(pg.length) : pool;
    rest.forEach((id, k) => add(others[k % others.length], id));
  } else {
    for (const id of ids) {
      const w = leastBusy();
      if (!groups.has(w)) { groups.set(w, []); }
      groups.get(w).push(id);
    }
  }
  return Promise.all([...groups].map(([w, gids]) => new Promise((resolve, reject) => {
    const task = enqueue(w, { op, signalIds: gids, ...extra, req });
    req.parts = [...(req.parts || []), { w, task }];
    task.done = (m) => {
      req.workerMs = Math.max(req.workerMs || 0, m.ms);
      if (m.error) { reject(new Error(m.error)); } else { resolve(gids.map((id, k) => [id, m.result[k]])); }
    };
  }))).then((parts) => { const by = new Map(parts.flat()); return ids.map((id) => by.get(id)); });
}
// ---- warm readers (the reader's navDB-once mode) ----
// A reader that keeps the file's navigation DB (ffrSetLoadNavDBOnlyOnce) answers a view window
// of its signals in ~1-20 ms instead of a cold read's ~110 ms (1.7 GB) to ~650 ms (10 GB) per
// call, but every signal it reads must be in its first load: the reader can return wrong
// results otherwise. So a warm reader is its own process with a fixed set: the signals being
// viewed (ranged reads asked for in the last HOT_RECENT_MS, not stored whole), at most HOT_MAX.
// Ranged reads of signals in a ready set go to it; the rest are read cold as before, in
// parallel. When a quarter of what is being viewed is outside the ready set, a new reader is
// built in the background with the new set and the old one retires once it is ready. Warm
// readers take no load pieces and keep no store; their answers are windowCold's records.
const HOT = process.env.FSDB_WARM !== '0';
const HOT_MAX = Number(process.env.FSDB_WARM_SIGNALS || 16);
const HOT_RECENT_MS = Number(process.env.FSDB_WARM_RECENT_MS || 3000);
const HOT_RSS = Number(process.env.FSDB_WARM_RSS_MB || 600) * 1e6;
const hot = { readers: [], building: null, asked: new Map(), timer: null };  // asked: id -> last ranged ask (ms)
const storedWhole = (id) => derived.has(id) || (route.has(id) && !floating.has(id) && workerFor(id).state.cached.includes(id));
function hotStop() {
  for (const r of [...hot.readers, hot.building].filter(Boolean)) { hotKill(r); }
  hot.readers = []; hot.building = null; hot.asked.clear();
  if (hot.timer) { clearTimeout(hot.timer); hot.timer = null; }
}
function hotKill(r) {
  r.state = 'dead';
  for (const p of r.pending.values()) { p({ error: 'warm reader retired' }); }
  r.pending.clear();
  try { r.proc.kill(); } catch (e) { /* gone */ }
}
function hotCall(r, msg) {
  return new Promise((resolve) => {
    if (r.state === 'dead') { resolve({ error: 'warm reader retired' }); return; }
    const tid = r.tid++;
    r.pending.set(tid, resolve);
    r.proc.send({ ...msg, tid }, (e) => { if (e && r.pending.delete(tid)) { resolve({ error: e.message }); } });
  });
}
function hotSpawn(ids) {
  const proc = fork(path.join(__dirname, 'worker.js'), [], { stdio: ['ignore', 2, 2, 'ipc'], serialization: 'advanced' });
  const r = { proc, ids: new Set(ids), state: 'starting', pending: new Map(), tid: 1, epoch, rss: 0, ready: null };
  r.ready = new Promise((resolve) => { r.onReady = resolve; });
  proc.on('message', (m) => {
    if (m.ready) { r.onReady(); return; }
    if (m.state) { r.rss = m.state.rss || 0; }
    const p = r.pending.get(m.tid);
    if (p) { r.pending.delete(m.tid); p(m); }
  });
  proc.on('error', () => {});
  proc.on('exit', () => {
    hotKill(r);
    hot.readers = hot.readers.filter((x) => x !== r);
    if (hot.building === r) { hot.building = null; }
  });
  return r;
}
// The set wanted now: ranged reads of the last HOT_RECENT_MS, newest first, not stored whole.
function hotWanted() {
  const now = performance.now();
  for (const [id, t] of hot.asked) { if (now - t > HOT_RECENT_MS) { hot.asked.delete(id); } }
  // Stored (primary) signals only, once the kinds are known: a warm reader saves the per-call
  // floor, but a rebuilt signal costs the same rebuild per window (~175 ms at 1% of 1.7 GB) and
  // in one warm process they would be read one after another instead of spread over workers.
  const ok = (id) => kinds.state !== 'ready' || kindOf(id) === 'p';
  return [...hot.asked].filter(([id]) => ok(id) && !storedWhole(id) && !bgFailed.has(id)).sort((a, b) => b[1] - a[1]).slice(0, HOT_MAX).map(([id]) => id);
}
function hotNote(ids) {
  if (!HOT || !openFile) { return; }
  const now = performance.now();
  for (const id of ids) { hot.asked.delete(id); hot.asked.set(id, now); }
  if (!hot.timer) { hot.timer = setTimeout(() => { hot.timer = null; hotCheck(); }, 200); }
}
function hotCheck() {
  if (!HOT || !openFile || hot.building) { return; }
  const want = hotWanted();
  if (!want.length) { return; }
  const cur = hot.readers.find((r) => r.state === 'ready');
  const outside = cur ? want.filter((id) => !cur.ids.has(id)).length : want.length;
  const overRss = cur && cur.rss > HOT_RSS;
  if (cur && !overRss && outside * 4 < want.length) { return; }
  hotBuild(want);
}
async function hotBuild(ids) {
  const ep = epoch, file = openFile;
  const r = hotSpawn(ids);
  hot.building = r;
  try {
    await r.ready;
    const o = await hotCall(r, { op: 'hotOpen', file });
    if (o.error) { throw new Error(o.error); }
    const l = await hotCall(r, { op: 'hotLoad', signalIds: ids });
    if (l.error) { throw new Error(l.error); }
    // (a signal the reader can't load stays out of the set: read cold)
    l.result.forEach((x, k) => { if (x && x.error) { r.ids.delete(ids[k]); } });
    // The reader's first load (navigation built, ~0.2-0.9 s) is its first window: done here,
    // over the last window asked for, so the first pan once the set is ready doesn't pay it.
    if (r.ids.size && epoch === ep && r.state !== 'dead') {
      const p = await hotCall(r, { op: 'hotWindow', signalIds: [...r.ids], ...(hot.lastRange || { t0: 0, t1: Math.max(1, Math.floor((timeEnd || 1) / 100)), buckets: 1024 }) });
      if (p.error) { throw new Error(p.error); }
    }
    if (epoch !== ep || r.state === 'dead') { hotKill(r); return; }
    r.state = 'ready';
    const old = hot.readers;
    hot.readers = [r];
    for (const x of old) { x.state = 'retiring'; Promise.all([...x.pending.values()]).finally(() => {}); setTimeout(() => hotKill(x), 5000); }
  } catch (e) {
    if (DEBUG) { process.stderr.write(`[helper] warm reader: ${(e && e.message) || e}\n`); }
    hotKill(r);
  } finally {
    if (hot.building === r) { hot.building = null; }
    if (epoch === ep) { setTimeout(hotCheck, 50); }
  }
}
// A warm call loads the reader's whole set however many signals it names, and the page asks
// for each row in its own request, all at once: requests that reach a reader together (within
// HOT_GATHER_MS of each other, or while it is busy) go to it as one call per window.
const HOT_GATHER_MS = 3;
function hotWindowBatched(r, ids, range) {
  return new Promise((resolve) => {
    (r.queue || (r.queue = [])).push({ ids, range, key: JSON.stringify(range), resolve });
    if (!r.busy && !r.pumpSoon) { r.pumpSoon = true; setTimeout(() => { r.pumpSoon = false; hotPump(r); }, HOT_GATHER_MS); }
  });
}
async function hotPump(r) {
  if (r.busy || !r.queue || !r.queue.length) { return; }
  r.busy = true;
  const groups = new Map();
  for (const q of r.queue.splice(0)) { if (!groups.has(q.key)) { groups.set(q.key, []); } groups.get(q.key).push(q); }
  for (const qs of groups.values()) {
    const ids = [...new Set(qs.flatMap((q) => q.ids))];
    const a = await hotCall(r, { op: 'hotWindow', signalIds: ids, ...qs[0].range });
    for (const q of qs) {
      if (a.error) { q.resolve({ error: a.error }); continue; }
      const want = new Set(q.ids);
      q.resolve({ ms: a.ms, result: a.result.filter((x) => want.has(x.signalId)) });
    }
  }
  r.busy = false;
  if (r.queue.length) { hotPump(r); }
}
// A ranged cold read: the signals in the ready warm set from it, the rest cold (coldTask),
// in parallel; a warm read that fails falls back to cold. -> results in ids order
async function rangedRead(req, ids, range) {
  hotNote(ids);
  if (HOT) { hot.lastRange = range; }
  const r = hot.readers.find((x) => x.state === 'ready');
  const inSet = r ? ids.filter((id) => r.ids.has(id)) : [];
  const rest = ids.filter((id) => !inSet.includes(id));
  const [a, b] = await Promise.all([
    inSet.length ? hotWindowBatched(r, [...new Set(inSet)], range) : null,
    rest.length ? coldTask(req, 'windowCold', rest, range, true) : []]);
  const by = new Map(rest.map((id, k) => [id, b[k]]));
  if (inSet.length) {
    if (a.error) { (await coldTask(req, 'windowCold', inSet, range, true)).forEach((x, k) => by.set(inSet[k], x)); } else {
      req.workerMs = Math.max(req.workerMs || 0, a.ms || 0);
      for (const x of a.result) { by.set(x.signalId, x); }
    }
  }
  return ids.map((id) => by.get(id));
}

// valueAt {prev: true} of signals that aren't stored: view windows [t - span, t] that grow x8
// until each signal's last real change is in one or the window reaches 0 (then it has none:
// null). Stored (primary) signals pay a floor per call, so they start wide (1/256 of the dump)
// and go in one call; rebuilt ones cost by the span, so they start narrow (1/4096) and are
// spread. -> Map id -> {value, prev: {t, value} | null} (value null: unreadable)
async function coldNear(req, ids, t) {
  const out = new Map();
  const T = Math.max(1, timeEnd || 1);
  const round = async (todo, span) => {
    while (todo.length && !req.cancelled) {
      const rs = await coldTask(req, 'coldNear', todo, { t, span }, true);
      const next = [];
      todo.forEach((id, k) => {
        const r = rs[k];
        if (!r || r.error) { out.set(id, { value: null, prev: null }); return; }
        if (!r.none) { out.set(id, { value: r.value, prev: { t: r.t, value: r.value } }); return; }
        out.set(id, { value: r.value, prev: null });
        if (span < t) { next.push(id); }
      });
      todo = next; span *= 8;
    }
  };
  const prim = ids.filter((id) => kindOf(id) === 'p'), rest = ids.filter((id) => kindOf(id) !== 'p');
  await Promise.all([round(rest, Math.max(1, Math.ceil(T / 4096))), round(prim, Math.max(1, Math.ceil(T / 256)))]);
  return out;
}

// Background whole walks (after a ranged first draw): a job nobody waits for, so it runs in
// pieces only when no interactive work is queued (see jobs above).
const bgFailed = new Map();  // signalId -> error: loads that failed for good (over the store cap, unreadable); not retried until a reopen
// FSDB_BG_LOAD=0 (checks and benches): rows are never stored whole in the background, so they
// stay on ranged (cold or warm) reads.
const BG_LOAD = process.env.FSDB_BG_LOAD !== '0';
function scheduleBgLoad(id) {
  if (!BG_LOAD) { return; }
  if (jobs.has(id) || bgFailed.has(id) || !timeEnd || derived.has(id)) { return; }
  if (STORE_CACHE && warm.epoch === epoch && warm.files.has(id)) { return; }
  if (route.has(id) && !floating.has(id) && workerFor(id).state.cached.includes(id)) { return; }
  startJob(id, null);
}

// ---- full hierarchy index (paths for expressions and searchAll) ----
let index = null;  // {byPath, byId, list: [{path, signalId, width, msb, lsb, encoding}]}
// SystemVerilog strings (FSDB varType 63, 2 bytes per bit) are listed as width-1 BitVectors of type
// 'unknown_var_type'; the reader can't give them as bit vectors, so they're never search or
// warm-up candidates (they made every search containing them incomplete).
const bitVector = (v) => v.encoding === 'BitVector' && v.type !== 'unknown_var_type';
function getIndex() {
  if (index) { return index; }
  const t0 = performance.now();
  const list = [], byPath = new Map(), byId = new Map();
  const walk = (scope, p) => {
    addon.readVars(p, scope.scopeOffsetIdx, (name, type, encoding, varPath, netlistId, signalId, width, msb, lsb) => {
      // The reader gives plain reg/wire for `logic signed`; only integer-like types are known signed.
      const signed = /^(integer|int|shortint|longint|byte)$/i.test(String(type));
      const v = { path: p + '.' + stripRange(name, width, msb, lsb), signalId, width, msb, lsb, encoding, type, signed };
      // A path another scope tree re-enters (a modport port's own tree) is listed once.
      if (byPath.has(v.path)) { return; }
      list.push(v);
      if (!byPath.has(v.path)) { byPath.set(v.path, v); }
      if (!byId.has(signalId)) { byId.set(signalId, v); }
      widthOf.set(signalId, width);
    }, () => {}, () => {}, () => {}, () => {});
    let start = 0, rem = 1, guard = 256;
    while (rem > 0 && guard-- > 0) {
      const r = addon.getScopeChildren(scope.scopeOffsetIdx, start);
      for (const c of r.scopes) { if (!c.name.startsWith('$')) { walk(c, p + '.' + c.name); } }
      rem = r.remainingItems; start += r.totalReturned;
      if (!r.totalReturned) { break; }
    }
  };
  for (const s of addon.readScopes()) { if (!s.name.startsWith('$')) { walk(s, s.name); } }
  index = { list, byPath, byId, ms: performance.now() - t0 };
  return index;
}

// Expression reference -> {signalId, width, msb, lsb, path, sel}. A path may
// carry its own index brackets (pc_rdata[0]); the longest bracket prefix that
// names a variable wins and the rest are selects. A unique suffix also works.
const fmtSel = ([m, l]) => (m === l ? `[${m}]` : `[${m}:${l}]`);
function resolveRef(r) {
  const idx = getIndex();
  if (r.id !== undefined) {
    const d = derived.get(r.id);
    if (d) { return { signalId: d.id, width: d.width, msb: d.width - 1, lsb: 0, signed: d.signed, path: d.name || `#${d.id}`, sel: r.sel }; }
    const v = idx.byId.get(r.id);
    if (!v) { throw new Error(`unknown signal #${r.id}`); }
    return { ...v, sel: r.sel };
  }
  for (let k = r.sel.length; k >= 0; k--) {
    const name = r.path + r.sel.slice(0, k).map(fmtSel).join('');
    const d = derivedByName.get(name);
    if (d) { return { signalId: d.id, width: d.width, msb: d.width - 1, lsb: 0, signed: d.signed, path: name, sel: r.sel.slice(k) }; }
    const v = idx.byPath.get(name);
    if (v) { return { ...v, sel: r.sel.slice(k) }; }
    const hits = idx.list.filter((e) => e.path.endsWith('.' + name));
    const ids = [...new Set(hits.map((e) => e.signalId))];
    if (ids.length === 1) { return { ...hits[0], sel: r.sel.slice(k) }; }
    if (ids.length > 1) { throw new Error(`ambiguous signal ${name}: ${hits.slice(0, 3).map((e) => e.path).join(', ')}${hits.length > 3 ? ', ...' : ''}`); }
  }
  throw new Error(`unknown signal ${r.path}`);
}

// ---- derived signals ----
// def: {id, key, expr, name, program, operands, width, signed, pending, count, ms}.
// The result lives on the first operand's worker; operands on other workers
// are walked there (in parallel) and handed over as store files. Definitions
// are keyed on the compiled program plus resolved operand ids, never on the
// text, so `a & &b` and `a && b` (or a rebound name) can't share an id.
let nextDerived = DERIVED_BASE;
const derived = new Map();
const derivedByKey = new Map();
const derivedByName = new Map();
const DERIVE_DEADLINE_MS = 60000;

// -> {d, created}; throws on a bad expression or name.
function defineDerived(text, name) {
  const c = expr.compile(expr.parse(String(text)), resolveRef);
  if (name !== undefined && name !== null) { checkName(name); }
  const key = JSON.stringify([c.program, c.operands]);
  let d = derivedByKey.get(key), created = false;
  if (!d) {
    d = { id: nextDerived++, key, expr: String(text), name: null, program: c.program, operands: c.operands,
      width: c.width, signed: c.signed, refs: c.refs, pending: null };
    derived.set(d.id, d);
    derivedByKey.set(key, d);
    route.set(d.id, workerFor(c.operands[0]).i);
    widthOf.set(d.id, d.width);
    created = true;
  }
  if (name) { d.name = name; derivedByName.set(name, d); }
  return { d, created, refs: c.refs };
}
// A derive name must not hide a real signal (path or unique suffix).
function checkName(name) {
  if (typeof name !== 'string' || !/^[A-Za-z_][\w$]*$/.test(name)) { throw new Error(`bad derive name ${name}`); }
  const idx = getIndex();
  if (idx.byPath.has(name) || idx.list.some((e) => e.path.endsWith('.' + name))) { throw new Error(`name ${name} already names a signal`); }
}
function dropDerived(d) {
  derived.delete(d.id);
  if (derivedByKey.get(d.key) === d) { derivedByKey.delete(d.key); }
  if (d.name && derivedByName.get(d.name) === d) { derivedByName.delete(d.name); }
  const w = workerFor(d.id);
  if (w.state.cached.includes(d.id)) { runTask(w, { op: 'free', signalIds: [d.id] }).catch(() => {}); }
}

// opts.deadlineAt (performance.now() ms): a searchAll's budget for a derived signal only it uses.
function ensureDerived(ids, force = false, opts = {}) {
  const waits = [];
  for (const id of ids) {
    const d = derived.get(id);
    if (!d) { continue; }
    if (d.pending) { waits.push(d.pending); continue; }
    if (!force && workerFor(id).state.cached.includes(id)) { continue; }
    d.pending = materialize(d, opts).finally(() => { d.pending = null; });
    waits.push(d.pending);
  }
  return waits.length ? Promise.all(waits) : null;
}

async function materialize(d, { deadlineAt } = {}) {
  const t0 = performance.now();
  const ep = epoch;
  const live = () => { if (epoch !== ep || derived.get(d.id) !== d) { throw new Error('file reopened'); } };
  const nested = ensureDerived(d.operands.filter((id) => derived.has(id)));
  if (nested) { await nested; }
  live();
  const split = splitWalks({}, d.operands.filter((id) => !derived.has(id)));
  if (split) { await split; }
  live();
  const R = workerFor(d.id);
  const local = d.operands.filter((id) => workerFor(id) === R);
  const groups = new Map();
  for (const id of d.operands) {
    const w = workerFor(id);
    if (w !== R) { if (!groups.has(w)) { groups.set(w, []); } groups.get(w).push(id); }
  }
  const paths = new Map();
  for (const ids of groups.values()) { for (const id of ids) { paths.set(id, tmpPath(`d${d.id}-${id}`)); } }
  try {
    const loads = [];
    if (local.length) { loads.push(runTask(R, { op: 'load', signalIds: local })); }
    for (const [w, ids] of groups) { loads.push(runTask(w, { op: 'export', signalIds: ids, paths: ids.map((id) => paths.get(id)) })); }
    const lr = await Promise.all(loads);
    live();
    const t1 = performance.now();
    const left = deadlineAt === undefined ? DERIVE_DEADLINE_MS : Math.min(DERIVE_DEADLINE_MS, deadlineAt - t1);
    if (left <= 0) { throw new Error('search budget used up'); }
    const r = await runTask(R, { op: 'derive', signalId: d.id, program: d.program, deadlineMs: left,
      operands: d.operands.map((id) => (paths.has(id) ? { id, path: paths.get(id) } : { id })) });
    if (derived.get(d.id) !== d) {  // dropped meanwhile (its search ended): don't leave the result stored
      runTask(R, { op: 'free', signalIds: [d.id] }).catch(() => {});
      throw new Error('derived signal dropped');
    }
    Object.assign(d, { count: r.count, xz: !!r.xz, steps: r.steps, ms: performance.now() - t0, loadMs: t1 - t0, mergeMs: r.ms,
      walks: lr.flat().filter((e) => e && !e.cached).length });
    return r;
  } finally {
    for (const f of paths.values()) { fs.rmSync(f, { force: true }); }
  }
}

function derivedIdsOf(req) {
  const ids = [...(req.signals || []).map((s) => s.signalId), ...(req.signalIds || []), ...(req.signalId !== undefined ? [req.signalId] : [])];
  return ids.filter((id) => derived.has(id));
}

// ---- searchAll ----
const MAX_SEARCH_MS = 60000;
let activeSearch = null;  // one searchAll at a time: a new one cancels the old
// `value` -> MSB-first pattern. A string of only 0/1/x/z/? is binary (so "10"
// is 2'b10); anything else is a literal: 32'h12xx, 'd5, or a plain decimal
// like 12 (32 bits).
// With wildcard: '?' (strict) only ? is a wildcard and x/z in the value are literal;
// the pattern then starts with '!' for the addon (not counted in its width).
function strictWildcard(req) {
  if (req.wildcard === undefined || req.wildcard === null) { return false; }
  if (req.wildcard !== '?') { throw new Error(`bad wildcard ${req.wildcard} (only '?')`); }
  return true;
}
function toPattern(value, strict) {
  const v = String(value).replace(/_/g, '');
  if (/'/.test(v) || /^\d+$/.test(v) && !/^[01xX]+$/.test(v)) { const b = expr.literalBits(v); return strict ? '!' + b : b.replace(/z/g, 'x'); }
  if (!/^[01xXzZ?]+$/.test(v)) { throw new Error(`bad search value ${value}`); }
  return strict ? '!' + v.toLowerCase() : v.toLowerCase().replace(/\?/g, 'x');
}
const patternWidth = (p) => p.length - (p[0] === '!' ? 1 : 0);
// Glob with * and ? in O(len(glob) * len(name)), no regex backtracking.
function globMatch(g, s) {
  let i = 0, j = 0, star = -1, mark = 0;
  while (j < s.length) {
    if (i < g.length && (g[i] === '?' || g[i] === s[j])) { i++; j++; }
    else if (i < g.length && g[i] === '*') { star = i++; mark = j; }
    else if (star >= 0) { i = star + 1; j = ++mark; }
    else { return false; }
  }
  while (i < g.length && g[i] === '*') { i++; }
  return i === g.length;
}

// `fixed` operands of a searchAll expr: loaded once on their owner without evicting anything,
// and copied only to workers whose store has room for them (a copy must not evict the viewer's
// signals: verify V4). The primary (fixed[0]'s owner) gets every other fixed operand; candidates
// of workers that don't hold them all are moved to it. -> {copies, temps, holders}: what to free
// afterwards, and the workers that can evaluate. Stops early once the search is cancelled.
async function spreadFixed(req, fixed, targets) {
  const copies = [], temps = [];
  const primary = workerFor(fixed[0]);
  const ws = [...new Set([...targets, primary])];
  const has = new Map(ws.map((w) => [w, new Set()]));
  try {
  for (const id of fixed) {
    if (req.cancelled) { break; }
    const owner = workerFor(id);
    const had = owner.state.cached.includes(id);
    const [info] = await runTask(owner, { op: 'loadTemp', signalIds: [id] });
    if (!had) { temps.push({ w: owner, id }); }
    if (info.error) { throw new Error(info.error); }
    if (has.has(owner)) { has.get(owner).add(id); }
    for (const w of ws) {
      if (w === owner || req.cancelled) { continue; }
      const room = (w.state.limit || 0) - (w.state.bytes || 0);
      if (w !== primary && room < info.bytes * 1.05 + 1e6) { continue; }
      const p = tmpPath(`f${id}`);
      try {
        await runTask(owner, { op: 'export', signalIds: [id], paths: [p] });
        await runTask(w, { op: 'adopt', signalId: id, paths: [p] });
        copies.push({ w, id });
        has.get(w).add(id);
      } finally { fs.rmSync(p, { force: true }); }
    }
  }
  } catch (e) { freeAll([...copies, ...temps]); throw e; }
  const holders = new Set(ws.filter((w) => fixed.every((id) => has.get(w).has(id))));
  return { copies, temps, holders, primary };
}
const freeAll = (list) => { for (const { w, id } of list) { runTask(workers[w.i] || w, { op: 'free', signalIds: [id] }).catch(() => {}); } };

// ---- search index warm-up (opt-in) ----
// `open {file, warm: true}` (or `warm {on: true}`) walks the file's BitVector
// signals that aren't indexed yet, in the background on at most 2 workers,
// into deflated store files (.vvz) under <index root>/<key>/ (0700; see indexRoot; key =
// hash of the file format, the dump's real path, size and mtime, so a rewritten
// dump gets a fresh index).
// Each walk is one background task: it yields to interactive work (SIGUSR2)
// and is retried later, and it goes straight to the file, never into the LRU
// store; the worker's memory guard applies. The index stops growing at
// FSDB_INDEX_MB (default 2048). searchAll reads indexed candidates from their
// files instead of the reader. Index dirs unused for 7 days are deleted.
// Where: node-local /tmp/<user>-cmux-helper/index (0700, ours, not a symlink),
// not the helper dir, which can be the NFS home with its quota; the helper dir
// only if /tmp is unusable. FSDB_INDEX_DIR overrides. All key dirs together
// stay under FSDB_INDEX_TOTAL_MB (default 4096): at open, the least recently
// used other keys are deleted until they fit.
const INDEX_TOTAL_BYTES = arg('--index-total-mb', 'FSDB_INDEX_TOTAL_MB', 4096) * 1e6;
const INDEX_BYTES = Math.min(INDEX_TOTAL_BYTES, arg('--index-mb', 'FSDB_INDEX_MB', 2048) * 1e6);
// Re-validated at every open (a /tmp dir can be removed and recreated by
// someone else while we run); the sweep and the LRU only delete key-named dirs.
const KEY_NAME = /^[0-9a-f]{16}$/;
function indexRoot() {
  let user = String(process.getuid());
  try { user = require('node:os').userInfo().username.replace(/[^A-Za-z0-9._-]/g, '_') || user; } catch (e) { /* uid */ }
  const tries = process.env.FSDB_INDEX_DIR
    ? [[process.env.FSDB_INDEX_DIR]]  // an override: only it is made private, not its parent
    : [[path.join('/tmp', `${user}-cmux-helper`), path.join('/tmp', `${user}-cmux-helper`, 'index')]];
  tries.push([path.join(__dirname, 'index')]);
  for (const dirs of tries) {
    try {
      for (const d of dirs) { privateDir(d); }
      const dir = dirs[dirs.length - 1];
      fs.accessSync(dir, fs.constants.W_OK);
      return dir;
    } catch (e) { /* next */ }
  }
  throw new Error('no usable index directory');
}
function dirBytes(d) {
  let n = 0;
  for (const name of fs.readdirSync(d)) { try { const st = fs.lstatSync(path.join(d, name)); if (st.isFile()) { n += st.size; } } catch (e) { /* racing */ } }
  return n;
}
// Least recently used first (a key dir's mtime is touched at every open).
function capIndexRoot(root, keep) {
  const dirs = [];
  for (const name of fs.readdirSync(root)) {
    const d = path.join(root, name);
    try {
      const st = fs.lstatSync(d);
      if (!KEY_NAME.test(name) || !st.isDirectory() || st.uid !== process.getuid()) { continue; }
      dirs.push({ d, name, mtime: st.mtimeMs, bytes: dirBytes(d) });
    } catch (e) { /* racing */ }
  }
  let total = dirs.reduce((n, x) => n + x.bytes, 0);
  dirs.sort((x, y) => x.mtime - y.mtime);
  for (const x of dirs) {
    if (total <= INDEX_TOTAL_BYTES) { break; }
    if (x.name === keep) { continue; }
    fs.rmSync(x.d, { recursive: true, force: true });
    total -= x.bytes;
  }
}
const WARM_WORKERS = 2;
const INDEX_FORMAT = 'vvz1-normalized';  // part of the index key: a change of what files hold starts a new index
const warm = { on: false, epoch: -1, dir: null, files: new Map(), bytes: 0, rawBytes: 0, todo: [], failed: new Map(), inflight: 0, gen: 0,
  startedAt: 0, doneAt: 0, stopped: null, yields: 0 };

function privateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.uid !== process.getuid()) { throw new Error(`${dir} is not ours`); }
  if (st.mode & 0o077) { fs.chmodSync(dir, 0o700); }
}
function openIndex(file) {
  Object.assign(warm, { on: false, epoch, dir: null, files: new Map(), bytes: 0, rawBytes: 0, todo: [], failed: new Map(), startedAt: 0, doneAt: 0, stopped: null, yields: 0 });
  try {
    const root = indexRoot();
    const st = fs.statSync(file);
    const key = crypto.createHash('sha1').update(`${INDEX_FORMAT}\0${fs.realpathSync(file)}\0${st.dev}\0${st.ino}\0${st.size}\0${st.mtimeMs}`).digest('hex').slice(0, 16);
    for (const name of fs.readdirSync(root)) {  // sweep old indexes
      const d = path.join(root, name);
      if (name !== key && KEY_NAME.test(name) && fs.lstatSync(d).mtimeMs < Date.now() - 7 * 86400e3) { fs.rmSync(d, { recursive: true, force: true }); }
    }
    capIndexRoot(root, key);
    warm.dir = path.join(root, key);
    if (!fs.existsSync(warm.dir)) { return; }
    privateDir(warm.dir);
    fs.utimesSync(warm.dir, new Date(), new Date());
    const man = readManifest(warm.dir);
    for (const name of fs.readdirSync(warm.dir)) {
      const m = /^(\d+)\.vvz$/.exec(name), f = path.join(warm.dir, name);
      if (name === MANIFEST || name === KINDS_FILE || name === ALIASES_FILE) { continue; }
      if (!m) {  // leftover temp files; another live helper's fresh ones (< 1 min) are left alone
        try { if (!/\.tmp$/.test(name) || fs.lstatSync(f).mtimeMs < Date.now() - 60e3) { fs.rmSync(f, { force: true }); } } catch (e) { /* gone */ }
        continue;
      }
      const st = fs.lstatSync(f);
      const e = { path: f, bytes: st.size };
      const h = man[m[1]];  // trusted only while the file is unchanged, and only if it is one the worker would accept
      if (st.isFile() && st.nlink === 1 && st.uid === process.geteuid() && validEntry(h) && h[3] === st.size && h[4] === st.mtimeMs && h[5] === st.ino && h[6] === st.ctimeMs) {
        e.hdr = { count: h[0], bits: h[1], xz: h[2] === 1 }; setStamp(e, st);
      }
      warm.files.set(Number(m[1]), e);
      warm.bytes += st.size;
    }
    if ([...warm.files.values()].some((x) => x.hdr === undefined)) { scheduleManifest(); }  // headers of files from older helpers: read in the background
  } catch (e) {
    warm.dir = null;
    send({ id: 0, error: 'search index unavailable: ' + e.message });
  }
}
function startWarm() {
  if (!warm.dir || warm.epoch !== epoch) { throw new Error('no search index for this file'); }
  privateDir(path.dirname(warm.dir));
  privateDir(warm.dir);
  const seen = new Set();
  warm.todo = [];
  for (const v of getIndex().list) {
    if (!bitVector(v) || seen.has(v.signalId)) { continue; }
    seen.add(v.signalId);
    if (!warm.files.has(v.signalId) && !warm.failed.has(v.signalId)) { warm.todo.push(v.signalId); }
  }
  Object.assign(warm, { on: true, startedAt: performance.now(), doneAt: 0, stopped: null });
  pumpWarm();
}
function pumpWarm() {
  if (!warm.on || warm.epoch !== epoch) { return; }
  for (let k = 0; k < Math.min(WARM_WORKERS, workers.length); k++) {
    const w = workers[k];
    if (w.warming) { continue; }
    if (warm.bytes >= INDEX_BYTES) { warm.on = false; warm.stopped = 'index size limit'; return; }
    const id = warm.todo.shift();
    if (id === undefined) { if (!warm.inflight) { warm.on = false; warm.doneAt = performance.now(); } return; }
    w.warming = true; warm.inflight++;
    const task = enqueue(w, { op: 'warm', signalIds: [id], dir: warm.dir, bg: true });
    task.done = (m) => {
      w.warming = false; warm.inflight--;
      let delay = 0;
      if (task.epoch !== epoch) { return; }
      if (m.error) {
        if (/exited|reopened|memory limit/.test(m.error)) { warm.todo.push(id); delay = 1000; } else { warm.failed.set(id, m.error); }
      } else {
        for (const r of m.result) {
          if (r.yielded) { warm.todo.unshift(r.signalId); warm.yields++; delay = 500; continue; }  // interactive work: back off
          if (r.error) { warm.failed.set(r.signalId, r.error); continue; }
          const f = path.join(warm.dir, `${r.signalId}.vvz`);
          warm.files.set(r.signalId, { path: f, bytes: r.bytes });
          warm.bytes += r.bytes;
          warm.rawBytes += r.rawBytes || 0;
        }
        scheduleManifest();
      }
      if (delay) { setTimeout(pumpWarm, delay); } else { setImmediate(pumpWarm); }
    };
  }
}
// ---- persistent store cache (WINDOWING.md "Persistent store cache") ----
// Every signal walked into a store is written to the dump's index dir in the
// background (same .vvz files and key as the search index: format, real path,
// device, inode, size, mtime), and later loads in this or any later helper read
// the file instead of walking: spike_rvfi 71 ms instead of 1,589 ms, clk 10 ms
// instead of 256 ms. FSDB_STORE_CACHE=0 turns it off; FSDB_INDEX_MB caps it.
const STORE_CACHE = process.env.FSDB_STORE_CACHE !== '0';
const CACHE_FILE_OPS = new Set(['window', 'valueAt', 'lastChange', 'digest', 'edge', 'search', 'load', 'bgLoad', 'export', 'derive', 'searchExpr']);
const persisting = new Set();
function persistLater(w, ids) {
  if (!STORE_CACHE || !warm.dir || warm.epoch !== epoch) { return; }
  const todo = ids.filter((id) => id < DERIVED_BASE && !warm.files.has(id) && !persisting.has(id));
  if (!todo.length || warm.bytes >= INDEX_BYTES) { return; }
  try { privateDir(path.dirname(warm.dir)); privateDir(warm.dir); } catch (e) { return; }  // root re-checked: never write through a swapped-in link
  for (const id of todo) { persisting.add(id); }
  const gen = warm.gen;
  const task = enqueue(w, { op: 'persist', signalIds: todo, dir: warm.dir, bg: true });
  task.done = (m) => {
    for (const id of todo) { persisting.delete(id); }
    if (task.epoch !== epoch || warm.gen !== gen || m.error) { return; }  // (L6: written before a warm {clear})
    const again = m.result.filter((r) => r.yielded).map((r) => r.signalId);
    if (again.length) {  // yielded to interactive work: write them a little later (still background)
      const ep = epoch;
      setTimeout(() => { if (epoch === ep) { persistLater(workers[w.i], again); } }, 300);
    }
    for (const r of m.result) {
      if (r.error) { continue; }
      const e = { path: path.join(warm.dir, `${r.signalId}.vvz`), bytes: r.bytes };
      if (r.count !== undefined && r.stamp) { e.hdr = { count: r.count, bits: r.bits, xz: !!r.xz }; e.stamp = r.stamp; }  // no header read needed
      warm.files.set(r.signalId, e);
      warm.bytes += r.bytes;
      warm.rawBytes += r.rawBytes || 0;
    }
    scheduleManifest();
  };
}
const indexFor = (ids) => {
  if (warm.epoch !== epoch || !warm.files.size) { return null; }
  const o = {};
  for (const id of ids) { const f = warm.files.get(id); if (f) { o[id] = f.path; } }
  return o;
};
const warmStats = () => ({ on: warm.on, dir: warm.dir, indexed: warm.files.size, bytes: warm.bytes, rawBytes: warm.rawBytes, todo: warm.todo.length,
  inflight: warm.inflight, failed: warm.failed.size, yields: warm.yields, stopped: warm.stopped,
  ms: warm.startedAt ? +((warm.doneAt || performance.now()) - warm.startedAt).toFixed(0) : 0 });

// ---- hierarchy (in this process, as v1) ----
let openFile = null;
let lastOpen = null;  // {ident, result} of the open file, for reopen-unchanged
function fileIdent(file) {
  const real = fs.realpathSync(file), st = fs.statSync(real);
  return [real, st.dev, st.ino, st.size, st.mtimeMs, st.ctimeMs].join('\0');
}
function stripRange(name, width, msb, lsb) {
  const suffix = `[${msb}:${lsb}]`;
  return width > 1 && name.endsWith(suffix) ? name.slice(0, -suffix.length) : name;
}

const inflight = new Map();  // id -> req (for cancel)

// Ids must be signals of the open file (or live derived signals); the reader
// misbehaves on ids it doesn't have.
function checkIds(ids) {
  if (!Array.isArray(ids)) { throw new Error('signal ids must be an array'); }
  const idx = getIndex();
  for (const id of ids) {
    if (!Number.isInteger(id) || id < 0 || (id >= DERIVED_BASE ? !derived.has(id) : !idx.byId.has(id))) { throw new Error(`unknown signal #${id}`); }
  }
  return ids;
}
const textCheck = require('./text.js').check;
function checkTime(name, t) {
  if (typeof t !== 'number' || !Number.isFinite(t) || t < 0 || t > 1.8e19) { throw new Error(`bad ${name}: ${t}`); }
  return Math.floor(t);
}
const NO_FILE_OK = new Set(['open', 'stats', 'close']);

async function runSearchAll(req) {
  const t = checkTime('t', Number(req.t || 0)), dir = req.dir < 0 ? -1 : 1;
  const limit = Math.max(1, Math.min(10000, Math.floor(Number(req.limit)) || 50));
  const budgetMs = Math.min(MAX_SEARCH_MS, Math.max(1, Number(req.budgetMs) || 30000));
  const started = performance.now();
  const remaining = () => Math.max(1, budgetMs - (performance.now() - started));
  if (req.expr !== undefined && !/(^|[^\w$])\$(?![\w$])/.test(req.expr)) {
    // No `$`: one temporary derived signal, true = any bit 1. Its materialization gets the
    // search's budget (a derive it creates is stopped at the deadline; a shared existing one is
    // only no longer waited for), and the reply has the `$` path's shape.
    const { d, created } = defineDerived(`|(${req.expr})`);
    const deadlineAt = started + budgetMs;
    const overBudget = (e) => /took longer than|budget used up|derived signal dropped/.test(String(e && e.message));
    try {
      let r = null;
      for (let attempt = 0; attempt < 3 && !req.cancelled; attempt++) {
        const p = ensureDerived([d.id], attempt > 0, created ? { deadlineAt } : {});
        if (p) {
          p.catch(() => {});  // may settle after we stop waiting
          let timer;
          const out = await Promise.race([p.then(() => 'ok', (e) => e), new Promise((res) => { timer = setTimeout(() => res('budget'), remaining()); })]);
          clearTimeout(timer);
          if (out === 'budget' || (out instanceof Error && overBudget(out))) { break; }
          if (out instanceof Error) { throw out; }
        }
        if (req.cancelled || performance.now() - started > budgetMs) { break; }
        try { r = await single(req, 'search', d.id, { t, dir, value: '1' }); break; } catch (e) { if (!/DERIVED_EVICTED/.test(e.message)) { throw e; } }
      }
      const timedOut = !r && !req.cancelled;
      const found = r && r.t !== null ? 1 : 0;
      return { matches: found ? [{ signalId: d.id, path: req.expr, t: r.t }] : [], found, searched: r ? 1 : 0, walked: 0, indexed: 0,
        errors: 0, unreadable: [], retried: 0, total: 1, timedOut, yields: 0, firstMatchMs: found ? +(performance.now() - started).toFixed(1) : null,
        complete: !!r, incomplete: r ? null : { timedOut, cancelled: !!req.cancelled, unsearched: 1, errors: 0, failedSignals: [] } };
    } finally {
      if (created) { dropDerived(d); }
    }
  }
  const idx = getIndex();
  const glob = req.names ? String(req.names).replace(/\*+/g, '*') : null;
  const onPath = glob && glob.includes('.');
  const seen = new Set(), cands = [];
  for (const v of idx.list) {
    if (!bitVector(v) || seen.has(v.signalId)) { continue; }
    if (req.scope && v.path !== req.scope && !v.path.startsWith(req.scope + '.')) { continue; }
    if (glob && !globMatch(glob, onPath ? v.path : v.path.slice(v.path.lastIndexOf('.') + 1))) { continue; }
    seen.add(v.signalId);
    cands.push(v);
  }
  let pattern = null, programs = null, fixed = [];
  if (req.expr !== undefined) {
    const ast = expr.parse(String(req.expr));
    programs = new Map();  // width -> compiled program for `$` of that width
    for (const v of cands) {
      if (!programs.has(v.width)) {
        try { programs.set(v.width, expr.asBool(expr.compile(ast, resolveRef, { width: v.width }))); } catch (e) { programs.set(v.width, e); }
      }
    }
    const ok = [...programs.values()].find((c) => !(c instanceof Error));
    if (!ok) { throw [...programs.values()][0] || new Error('no candidates'); }
    fixed = ok.operands.slice(1);
    if (fixed.some((id) => derived.has(id))) { throw new Error('searchAll expr may not use derived signals'); }
  } else {
    pattern = toPattern(req.value, strictWildcard(req));
    for (let k = cands.length - 1; k >= 0; k--) { if (cands[k].width !== patternWidth(pattern)) { cands.splice(k, 1); } }
  }
  const pathOf = new Map(cands.map((v) => [v.signalId, v.path]));
  if (req.listCandidates) { return { candidates: cands.map((v) => ({ signalId: v.signalId, path: v.path, width: v.width })) }; }
  // Per worker: signals it already holds first, then indexed, then cold ones, in chunks.
  const perWorker = new Map();
  for (const v of cands) {
    const w = workerFor(v.signalId);
    if (!perWorker.has(w)) { perWorker.set(w, []); }
    perWorker.get(w).push(v.signalId);
  }
  let copies = [];
  if (fixed.length) {
    const sp = await spreadFixed(req, fixed, [...perWorker.keys()]);
    copies = [...sp.copies, ...sp.temps];
    if (req.cancelled) { freeAll(copies); return {}; }
    for (const [w, ids] of [...perWorker]) {  // no room for the operand there: its candidates go to the primary
      if (sp.holders.has(w)) { continue; }
      perWorker.delete(w);
      if (!perWorker.has(sp.primary)) { perWorker.set(sp.primary, []); }
      perWorker.get(sp.primary).push(...ids);
    }
  }
  const rank = (w, id) => (w.state.cached.includes(id) ? 0 : warm.files.has(id) && warm.epoch === epoch ? 1 : 2);
  // Stored and indexed candidates go to their own worker. Cold value scans keep
  // nothing, so any worker can do them: they wait in one pool, in small chunks,
  // and each worker takes the next when it finishes one (no worker idles while
  // another still has a queue; this dump's heavy signals made one worker's
  // share take 4x the others').
  const chunks = [], coldPool = [];
  for (const [w, ids] of perWorker) {
    ids.sort((a, b) => rank(w, a) - rank(w, b));
    const own = pattern !== null ? ids.filter((id) => rank(w, id) < 2) : ids;
    for (let k = 0; k < own.length; k += SEARCH_CHUNK) { chunks.push([w, own.slice(k, k + SEARCH_CHUNK)]); }
    if (pattern !== null) { coldPool.push(...ids.filter((id) => rank(w, id) === 2)); }
  }
  return new Promise((resolve) => {
    const matches = [], unreadable = [], failed = [];
    let searched = 0, walked = 0, indexed = 0, errors = 0, left = 0, finished = false, firstMatchMs = null, yields = 0;
    req.parts = [];
    const retry = new Map();
    let retried = false;
    const finish = (timedOut) => {
      if (finished) { return; }
      finished = true;
      clearTimeout(timer);
      for (const { w, task } of req.parts) { dequeue(w, task); }
      freeAll(copies);
      matches.sort((a, b) => (a.t - b.t) * dir || a.signalId - b.signalId);  // ties by id: deterministic
      const unsearched = cands.length - searched;
      const complete = !timedOut && !req.cancelled && errors === 0 && unsearched === 0;
      resolve({ matches: matches.slice(0, limit), found: matches.length, searched, walked, indexed, errors, unreadable,
        retried: [...retry.values()].reduce((n, a) => n + a.length, 0), total: cands.length, timedOut, yields,
        firstMatchMs: firstMatchMs === null ? null : +firstMatchMs.toFixed(1), complete,
        incomplete: complete ? null : { timedOut, cancelled: !!req.cancelled, unsearched, errors, failedSignals: failed.slice(0, 50) } });
    };
    req.onCancel = () => finish(false);
    // Once `limit` matches are known, later scans stop at the limit-th nearest one.
    const bound = () => {
      if (matches.length < limit) { return { bound: dir > 0 ? 1.8e19 : 0 }; }
      const ts = matches.map((m) => m.t).sort((a, b) => (a - b) * dir);
      return { bound: ts[limit - 1] };
    };
    const timer = setTimeout(() => finish(true), budgetMs);
    // Some signals read as 0 bits until other signals have been loaded in the
    // same process (aliases, it seems): those get one retry after the pass.
    const pullCold = (w) => {
      if (finished || !coldPool.length) { return false; }
      runChunk(w, coldPool.splice(0, COLD_CHUNK), true);
      return true;
    };
    const runChunk = (w0, ids, fromPool = false, crashed = 0) => {
      const w = workers[w0.i] || workers[0];  // the live worker at that index (w0 may have been replaced)
      left++;
      const task = pattern !== null
        ? { op: 'searchScan', signalIds: ids, t, dir, pattern, req, bg: true }
        : { op: 'searchExpr', signalIds: ids, t, dir, fixed, req, bg: true,
          programs: ids.map((id) => { const c = programs.get(widthOf.get(id)); return c instanceof Error || !c ? null : c.program; }) };
      task.prepare = () => ({ ...(pattern !== null ? bound() : {}), deadlineMs: remaining(), index: pattern !== null ? indexFor(ids) : null });
      enqueue(w, task);
      req.parts.push({ w, task });
      task.done = (m) => {
        left--;
        if (finished) { return; }
        const found = [], again = [];
        if (m.error && /exited/.test(m.error) && !crashed) {  // its worker died: run the chunk once more on the replacement
          runChunk(w, ids, fromPool, 1);
          return;
        }
        if (m.error) { errors += ids.length; failed.push(...ids.map((id) => ({ signalId: id, path: pathOf.get(id), error: m.error }))); } else {
          for (const r of m.result) {
            if (r.yielded) { again.push(r.signalId); continue; }
            if (r.error && !retried && /0 bits/.test(r.error)) {
              if (!retry.has(w.i)) { retry.set(w.i, []); }  // by index: the worker may be replaced by then
              retry.get(w.i).push(r.signalId);
              continue;
            }
            searched++;
            if (r.walked) { walked++; }
            if (r.indexed) { indexed++; }
            if (r.error) { errors++; if (unreadable.length < 50) { unreadable.push({ signalId: r.signalId, path: pathOf.get(r.signalId), error: r.error }); } }
            if (r.t !== null && r.t !== undefined) { found.push({ signalId: r.signalId, path: pathOf.get(r.signalId), t: r.t }); }
          }
        }
        if (found.length) {
          if (firstMatchMs === null) { firstMatchMs = performance.now() - started; }
          matches.push(...found);
          if (!req.cancelled) { send({ id: req.id, partial: true, result: { matches: found, searched, total: cands.length } }); }
        }
        if (again.length) { yields++; runChunk(w, again, fromPool, crashed); }  // yielded to interactive work (or hit the deadline): queue the rest again
        else if (fromPool) { pullCold(w); }
        if (left === 0 && !coldPool.length) {
          if (!retried && retry.size) {
            retried = true;
            for (const [ri, rids] of retry) { for (let k = 0; k < rids.length; k += SEARCH_CHUNK) { runChunk(workers[ri % workers.length], rids.slice(k, k + SEARCH_CHUNK)); } }
            return;
          }
          finish(false);
        }
      };
    };
    for (const [w, ids] of chunks) { runChunk(w, ids); }
    for (const w of workers) { pullCold(w); }  // one pool chunk in flight per worker
    if (!chunks.length && !left) { finish(false); }
  });
}

// ---- whole-signal counts (count op, hybrid mode) ----
function sizeEntry(signalId, count, bits, xz, source) { return { signalId, count, bits, xz: !!xz, bytes: count * (8 + bits), source }; }
// {count, bits, xz} from a .vvz header ("VVZ1", u32 bits, u64 n, u8 hasXz, u64 raw,
// u64 zlen), with readIndexFile's header checks; cached on the entry. A file
// that fails them is null for good; an I/O error isn't cached (retried next time).
function parseHeader(b, st) {
  if (b.toString('latin1', 0, 4) !== 'VVZ1') { return null; }
  const bits = b.readUInt32LE(4), n = b.readBigUInt64LE(8), xz = b[16], raw = b.readBigUInt64LE(17), zlen = b.readBigUInt64LE(25);
  const per = 8n + BigInt((bits + 7) >> 3) * (xz ? 2n : 1n);
  const ok = bits >= 1 && bits <= (1 << 20) && xz <= 1 && BigInt(st.size) === 33n + zlen && raw === n * per && raw <= 1032n * zlen + 1024n && n <= BigInt(Number.MAX_SAFE_INTEGER);
  return ok ? { count: Number(n), bits, xz: xz === 1 } : null;
}
function fileHeader(f) {
  if (f.hdr !== undefined) { return f.hdr; }
  let fd = -1, hdr;
  try {
    fd = fs.openSync(f.path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const st = fs.fstatSync(fd);
    const b = Buffer.alloc(33);
    hdr = null;
    if (st.isFile() && st.uid === process.geteuid() && st.nlink === 1 && fs.readSync(fd, b, 0, 33, 0) === 33) { hdr = parseHeader(b, st); }
    if (hdr) { setStamp(f, st); }
  } catch (e) { hdr = undefined; }
  if (fd >= 0) { try { fs.closeSync(fd); } catch (e) { /* closed */ } }
  if (hdr !== undefined) { f.hdr = hdr; }
  return hdr || null;
}
// Header manifest: <key dir>/manifest.json {v: 2, entries: {id: [count, bits, xz, size, mtimeMs,
// ino, ctimeMs]}}, so count can answer file-only signals right after open without reading 200
// headers on the request path (26.9 ms -> 0). An entry is used only while its file's stamp
// (size, mtime, inode, ctime) matches and the file is one the worker would adopt (regular,
// ours, nlink 1). Written (tmp + rename) 1.5 s after files change, the headers it lacks read
// one by one with async I/O off the request path; flushed at open, close and shutdown.
// v1 manifests (383ddd6) are ignored and rewritten.
const MANIFEST = 'manifest.json';
// The file identity an entry is trusted for: size, mtime, inode, ctime (a rename-replace gets a
// new inode; utimes can't set ctime).
const setStamp = (f, st) => { f.stamp = [st.size, st.mtimeMs, st.ino, st.ctimeMs]; };
const validEntry = (h) => Array.isArray(h) && h.length === 7 && Number.isSafeInteger(h[0]) && h[0] >= 0
  && Number.isInteger(h[1]) && h[1] >= 1 && h[1] <= (1 << 20) && (h[2] === 0 || h[2] === 1);
function readManifest(dir) {
  try {
    const fd = fs.openSync(path.join(dir, MANIFEST), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    let text;
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== process.geteuid() || st.nlink !== 1 || st.size > 64e6) { return {}; }
      text = fs.readFileSync(fd, 'utf8');
    } finally { fs.closeSync(fd); }
    const m = JSON.parse(text);
    return m && m.v === 2 && m.entries && typeof m.entries === 'object' ? m.entries : {};
  } catch (e) { return {}; }
}
function writeManifest() {
  if (!warm.dir || warm.epoch !== epoch) { return; }
  const entries = {};
  for (const [id, f] of warm.files) { if (f.hdr && f.stamp) { entries[id] = [f.hdr.count, f.hdr.bits, f.hdr.xz ? 1 : 0, ...f.stamp]; } }
  const dst = path.join(warm.dir, MANIFEST), tmp = path.join(warm.dir, `.manifest.${process.pid}.tmp`);
  try {
    privateDir(path.dirname(warm.dir)); privateDir(warm.dir);
    fs.rmSync(tmp, { force: true });
    const fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(fd, JSON.stringify({ v: 2, entries })); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, dst);
    manifestDirty = false;  // (L4: only once it is really written)
  } catch (e) { try { fs.rmSync(tmp, { force: true }); } catch (e2) { /* gone */ } }
}
let manifestTimer = null, manifestDirty = false;
function scheduleManifest() {
  if (!warm.dir) { return; }
  manifestDirty = true;
  if (manifestTimer) { return; }
  const ep = epoch, dir = warm.dir, gen = warm.gen;
  const live = () => epoch === ep && warm.dir === dir && warm.gen === gen;
  manifestTimer = setTimeout(async () => {
    manifestTimer = null;
    for (const f of [...warm.files.values()]) {
      if (!live()) { return; }
      if (f.hdr === undefined) { await fileHeaderAsync(f); }
    }
    if (live()) { writeManifest(); }
  }, 1500);
}
function flushManifest() {
  if (manifestTimer) { clearTimeout(manifestTimer); manifestTimer = null; }
  if (manifestDirty) { writeManifest(); }
}

// fileHeader's checks with async I/O, for the background manifest job.
async function fileHeaderAsync(f) {
  let fh = null, hdr;
  try {
    fh = await fs.promises.open(f.path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const st = await fh.stat();
    const b = Buffer.alloc(33);
    hdr = null;
    if (st.isFile() && st.uid === process.geteuid() && st.nlink === 1 && (await fh.read(b, 0, 33, 0)).bytesRead === 33) { hdr = parseHeader(b, st); }
    if (hdr && f.hdr === undefined) { setStamp(f, st); }  // (L9: stamp and header from the same read)
  } catch (e) { hdr = undefined; }
  if (fh) { try { await fh.close(); } catch (e) { /* closed */ } }
  if (hdr !== undefined && f.hdr === undefined) { f.hdr = hdr; }
}

function countOf(id) {
  const d = derived.get(id);
  if (d && d.count !== undefined && d.count !== null) { return sizeEntry(id, d.count, d.width, d.xz, 'derived'); }
  for (const w of workers) {
    const e = w.sizes && w.sizes.get(id);
    if (e) { return sizeEntry(id, e[1], e[2], e[3], 'store'); }
  }
  const f = STORE_CACHE && warm.epoch === epoch ? warm.files.get(id) : null;
  const h = f && fileHeader(f);
  return h ? sizeEntry(id, h.count, h.bits, h.xz, 'file') : null;
}

const handlers = {
  async open({ file, workers: n, warm: wantWarm, reload }) {
    if (typeof file !== 'string' || !file) { throw new Error('open needs a file'); }
    const want = Math.max(1, Math.min(MAX_WORKERS, n || DEFAULT_WORKERS));
    // Reopening the file that is already open, unchanged (same real path, device,
    // inode, size, mtime and ctime) and with the same pool keeps everything: the
    // workers' stores, derived signals, routes and the search index.
    let ident = null;
    try { ident = fileIdent(file); } catch (e) { /* missing: the real open below reports it */ }
    if (!reload && openFile && lastOpen && ident && ident === lastOpen.ident && want === workers.length) {
      if (wantWarm && !warm.on) { startWarm(); }
      return { ...lastOpen.result, index: warmStats(), reused: true };
    }
    flushManifest();  // the previous file's headers
    lastOpen = null;
    clearJobs();
    bgFailed.clear();
    persisting.clear();
    epoch++;
    hotStop();
    splitting.clear();
    widthOf.clear();
    index = null;
    derived.clear(); derivedByKey.clear(); derivedByName.clear();
    if (activeSearch) {  // ends with its terminal line {id, cancelled: true, reason: 'reopened'} (verify F1)
      const a = activeSearch; activeSearch = null;
      if (inflight.get(a.id) === a) { handlers.cancel({ target: a.id, reason: 'reopened' }); } else { a.cancelled = true; }
    }
    clearFloats('file reopened');
    if (want !== workers.length) { spawnPool(want); } else { route.clear(); rr = 0; }
    for (const w of workers) {
      const lost = [...w.queue, ...w.bgQueue]; w.queue = []; w.bgQueue = []; w.warming = false;
      w.state = { ...w.state, cached: [] };  // nothing may jump ahead of the reopen
      w.sizes = new Map();  // count: the old file's stores are gone
      failTasks(lost, 'file reopened');
    }
    // Workers open in parallel with the hierarchy read below; queued work waits behind it.
    const opens = workers.map((w) => runTask(w, { op: 'open', file, cacheBytes: storeShare(want), barrier: true }, true));
    if (openFile) { addon.unload(); openFile = null; }
    try {
      addon.openFsdb(file);
    } catch (e) {
      await Promise.allSettled(opens);
      throw e;
    }
    openFile = file;
    try { fileBytes = fs.statSync(file).size; } catch (e) { fileBytes = 0; }
    const metadata = { timeTableLoaded: false, scopeCount: 0, netlistIdCount: 0, signalIdCount: 0,
      timeTableCount: 0, timeEnd: 0, minTimeStep: 1, timeScale: 1, timeUnit: 'ns' };
    addon.readMetadata(
      (scopecount, varcount, timescale, timeunit) => Object.assign(metadata,
        { scopeCount: scopecount, netlistIdCount: varcount, timeScale: timescale, timeUnit: timeunit }),
      (chunksize, timeend) => Object.assign(metadata, { timeEnd: Number(timeend), timeTableLoaded: true }));
    timeEnd = metadata.timeEnd;
    const top = scopes.top();
    // The hierarchy index (paths, widths) is built now, while the workers open,
    // not by the first request (count's latency target; ~8-16 ms on this dump).
    try { getIndex(); } catch (e) { /* rebuilt on demand */ }
    const failed = (await Promise.allSettled(opens)).find((r) => r.status === 'rejected');
    if (failed) { addon.unload(); openFile = null; throw new Error('workers could not open the file: ' + failed.reason.message); }
    warm.inflight = 0;
    openIndex(file);
    resetLearned();
    startKinds(file);
    loadAliases();
    if (wantWarm) { startWarm(); }
    const result = { metadata, top, workers: want };
    if (ident) { lastOpen = { ident, result }; }
    return { ...result, index: warmStats() };
  },

  async children({ scopeOffsetIdx, scopePath }) {
    // The reader's arrays come as scopes holding their elements (tree.js); a scope that
    // other trees re-enter lists every member's children, each name once.
    return scopes.children(scopeOffsetIdx, scopePath,
      (name, type, encoding, varPath, netlistId, signalId, width, msb, lsb) =>
        { widthOf.set(signalId, width); return { name: stripRange(name, width, msb, lsb), type, encoding, netlistId, signalId, width, msb, lsb }; });
  },

  // Header {signals: [{signalId, exact, count, bytes, bucketBytes, cached, walkMs}]};
  // binary = per signal, deflated records then bucketBytes of u32 counts.
  async window(req) {
    const { signals, deflateCounts } = req;
    if (!Array.isArray(signals)) { throw new Error('window needs signals'); }
    const ids = checkIds(signals.map((s) => s && s.signalId));
    const t0 = checkTime('t0', req.t0), t1 = checkTime('t1', req.t1);
    if (t1 < t0) { throw new Error('window needs t1 >= t0'); }
    const buckets = Math.max(1, Math.min(MAX_BUCKETS, Math.floor(Number(req.buckets)) || 1));
    for (const s of signals) { if (s.width) { widthOf.set(s.signalId, s.width); } }
    const ranged = t1 > t0 && timeEnd > 0 && (t1 - t0) <= timeEnd * COLD_RANGE;
    // A signal whose load failed for good (unreadable, over the store cap) answers that error,
    // without loading it again; over the cap, ranged windows still read it cold.
    const failed = new Map(ids.filter((id) => bgFailed.has(id) && !derived.has(id) && !(ranged && /larger than/.test(bgFailed.get(id)))).map((id) => [id, { signalId: id, error: bgFailed.get(id) }]));
    // (a signal in the persistent store cache is read from its file instead: <= ~70 ms, and it stays)
    const cold = new Set(ranged ? ids.filter((id) => !failed.has(id) && isCold(id) && !(STORE_CACHE && warm.epoch === epoch && warm.files.has(id))) : []);
    const warmIds = [...new Set(ids.filter((id) => !cold.has(id) && !failed.has(id)))];
    const sp = prep(req, warmIds);
    // Signals that wait for nothing (no split walk, no derived rebuild) are asked for now,
    // not after the split walks: a 20-signal add waited for its wide signals' splits first.
    const later = sp ? new Set(warmIds.filter((id) => jobs.has(id) || derived.has(id))) : new Set();
    const now = warmIds.filter((id) => !later.has(id));
    const range = { t0, t1, buckets };
    const nowRes = now.length ? scatter(req, 'window', now, range, (m) => m.result, true) : null;
    // A failed split walk (e.g. an unreadable signal) is not the request's error: the regular
    // load below reports it for that signal only.
    const afterSplit = sp ? sp.catch((e) => { if (req.cancelled || /reopened|closed/.test(String(e && e.message))) { throw e; } }) : null;
    const laterRes = afterSplit ? afterSplit.then(() => {
      if (req.cancelled) { return []; }
      const ok = [...later].filter((id) => !bgFailed.has(id) || derived.has(id));  // failed for good while this waited
      for (const id of later) { if (!ok.includes(id)) { failed.set(id, { signalId: id, error: bgFailed.get(id) }); } }
      return ok.length ? scatter(req, 'window', ok, range, (m) => m.result, true) : [];
    }) : null;
    const [r1, r2, coldRes] = await Promise.all([nowRes || [], laterRes || [],
      cold.size ? rangedRead(req, [...cold], { t0, t1, buckets }) : []]);
    if (req.cancelled) { return {}; }
    const warmRes = [...r1, ...r2];
    const byId = new Map([...warmRes, ...coldRes, ...failed.values()].map((r) => [r.signalId, r]));
    for (const r of coldRes) { if (!r.error) { scheduleBgLoad(r.signalId); } }
    const res = ids.map((id) => byId.get(id));
    const head = [], bins = [];
    for (const r of res) {
      if (r.error) { head.push({ signalId: r.signalId, error: r.error, bytes: 0, bucketBytes: 0 }); continue; }
      const rec = asBuf(r.records);
      let cnt = asBuf(r.counts);
      if (cnt && deflateCounts) { cnt = zlib.deflateRawSync(cnt, { level: 1 }); }
      const sp = req.split && req.split.get(r.signalId);
      head.push({ signalId: r.signalId, exact: r.exact, count: r.count, bytes: rec.length, bucketBytes: cnt ? cnt.length : 0,
        cached: sp ? false : r.cached, walkMs: +(sp ? sp.ms : r.loadMs + r.walkMs).toFixed(1), ...(sp ? { split: sp.slices.length } : {}),
        ...(r.ranged ? { ranged: true } : {}), ...(r.warm ? { warm: true } : {}), ...(r.file ? { file: true } : {}), ...(r.total !== undefined && !r.ranged ? { total: r.total } : {}) });
      bins.push(rec);
      if (cnt) { bins.push(cnt); }
    }
    return { result: { signals: head }, bin: Buffer.concat(bins) };
  },

  // Stored (or derived) signals answer from the store; others with a cold
  // [t, t] read that walks and keeps nothing. -> {values, cold: how many were cold}
  async valueAt(req) {
    const t = checkTime('t', req.t);
    const ids = checkIds(req.signalIds);
    const cold = new Set(ids.filter(isCold));
    const warmIds = [...new Set(ids.filter((id) => !cold.has(id)))];
    const sp = prep(req, warmIds);
    if (sp) { await sp; }
    if (req.prev) {
      const [wv, cv] = await Promise.all([
        warmIds.length ? scatter(req, 'lastChange', warmIds, { t }, (m) => m.result) : [],
        cold.size ? coldNear(req, [...cold], t) : new Map()]);
      const byId = new Map([...warmIds.map((id, k) => [id, wv[k]]), ...cv]);
      return { values: ids.map((id) => byId.get(id).value), prev: ids.map((id) => byId.get(id).prev), cold: cold.size };
    }
    const [wv, cv] = await Promise.all([
      warmIds.length ? scatter(req, 'valueAt', warmIds, { t }, (m) => m.result) : [],
      cold.size ? coldTask(req, 'coldValueAt', [...cold], { t }, 'even') : []]);
    const byId = new Map([...warmIds.map((id, k) => [id, wv[k]]), ...[...cold].map((id, k) => [id, cv[k]])]);
    return { values: ids.map((id) => byId.get(id)), cold: cold.size };
  },

  async edge(req) {
    const t = checkTime('t', req.t);
    const sp = prep(req, checkIds([req.signalId])); if (sp) { await sp; }
    return single(req, 'edge', req.signalId, { t, dir: req.dir < 0 ? -1 : 1, kind: req.kind });
  },
  async search(req) {
    const t = checkTime('t', req.t);
    if (typeof req.value !== 'string' || !/^[01xXzZ?]*$/.test(req.value)) { throw new Error(`bad search value ${req.value}`); }
    const sp = prep(req, checkIds([req.signalId])); if (sp) { await sp; }
    // wildcard: '?' -> strict pattern: only ? matches anything, x and z are literal.
    return single(req, 'search', req.signalId, { t, dir: req.dir < 0 ? -1 : 1, value: (strictWildcard(req) ? '!' : '') + req.value });
  },

  // searchText {signalId, t, dir, inclusive?, format, pattern, caseSensitive?, alias?, budgetMs?}: the first
  // change from t (as search) whose value, formatted as the viewer formats it, matches the
  // pattern (WINDOWING.md "searchText"). -> {t, value, text, distinct, formatted} | {t: null}
  // | {t: null, incomplete: {timedOut: true, at}}
  async searchText(req) {
    const t = checkTime('t', req.t);
    textCheck(req);
    const sp = prep(req, checkIds([req.signalId])); if (sp) { await sp; }
    return single(req, 'searchText', req.signalId, { t, dir: req.dir < 0 ? -1 : 1, inclusive: req.inclusive === true, format: req.format, pattern: req.pattern,
      caseSensitive: req.caseSensitive === true, alias: req.alias, budgetMs: req.budgetMs, stoppable: true });
  },

  // derive {expr, name?} -> {signalId, width, signed, name, operands, count, materializeMs, ...}
  async derive(req) {
    const { d, created, refs } = defineDerived(req.expr, req.name);
    const t0 = performance.now();
    const p = ensureDerived([d.id]);
    if (p) { try { await p; } catch (e) { if (created) { dropDerived(d); } throw e; } }
    return { signalId: d.id, width: d.width, signed: d.signed, name: d.name, operands: d.operands, refs, count: d.count,
      materialized: !!p, materializeMs: p ? +(performance.now() - t0).toFixed(1) : 0,
      loadMs: p ? +d.loadMs.toFixed(1) : 0, mergeMs: p ? +d.mergeMs.toFixed(1) : 0, steps: d.steps };
  },

  // searchAll {value | expr, t, dir, scope?, names?, limit?, budgetMs?}: nearest match per
  // signal, streamed as {id, partial: true, result: {matches, searched, total}} lines,
  // then {id, final: true, result: {matches (nearest first, <= limit), ..., complete, incomplete}}.
  async searchAll(req) {
    if (activeSearch && activeSearch !== req) { await handlers.cancel({ target: activeSearch.id, reason: 'superseded' }); }
    activeSearch = req;
    try { return await runSearchAll(req); } finally { if (activeSearch === req) { activeSearch = null; } }
  },

  // v1: whole signals, deflated [u64 delta][chars] records.
  // maxChanges (count first, debugger M5(c)): a signal with more changes than that comes back
  // as {signalId, width, count, overCap: true, bytes: 0} and sends no records. One whose
  // normalized count (store, store-cache file) is already over is answered here without a
  // reader load: its count is then the normalized count (countKind: 'normalized'), a lower
  // bound of the raw count, which only normalization can make smaller.
  async signals(req) {
    const { signalIds, widths } = req;
    checkIds(signalIds);
    if (signalIds.some((id) => id >= DERIVED_BASE)) { throw new Error('signals does not take derived signals'); }
    const capped = req.maxChanges !== undefined;
    if (capped && !(Number.isInteger(req.maxChanges) && req.maxChanges >= 0)) { throw new Error(`bad maxChanges: ${JSON.stringify(req.maxChanges)} (an integer >= 0)`); }
    const wOf = new Map(signalIds.map((id, k) => [id, widths ? widths[k] : undefined]));
    const known = new Map();
    if (capped) {
      for (const id of signalIds) {
        const c = countOf(id);
        if (c && c.count > req.maxChanges) { known.set(id, { signalId: id, width: wOf.get(id) !== undefined ? wOf.get(id) : c.bits, count: c.count, countKind: 'normalized', overCap: true }); }
      }
    }
    const res = await new Promise((resolve, reject) => {
      const groups = new Map();
      const byId = new Map(known);
      // Each signal is read once, however often the request names it (two rows aliasing one
      // FSDB signal): the worker unloads a signal after reading it, so a second copy would read
      // nothing (verify D1). byId fans the one answer out to every copy.
      for (const id of new Set(signalIds)) { if (known.has(id)) { continue; } const w = workerFor(id); if (!groups.has(w)) { groups.set(w, []); } groups.get(w).push(id); }
      let left = groups.size;
      if (!left) { resolve(signalIds.map((id) => byId.get(id))); return; }
      req.parts = [];
      for (const [w, ids] of groups) {
        const task = enqueue(w, { op: 'signals', signalIds: ids, widths: widths && ids.map((id) => wOf.get(id)), ...(capped ? { maxChanges: req.maxChanges } : {}), req });
        req.parts.push({ w, task });
        task.done = (m) => {
          if (m.error) { reject(new Error(m.error)); return; }
          m.result.forEach((r) => byId.set(r.signalId, r));
          if (--left === 0) { resolve(signalIds.map((id) => byId.get(id))); }
        };
      }
    });
    const out = [], parts = [];
    for (const r of res) {
      if (r.records) {
        const b = asBuf(r.records);
        out.push({ signalId: r.signalId, width: r.width, count: r.count, bytes: b.length, min: 0, max: 0 });
        parts.push(b);
      } else if (r.overCap) {
        out.push({ ...r, bytes: 0 });
      } else {
        out.push(r);
      }
    }
    return { result: out, bin: parts.length ? Buffer.concat(parts) : null };
  },

  // count {signalIds, exact?} -> {counts: [{signalId, count, bits, xz, bytes, source} | {signalId, unknown: true}]}
  // Whole-signal normalized change count (what a [0, T+1) window reports), its
  // width, and v1's packed size count * (8 + bits). Answered here, never queued:
  // source 'store' (a worker holds it), 'derived', or 'file' (the store-cache
  // .vvz header). Others are {unknown: true}, unless exact: true, which loads
  // them first (a walk; source 'store').
  async count(req) {
    const ids = checkIds(req.signalIds);
    const errors = new Map();  // exact: why a signal couldn't be counted
    if (req.exact === true) {
      const need = [...new Set(ids.filter((id) => !countOf(id)))];
      for (const id of need.filter((x) => derived.has(x))) {  // a derived signal: materialize it (its count is then known)
        try { const p = ensureDerived([id]); if (p) { await p; } } catch (e) { errors.set(id, String(e && e.message || e)); }
      }
      // A signal whose walk already failed for good (bgFailed: over the store cap,
      // unreadable) is reported from memory, not walked again.
      for (const id of need) { if (bgFailed.has(id) && /larger than|0 bits|unsupported|limit/.test(bgFailed.get(id))) { errors.set(id, bgFailed.get(id)); } }
      const real = need.filter((x) => !derived.has(x) && !errors.has(x));
      if (real.length) {
        try { const sp = prep(req, real); if (sp) { await sp; } } catch (e) { /* a failed split: the load below reports it per signal */ }
        // (a load that failed for good meanwhile is reported, not loaded again whole)
        for (const id of real) { if (bgFailed.has(id)) { errors.set(id, bgFailed.get(id)); } }
        const left = real.filter((id) => !errors.has(id));
        const res = left.length ? await scatter(req, 'load', left, {}, (m) => m.result) : [];
        for (const r of res) {  // (load's results carry their ids)
          if (r && r.error) { errors.set(r.signalId, r.error); if (/larger than|0 bits|unsupported/.test(r.error)) { bgFailed.set(r.signalId, r.error); } }
        }
      }
    }
    return { counts: ids.map((id) => countOf(id) || (errors.has(id) ? { signalId: id, error: errors.get(id) } : { signalId: id, unknown: true })) };
  },

  // aliasHints {pairs: [[rebuiltId, storedId], ...]} -> {accepted, refused: [{pair, why}]}: candidate
  // aliases from the app's design model (port bindings); see "aliases" above.
  async aliasHints(req) {
    if (!Array.isArray(req.pairs)) { throw new Error('aliasHints needs pairs'); }
    const idOf = (x) => (Number.isInteger(x) ? x : typeof x === 'string' ? ((getIndex().byPath.get(x) || {}).signalId ?? null) : null);
    let accepted = 0, pending = 0;
    const refused = [];
    for (const pr of req.pairs) {
      const [s, p] = Array.isArray(pr) && pr.length === 2 ? pr.map(idOf) : [null, null];
      if (s === null || p === null || s === p) { refused.push({ pair: pr, why: 'not a pair of signals' }); continue; }
      if (kinds.state === 'pending') { aliasPending.push([pr, s, p]); pending++; continue; }
      if (kinds.state !== 'ready') { refused.push({ pair: pr, why: 'stored signals not known' }); continue; }
      const why = addAlias(s, p);
      if (why) { refused.push({ pair: pr, why }); } else { accepted++; }
    }
    return { accepted, refused, pending };
  },

  async free(req) {
    // (a freed rebuilt signal's alias goes too: a later hint checks it again)
    if (!req.signalIds) { aliases.clear(); aliasPending = []; } else { for (const id of req.signalIds) { aliases.delete(id); } }
    // (a load of a freed signal that nobody waits for is dropped, not stored again later)
    for (const j of [...jobs.values()]) { if (!req.signalIds || req.signalIds.includes(j.id)) { dropJob(j); } }
    if (!req.signalIds) { await broadcast('free', {}); return {}; }
    await scatter(req, 'free', req.signalIds, {}, (m, ids) => ids.map(() => true));
    return {};
  },

  // Answered from the state each worker attaches to its replies (never waits on a walk).
  async stats() {
    return {
      workers: workers.map((w) => ({ worker: w.i, pid: w.pid, loaded: w.state.cached, bytesCached: w.state.bytes,
        limit: w.state.limit, queue: w.queue.length + (w.busy && !w.busy.bg ? 1 : 0), background: w.bgQueue.length + (w.busy && w.busy.bg ? 1 : 0),
        busy: w.busy ? w.busy.op : null, rss: w.state.rss })),
      index: warmStats(),
      searching: activeSearch ? activeSearch.id : null,
      coordinatorRss: process.memoryUsage().rss,
      recycled,
      ...(rssCapRaised ? { rssCapRaised } : {}),
      splitting: [...splitting.keys()],
      firstLoads: floatQueue.length,  // first loads waiting for a free worker (floatQueue)
      coldWalks: { pending: [...jobs.values()].filter((j) => !j.reqs.size).map((j) => j.id), failed: [...bgFailed.keys()] },
      pieceFiles: { bytes: shmBytes, peak: shmPeak, cap: SHM_CAP },
      warm: { ready: (hot.readers.find((r) => r.state === 'ready') || { ids: new Set() }).ids.size ? [...hot.readers.find((r) => r.state === 'ready').ids] : [],
        building: hot.building ? [...hot.building.ids] : null, rss: hot.readers.map((r) => r.rss) },
      aliases: { checking: [...aliases.values()].filter((a) => a.state === 'checking').length, on: [...aliases].filter(([, a]) => a.state === 'on').map(([x, a]) => [x, a.p]),
        verified: [...aliases].filter(([, a]) => a.state === 'verified').map(([x, a]) => [x, a.p]), bad: [...aliases].filter(([, a]) => a.state === 'bad').map(([x, a]) => [x, a.p]), log: aliasLog },
      kinds: { state: kinds.state, source: kinds.source, primaries: kinds.primaries ? kinds.primaries.size : 0, ms: kinds.ms, error: kinds.error, floorMs: Math.round(primFloor()) },
      loads: [...jobs.values()].map((j) => ({ signalId: j.id, waiting: j.reqs.size, pieces: j.pieces.length, running: j.running, done: +(j.doneLen / j.end).toFixed(3) })),
      derived: [...derived.values()].map((d) => ({ signalId: d.id, expr: d.expr, name: d.name, width: d.width, count: d.count })),
    };
  },

  // Drop queued parts of request `target`; its reply becomes {cancelled: true}.
  async cancel({ target, reason }) {
    const req = inflight.get(target);
    if (!req) { return { cancelled: false }; }
    let dropped = 0, running = 0;
    // (a recycled worker's task runs on its replacement, workers[w.i]: verify F8)
    const runner = (w, task) => [w, workers[w.i]].find((x) => x && x.busy === task);
    for (const { w, task } of req.parts || []) {
      if (dequeue(w, task)) {
        dropped++;
        // A first load not started: walked in the background instead (see floatQueue).
        if (task.floatIds) { task.floatIds.forEach(scheduleBgLoad); }
        continue;
      }
      const x = runner(w, task);
      if (!x) { continue; }  // already answered
      running++; task.done = () => {};
      // background tasks and stoppable interactive ones (searchText) stop early on SIGUSR2
      if ((task.bg || task.stoppable) && !task.yieldSent && x.pid) {
        task.yieldSent = true;
        // (searchText polls it between values; no SIGINT: with vm breakOnSigint it killed workers
        // and cancelled later requests, verify R1. One value stuck in a regex ends at the budget.)
        try { process.kill(x.pid, 'SIGUSR2'); } catch (e) { /* gone */ }
      }
    }
    // A whole load no other request waits for goes on in the background (jobs): asking again
    // finds it stored or further along. Its running pieces are counted as running.
    for (const sp of req.splits || []) {
      sp.reqs.delete(req);
      if (!sp.reqs.size) { sp.demoted = ++demoteSeq; if (sp.running) { running += sp.running; } }
    }
    capDemoted();
    req.cancelled = true;
    if (req.onCancel) { req.onCancel(); }
    inflight.delete(target);
    send({ id: target, cancelled: true, ...(reason ? { reason } : {}) });
    return { cancelled: true, dropped, running };
  },

  // warm {on?: bool, clear?: bool} -> index state (see "search index warm-up").
  async warm(req) {
    if (req.clear) {
      warm.on = false;
      if (manifestTimer) { clearTimeout(manifestTimer); manifestTimer = null; }  // (L6) nothing left to write
      manifestDirty = false;
      if (warm.dir) { fs.rmSync(warm.dir, { recursive: true, force: true }); }
      Object.assign(warm, { files: new Map(), bytes: 0, rawBytes: 0, todo: [], failed: new Map(), gen: (warm.gen || 0) + 1 });
    }
    if (req.on === true) { startWarm(); } else if (req.on === false) { warm.on = false; }
    return warmStats();
  },

  async close() {
    stopKinds();
    aliases.clear(); aliasDropped = [];
    flushManifest();
    lastOpen = null;
    clearJobs();
    bgFailed.clear();
    persisting.clear();
    epoch++;
    hotStop();
    splitting.clear();
    derived.clear(); derivedByKey.clear(); derivedByName.clear();
    index = null;
    warm.on = false; warm.epoch = -1; warm.inflight = 0;
    for (const w of workers) { const lost = [...w.queue, ...w.bgQueue]; w.queue = []; w.bgQueue = []; w.warming = false; w.state = { ...w.state, cached: [] }; w.sizes = new Map(); failTasks(lost, 'file closed'); }
    if (openFile) { addon.unload(); openFile = null; }
    await Promise.allSettled(workers.map((w) => runTask(w, { op: 'close', barrier: true }, true)));
    return {};
  },
};

spawnPool(DEFAULT_WORKERS);
send({ id: 0, ready: true, pid: process.pid, workers: workers.length });

// The integer value of the line's top-level "id" key (the last one, as JSON.parse would keep), or -1.
// Skips strings and nested objects/arrays, so an id-like number elsewhere is never taken.
function topLevelId(line) {
  let depth = 0, id = -1, i = 0;
  const n = line.length;
  while (i < n) {
    const c = line.charCodeAt(i);
    if (c === 34) {  // a string: a key if at depth 1 and followed by ':'
      const start = i + 1; i++;
      while (i < n && line.charCodeAt(i) !== 34) { i += line.charCodeAt(i) === 92 ? 2 : 1; }
      const key = line.slice(start, i); i++;
      if (depth !== 1 || key !== 'id') { continue; }
      let j = i; while (j < n && /\s/.test(line[j])) { j++; }
      if (line[j] !== ':') { continue; }
      j++; while (j < n && /\s/.test(line[j])) { j++; }
      const m = /^(\d{1,15})\s*[,}]/.exec(line.slice(j, j + 40));
      id = m ? Number(m[1]) : -1;
      continue;
    }
    if (c === 123 || c === 91) { depth++; } else if (c === 125 || c === 93) { depth--; }
    i++;
  }
  return id;
}

readline.createInterface({ input: process.stdin }).on('line', async (line) => {
  if (!line.trim()) { return; }
  if (line.length > MAX_LINE) {  // answered under the request's own id when it can be read (verify F6)
    send({ id: topLevelId(line), error: `request longer than ${MAX_LINE} bytes` });
    return;
  }
  let req;
  try { req = JSON.parse(line); } catch (e) { send({ id: -1, error: 'bad json' }); return; }
  const t0 = process.hrtime.bigint();
  // `cancel {id, target}` always gets a reply under its own id: {cancelled, dropped, running}.
  // `cancel {id}` (spec form) names the target in `id`: the target's reply becomes
  // {id, cancelled: true}, or, if it isn't running (already answered, or unknown),
  // one {id, cancelled: false} line, which a client with nothing pending ignores.
  if (req.cmd === 'cancel') {
    const r = await handlers.cancel({ target: req.target ?? req.id });
    if (req.target !== undefined) { send({ id: req.id, result: r }); } else if (!r.cancelled) { send({ id: req.id, cancelled: false }); }
    return;
  }
  inflight.set(req.id, req);
  try {
    const fn = handlers[req.cmd];
    if (!fn) { throw new Error('unknown command ' + req.cmd); }
    if (!openFile && !NO_FILE_OK.has(req.cmd)) { throw new Error('no file open'); }
    let r;
    const fix = aliasRewrite(req);
    for (let attempt = 0; ; attempt++) {
      try {
        r = await fn(req);
        break;
      } catch (e) {
        // A derived signal was evicted between our check and the worker: rebuild and retry
        // (searchAll handles its own, so partial replies are never sent twice).
        if (!/DERIVED_EVICTED/.test(String(e && e.message)) || req.cancelled || req.cmd === 'searchAll' || attempt >= 2) { throw e; }
        await ensureDerived(derivedIdsOf(req), true);
      }
    }
    if (req.cancelled) { return; }
    if (fix) { r = fix(r); }
    const ms = +(Number(process.hrtime.bigint() - t0) / 1e6).toFixed(3);
    const workerMs = req.workerMs !== undefined ? +req.workerMs.toFixed(3) : undefined;
    const fin = req.cmd === 'searchAll' ? { final: true } : {};
    if (r && r.bin !== undefined) { send({ id: req.id, result: r.result, ms, workerMs }, r.bin); } else { send({ id: req.id, ...fin, result: r, ms, workerMs }); }
  } catch (e) {
    if (DEBUG) { process.stderr.write(`[req ${req.id}] ${(e && e.stack) || e}\n`); }
    if (!req.cancelled) { send({ id: req.id, error: String((e && e.message) || e) }); }
  } finally {
    if (inflight.get(req.id) === req) { inflight.delete(req.id); }
    for (const sp of req.splits || []) { sp.reqs.delete(req); }  // a finished request no longer holds its splits (verify F7)
  }
}).on('close', () => {
  if (openFile) { addon.unload(); }
  shutdown(0);
});
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) { process.on(sig, () => shutdown(0)); }
process.on('exit', removeTmpDir);
