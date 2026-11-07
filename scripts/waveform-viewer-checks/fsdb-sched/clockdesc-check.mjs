// run.sh fsdb-sched: fsdb-helper-v2's clock descriptors (clockdesc.js) answer exactly as the
// reader's store would, on random clock-like rows: gated stretches, x/z, glitches, a frequency
// change, a clock that stops, odd starts. Each row is scanned as clockseg scans it (the same
// algorithm, in JS: stub-addon.cjs clockScan's), over random contiguous ranges merged as the
// verify job merges them, then every answer is compared with a brute-force model of the addon's
// cacheValueAt / cacheEdge / cacheSearch / windowOf over the row's normalized changes (windows byte
// for byte, at every level of the page's tiles, bucketed ones included).
// Usage: node clockdesc-check.mjs <fsdb-helper-v2 folder> [cases]
import { createRequire } from 'node:module';
import path from 'node:path';
import { refWindow } from './windowof-ref.mjs';

const require = createRequire(import.meta.url);
const cd = require(path.join(path.resolve(process.argv[2]), 'clockdesc.js'));
const CASES = Number(process.argv[3] || 300);
let fails = 0, compared = 0;
const check = (ok, what) => { if (!ok) { fails++; if (fails <= 20) { console.log('FAIL ' + what); } } };

let seed = Number(process.env.SEED || 12345);
const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const ri = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const pick = (xs) => xs[ri(0, xs.length - 1)];

// A row: the grid, then deviations, normalized as the store does (the last change per time wins,
// repeats dropped; 'x' before the first change).
function makeRow() {
  const P = 2 * ri(2, 20), H = ri(1, P - 1), R0 = ri(0, 3 * P), T = ri(20, 400) * P;
  const m = new Map();
  if (rnd() < 0.8) { m.set(0, pick(['0', '0', 'x', '1'])); }
  for (let t = R0; t <= T; t += P) { m.set(t, '1'); if (t + H <= T) { m.set(t + H, '0'); } }
  const n = ri(0, 12);
  for (let k = 0; k < n; k++) {
    const what = ri(0, 5), t = ri(0, T);
    if (what === 0) { m.set(t, pick(['x', 'z'])); }
    else if (what === 1) { m.set(t, pick(['0', '1'])); }  // a glitch
    else if (what === 2) { const w = ri(1, 6) * P; for (const k2 of [...m.keys()]) { if (k2 > t && k2 < t + w) { m.delete(k2); } } }  // gated: held
    else if (what === 3) { for (const k2 of [...m.keys()]) { if (k2 > t) { m.delete(k2); } } }  // stops
    else if (what === 4) { const w = ri(2, 8) * P, p2 = 2 * ri(1, P); for (const k2 of [...m.keys()]) { if (k2 > t && k2 < t + w) { m.delete(k2); } } for (let u = t; u < t + w; u += p2) { m.set(u, '1'); m.set(u + p2 / 2, '0'); } }  // frequency change
    else { m.set(t, pick(['0', '1', 'x', 'z'])); m.set(t + 1, pick(['0', '1'])); }
  }
  const ts = [...m.keys()].filter((t) => t <= T).sort((a, b) => a - b);
  const norm = []; let pv = 'x';
  for (const t of ts) { const v = m.get(t); if (v !== pv) { norm.push([t, v]); pv = v; } }
  return { P, H, R0, T, norm };
}

// clockseg's scan of [a, b) (stub-addon.cjs clockScan, over an array).
function scan(norm, a, b, P, H, R0) {
  let vBefore = 'x';
  for (const c of norm) { if (c[0] < a) { vBefore = c[1]; } }
  const inR = norm.filter((c) => c[0] >= a && c[0] < b);
  const g = (t) => (t < R0 ? '0' : ((t - R0) % P) < H ? '1' : '0');
  const nextEdge = (t) => { if (t < R0) { return R0; } const bs = t - (t - R0) % P; return t - bs < H ? bs + H : bs + P; };
  const onEdge = (t) => t >= R0 && ((t - R0) % P === 0 || (t - R0) % P === H);
  const ivs = []; let inSync = false, expE = 0, ivS = 0, rec = [], edges = 0, changes = 0;
  const open = (s0) => { inSync = false; ivS = s0; rec = []; };
  const close = (e) => { ivs.push([ivS, e, rec]); rec = []; };
  const gb = a === 0 || a - 1 < R0 ? '0' : g(a - 1);
  if (a >= R0 && vBefore === gb) { inSync = true; expE = nextEdge(a - 1); } else { open(a); }
  for (const [t, v] of inR) {
    changes++;
    if (inSync) {
      if (t === expE && v === g(t)) { edges++; expE = nextEdge(t); continue; }
      open(Math.min(t, expE));
    }
    if (onEdge(t) && v === g(t)) { close(t); inSync = true; edges++; expE = nextEdge(t); continue; }
    rec.push([t, v]);
  }
  if (inSync && expE < b) { open(expE); }
  if (!inSync) { close(-1); }
  return { vBefore, changes, edges, intervals: ivs };
}
function describe(row, P, H, R0) {
  const lo = 0, end = row.T + 1;
  const d = { period: P, high: H, firstRise: R0, lo, verifiedEnd: row.T, changes: 0, edges: 0, records: 0, intervals: [], open: null };
  for (let a = lo; a < end;) {
    const b = Math.min(end, a + ri(1, Math.max(2, Math.ceil(row.T / ri(1, 12)))));
    cd.merge(d, scan(row.norm, a, b, P, H, R0), a);
    a = b;
  }
  if (d.open) { d.open[1] = end; d.open = null; }
  return d;
}

