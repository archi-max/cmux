// A VCD reader and a dump provider for cmux-trace.js's checks (run.sh trace): values, the change
// in effect at a time, and edges, the questions the page's dump answers (host.js) in the app.
/* exported traceVcd */
function traceVcd(text) {
  const sig = new Map();   // path -> { width, changes: [[t, bits]] }
  const byCode = new Map();
  const scope = [];
  let t = 0;
  const toks = text.split(/\s+/);
  for (let i = 0; i < toks.length; i++) {
    const w = toks[i];
    if (w === '$scope') { scope.push(toks[i + 2]); i += 3; continue; }
    if (w === '$upscope') { scope.pop(); i += 1; continue; }
    if (w === '$var') {
      const width = Number(toks[i + 2]), code = toks[i + 3], name = toks[i + 4];
      const path = [...scope, name].join('.');
      const s = { width, changes: [] };
      if (!sig.has(path)) { sig.set(path, s); }
      if (!byCode.has(code)) { byCode.set(code, []); }
      byCode.get(code).push(sig.get(path));
      while (toks[i] !== '$end') { i++; }
      continue;
    }
    if (w.startsWith('$')) { if (w !== '$dumpvars' && w !== '$end') { while (i < toks.length && toks[i] !== '$end') { i++; } } continue; }
    if (w.startsWith('#')) { t = Number(w.slice(1)); continue; }
    let bits, code;
    if (w[0] === 'b' || w[0] === 'B') { bits = w.slice(1).toLowerCase(); code = toks[++i]; } else if (w) { bits = w[0].toLowerCase(); code = w.slice(1); } else { continue; }
    for (const s of byCode.get(code) || []) {
      if (bits.length < s.width) { bits = (bits[0] === 'x' || bits[0] === 'z' ? bits[0] : '0').repeat(s.width - bits.length) + bits; }
      const last = s.changes[s.changes.length - 1];
      if (last && last[0] === t) { last[1] = bits; } else if (!last || last[1] !== bits) { s.changes.push([t, bits]); }
    }
  }
  const idx = (c, at) => { let lo = 0, hi = c.length; while (lo < hi) { const m = (lo + hi) >> 1; if (c[m][0] <= at) { lo = m + 1; } else { hi = m; } } return lo - 1; };
  const valueAt = (s, at) => { const i = idx(s.changes, at); return i < 0 ? 'x'.repeat(s.width) : s.changes[i][1]; };
  const isEdge = (prev, now, edge) => {
    const pos = (prev === '0' && now !== '0') || ((prev === 'x' || prev === 'z') && now === '1');
    const neg = (prev === '1' && now !== '1') || ((prev === 'x' || prev === 'z') && now === '0');
    return edge === 'PosEdge' ? pos : edge === 'NegEdge' ? neg : pos || neg;
  };
  const stats = { values: 0, lastChange: 0, prevEdge: 0 };
  const provider = {
    stats,
    async values(paths, at) { stats.values++; const out = new Map(); for (const p of paths) { const s = sig.get(p); out.set(p, s ? valueAt(s, at) : undefined); } return out; },
    async lastChange(p, at) { stats.lastChange++; const s = sig.get(p); if (!s) { return null; } const i = idx(s.changes, at); return i < 0 ? 0 : s.changes[i][0]; },
    async prevEdge(p, at, edge) {
      stats.prevEdge++;
      const s = sig.get(p);
      if (!s) { return null; }
      for (let i = idx(s.changes, at); i > 0; i--) { if (isEdge(s.changes[i - 1][1], s.changes[i][1], edge)) { return s.changes[i][0]; } }
      return null;
    },
  };
  return { sig, provider };
}
