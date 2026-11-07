// Part of cmux's FSDB helper v2. GPL-3.0, as the rest of this folder.
// Live simulation (simctl): sim.* requests, dispatched here by helper.js and kept apart from the FSDB code.
//
// One simulation per helper. `sim.open` runs the simulator that made the panel's dump, again, under
// simctl/sim-worker.js and the simctl VPI library (simctl/libsimctl.so, built by build.sh next to the
// addon when the host has VCS). The simulator must have been elaborated with the stub as a VPI
// registration routine (a run-time `simv -load` does not register VPI):
//     -load <stable path>/libsimctl_stub.so:simctl_register
// The stub does nothing unless the worker sets SIMCTL_LIB, so that build runs as before without cmux.
//
// Requests (each answered once, as the other commands: {id, result, ms} or {id, error}):
//   sim.open {dir, clock?}  dir: the folder holding novas_dump.log (cmux pins it to the panel file's
//       folder); clock: a 1-bit signal whose period makes the cycles of run/until (without it, by time only).
//       The simulator is novas_dump.log's option[0] (relative to dir) and its run arguments are
//       the options before the compiler entry, without +fsdb*, -l <file>, -ucli, -ucli2Proc.
//       -> {t, precision, period, simv, args, dumpFile}. Refused without the stub in <simv>.daidir's
//       build record, with {needsFlag} and the line to add in the error.
//   sim.run {cycles | time}, sim.until {expr, maxCycles | maxTime}  -> {started: true} at once; the end
//       comes in a poll's `stop`.
//   sim.stop {}                     -> {t} once stopped
//   sim.read {signals}              -> {t, values: ['01xz..' | null]}
//   sim.watch {signals}             -> {t, watch: [{simSignal, width} | null]}
//   sim.unwatch {simSignals}        -> {unwatched}
//   sim.poll {waitMs <= 2000}       -> {t, running, stop: {t, stopped} | null, signals: [{simSignal, count,
//       bytes}], dropped, exited} + per signal `bytes` of records [u64 LE delta][width chars], the first
//       delta from 0 (an absolute time), then from the previous record (helper-v2's window layout, not
//       deflated). Answers as soon as there is something, else after waitMs. Changes not polled for are
//       kept up to SIM_BUFFER bytes; beyond that the oldest are dropped and counted in `dropped`.
//   sim.close {}                    -> {} (the simulation is ended and its processes killed)
// Times are in the simulator's precision (10^precision s).
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const WORKER = process.env.CMUX_SIM_WORKER || path.join(__dirname, 'simctl/sim-worker.js');
const LIB = process.env.CMUX_SIM_LIB || path.join(__dirname, 'simctl/libsimctl.so');
const STUB = process.env.CMUX_SIM_STUB || path.join(os.homedir(), '.cache/cmux/simctl/libsimctl_stub.so');
const SIM_BUFFER = Number(process.env.CMUX_SIM_BUFFER) || 64 * 1024 * 1024;
const MAX_WAIT_MS = 2000;
const PAGE_COMMANDS = new Set(['sim.open', 'sim.run', 'sim.until', 'sim.stop', 'sim.read', 'sim.watch', 'sim.unwatch', 'sim.poll', 'sim.close']);

// ---- novas_dump.log, the build record
// The FSDB dumper writes the run's command line into novas_dump.log in the run folder:
// " option[0]: ./simv", then the run arguments, then the compiler's own entries (from .../vcs1 on).
function parseDumpLog(text) {
  const opts = [];
  for (const line of String(text).split('\n')) {
    const m = /^\s*option\[(\d+)\]:\s?(.*)$/.exec(line);
    if (m) opts[Number(m[1])] = m[2];
  }
  if (!opts.length || opts[0] === undefined) return null;
  const args = [];
  for (let i = 1; i < opts.length; i++) {
    const o = opts[i];
    if (o === undefined || /(^|\/)vcs1$/.test(o)) break;
    args.push(o);
  }
  return { simv: opts[0], args };
}
function runArgs(args) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-l') { i++; continue; }
    if (/^\+fsdb/.test(a) || a === '-ucli' || a === '-ucli2Proc') continue;
    out.push(a);
  }
  return out;
}
function dumpFileOf(args) {
  for (const a of args) { const m = /^\+fsdb(?:file)?[=+](.+)$/.exec(a); if (m) return m[1]; }
  return null;
}
// The stub this simulator registers, from its build record (`-load <path>:simctl_register`).
function stubFrom(text) {
  const m = /(?:^|\s|')(\/[^\s':]*libsimctl_stub\.so):simctl_register\b/.exec(String(text));
  return m ? m[1] : null;
}
function buildRecord(simv) {
  for (const f of ['.vcs.timestamp', 'build_db']) {
    try { return fs.readFileSync(path.join(simv + '.daidir', f), 'latin1'); } catch { /* next */ }
  }
  return null;
}

