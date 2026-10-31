// Mock protocol-v2 FSDB helper for run.sh windowed (cmux's WINDOWING.md protocol, the
// replies helper-v2 gives): NDJSON requests on stdin, replies on fd 3 as one JSON line
// plus `binLength` raw bytes, an artificial round trip per request. Generated dumps only
// (`synth:`, see makeSynth); it never reads a real file. Besides the protocol it answers
//   sleep {ms}            a reply after ms (cancellable while it waits): relay cancel checks
//   searchAll {...}       two {partial: true} lines, then the final one: relay partial checks
// With --v1 it stands in for the v1 helper: open, children and signals only.
// Usage: node mock-helper-v2.cjs [--latency 40] [--jitter 60] [--v1] 3>replies
'use strict';
const fs = require('node:fs');
const readline = require('node:readline');
const zlib = require('node:zlib');

const argv = process.argv.slice(2);
const opt = (name, dflt) => { const i = argv.indexOf('--' + name); return i >= 0 ? argv[i + 1] : dflt; };
let LATENCY = Number(opt('latency', 40));
let JITTER = Number(opt('jitter', 60));
const OUT = 3;
const V1 = argv.includes('--v1');
const V1_COMMANDS = new Set(['open', 'children', 'signals']);

function send(obj, bin) {
  if (bin) { obj.binLength = bin.length; }
  fs.writeSync(OUT, JSON.stringify(obj) + '\n');
  if (bin) { let off = 0; while (off < bin.length) { off += fs.writeSync(OUT, bin, off, bin.length - off); } }
}

// ---------------------------------------------------------------------------
// Signal store. A signal is sorted change times plus a way to get the value at
// index i. Generated signals compute values from the index (cheap memory, still
// binary-searched like the real helper); loaded signals keep strings.
class Sig {
  constructor(width, times, valueFn, opts = {}) {
    this.width = width; this.times = times; this.n = times.length; this.valueFn = valueFn;
    this.num = opts.num || null; // (i) => u32, for width <= 32 two-state fast matching
    this.min = opts.min ?? 0; this.max = opts.max ?? 1;
  }
  value(i) { return i < 0 ? 'x'.repeat(this.width) : this.valueFn(i); }
  // first index with time >= t
  lower(t) { let lo = 0, hi = this.n; const a = this.times; while (lo < hi) { const m = (lo + hi) >>> 1; if (a[m] < t) { lo = m + 1; } else { hi = m; } } return lo; }
  // first index with time > t
  upper(t) { let lo = 0, hi = this.n; const a = this.times; while (lo < hi) { const m = (lo + hi) >>> 1; if (a[m] <= t) { lo = m + 1; } else { hi = m; } } return lo; }
}

// The protocol's normalized change stream (WINDOWING.md): several changes at one time
// collapse to the last value at that time; then a change to the value already in effect is
// dropped; before the first change the value is all 'x', so a first change to all-x is
// dropped too. Every answer (window, counts, valueAt, edge, search) uses this one stream.
function normalize(sig) {
  const keep = [];
  let prev = 'x'.repeat(sig.width);
  for (let i = 0; i < sig.n; i++) {
    if (i + 1 < sig.n && sig.times[i + 1] === sig.times[i]) { continue; } // not the last at this time
    const v = sig.valueFn(i);
    if (v === prev) { continue; }
    keep.push(i); prev = v;
  }
  if (keep.length === sig.n) { return sig; }
  const idx = Int32Array.from(keep);
  return new Sig(sig.width, Float64Array.from(keep, (i) => sig.times[i]), (j) => sig.valueFn(idx[j]),
    { num: sig.num ? (j) => sig.num(idx[j]) : null, min: sig.min, max: sig.max });
}

function hash32(a, b) {
  let h = (a * 0x9E3779B1) ^ (b * 0x85EBCA77);
  h = Math.imul(h ^ (h >>> 16), 0x7FEB352D);
  h = Math.imul(h ^ (h >>> 15), 0x846CA68B);
  return (h ^ (h >>> 16)) >>> 0;
}
const bin32 = (v, w) => (v >>> 0).toString(2).padStart(32, '0').slice(32 - w);

