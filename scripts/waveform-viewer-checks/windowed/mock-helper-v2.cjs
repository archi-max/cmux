// Mock protocol-v2 FSDB helper for run.sh windowed (protocol 2, the
// replies helper-v2 gives): NDJSON requests on stdin, replies on fd 3 as one JSON line
// plus `binLength` raw bytes, an artificial round trip per request. Generated dumps only
// (`synth:`, see makeSynth); it never reads a real file. Besides the protocol it answers
//   sleep {ms}            a reply after ms (cancellable while it waits): relay cancel checks
//   searchAll {...}       two {partial: true} lines, then the final one: relay partial checks
//   textControl {...}     searchText test knobs: refuse (answer it as an unknown command, as
//                         a helper without it), delayMs (wait first, cancellable), budgetMs
//                         (override the viewer's budget, to force incomplete + resume),
//                         tooLarge (answer {incomplete: {tooLarge}}); textStats counts them
//   loadControl {firstLoadMs: {signalId: ms}}  a window naming a signal no window has named
//                         yet waits that long first (a cold reader load on a big dump; it
//                         finishes even if the request is cancelled, as helper-v2's do);
//                         loadStats {} -> {cancels: {signalId: window requests cancelled}}
//   aliasControl {serveAs: {signalId: otherId}, drop: [signalIds]}  windows of signalId are
//                         answered with otherId's data and alias: otherId (helper-v2's aliases);
//                         drop stops that and puts aliasDropped on the next window, valueAt or
//                         count reply
// searchText is the shipped helper's own text.js (and formats.js, the viewer's formatters)
// over this mock's change stream, through a JS stand-in for the addon's cacheTextScan.
// With --v1 it stands in for the v1 helper: open, children and signals only.
// Usage: node mock-helper-v2.cjs [--latency 40] [--jitter 60] [--v1] 3>replies
'use strict';
const fs = require('node:fs');
const readline = require('node:readline');
const zlib = require('node:zlib');
const path = require('node:path');
let textSearch = null;
try { textSearch = require(path.join(__dirname, '../../../Resources/vaporview/fsdb-helper-v2/text.js')); } catch (e) { textSearch = null; }

const argv = process.argv.slice(2);
const opt = (name, dflt) => { const i = argv.indexOf('--' + name); return i >= 0 ? argv[i + 1] : dflt; };
let LATENCY = Number(opt('latency', 40));
let JITTER = Number(opt('jitter', 60));
const OUT = 3;
const V1 = argv.includes('--v1');
// --stall-open-file F --stall-opens N: each launch appends its pid as a line to F; the first
// N launches never answer `open` (a reader stuck opening the file), later ones answer
// normally. --stall-launches 2,4 stalls those launches (1-based) instead, and
// --hang-ready-launches 2 never sends the ready line on those. A stalled open stands in for
// the coordinator's main thread blocked in the reader: from then on it ignores the end of
// stdin and SIGTERM, so only a SIGKILL ends it.
const STALL_FILE = opt('stall-open-file', '');
const listOpt = (name) => String(opt(name, '')).split(',').filter(Boolean).map(Number);
let stallOpen = false;
let hangReady = false;
let stuck = false;
if (STALL_FILE) {
  fs.appendFileSync(STALL_FILE, process.pid + '\n');
  const launch = fs.readFileSync(STALL_FILE, 'utf8').split('\n').filter(Boolean).length;
  const list = listOpt('stall-launches');
  stallOpen = list.length ? list.includes(launch) : launch <= Number(opt('stall-opens', 1));
  hangReady = listOpt('hang-ready-launches').includes(launch);
}
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
    this.kind = opts.kind || null; // 'string' | 'real': text records (helper-v2's `text: true`)
    this.error = opts.error || null; // {message, permanent}: every window of it fails (helper-v2's per-signal error)
    this.textMean = opts.textMean ?? null; // text: the header's mean text bytes per change (helper-v2's textMean)
    this.torn = !!opts.torn;          // every window's records end mid-record (a torn reply)
    this.sliceRange = !!opts.sliceRange; // real: min/max of each window's own records, not the signal's
    this.coldRange = !!opts.coldRange; // real: no min/max on its first, ranged (cold) window, as helper-v2's ranged replies
    this.tornWhole = !!opts.tornWhole; // only whole-dump exact windows (the page's whole load) end mid-record
    this.cut = !!opts.cut;            // the whole load's header says cut: true (helper-v2 cut its values to fit the budget)
  }
  value(i) { return i < 0 ? (this.kind ? 'x' : 'x'.repeat(this.width)) : this.valueFn(i); }
  // first index with time >= t
  lower(t) { let lo = 0, hi = this.n; const a = this.times; while (lo < hi) { const m = (lo + hi) >>> 1; if (a[m] < t) { lo = m + 1; } else { hi = m; } } return lo; }
  // first index with time > t
  upper(t) { let lo = 0, hi = this.n; const a = this.times; while (lo < hi) { const m = (lo + hi) >>> 1; if (a[m] <= t) { lo = m + 1; } else { hi = m; } } return lo; }
}