// ---- the running simulation
let cur = null;   // {proc, ready, pending: Map, nextId, buf, hdr, records: [{simSignal, t, value}] , bytes, dropped, stop, running, waiters, t, widths}
const flagLine = () => `-load ${STUB}:simctl_register`;

function startWorker(simv, args, clock) {
  const scratch = fs.mkdtempSync(path.join(process.env.CMUX_SIM_SCRATCH || process.cwd() || os.tmpdir(), 'sim-'));
  fs.chmodSync(scratch, 0o700);
  const wargs = [WORKER, '--simv', simv, '--lib', LIB, '--scratch', scratch, '--run', 'run'];
  if (clock) wargs.push('--clock', clock);
  wargs.push('--', ...args);
  const proc = spawn(process.execPath, wargs, { stdio: ['pipe', 'pipe', 'pipe'], detached: false });
  const s = { proc, scratch, pending: new Map(), nextId: 1, buf: Buffer.alloc(0), hdr: null, batches: [], bytes: 0, dropped: 0,
    stop: null, running: false, waiters: [], t: 0, widths: new Map(), exited: null, stderr: '' };
  s.ready = new Promise((resolve, reject) => { s.readyRes = resolve; s.readyRej = reject; });
  proc.stderr.on('data', (d) => { s.stderr = (s.stderr + d).slice(-4000); });
  proc.stdout.on('data', (d) => onData(s, d));
  proc.on('exit', (code, signal) => {
    s.exited = { code, signal };
    s.running = false;
    s.readyRej(new Error(`simulation exited before it was ready (${code ?? signal})${s.stderr ? ': ' + s.stderr.trim().split('\n').slice(-3).join(' ') : ''}`));
    for (const [, p] of s.pending) p.reject(new Error('simulation exited'));
    s.pending.clear();
    wake(s);
    fs.rm(scratch, { recursive: true, force: true }, () => {});
  });
  proc.stdin.on('error', () => {});
  return s;
}
function onData(s, d) {
  s.buf = s.buf.length ? Buffer.concat([s.buf, d]) : d;
  for (;;) {
    if (s.hdr) {
      if (s.buf.length < s.hdr.binLength) return;
      const bin = s.buf.subarray(0, s.hdr.binLength); s.buf = s.buf.subarray(s.hdr.binLength);
      onChanges(s, s.hdr, Buffer.from(bin)); s.hdr = null; continue;
    }
    const nl = s.buf.indexOf(10);
    if (nl < 0) return;
    let m; try { m = JSON.parse(s.buf.subarray(0, nl).toString()); } catch { m = null; }
    s.buf = s.buf.subarray(nl + 1);
    if (!m) continue;
    if (m.id === 0) {
      if (m.event === 'changes') { if (m.binLength) { s.hdr = m; } continue; }
      if (m.event === 'ready') { s.t = m.t; s.period = Number(m.period) || 0; s.readyRes(m); }
      if (m.event === 'finish') { s.t = m.t; }
      continue;
    }
    const p = s.pending.get(m.id);
    if (!p) continue;
    s.pending.delete(m.id);
    if (m.result && typeof m.result.t === 'number') s.t = m.result.t;
    if (m.error) p.reject(new Error(m.error)); else p.resolve(m.result);
  }
}
// A worker batch: per signal [u64 delta][chars] with the first delta from the batch's t0.
function onChanges(s, h, bin) {
  let off = 0;
  for (const sig of h.signals) {
    const width = s.widths.get(sig.signalId);
    const bytes = bin.subarray(off, off + sig.bytes); off += sig.bytes;
    if (width === undefined) continue;          // unwatched meanwhile
    s.batches.push({ simSignal: sig.signalId, width, t0: h.t0, count: sig.count, bytes });
    s.bytes += bytes.length;
  }
  while (s.bytes > SIM_BUFFER && s.batches.length > 1) { const b = s.batches.shift(); s.bytes -= b.bytes.length; s.dropped += b.count; }
  wake(s);
}
function wake(s) { const w = s.waiters; s.waiters = []; for (const f of w) f(); }
function call(s, cmd, args = {}) {
  return new Promise((resolve, reject) => {
    if (s.exited) { reject(new Error('simulation exited')); return; }
    const id = s.nextId++;
    s.pending.set(id, { resolve, reject });
    s.proc.stdin.write(JSON.stringify({ id, cmd, ...args }) + '\n');
  });
}
function kill(s) {
  if (!s || s.exited) return;
  try { s.proc.stdin.end(); } catch { /* gone */ }
  // the worker quits its simulation when stdin closes; make sure, a little later
  const t = setTimeout(() => { if (!s.exited) { try { s.proc.kill('SIGKILL'); } catch { /* gone */ } } }, 3000);
  t.unref();
}