// Generated dump: 1 ps resolution, 2 ns clock. Params (synth:ms=1,buses=4,busEvery=2000,skip=0.15):
//   clk: toggles every 1000 ps          -> ms * 1e6 changes
//   rst: high for 20 cycles
//   bus<k> (32-bit): changes every busEvery ps unless skipped (prob `skip`), 'x' for the first 4
//   state (4-bit): changes every 50..550 cycles (sparse, resolves to exact windows when zoomed out)
//   wide (480-bit): changes every cycle
function makeSynth(spec) {
  const p = Object.fromEntries(spec.replace(/^synth:?/, '').split(',').filter(Boolean).map((kv) => kv.split('=')));
  const ms = Number(p.ms || 1), buses = Number(p.buses ?? 4), busEvery = Number(p.busEvery || 2000);
  const skip = Number(p.skip ?? 0.15), wides = Number(p.wide ?? 1);
  const timeEnd = Math.round(ms * 1e9);
  const sigs = [];
  const vars = [];
  const addVar = (name, width, sig) => {
    const signalId = sigs.length;
    sigs.push(normalize(sig));
    vars.push({ name, type: width === 1 ? 'wire' : 'reg', encoding: 'BitVector', netlistId: signalId + 1, signalId,
      width, msb: width - 1, lsb: 0 });
  };
  const periodic = (period, start = 0) => {
    const n = Math.floor((timeEnd - start) / period) + 1;
    const t = new Float64Array(n);
    for (let i = 0; i < n; i++) { t[i] = start + i * period; }
    return t;
  };
  const skipping = (period, seed, prob) => {
    const out = [0];
    for (let t = period, i = 0; t <= timeEnd; t += period, i++) { if (hash32(seed, i) / 4294967296 >= prob) { out.push(t); } }
    return Float64Array.from(out);
  };

  const clk = periodic(1000);
  addVar('clk', 1, new Sig(1, clk, (i) => (i & 1 ? '1' : '0'), { num: (i) => i & 1 }));
  addVar('rst', 1, new Sig(1, Float64Array.from([0, 40000]), (i) => (i === 0 ? '1' : '0'), { num: (i) => (i === 0 ? 1 : 0) }));
  for (let k = 0; k < buses; k++) {
    const t = skipping(busEvery, 1000 + k, skip);
    const seed = 77 + k;
    addVar(`bus${k}`, 32, new Sig(32, t, (i) => (i < 4 ? 'x'.repeat(32) : bin32(hash32(seed, i), 32)),
      { num: (i) => (i < 4 ? null : hash32(seed, i)) }));
  }
  {
    const out = [0]; let t = 0, i = 0;
    while (true) { t += 2000 * (50 + (hash32(5, i++) % 500)); if (t > timeEnd) { break; } out.push(t); }
    addVar('state', 4, new Sig(4, Float64Array.from(out), (j) => bin32(hash32(9, j) & 15, 4), { num: (j) => hash32(9, j) & 15 }));
  }
  for (let k = 0; k < wides; k++) {
    const t = periodic(2000, 500);
    addVar(k ? `spike_rvfi${k}` : 'spike_rvfi', 480, new Sig(480, t, (i) => {
      let s = '';
      for (let w = 0; w < 15; w++) { s += bin32(hash32(300 + w + k * 16, i), 32); }
      return s;
    }));
  }
  const metadata = { timeTableLoaded: true, scopeCount: 2, netlistIdCount: vars.length, signalIdCount: vars.length,
    timeTableCount: 0, timeEnd, minTimeStep: 1000, timeScale: 1, timeUnit: 'ps' };
  const scopes = { 1: { name: 'tb', scopes: [{ name: 'dut', scopeOffsetIdx: 2, type: 'module' }], vars: vars.slice(0, 2) },
    2: { name: 'dut', scopes: [], vars: vars.slice(2) } };
  return {
    metadata, top: [{ name: 'tb', scopeOffsetIdx: 1, type: 'module' }],
    children: (idx) => ({ scopes: scopes[idx]?.scopes || [], vars: scopes[idx]?.vars || [] }),
    getSig: (signalId) => sigs[signalId],
  };
}

async function openDump(file) {
  if (file.startsWith('synth')) { return makeSynth(file); }
  throw new Error('cannot open ' + file + ': the mock serves synth: dumps only');
}

// ---------------------------------------------------------------------------
// Queries
let dump = null;
const sig = (signalId, width) => { const s = dump.getSig(signalId, width); if (!s) { throw new Error('no signal ' + signalId); } return s; };

function packRecords(recs, width) {
  const rec = 8 + width, buf = Buffer.allocUnsafe(recs.length * rec);
  let prev = 0, off = 0;
  for (const [t, v] of recs) {
    buf.writeBigUInt64LE(BigInt(t - prev), off);
    buf.write(v.length === width ? v : v.padStart(width, '0').slice(-width), off + 8, 'latin1');
    prev = t; off += rec;
  }
  return zlib.deflateRawSync(buf, { level: 1 });
}

