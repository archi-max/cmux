// A stand-in for fsdb-helper-v2/simctl/sim-worker.js (no simulator on this Mac): the same JSON-lines protocol
// on stdio, over a toy design. Time unit 1, clock period FAKE_PERIOD (default 10, even).
//   tb.clk        1 bit, rises at 5, 15, 25, ... (period/2 + k*period)
//   tb.cnt        8 bits, counts on each rising edge from 0 (wraps)
//   tb.dut.state  4 bits, the counter's low 4 bits (a name the mock's synth dump also has)
//   tb.x          4 bits, always xxxx
//   tb.z          2 bits, always zz
// `deposit tb.cnt` sets the counter. An unwatch takes effect FAKE_UNWATCH_LAG_MS (default 30) later, as the
// real worker's batches in flight still carry the signal. FAKE_WORKER_LOG (a file) gets {argv, pid}.
'use strict';
const fs = require('node:fs');
if (process.env.FAKE_WORKER_LOG) fs.writeFileSync(process.env.FAKE_WORKER_LOG, JSON.stringify({ argv: process.argv.slice(2), pid: process.pid }));
const out = (o, bin) => { process.stdout.write(JSON.stringify(o) + '\n'); if (bin && bin.length) process.stdout.write(bin); };
const PERIOD = Number(process.env.FAKE_PERIOD) || 10;
const HALF = PERIOD / 2;
let t = 0, cnt = 0, running = null;
const BATCH_CYCLES = Number(process.env.FAKE_BATCH_CYCLES) || 0;   // >0: a batch every N cycles, all in one go
const UNWATCH_LAG = process.env.FAKE_UNWATCH_LAG_MS !== undefined ? Number(process.env.FAKE_UNWATCH_LAG_MS) : 30;
const width = { 'tb.clk': 1, 'tb.cnt': 8, 'tb.dut.state': 4, 'tb.x': 4, 'tb.z': 2 };
const clkAt = (tt) => ((tt % PERIOD) < HALF ? '0' : '1'); // 0 for [0,5), 1 for [5,10), ...
const value = (name) => name === 'tb.clk' ? clkAt(t) : name === 'tb.cnt' ? (cnt & 255).toString(2).padStart(8, '0')
  : name === 'tb.dut.state' ? (cnt & 15).toString(2).padStart(4, '0') : name === 'tb.x' ? 'xxxx' : 'zz';