// Merge the waiting batches into one reply: per simSignal its records with absolute first delta.
function takeChanges(s) {
  const per = new Map();
  for (const b of s.batches) {
    let list = per.get(b.simSignal); if (!list) per.set(b.simSignal, (list = { width: b.width, recs: [] }));
    let t = b.t0;
    for (let o = 0; o < b.bytes.length; o += 8 + b.width) { t += Number(b.bytes.readBigUInt64LE(o)); list.recs.push([t, b.bytes.subarray(o + 8, o + 8 + b.width)]); }
  }
  s.batches = []; s.bytes = 0;
  const parts = [], signals = [];
  for (const [simSignal, { width, recs }] of per) {
    const b = Buffer.allocUnsafe(recs.length * (8 + width));
    let o = 0, prev = 0;
    for (const [t, v] of recs) { b.writeBigUInt64LE(BigInt(t - prev), o); v.copy(b, o + 8); o += 8 + width; prev = t; }
    parts.push(b); signals.push({ simSignal, count: recs.length, bytes: b.length });
  }
  return { signals, bin: Buffer.concat(parts) };
}

function needSim() { if (!cur || cur.exited) throw new Error('no simulation'); return cur; }
// Cycles need the clock's period, which the worker measures on the clock sim.open names.
function needPeriod(s) { if (!s.period) throw new Error('no clock period known: open the simulation with a clock, or run by time'); }
async function startRun(s, cmd, args) {
  if (s.running) throw new Error('a run is in flight; stop it first');
  s.running = true; s.stop = null;
  call(s, cmd, args).then((r) => { s.running = false; s.stop = { t: r.t, stopped: r.stopped }; wake(s); },
    (e) => { s.running = false; s.stop = { t: s.t, stopped: 'error', error: String(e.message || e) }; wake(s); });
  return { started: true };
}

