// Part of cmux's FSDB helper v2. GPL-3.0, as VaporView (see ../LICENSE).
// Clock descriptors (helper.js "clock descriptors"): answers for a verified 1-bit clock row from
// its grid and its off-grid intervals, never from the reader.
//
// A descriptor d: {period P, high H, firstRise R0, lo, verifiedEnd, intervals: [[s, e, [[t, v], ...]], ...]}
// (intervals in time order, not overlapping; e = Infinity or past verifiedEnd: off the grid to the
// end). Its row's changes (normalized as the store's: the last change per time, repeats dropped)
// are exactly:
//   - each interval's records, verbatim (values '0' '1' 'x' 'z'), and
//   - each grid edge tau >= R0 (rises at R0 + kP, value '1'; falls H later, value '0') at or before
//     verifiedEnd that is in no interval [s, e).
// The verify (clockseg) proves this: in sync, every expected edge came, at its time, with its
// value, and nothing else changed; anything else opened an interval. Before R0 it is all an
// interval from lo. The value before the first change is 'x'.
//
// Times are Numbers (exact below 2^53).
'use strict';

const gridAt = (d, t) => (t < d.firstRise ? '0' : ((t - d.firstRise) % d.period) < d.high ? '1' : '0');
const end = (d, iv) => (iv[1] < 0 ? Infinity : iv[1]);
// The interval holding t (s <= t < e), or -1; and the index of the first interval with s > t.
function ivIndex(d, t) {
  const ivs = d.intervals;
  let a = 0, b = ivs.length;  // first with s > t
  while (a < b) { const m = (a + b) >> 1; if (ivs[m][0] > t) { b = m; } else { a = m + 1; } }
  const k = a - 1;
  return { at: k >= 0 && t < end(d, ivs[k]) ? k : -1, after: a };
}
// Grid edges of a type ('rise' | 'fall' | 'any') at or after u / at or before u.
function gridUp(d, u, type) {
  const P = d.period, R0 = d.firstRise;
  const up = (off) => { const b = R0 + off; return u <= b ? b : b + Math.ceil((u - b) / P) * P; };
  if (type === 'rise') { return up(0); }
  if (type === 'fall') { return up(d.high); }
  return Math.min(up(0), up(d.high));
}
function gridDown(d, u, type) {  // (-Infinity: none)
  const P = d.period, R0 = d.firstRise;
  const down = (off) => { const b = R0 + off; return u < b ? -Infinity : b + Math.floor((u - b) / P) * P; };
  if (type === 'rise') { return down(0); }
  if (type === 'fall') { return down(d.high); }
  return Math.max(down(0), down(d.high));
}
// The value in effect at t (the last change at or before it).
function valueAt(d, t) {  // (t past verifiedEnd: as at verifiedEnd; callers ask within it)
  if (t < d.lo) { return 'x'; }
  if (t > d.verifiedEnd) { t = d.verifiedEnd; }
  const ivs = d.intervals;
  for (;;) {
    const { at } = ivIndex(d, t);
    if (at < 0) { return t < d.firstRise ? 'x' : gridAt(d, t); }
    const recs = ivs[at][2];
    let a = 0, b = recs.length;  // last record <= t
    while (a < b) { const m = (a + b) >> 1; if (recs[m][0] > t) { b = m; } else { a = m + 1; } }
    if (a > 0) { return recs[a - 1][1]; }
    if (ivs[at][0] <= d.lo) { return 'x'; }
    t = ivs[at][0] - 1;  // (nothing yet in the interval: the value before it)
  }
}
// The time of the row's first change (for the edge rule on it), or null.
function firstChange(d) { return find(d, d.lo - 1, 1, 'any', () => true); }
// The first change after t (dir 1) or the last before t (dir -1) that `ok(t, v, prev)` accepts;
// on the grid, only edges of `gridType` ('rise' | 'fall' | 'any' | null: none) are accepted, which
// is what ok() would say of any grid edge (an edge's previous value never matters: see edge()).
// -> time | null. Within [lo, verifiedEnd] only.
function find(d, t, dir, gridType, ok, skip = null) {  // (skip(g): a grid edge ok() would refuse)
  const ivs = d.intervals, V = d.verifiedEnd;
  if (dir > 0) {
    let u = Math.max(t + 1, d.lo);
    while (u <= V) {
      const { at, after } = ivIndex(d, u);
      if (at >= 0) {  // records in [u, e), then on from e
        const iv = ivs[at], recs = iv[2];
        let a = 0, b = recs.length;
        while (a < b) { const m = (a + b) >> 1; if (recs[m][0] < u) { a = m + 1; } else { b = m; } }
        let prev = a > 0 ? recs[a - 1][1] : (iv[0] <= d.lo ? 'x' : valueAt(d, iv[0] - 1));
        for (let k = a; k < recs.length && recs[k][0] <= V; k++) { if (ok(recs[k][0], recs[k][1], prev)) { return recs[k][0]; } prev = recs[k][1]; }
        u = end(d, iv);
        continue;
      }
      const stop = after < ivs.length ? ivs[after][0] : Infinity;  // (the grid stretch [u, stop))
      if (gridType) {
        const g = gridUp(d, Math.max(u, d.firstRise), gridType);
        if (g < stop && g <= V) { if (skip && skip(g)) { u = g + 1; continue; } return g; }
      }
      u = stop;
    }
    return null;
  }
  let u = Math.min(t - 1, V);
  while (u >= d.lo) {
    const { at, after } = ivIndex(d, u);
    if (at >= 0) {
      const iv = ivs[at], recs = iv[2];
      let a = 0, b = recs.length;  // records <= u: [0, a)
      while (a < b) { const m = (a + b) >> 1; if (recs[m][0] > u) { b = m; } else { a = m + 1; } }
      for (let k = a - 1; k >= 0; k--) {
        const prev = k > 0 ? recs[k - 1][1] : (iv[0] <= d.lo ? 'x' : valueAt(d, iv[0] - 1));
        if (ok(recs[k][0], recs[k][1], prev)) { return recs[k][0]; }
      }
      u = iv[0] - 1;
      continue;
    }
    const from = after > 0 ? end(d, ivs[after - 1]) : -Infinity;  // (the grid stretch [from, u])
    if (gridType) {
      const g = gridDown(d, u, gridType);
      if (g >= from && g >= d.firstRise) { if (skip && skip(g)) { u = g - 1; continue; } return g; }
    }
    u = from - 1;
  }
  return null;
}
// edge(t, dir, kind, start): as the addon's cacheEdge (kinds any, rise, fall, posedge, negedge,
// edge; the dump's first value, a first change at or before start, is never a posedge/negedge/
// edge). A grid edge is 0->1 or 1->0, or from x/z to the grid's value (after an interval, or as
// the row's first change): the same kind either way, so the grid is answered in closed form.
const GRID_OF = { any: 'any', edge: 'any', rise: 'rise', posedge: 'rise', fall: 'fall', negedge: 'fall' };
function edge(d, t, dir, kind = 'any', start = 0) {
  const k = kind || 'any';
  if (!(k in GRID_OF)) { throw new Error(`edge: unknown kind ${JSON.stringify(kind)}`); }
  const first = k === 'posedge' || k === 'negedge' || k === 'edge' ? firstChange(d) : null;
  const ok = (tt, v, prev) => {
    if (k === 'any') { return true; }
    if (k === 'rise' || k === 'fall') { return v === (k === 'rise' ? '1' : '0'); }
    if (tt === first && tt <= start) { return false; }
    const a = prev, b = v;
    const pos = (a === '0' && b !== '0') || ((a === 'x' || a === 'z') && b === '1');
    const neg = (a === '1' && b !== '1') || ((a === 'x' || a === 'z') && b === '0');
    return k === 'posedge' ? pos : k === 'negedge' ? neg : pos || neg;
  };
  // (the first change can be a grid edge: a row x until its first rise)
  return find(d, t, dir, GRID_OF[k], ok, first !== null && first <= start ? (g) => g === first : null);
}
// search(t, dir, value): as the addon's cacheSearch on a 1-bit row: the pattern's last character;
// '?' (and 'x' unless strict: a leading '!') matches any change, else the new value must be it.
function search(d, t, dir, pattern) {
  let p = String(pattern);
  const strict = p[0] === '!';
  if (strict) { p = p.slice(1); }
  let c = p.length ? p[p.length - 1] : '0';
  if (c === '?') { c = 'd'; } else if (c === 'x' || c === 'X') { c = strict ? 'x' : 'd'; } else if (c === 'z' || c === 'Z') { c = 'z'; } else if (c !== '1') { c = '0'; }
  if (c === 'd') { return find(d, t, dir, 'any', () => true); }
  return find(d, t, dir, c === '1' ? 'rise' : c === '0' ? 'fall' : null, (tt, v) => v === c);
}
// Every change in [a, b] in order (for checks and window synthesis): f(t, v).
function changes(d, a, b, f) {
  let t = a - 1;
  for (;;) {
    const n = find(d, t, 1, 'any', () => true);
    if (n === null || n > b) { return; }
    f(n, valueAt(d, n));
    t = n;
  }
}