// The protocol's normalized change stream: several changes at one time
// collapse to the last value at that time; then a change to the value already in effect is
// dropped; before the first change the value is all 'x', so a first change to all-x is
// dropped too. Every answer (window, counts, valueAt, edge, search) uses this one stream.
function normalize(sig) {
  const keep = [];
  let prev = sig.kind ? 'x' : 'x'.repeat(sig.width);
  for (let i = 0; i < sig.n; i++) {
    if (i + 1 < sig.n && sig.times[i + 1] === sig.times[i]) { continue; } // not the last at this time
    const v = sig.valueFn(i);
    if (v === prev) { continue; }
    keep.push(i); prev = v;
  }
  if (keep.length === sig.n) { return sig; }
  const idx = Int32Array.from(keep);
  return new Sig(sig.width, Float64Array.from(keep, (i) => sig.times[i]), (j) => sig.valueFn(idx[j]),
    { num: sig.num ? (j) => sig.num(idx[j]) : null, min: sig.min, max: sig.max, kind: sig.kind, error: sig.error,
      textMean: sig.textMean, torn: sig.torn, sliceRange: sig.sliceRange, coldRange: sig.coldRange, tornWhole: sig.tornWhole, cut: sig.cut });
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
//   insn (32-bit, insn=1): an instruction every cycle from t=0, few distinct values: a
//     unique `lui a0,0x12345` at t=0, a unique `lui ra,0xdeadc` at INSN_FAR of the
//     changes, the ASCII word "cmux" at INSN_ASCII, otherwise one of 16 common words
function makeSynth(spec) {
  const p = Object.fromEntries(spec.replace(/^synth:?/, '').split(',').filter(Boolean).map((kv) => kv.split('=')));
  const ms = Number(p.ms || 1), buses = Number(p.buses ?? 4), busEvery = Number(p.busEvery || 2000);
  const skip = Number(p.skip ?? 0.15), wides = Number(p.wide ?? 1), insn = Number(p.insn ?? 0);
  const timeEnd = Math.round(ms * 1e9);
  const sigs = [];
  const vars = [];
  const addVar = (name, width, sig, type = width === 1 ? 'wire' : 'reg', encoding = 'BitVector') => {
    const signalId = sigs.length;
    sigs.push(normalize(sig));
    vars.push({ name, type, encoding, netlistId: signalId + 1, signalId,
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
  if (insn) {
    const t = periodic(2000);
    const far = Math.floor(t.length * INSN_FAR), asc = Math.floor(t.length * INSN_ASCII);
    const word = (i) => (i === 0 ? 0x12345537 : i === far ? 0xdeadc0b7 : i === asc ? 0x636d7578 : INSN_WORDS[hash32(11, i) & 15]);
    addVar('insn', 32, new Sig(32, t, (i) => bin32(word(i), 32), { num: word }));
  }
  // text=1: helper-v2's string and real variables, and two signals the helper can't read:
  //   msg (string): a word every 2000 ps (500k changes, so windowed), "boot" at t=0, the one
  //     "needle-far" at MSG_FAR of the changes
  //   level (real): every 1e6 ps (1000 changes, loaded whole); values like -12.5 .. 37.25
  //   bad (8-bit): every window fails with a permanent error (an encoding the reader can't give)
  //   flaky (8-bit): every window fails with a transient error (retried)
  //   banner (string): 1000 changes, but its headers say 200 KB of text per change (textMean),
  //     too much to load whole
  //   torn (string): every window reply ends mid-record
  //   swing (real): 400k changes (windowed), 0..9 in the first half, -109..-100 in the second;
  //     each window says only its own records' min/max (as a ranged slice would)
  //   coldlvl (real): 400k changes (windowed), -50..-11; its first window, if ranged, has no
  //     min/max (helper-v2 sends none on a ranged answer), later ones say -50..0
  //   tornwhole (string): 1000 short changes (loaded whole), but the whole load's reply is torn
  //   cutlong (string): 1000 changes, small enough to load whole, but the whole load's reply says
  //     its values were cut (cut: true), so the page keeps it windowed (search uses the whole text)
  if (p.text) {
    const t = periodic(2000), far = Math.floor(t.length * MSG_FAR);
    addVar('msg', 1, new Sig(1, t, (i) => (i === 0 ? 'boot' : i === far ? 'needle-far' : MSG_WORDS[hash32(21, i) % MSG_WORDS.length]), { kind: 'string' }), 'string', 'String');
    const lt = periodic(1e6);
    const lv = (i) => String(((hash32(23, i) % 200) - 50) / 4);
    let mn = 0, mx = 0; for (let i = 0; i < lt.length; i++) { const x = Number(lv(i)); mn = Math.min(mn, x); mx = Math.max(mx, x); }
    addVar('level', 1, new Sig(1, lt, lv, { kind: 'real', min: mn, max: mx }), 'real', 'Real');
    addVar('bad', 8, new Sig(8, periodic(4000), (i) => bin32(i & 255, 8), { error: { message: 'unsupported encoding (2 bytes per bit, var type 4)', permanent: true } }));
    addVar('flaky', 8, new Sig(8, periodic(4000), (i) => bin32(i & 255, 8), { error: { message: 'mock: worker restarted', permanent: false } }));
    addVar('banner', 1, new Sig(1, periodic(1e6), (i) => 'banner ' + i, { kind: 'string', textMean: 200000 }), 'string', 'String');
    addVar('torn', 1, new Sig(1, periodic(4000), (i) => 'w' + (i % 7), { kind: 'string', torn: true }), 'string', 'String');
    const st = periodic(2500), half = st.length / 2;
    addVar('swing', 1, new Sig(1, st, (i) => String(i < half ? i % 10 : -100 - (i % 10)), { kind: 'real', sliceRange: true }), 'real', 'Real');
    addVar('coldlvl', 1, new Sig(1, periodic(2500), (i) => String(-50 + (i % 40)), { kind: 'real', min: -50, max: 0, coldRange: true }), 'real', 'Real');
    addVar('cutlong', 1, new Sig(1, periodic(1e6), (i) => 'c' + (i % 5) + '\u2026', { kind: 'string', textMean: 2, cut: true }), 'string', 'String');
    addVar('tornwhole', 1, new Sig(1, periodic(1e6), (i) => 't' + (i % 5), { kind: 'string', textMean: 2, tornWhole: true }), 'string', 'String');
  }
  const own = vars.length;
  // arrays=1: packed arrays as helper-v2 reports the reader's ARRAY scopes (tree.js): a scope
  // of the reply with its elements inline, by their full names; nested for each dimension.
  const arrayScopes = [];
  if (p.arrays) {
    const element = (name, width, seed) => {
      addVar(name, width, new Sig(width, periodic(4000), (i) => bin32(hash32(seed, i) & (2 ** width - 1), width), { num: (i) => hash32(seed, i) & (2 ** width - 1) }));
      return vars[vars.length - 1];
    };
    arrayScopes.push({ name: 'dfp_addr[1:0]', type: 'array', inline: { scopes: [], vars: [element('dfp_addr[1]', 16, 401), element('dfp_addr[0]', 16, 402)] } });
    arrayScopes.push({ name: 'cube[1:0]', type: 'array', inline: { vars: [], scopes: [1, 0].map((a) => ({ name: `cube[${a}][2:0]`, type: 'array',
      inline: { scopes: [], vars: [2, 1, 0].map((b) => element(`cube[${a}][${b}]`, 4, 410 + a * 3 + b)) } })) } });
  }
  const metadata = { timeTableLoaded: true, scopeCount: 2, netlistIdCount: vars.length, signalIdCount: vars.length,
    timeTableCount: 0, timeEnd, minTimeStep: 1000, timeScale: 1, timeUnit: 'ps' };
  const scopes = { 1: { name: 'tb', scopes: [{ name: 'dut', scopeOffsetIdx: 2, type: 'module' }, ...arrayScopes], vars: vars.slice(0, 2) },
    2: { name: 'dut', scopes: [], vars: vars.slice(2, own) } };
  return {
    metadata, top: [{ name: 'tb', scopeOffsetIdx: 1, type: 'module' }],
    children: (idx) => ({ scopes: scopes[idx]?.scopes || [], vars: scopes[idx]?.vars || [] }),
    getSig: (signalId) => sigs[signalId],
  };
}

const MSG_FAR = 0.9;
const MSG_WORDS = ['fetch', 'decode', 'exec', 'mem', 'wb', 'stall', 'flush'];
// insn's common words: addi aK,aK,j / add aK,aK,aJ / lw aK,4j(sp) (never lui, never ra).
const INSN_FAR = 0.93, INSN_ASCII = 0.8;
const INSN_WORDS = [];
for (let k = 0; k < 6; k++) { INSN_WORDS.push(((k + 1) << 20) | ((10 + k) << 15) | ((10 + k) << 7) | 0x13); }
for (let k = 0; k < 5; k++) { INSN_WORDS.push(((11 + k) << 20) | ((10 + k) << 15) | ((10 + k) << 7) | 0x33); }
for (let k = 0; k < 5; k++) { INSN_WORDS.push(((4 * (k + 1)) << 20) | (2 << 15) | (2 << 12) | ((10 + k) << 7) | 0x03); }

async function openDump(file) {
  if (file.startsWith('synth')) { return makeSynth(file); }
  throw new Error('cannot open ' + file + ': the mock serves synth: dumps only');
}

// ---------------------------------------------------------------------------
// Queries
let dump = null;
const sig = (signalId, width) => { const s = dump.getSig(signalId, width); if (!s) { throw new Error('no signal ' + signalId); } return s; };

function packRecords(recs, width, text = false) {
  if (text) { // helper-v2 string/real records: [u64 delta][u32 length][UTF-8 text]
    const parts = [];
    let prev = 0;
    for (const [t, v] of recs) {
      const b = Buffer.from(v, 'utf8'), h = Buffer.alloc(12);
      h.writeBigUInt64LE(BigInt(t - prev), 0); h.writeUInt32LE(b.length, 8);
      parts.push(h, b); prev = t;
    }
    return zlib.deflateRawSync(Buffer.concat(parts), { level: 1 });
  }
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
const windowAsks = {}; // signalId -> window requests naming it (textStats.windowAsks)
const loadCtl = { firstLoadMs: {} };
const aliasCtl = { serveAs: {}, dropped: [] };
const loadStats = { cancels: {}, windows: [] };
const firstLoaded = new Set(); // loaded since the last loadControl
function windowQuery({ signals, t0, t1, buckets }) {
  if (buckets === 32768) { textStats.scanWindows++; } // the viewer's value-search chunks (SCAN_BUCKETS)
  const out = [], parts = [];
  for (const { signalId, width } of signals) {
    const s = sig(signalId, width);
    windowAsks[signalId] = (windowAsks[signalId] || 0) + 1;
    if (s.error) {
      out.push({ signalId, error: s.error.message, bytes: 0, bucketBytes: 0, ...(s.error.permanent ? { permanent: true } : {}) });
      continue;
    }
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
    let packed = packRecords(recs, s.width, !!s.kind);
    const whole = exact && t0 === 0 && count >= s.n && buckets === Math.ceil(s.n / 2) + 1; // the page's whole load, not a tile
    if (s.torn || (s.tornWhole && whole)) { const raw = zlib.inflateRawSync(packed); packed = zlib.deflateRawSync(raw.subarray(0, raw.length - 2), { level: 1 }); }
    let mn = s.min, mx = s.max;
    if (s.coldRange && !known && (t1 - t0) <= 0.25 * dump.metadata.timeEnd) { mn = undefined; mx = undefined; }
    if (s.tornWhole && whole) { textStats.tornWholeLoads = (textStats.tornWholeLoads || 0) + 1; }
    if (s.sliceRange) { const xs = recs.map((r) => Number(r[1])).filter(Number.isFinite); mn = Math.min(...xs); mx = Math.max(...xs); }
    const head = { signalId, exact, count, bytes: packed.length, bucketBytes: counts ? counts.length : 0, min: mn, max: mx,
      ...(s.kind ? { text: true, kind: s.kind } : {}), ...(s.textMean !== null ? { textMean: s.textMean } : {}), ...(s.cut && whole ? { cut: true } : {}) };
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

// The addon's cacheTextScan (helper-v2 addon/window.cpp.inc) over the mock's stream: each
// change's distinct-value index, then the same scan, so text.js runs unchanged.
const distinct = new Map(); // signalId -> {vidx, dfirst}
function distinctOf(id) {
  let d = distinct.get(id);
  if (d) { return d; }
  const s = sig(id), ids = new Map(), vidx = new Uint32Array(s.n), dfirst = [];
  for (let i = 0; i < s.n; i++) {
    const v = s.value(i);
    let k = ids.get(v);
    if (k === undefined) { k = dfirst.length; ids.set(v, k); dfirst.push(i); }
    vidx[i] = k;
  }
  d = { vidx, dfirst };
  distinct.set(id, d);
  return d;
}
const textAddon = {
  cacheTextScan(id, t, dir, mask, maxNew, fromK = -1, bound, inclusive = false) {
    const s = sig(id), { vidx, dfirst } = distinctOf(id), n = s.n;
    dir = dir < 0 ? -1 : 1;
    const lim = typeof bound === 'number' ? bound : dir > 0 ? Infinity : 0;
    const mlen = mask ? mask.length : 0;
    let k;
    if (fromK >= 0) { k = Math.min(fromK, n - (dir > 0 ? 0 : 1)); }
    else if (dir > 0) { k = inclusive ? s.lower(t) : s.upper(t); }
    else { k = (inclusive ? s.upper(t) : s.lower(t)) - 1; }
    const o = { gen: 1, n: dfirst.length };
    const need = [], seen = new Set();
    let needK = -1;
    for (; k >= 0 && k < n; k += dir) {
      const tk = s.times[k];
      if (dir > 0 ? tk > lim : tk < lim) { break; }
      const d = vidx[k], m = d < mlen ? mask[d] : 0;
      if (m === 1 && needK < 0) { return Object.assign(o, { t: tk, k, d, v: s.value(k) }); }
      if (m === 0 && !seen.has(d)) {
        seen.add(d);
        if (needK < 0) { needK = k; }
        need.push({ d, v: s.value(dfirst[d]) });
        if (seen.size >= maxNew) { break; }
      }
    }
    if (needK >= 0) { return Object.assign(o, { need, k: needK, kt: s.times[needK] }); }
    return Object.assign(o, { t: null });
  },
};
const textCtl = { refuse: false, delayMs: 0, budgetMs: 0, tooLarge: false };
let signalsLast = null; // the last v1 signals request: its maxChanges, bytes sent, signals over it
const textResume = new Map(); // signalId -> resume.t of its last incomplete reply
const textStats = { scanWindows: 0, refused: 0, calls: 0, resumed: 0, inclusive: 0, cancelled: 0, incomplete: 0, last: null };

const handlers = {
  async searchText(req) {
    if (!textSearch || textCtl.refuse) { textStats.refused++; throw new Error('unknown command searchText'); }
    textSearch.check(req);
    textStats.calls++;
    if (req.inclusive === true) { textStats.inclusive++; }
    // A resume: the request starts, inclusive, where the last incomplete reply said to.
    if (req.inclusive === true && textResume.get(req.signalId) === req.t) { textStats.resumed++; }
    textResume.delete(req.signalId);
    textStats.last = { t: req.t, dir: req.dir, inclusive: req.inclusive === true, format: req.format, pattern: req.pattern,
      alias: req.alias ? { table: req.alias.table, fileName: req.alias.fileName, chars: req.alias.text.length } : null, budgetMs: req.budgetMs };
    if (textCtl.delayMs) { await new Promise((r) => setTimeout(r, textCtl.delayMs)); }
    const p = { ...req, inclusive: req.inclusive === true, caseSensitive: req.caseSensitive === true };
    if (textCtl.budgetMs) { p.budgetMs = textCtl.budgetMs; }
    if (textCtl.tooLarge) { textStats.incomplete++; return { t: null, incomplete: { tooLarge: true, reason: 'mock: value table over the signal cap' } }; }
    const r = textSearch.search(textAddon, p);
    if (r.incomplete) { textStats.incomplete++; if (r.incomplete.resume) { textResume.set(req.signalId, r.incomplete.resume.t); } }
    return r;
  },
  textControl(c) { Object.assign(textCtl, c); return { ...textCtl }; },
  textStats() { return { ...textStats, signalsLast, windowAsks }; },
  async open({ file }) {
    if (stallOpen) {
      stuck = true;
      process.on('SIGTERM', () => {});
      setInterval(() => {}, 1 << 30);
      await new Promise(() => {});
    }
    dump = await openDump(file); stored.clear(); distinct.clear();
    const r = { metadata: dump.metadata, top: dump.top };
    if (dump.topVars) { r.topVars = dump.topVars; }
    return r;
  },
  children({ scopeOffsetIdx }) { return dump.children(scopeOffsetIdx); },
  async window(req) {
    const ids = req.signals.map((x) => x.signalId);
    if (Object.keys(loadCtl.firstLoadMs).length) { loadStats.windows.push(ids); }
    const cold = ids.filter((id) => !firstLoaded.has(id));
    const ms = Math.max(0, ...cold.map((id) => Number(loadCtl.firstLoadMs[id] || 0)));
    if (ms > 0) { await new Promise((r) => setTimeout(r, ms)); }
    cold.forEach((id) => firstLoaded.add(id));
    const as = (id) => (aliasCtl.serveAs[id] !== undefined ? Number(aliasCtl.serveAs[id]) : null);
    if (!ids.some((id) => as(id) !== null)) { return windowQuery(req); }
    const r = windowQuery({ ...req, signals: req.signals.map((x) => (as(x.signalId) !== null ? { ...x, signalId: as(x.signalId) } : x)) });
    r.result.signals.forEach((h, k) => { if (as(ids[k]) !== null) { h.alias = h.signalId; h.signalId = ids[k]; } });
    return r;
  },
  // aliasHints {pairs}: the real helper's reply shape (every pair taken; the mock serves none).
  aliasHints(c) { return { accepted: Array.isArray(c.pairs) ? c.pairs.length : 0, refused: [], pending: 0 }; },
  aliasControl(c) {
    if (c.serveAs) { aliasCtl.serveAs = c.serveAs; }
    if (Array.isArray(c.drop)) { for (const id of c.drop) { delete aliasCtl.serveAs[id]; aliasCtl.dropped.push(id); } }
    return { serveAs: aliasCtl.serveAs, dropped: aliasCtl.dropped };
  },
  loadControl(c) { if (c.firstLoadMs) { loadCtl.firstLoadMs = c.firstLoadMs; firstLoaded.clear(); loadStats.windows = []; } return { ...loadCtl }; },
  loadStats() { return { ...loadStats }; },
  // count {signalIds, exact}: whole-dump change count per signal. exact: false answers only
  // stored signals (cheap) and {unknown: true} for the rest; exact: true always answers.
  count({ signalIds, exact }) {
    return { counts: signalIds.map((id) => {
      const s = sig(id);
      if (exact === false && !stored.has(id)) { return { signalId: id, unknown: true }; }
      return { signalId: id, count: s.n, bytes: s.n * (8 + s.width), bits: s.width, source: stored.has(id) ? 'store' : 'walked' };
    }) };
  },
  valueAt({ signalIds, t }) { return { values: signalIds.map((id) => { const s = sig(id); return s.error ? null : s.value(s.upper(t) - 1); }) }; },
  edge({ signalId, t, dir, kind }) {
    const s = sig(signalId);
    // rise/fall literally, strings and reals too (helper-v2 maps them to 'any' for text, but
    // the page must ask 'any' itself: a string row asking 'rise' here finds nothing).
    const want = kind === 'rise' ? '1' : kind === 'fall' ? '0' : null;
    const ok = (i) => want === null || s.value(i) === want;
    if (dir >= 0) { for (let i = s.upper(t); i < s.n; i++) { if (ok(i)) { return { t: s.times[i] }; } } }
    else { for (let i = s.lower(t) - 1; i >= 0; i--) { if (ok(i)) { return { t: s.times[i] }; } } }
    return { t: null };
  },
  search({ signalId, t, dir, value, wildcard }) {
    const s = sig(signalId);
    if (s.kind) { throw new Error(`search: a ${s.kind} signal has no bit pattern (use searchText, format string)`); }
    const cp = compilePattern(value, s.width, wildcard);
    if (dir >= 0) { for (let i = s.upper(t); i < s.n; i++) { if (matches(s, i, cp)) { return { t: s.times[i] }; } } }
    else { for (let i = s.lower(t) - 1; i >= 0; i--) { if (matches(s, i, cp)) { return { t: s.times[i] }; } } }
    return { t: null };
  },
  // v1 whole-signal fetch, kept for bit slices / fallbacks.
  // maxChanges (helper-v2 count first): a signal with more changes is {count, overCap}, no data.
  signals({ signalIds, widths, maxChanges }) {
    const out = [], parts = [];
    signalsLast = { maxChanges: maxChanges ?? null, bytes: 0, overCap: 0 };
    signalIds.forEach((id, k) => {
      const s = sig(id, widths && widths[k]);
      if (maxChanges !== undefined && s.n > maxChanges) {
        signalsLast.overCap++;
        out.push({ signalId: id, width: s.width, count: s.n, overCap: true, bytes: 0 });
        return;
      }
      const recs = []; for (let i = 0; i < s.n; i++) { recs.push([s.times[i], s.value(i)]); }
      const packed = packRecords(recs, s.width);
      out.push({ signalId: id, width: s.width, count: s.n, bytes: packed.length, min: s.min, max: s.max });
      parts.push(packed);
      signalsLast.bytes += packed.length;
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
  const entry = { timer: null, cancelled: false, cmd: req.cmd, signals: req.cmd === 'window' && Array.isArray(req.signals) ? req.signals.map((x) => x.signalId) : null };
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
        if (aliasCtl.dropped.length && (req.cmd === 'window' || req.cmd === 'valueAt' || req.cmd === 'count')) {
          (r && r.bin !== undefined ? r.result : r).aliasDropped = aliasCtl.dropped.splice(0);
        }
        const ms = Number(process.hrtime.bigint() - t0) / 1e6;
        if (r && r.bin !== undefined) { out = { id: req.id, result: r.result, ms }; bin = r.bin; } else { out = { id: req.id, result: r, ms }; }
      }
    } catch (e) { out = { id: req.id, error: String(e && e.message || e) }; }
    setTimeout(() => reply(out, bin), rtt / 2);
  }, rtt / 2);
}

if (hangReady) { setInterval(() => {}, 1 << 30); }
else { send(V1 ? { id: 0, ready: true } : { id: 0, ready: true, pid: process.pid, protocol: 2 }); }

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
    if (entry && entry.cmd === 'searchText') { textStats.cancelled++; }
    if (entry && entry.signals) { for (const id of entry.signals) { loadStats.cancels[id] = (loadStats.cancels[id] || 0) + 1; } }
    if (entry) { entry.cancelled = true; clearTimeout(entry.timer); live.delete(target); send({ id: target, cancelled: true }); }
    if (req.target !== undefined) { send({ id: req.id, result: { cancelled: !!entry, dropped: entry ? 1 : 0, running: 0 } }); }
    else if (!entry) { send({ id: req.id, cancelled: false }); }
    return;
  }
  schedule(req);
}).on('close', () => { if (!stuck) { process.exit(0); } });