const handlers = {
  async 'sim.open'(req) {
    if (cur && !cur.exited) throw new Error('a simulation is already open');
    const dir = String(req.dir || '');
    let text;
    try { text = fs.readFileSync(path.join(dir, 'novas_dump.log'), 'latin1'); } catch {
      throw new Error(`no novas_dump.log in ${dir}: live simulation reruns the simulator that wrote this dump, from that run's novas_dump.log`);
    }
    const parsed = parseDumpLog(text);
    if (!parsed) throw new Error(`novas_dump.log in ${dir} names no simulator command`);
    const simv = path.resolve(dir, parsed.simv);
    try { fs.accessSync(simv, fs.constants.X_OK); } catch { throw new Error(`the simulator ${simv} is missing or not executable`); }
    const stub = stubFrom(buildRecord(simv) || '');
    if (!stub || !fs.existsSync(stub)) {
      const e = new Error(`${simv} was not built for live simulation. Add this to its vcs elaboration and rebuild: ${flagLine()}` +
        (stub ? ` (its build names ${stub}, which is missing)` : ''));
      e.needsFlag = flagLine();
      throw e;
    }
    if (!fs.existsSync(LIB)) throw new Error('live simulation is not built on this host (it needs VCS when cmux builds its helper)');
    const args = runArgs(parsed.args);
    const s = startWorker(simv, args, req.clock ? String(req.clock) : '');
    cur = s;
    let ready;
    try { ready = await s.ready; } catch (e) { kill(s); cur = null; throw e; }
    return { t: ready.t, precision: ready.precision, period: ready.period, simv, args, dumpFile: dumpFileOf(parsed.args), stub };
  },
  'sim.run'(req) {
    const s = needSim();
    if (req.time === undefined) needPeriod(s);
    return startRun(s, 'run', req.time !== undefined ? { time: Number(req.time) } : { cycles: Number(req.cycles) });
  },
  'sim.until'(req) {
    const s = needSim();
    const a = { expr: String(req.expr || '') };
    if (req.maxTime !== undefined) a.maxTime = Number(req.maxTime); else { needPeriod(s); a.maxCycles = Number(req.maxCycles); }
    return startRun(s, 'until', a);
  },
  async 'sim.stop'() {
    const s = needSim();
    if (!s.running) return { t: s.t, idle: true };
    const r = await call(s, 'stop');
    return { t: r.t };
  },
  async 'sim.read'(req) { const s = needSim(); return call(s, 'read', { signals: (req.signals || []).map(String) }); },
  async 'sim.watch'(req) {
    const s = needSim();
    const r = await call(s, 'watch', { signals: (req.signals || []).map(String) });
    const watch = (r.watch || []).map((w) => { if (!w) return null; s.widths.set(w.signalId, w.width); return { simSignal: w.signalId, width: w.width }; });
    return { t: r.t, watch };
  },
  async 'sim.unwatch'(req) {
    const s = needSim();
    const ids = (req.simSignals || []).map(Number);
    for (const id of ids) s.widths.delete(id);
    s.batches = s.batches.filter((b) => s.widths.has(b.simSignal));
    return call(s, 'unwatch', { signalIds: ids });
  },
  async 'sim.poll'(req) {
    const s = needSim();
    const waitMs = Math.max(0, Math.min(MAX_WAIT_MS, Number(req.waitMs) || 0));
    if (!s.batches.length && !s.stop && !s.exited) {
      await new Promise((resolve) => { const t = setTimeout(resolve, waitMs); s.waiters.push(() => { clearTimeout(t); resolve(); }); });
    }
    const { signals, bin } = takeChanges(s);
    const stop = s.stop; s.stop = null;
    const dropped = s.dropped; s.dropped = 0;
    return { result: { t: s.t, running: s.running, stop, signals, dropped, exited: s.exited }, bin };
  },
  async 'sim.close'() {
    if (cur) { const s = cur; cur = null; kill(s); }
    return {};
  },
};

// helper.js: if (req.cmd starts with 'sim.') { sim.handle(req, send); return; }
function handle(req, send) {
  const t0 = process.hrtime.bigint();
  const fn = PAGE_COMMANDS.has(req.cmd) ? handlers[req.cmd] : null;
  if (!fn) { send({ id: req.id, error: 'unknown command ' + req.cmd }); return; }
  Promise.resolve().then(() => fn(req)).then((r) => {
    const ms = +(Number(process.hrtime.bigint() - t0) / 1e6).toFixed(3);
    if (r && r.bin !== undefined) send({ id: req.id, result: r.result, ms }, r.bin); else send({ id: req.id, result: r, ms });
  }, (e) => {
    const o = { id: req.id, error: String((e && e.message) || e) };
    if (e && e.needsFlag) o.needsFlag = e.needsFlag;
    send(o);
  });
}
// The helper is going away: SIGTERM makes the worker kill its simulator's process tree at once.
function closeAll() { if (cur) { const s = cur; cur = null; kill(s); if (s.proc && !s.exited) { try { s.proc.kill('SIGTERM'); } catch { /* gone */ } } } }
const workerPid = () => (cur && cur.proc ? cur.proc.pid : null);

module.exports = { handle, closeAll, parseDumpLog, runArgs, dumpFileOf, stubFrom, workerPid, PAGE_COMMANDS };