// The addon's store answers (window.cpp.inc cacheValueAt / cacheEdge / cacheSearch), brute force.
const refValue = (norm, t) => { let v = 'x'; for (const [u, w] of norm) { if (u <= t) { v = w; } else { break; } } return v; };
function refEdge(norm, t, dir, kind, start) {
  const isEdge = (k) => {
    const b = norm[k][1];
    if (kind === 'any') { return true; }
    if (kind === 'rise' || kind === 'fall') { return b === (kind === 'rise' ? '1' : '0'); }
    if (k === 0 && norm[0][0] <= start) { return false; }
    const a = k > 0 ? norm[k - 1][1] : 'x';
    const xz = (c) => c === 'x' || c === 'z';
    const pos = (a === '0' && b !== '0') || (xz(a) && b === '1');
    const neg = (a === '1' && b !== '1') || (xz(a) && b === '0');
    return kind === 'posedge' ? pos : kind === 'negedge' ? neg : pos || neg;
  };
  if (dir > 0) { for (let k = 0; k < norm.length; k++) { if (norm[k][0] > t && isEdge(k)) { return norm[k][0]; } } return null; }
  for (let k = norm.length - 1; k >= 0; k--) { if (norm[k][0] < t && isEdge(k)) { return norm[k][0]; } }
  return null;
}
function refSearch(norm, t, dir, pattern) {
  let p = pattern; const strict = p[0] === '!'; if (strict) { p = p.slice(1); }
  let c = p.length ? p[p.length - 1] : '0';
  if (c === '?') { c = 'd'; } else if (c === 'x' || c === 'X') { c = strict ? 'x' : 'd'; } else if (c === 'z' || c === 'Z') { c = 'z'; } else if (c !== '1') { c = '0'; }
  const ok = (k) => c === 'd' || norm[k][1] === c;
  if (dir > 0) { for (let k = 0; k < norm.length; k++) { if (norm[k][0] > t && ok(k)) { return norm[k][0]; } } return null; }
  for (let k = norm.length - 1; k >= 0; k--) { if (norm[k][0] < t && ok(k)) { return norm[k][0]; } }
  return null;
}