// The number of changes at times in [x, y): the records there, plus the grid edges there
// (at or before verifiedEnd) less those inside intervals. Per descriptor, an index: every record
// time, and the grid edges inside intervals 0..i-1 (prefix sums).
function gridCount(d, x, y) {  // grid edges in [x, y), x >= firstRise
  const P = d.period, R0 = d.firstRise;
  const n = (off) => { const b = R0 + off; const lo = x <= b ? 0 : Math.ceil((x - b) / P), hi = y <= b ? 0 : Math.ceil((y - b) / P); return Math.max(0, hi - lo); };
  return n(0) + n(d.high);
}
function index(d) {
  if (d._ix && d._ix.n === d.intervals.length) { return d._ix; }
  const recT = [], pre = [0], V1 = d.verifiedEnd + 1;
  const inIv = (iv) => { const s = Math.max(iv[0], d.firstRise), e = Math.min(end(d, iv), V1); return e > s ? gridCount(d, s, e) : 0; };
  for (const iv of d.intervals) { for (const r of iv[2]) { recT.push(r[0]); } pre.push(pre[pre.length - 1] + inIv(iv)); }
  d._ix = { n: d.intervals.length, recT: Float64Array.from(recT), pre, inIv };
  return d._ix;
}
function countIn(d, x, y) {
  if (y <= x) { return 0; }
  const ix = index(d), ivs = d.intervals, V1 = d.verifiedEnd + 1;
  const lb = (arr, v) => { let a = 0, b = arr.length; while (a < b) { const m = (a + b) >> 1; if (arr[m] < v) { a = m + 1; } else { b = m; } } return a; };
  let n = lb(ix.recT, y) - lb(ix.recT, x);
  const gx = Math.max(x, d.firstRise), gy = Math.min(y, V1);
  if (gy <= gx) { return n; }
  n += gridCount(d, gx, gy);
  // intervals overlapping [gx, gy): i0 the first with e > gx, i1 the last with s < gy
  let a = 0, b = ivs.length;
  while (a < b) { const m = (a + b) >> 1; if (end(d, ivs[m]) > gx) { b = m; } else { a = m + 1; } }
  const i0 = a;
  a = i0; b = ivs.length;
  while (a < b) { const m = (a + b) >> 1; if (ivs[m][0] < gy) { a = m + 1; } else { b = m; } }
  const i1 = a - 1;
  if (i1 < i0) { return n; }
  const clip = (iv) => { const s = Math.max(iv[0], gx), e = Math.min(end(d, iv), gy); return e > s ? gridCount(d, s, e) : 0; };
  n -= clip(ivs[i0]);
  if (i1 > i0) { n -= clip(ivs[i1]); n -= ix.pre[i1] - ix.pre[i0 + 1]; }
  return n;
}
// window(t0, t1, buckets): the addon's windowOf (window.cpp.inc) for this row, byte for byte:
// {exact, count, records: Buffer, counts?: Buffer}. A record is an 8-byte little-endian delta from
// the previous record's time (the first from 0) and the value's character. The first record is the
// value in effect at t0 (at t0 itself); then, when the changes in [t0, t1) number at most
// 2 * buckets, every change in (t0, t1); else per bucket k (from t0 + ceil(span * k / B), the last
// ending at t1) its change count (uint32) and its first and last change after t0.
function window(d, t0, t1, B) {
  B = Math.max(1, B | 0);
  const recs = [];
  let prev = 0;
  const put = (t, v) => { recs.push([t - prev, v]); prev = t; };
  put(t0, valueAt(d, t0));
  const count = t1 > t0 ? countIn(d, t0, t1) : 0;
  const exact = count <= 2 * B;
  let counts = null;
  if (exact) {
    if (count) { changes(d, t0 + 1, t1 - 1, put); }
  } else {
    counts = Buffer.alloc(4 * B);
    const span = t1 - t0, big = span * B > Number.MAX_SAFE_INTEGER;
    const ceilDiv = (x) => { let q = Math.floor(x / B); while (q * B > x) { q--; } while ((q + 1) * B <= x) { q++; } return q * B === x ? q : q + 1; };  // (exact: x < 2^53)
    const edgeAt = (k) => (k === B ? t1 : big ? t0 + Number((BigInt(span) * BigInt(k) + BigInt(B) - 1n) / BigInt(B)) : t0 + ceilDiv(span * k));
    let L = t0;
    for (let k = 0; k < B; k++) {
      const R = edgeAt(k + 1);
      counts.writeUInt32LE(countIn(d, L, R), 4 * k);
      const from = Math.max(L, t0 + 1);
      if (R > from) {
        const f = find(d, from - 1, 1, 'any', () => true);
        if (f !== null && f < R) {
          put(f, valueAt(d, f));
          const l = find(d, R, -1, 'any', () => true);
          if (l !== null && l > f) { put(l, valueAt(d, l)); }
        }
      }
      L = R;
    }
  }
  const out = Buffer.alloc(recs.length * 9);
  for (let k = 0; k < recs.length; k++) { out.writeBigUInt64LE(BigInt(recs[k][0]), 9 * k); out[9 * k + 8] = recs[k][1].charCodeAt(0); }
  return { exact, count, records: out, ...(counts ? { counts } : {}) };
}