// Signals a window request has touched count as "stored" (helper-v2: in a worker's store or
// its store-cache file); only their whole-dump count is known without a walk.
const stored = new Set();
function windowQuery({ signals, t0, t1, buckets }) {
  const out = [], parts = [];
  for (const { signalId, width } of signals) {
    const s = sig(signalId, width);
    const known = stored.has(signalId);
    stored.add(signalId);
    const a = s.lower(t0), b = s.lower(t1);
    const count = b - a;
    const first = [t0, s.value(s.upper(t0) - 1)]; // value in effect at t0, changes at t0 folded in
    const exact = count <= 2 * buckets;
    let recs = [first], counts = null;
    if (exact) {
      for (let i = s.upper(t0); i < b; i++) { recs.push([s.times[i], s.value(i)]); }
    } else {
      counts = Buffer.alloc(4 * buckets);
      let lo = a;
      for (let k = 0; k < buckets; k++) {
        const edge = t0 + Math.floor(((k + 1) * (t1 - t0)) / buckets);
        const hi = k === buckets - 1 ? b : s.lower(edge);
        const c = hi - lo;
        counts.writeUInt32LE(c, 4 * k);
        if (c > 0) {
          if (s.times[lo] > t0) { recs.push([s.times[lo], s.value(lo)]); }
          if (c >= 2 && s.times[hi - 1] > t0) { recs.push([s.times[hi - 1], s.value(hi - 1)]); }
        }
        lo = hi;
      }
    }
    const packed = packRecords(recs, s.width);
    const head = { signalId, exact, count, bytes: packed.length, bucketBytes: counts ? counts.length : 0, min: s.min, max: s.max };
    if (known) { head.total = s.n; } // whole-dump change count, once stored
    out.push(head);
    parts.push(packed); if (counts) { parts.push(counts); }
  }
  return { result: { signals: out }, bin: Buffer.concat(parts) };
}

// Pattern: MSB-first, shorter patterns left-padded with '0'. The wildcard is 'x' (the
// original rule), or, when the request names one (`wildcard: '?'`), only that character;
// then 'x' and 'z' are literal.
function compilePattern(pattern, width, wildcard) {
  const wild = wildcard || 'x';
  let p = pattern.toLowerCase();
  p = p.length >= width ? p.slice(p.length - width) : '0'.repeat(width - p.length) + p;
  if (width <= 32 && [...p].every((c) => c === '0' || c === '1' || c === wild)) {
    let mask = 0, val = 0;
    for (let i = 0; i < width; i++) {
      const bit = 1 << (width - 1 - i);
      if (p[i] !== wild) { mask |= bit; if (p[i] === '1') { val |= bit; } }
    }
    return { p, wild, mask: mask >>> 0, val: val >>> 0 };
  }
  return { p, wild };
}
function matches(s, i, cp) {
  if (cp.mask !== undefined && s.num) {
    const n = s.num(i);
    if (n !== null && n !== undefined) { return ((n & cp.mask) >>> 0) === cp.val; }
  }
  const v = s.value(i).toLowerCase();
  for (let k = 0; k < cp.p.length; k++) { if (cp.p[k] !== cp.wild && cp.p[k] !== v[k]) { return false; } }
  return true;
}

const handlers = {
  async open({ file }) {
    dump = await openDump(file); stored.clear();
    const r = { metadata: dump.metadata, top: dump.top };
    if (dump.topVars) { r.topVars = dump.topVars; }
    return r;
  },
  children({ scopeOffsetIdx }) { return dump.children(scopeOffsetIdx); },
  window: windowQuery,
  // count {signalIds, exact}: whole-dump change count per signal. exact: false answers only
  // stored signals (cheap) and {unknown: true} for the rest; exact: true always answers.
  count({ signalIds, exact }) {
    return { counts: signalIds.map((id) => {
      const s = sig(id);
      if (exact === false && !stored.has(id)) { return { signalId: id, unknown: true }; }
      return { signalId: id, count: s.n, bytes: s.n * (8 + s.width), bits: s.width, source: stored.has(id) ? 'store' : 'walked' };
    }) };
  },
  valueAt({ signalIds, t }) { return { values: signalIds.map((id) => { const s = sig(id); return s.value(s.upper(t) - 1); }) }; },
  edge({ signalId, t, dir, kind }) {
    const s = sig(signalId);
    const want = kind === 'rise' ? '1' : kind === 'fall' ? '0' : null;
    const ok = (i) => want === null || s.value(i) === want;
    if (dir >= 0) { for (let i = s.upper(t); i < s.n; i++) { if (ok(i)) { return { t: s.times[i] }; } } }
    else { for (let i = s.lower(t) - 1; i >= 0; i--) { if (ok(i)) { return { t: s.times[i] }; } } }
    return { t: null };
  },
  search({ signalId, t, dir, value, wildcard }) {
    const s = sig(signalId);
    const cp = compilePattern(value, s.width, wildcard);
    if (dir >= 0) { for (let i = s.upper(t); i < s.n; i++) { if (matches(s, i, cp)) { return { t: s.times[i] }; } } }
    else { for (let i = s.lower(t) - 1; i >= 0; i--) { if (matches(s, i, cp)) { return { t: s.times[i] }; } } }
    return { t: null };
  },
  // v1 whole-signal fetch, kept for bit slices / fallbacks.
  signals({ signalIds, widths }) {
    const out = [], parts = [];
    signalIds.forEach((id, k) => {
      const s = sig(id, widths && widths[k]);
      const recs = []; for (let i = 0; i < s.n; i++) { recs.push([s.times[i], s.value(i)]); }
      const packed = packRecords(recs, s.width);
      out.push({ signalId: id, width: s.width, count: s.n, bytes: packed.length, min: s.min, max: s.max });
      parts.push(packed);
    });
    return { result: out, bin: Buffer.concat(parts) };
  },
  sleep({ ms }) { return new Promise((resolve) => setTimeout(() => resolve({ slept: ms }), ms)); },
  stats() { return { workers: [{ loaded: 'all', queue: live.size }], latency: LATENCY, jitter: JITTER, requestsAfterCancel }; },
  setLatency({ latency, jitter }) { LATENCY = latency; JITTER = jitter; return { latency: LATENCY, jitter: JITTER }; },
};