const watches = new Map(); let nextWid = 0; const last = new Map();
let pend = [];   // [t, wid, value]
function flush() {
  if (!pend.length) return;
  const per = new Map(); let tmin = Infinity, tmax = 0;
  for (const [tt, wid, v] of pend) { if (!watches.has(wid)) continue; if (!per.has(wid)) per.set(wid, []); per.get(wid).push([tt, v]); tmin = Math.min(tmin, tt); tmax = Math.max(tmax, tt); }
  const parts = [], sigs = [];
  for (const [wid, recs] of per) {
    const w = width[watches.get(wid)];
    const b = Buffer.alloc(recs.length * (8 + w)); let o = 0, prev = tmin;
    for (const [tt, v] of recs) { b.writeBigUInt64LE(BigInt(tt - prev), o); b.write(v, o + 8, 'latin1'); o += 8 + w; prev = tt; }
    parts.push(b); sigs.push({ signalId: wid, count: recs.length, bytes: b.length });
  }
  const all = Buffer.concat(parts);
  pend = [];
  if (!sigs.length) return;
  out({ id: 0, event: 'changes', t0: tmin, t1: tmax, signals: sigs, binLength: all.length }, all);
}
function step(to) {
  // advance to time `to`, edge by edge (every HALF), recording watched changes
  while (t < to) {
    const nt = (Math.floor(t / HALF) + 1) * HALF;
    if (nt > to) { t = to; break; }
    t = nt;
    if (clkAt(t) === '1') cnt++;
    for (const [wid, name] of watches) {
      const v = value(name);
      if (last.get(wid) !== v) { last.set(wid, v); pend.push([t, wid, v]); }   // only real changes, as the worker does
    }
  }
}
function runTo(id, end, untilFn) {
  running = { id, end, untilFn, stop: null };
  const tick = () => {
    const r = running; if (!r) return;
    if (r.stop !== null) { running = null; flush(); out({ id: r.id, result: { t, stopped: 'stop' } }); out({ id: r.stop, result: { t } }); return; }
    const chunk = r.end - t > 1e5 * PERIOD ? 5 * PERIOD : r.end - t;   // long runs are slow, so a stop can catch them
    const target = t + chunk;
    let lastFlushT = t;
    while (t < target) {
      step(Math.min(target, t + HALF));
      if (BATCH_CYCLES && t - lastFlushT >= BATCH_CYCLES * PERIOD) { flush(); lastFlushT = t; }
      if (r.untilFn && r.untilFn()) { running = null; flush(); out({ id: r.id, result: { t, stopped: 'until' } }); return; }
    }
    if (t >= r.end) { running = null; flush(); out({ id: r.id, result: { t, stopped: 'done' } }); return; }
    flush();
    setTimeout(tick, 2);
  };
  setImmediate(tick);
}
require('node:readline').createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  const r = JSON.parse(line);
  const id = r.id;
  switch (r.cmd) {
    case 'run': {
      if (running) return out({ id, error: 'a run is in flight; stop it first' });
      const dt = r.time !== undefined ? Number(r.time) : Number(r.cycles) * PERIOD;
      return runTo(id, t + dt, null);
    }
    case 'until': {
      if (running) return out({ id, error: 'a run is in flight; stop it first' });
      const m = /^\s*(\S+)\s*==\s*'d(\d+)\s*$/.exec(r.expr || '');
      if (!m || !width[m[1]]) return out({ id, error: 'expected: sig == value' });
      const want = Number(m[2]);
      const dt = r.maxTime !== undefined ? Number(r.maxTime) : Number(r.maxCycles) * PERIOD;
      return runTo(id, t + dt, () => parseInt(value(m[1]), 2) === want);
    }
    case 'stop': if (running) { running.stop = id; } else out({ id, result: { t, idle: true } }); return;
    case 'time': return out({ id, result: { t } });
    case 'read': return out({ id, result: { t, values: (r.signals || []).map((s) => (width[s] ? value(s) : null)) } });
    case 'deposit': if (r.signal === 'tb.cnt') cnt = parseInt(String(r.value).replace(/^'d/, ''), 10); return out({ id, result: { t: t + 1, value: value(r.signal) } });
    case 'watch': {
      const ws = (r.signals || []).map((s) => { if (!width[s]) return null; const wid = nextWid++; watches.set(wid, s); last.set(wid, value(s)); pend.push([t, wid, value(s)]); return { signalId: wid, width: width[s] }; });
      out({ id, result: { t, watch: ws } });
      flush();
      return;
    }
    case 'unwatch': {
      const ids = (r.signalIds || []).filter((w) => watches.has(w));
      setTimeout(() => { for (const w of ids) watches.delete(w); }, UNWATCH_LAG);
      return out({ id, result: { unwatched: ids.length } });
    }
    case 'quit': out({ id, result: { t, quit: true } }); out({ id: 0, event: 'exit', code: 0 }); setTimeout(() => process.exit(0), 10); return;
    default: return out({ id, error: 'unknown cmd ' + r.cmd });
  }
});
// FAKE_REPORT_PERIOD=0: a simulation whose clock period isn't known (no clock given or found).
const REPORTED = process.env.FAKE_REPORT_PERIOD !== undefined ? Number(process.env.FAKE_REPORT_PERIOD) : PERIOD;
setTimeout(() => out({ id: 0, event: 'ready', t: 0, precision: -12, period: REPORTED, startupMs: 1 }), 20);
