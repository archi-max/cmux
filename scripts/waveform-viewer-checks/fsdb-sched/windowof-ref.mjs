// run.sh fsdb-sched: the FSDB addon's windowOf (fsdb-helper-v2 addon/window.cpp.inc), in JS over a
// row's normalized changes ([[t, v], ...], times ascending): the exact, count, records and counts a
// window reply carries, byte for byte. For clockdesc-check.mjs and check.mjs (clock descriptors).
export function refWindow(norm, t0, t1, B) {
  const times = norm.map((c) => c[0]), n = times.length;
  const lowerIdx = (t, from) => { let a = from, b = n; while (a < b) { const m = (a + b) >> 1; if (times[m] < t) { a = m + 1; } else { b = m; } } return a; };
  const upperIdx = (t, from) => { let a = from, b = n; while (a < b) { const m = (a + b) >> 1; if (times[m] <= t) { a = m + 1; } else { b = m; } } return a; };
  const lo = lowerIdx(t0, 0), first = upperIdx(t0, lo), hi = t1 > t0 ? lowerIdx(t1, first) : lo, count = hi - lo, exact = count <= 2 * B;
  const rec = []; let prev = 0n;
  const put = (t, k) => { const b = Buffer.alloc(9); b.writeBigUInt64LE(BigInt(t) - prev); prev = BigInt(t); b[8] = (k < 0 ? 'x' : norm[k][1]).charCodeAt(0); rec.push(b); };
  put(t0, first - 1);
  let counts = null;
  if (exact) { for (let k = first; k < hi; k++) { put(times[k], k); } }
  else {
    counts = Buffer.alloc(4 * B);
    const span = BigInt(t1 - t0); let a = lo;
    for (let k = 0; k < B; k++) {
      const b = k + 1 === B ? hi : lowerIdx(t0 + Number((span * BigInt(k + 1) + BigInt(B) - 1n) / BigInt(B)), a);
      counts.writeUInt32LE(b - a, 4 * k);
      const f = Math.max(a, first);
      if (b > f) { put(times[f], f); if (b - f >= 2) { put(times[b - 1], b - 1); } }
      a = b;
    }
  }
  return { exact, count, records: Buffer.concat(rec), ...(counts ? { counts } : {}) };
}