// Artificial round trip: half before the request is processed, half after. A request is
// cancellable until its reply is sent (helper-v2: queued parts dropped, running ones discarded).
const live = new Map(); // id -> {timer}
// Cancels whose target hadn't arrived (or had finished), and requests that came after
// their own cancel: a relay that publishes a request's id before writing it shows up here.
const cancelledUnseen = new Set();
let requestsAfterCancel = 0;
function schedule(req) {
  if (cancelledUnseen.has(req.id)) { requestsAfterCancel++; cancelledUnseen.delete(req.id); }
  const rtt = LATENCY + Math.random() * JITTER;
  const entry = { timer: null, cancelled: false };
  live.set(req.id, entry);
  const reply = (obj, bin) => { if (!entry.cancelled) { live.delete(req.id); send(obj, bin); } };
  entry.timer = setTimeout(async () => {
    const t0 = process.hrtime.bigint();
    let out, bin;
    try {
      const fn = handlers[req.cmd];
      if ((!fn && req.cmd !== 'searchAll') || (V1 && !V1_COMMANDS.has(req.cmd))) { throw new Error('unknown command ' + req.cmd); }
      if (req.cmd === 'searchAll') {
        for (let k = 0; k < 2; k++) {
          await new Promise((r) => setTimeout(r, 30));
          if (entry.cancelled) { return; }
          send({ id: req.id, partial: true, result: { matches: [{ signalId: k, path: 'tb.x' + k, t: k }], searched: k + 1, total: 3 } });
        }
        out = { id: req.id, final: true, result: { matches: [], found: 2, searched: 3, total: 3, complete: true, incomplete: null } };
      } else {
        const r = await fn(req);
        const ms = Number(process.hrtime.bigint() - t0) / 1e6;
        if (r && r.bin !== undefined) { out = { id: req.id, result: r.result, ms }; bin = r.bin; } else { out = { id: req.id, result: r, ms }; }
      }
    } catch (e) { out = { id: req.id, error: String(e && e.message || e) }; }
    setTimeout(() => reply(out, bin), rtt / 2);
  }, rtt / 2);
}

send(V1 ? { id: 0, ready: true } : { id: 0, ready: true, pid: process.pid, protocol: 2 });

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) { return; }
  let req;
  try { req = JSON.parse(line); } catch { send({ id: -1, error: 'bad json' }); return; }
  if (req.cmd === 'cancel' && !V1) {
    // helper-v2: cancel {id, target} replies under its own id; the target's reply becomes
    // {id: target, cancelled: true}. cancel {id} of nothing running: one {id, cancelled: false}.
    const target = req.target ?? req.id;
    const entry = live.get(target);
    if (!entry && cancelledUnseen.size < 100000) { cancelledUnseen.add(target); }
    if (entry) { entry.cancelled = true; clearTimeout(entry.timer); live.delete(target); send({ id: target, cancelled: true }); }
    if (req.target !== undefined) { send({ id: req.id, result: { cancelled: !!entry, dropped: entry ? 1 : 0, running: 0 } }); }
    else if (!entry) { send({ id: req.id, cancelled: false }); }
    return;
  }
  schedule(req);
}).on('close', () => process.exit(0));