// The page's windows (window_cache.ts): tiles at level L span 1024 * 2^L with 1024 buckets each
// (256 for wide rows), a request covers a run of tiles; plus odd spans and bucket counts.
function windowsFor(T, R0) {
  const out = [];
  for (let L = 0; 1024 * 2 ** L <= 4 * T; L++) {
    const span = 1024 * 2 ** L, tiles = Math.ceil((T + 1) / span);
    for (let r = 0; r < 3; r++) { const i = ri(0, tiles - 1), m = ri(1, 3); out.push([i * span, (i + m) * span, 1024 * m]); }
    out.push([0, span, 1024], [0, span, 256]);
  }
  for (let k = 0; k < 6; k++) { const t0 = ri(0, T), t1 = t0 + ri(0, T); out.push([t0, t1, ri(1, 64)]); }
  out.push([R0, R0, 4], [0, T + 1, 1], [0, T + 1, 1 << 22 > 4 * T ? 4 * T : 1 << 22]);
  return out;
}
let windows = 0, bucketed = 0;
const KINDS = ['any', 'rise', 'fall', 'posedge', 'negedge', 'edge'];
const PATTERNS = ['0', '1', 'x', 'z', '?', '!x', '!z', '!?', '10', 'X'];
for (let c = 0; c < CASES; c++) {
  const row = makeRow();
  // The fitted grid is usually the row's, sometimes off (any grid gives a correct descriptor).
  const off = rnd() < 0.2;
  const P = off ? 2 * ri(2, 20) : row.P, H = off ? ri(1, P - 1) : row.H, R0 = off ? ri(0, 3 * P) : row.R0;
  const d = describe(row, P, H, R0);
  const tag = `case ${c} (P ${P} H ${H} R0 ${R0} T ${row.T}, ${row.norm.length} changes, ${d.intervals.length} intervals)`;
  const all = []; cd.changes(d, 0, row.T, (t, v) => all.push([t, v]));
  check(JSON.stringify(all) === JSON.stringify(row.norm), `${tag}: changes() differs: ${JSON.stringify(all.slice(0, 8))} vs ${JSON.stringify(row.norm.slice(0, 8))}`);
  const ts = [0, 1, row.T, row.T + 1, R0, R0 - 1, R0 + 1];
  for (const [t] of row.norm) { if (rnd() < 0.15) { ts.push(t - 1, t, t + 1); } }
  for (let k = 0; k < 40; k++) { ts.push(ri(0, row.T + 1)); }
  for (const iv of d.intervals) { ts.push(iv[0] - 1, iv[0], iv[0] + 1, iv[1] - 1, iv[1], iv[1] + 1); }
  for (const [t0, t1, B] of windowsFor(row.T, R0)) {
    const w = cd.window(d, t0, t1, B), rw = refWindow(row.norm, t0, t1, B);
    windows++; if (!rw.exact) { bucketed++; }
    const same = w.exact === rw.exact && w.count === rw.count && w.records.equals(rw.records) && (!!w.counts === !!rw.counts) && (!w.counts || w.counts.equals(rw.counts));
    check(same, `${tag}: window [${t0}, ${t1}) x ${B}: exact ${w.exact}/${rw.exact}, count ${w.count}/${rw.count}, records ${w.records.length}/${rw.records.length} B${w.records.equals(rw.records) ? ' (same)' : ''}, counts ${w.counts ? w.counts.length : '-'}/${rw.counts ? rw.counts.length : '-'}${w.counts && rw.counts && w.counts.equals(rw.counts) ? ' (same)' : ''}`);
  }
  for (const t of ts.filter((x) => x >= 0 && x <= row.T + 1)) {
    compared++;
    const v = cd.valueAt(d, t), rv = refValue(row.norm, t);
    check(v === rv, `${tag}: valueAt ${t} = ${v}, the reader ${rv}`);
    for (const dir of [1, -1]) {
      for (const kind of KINDS) {
        const start = rnd() < 0.5 ? 0 : row.norm.length ? row.norm[0][0] : 0;
        const e = cd.edge(d, t, dir, kind, start), re = refEdge(row.norm, t, dir, kind, start);
        check(e === re, `${tag}: edge ${t} dir ${dir} ${kind} start ${start} = ${e}, the reader ${re}`);
      }
      for (const p of PATTERNS) {
        const s = cd.search(d, t, dir, p), rs = refSearch(row.norm, t, dir, p);
        check(s === rs, `${tag}: search ${t} dir ${dir} ${p} = ${s}, the reader ${rs}`);
      }
    }
  }
}
// A clock that stops early, scanned in many segments (review L2): each segment that starts in the
// stopped stretch opened an interval of its own, touching the last one with no records, and every
// one counted toward the 1% deviation limit (16-30 on a real dump). Touching intervals are merged:
// one interval for the stop, the answers unchanged.
{
  const P = 10, H = 5, R0 = 5, T = 100000, m = [];
  for (let t = R0; t <= 2000; t += P) { m.push([t, '1'], [t + H, '0']); }
  const norm = [[0, '0'], ...m];
  const d = { period: P, high: H, firstRise: R0, lo: 0, verifiedEnd: T, changes: 0, edges: 0, records: 0, intervals: [], open: null };
  for (let a = 0; a < T + 1; a += 997) { cd.merge(d, scan(norm, a, Math.min(T + 1, a + 997), P, H, R0), a); }
  if (d.open) { d.open[1] = T + 1; d.open = null; }
  const all = []; cd.changes(d, 0, T, (t, v) => all.push([t, v]));
  const ok = JSON.stringify(all) === JSON.stringify(norm) && cd.valueAt(d, 50000) === '0' && cd.edge(d, 3000, -1, 'any', 0) === 2000 && cd.edge(d, 3000, 1, 'any', 0) === null;
  check(ok && d.intervals.length <= 1, `a clock stopped over 98 of 101 segments (997 time units each): ${d.intervals.length} intervals (want 1), answers ${ok ? 'exact' : 'differ'}`);
  if (ok && d.intervals.length <= 1) { console.log(`a stopped clock over 101 segments (997 each): ${d.intervals.length} interval`); }
}
console.log(`${CASES} rows, ${windows} windows (byte for byte, ${bucketed} bucketed), ${compared} times x (1 value + 2 dirs x (6 edge kinds + ${PATTERNS.length} patterns))`);
if (fails) { console.log(`CLOCKDESC CHECKS FAILED: ${fails}`); process.exit(1); }
console.log('CLOCKDESC CHECKS PASSED');