// The verify's merge: one range's scan (clockseg's line) into the descriptor being built (ranges
// in order, contiguous).
function merge(d, r, a) {
  d.changes += r.changes; d.edges += r.edges;
  const ivs = r.intervals;
  let k = 0;
  if (d.open) {
    if (ivs.length && ivs[0][0] === a) { d.open[2].push(...ivs[0][2]); d.open[1] = ivs[0][1]; k = 1; if (d.open[1] !== -1) { d.open = null; } }
    else { d.open[1] = a; d.open = null; }  // (in sync again at a)
  }
  for (; k < ivs.length; k++) {
    const iv = [ivs[k][0], ivs[k][1], ivs[k][2]], last = d.intervals[d.intervals.length - 1];
    // (a closed interval and the next with no grid edge between them are one: the changes and the
    // values are the same either way, since outside intervals the row is the grid. A clock that
    // stops split into one interval per segment otherwise, each a deviation toward the 1% limit:
    // review L2)
    if (last && last[1] >= d.firstRise && last[1] <= iv[0] && gridCount(d, last[1], iv[0]) === 0) {
      last[2].push(...iv[2]); last[1] = iv[1]; if (last[1] === -1) { d.open = last; }
      continue;
    }
    d.intervals.push(iv); if (iv[1] === -1) { d.open = iv; }
  }
  d.records = d.intervals.reduce((x, iv) => x + iv[2].length, 0);
}

module.exports = { gridAt, valueAt, edge, search, changes, find, firstChange, countIn, window, merge };
