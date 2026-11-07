// run.sh fsdb-values, on the host: the real helper v2 (built there by its build.sh) over the
// writer-made fixture (make-values-fsdb.cpp): string, real (double and float) and event
// variables through every path the viewer uses: cold and stored valueAt, ranged (cold),
// exact and decimated windows, edges, search, searchText, count, derive, searchAll, and a
// permanent per-signal error for a value encoding the reader can't give.
// Optionally a real dump too: FSDB_VALUES_DUMP=<file> FSDB_VALUES_EXPECT=<path>=<value at 0>
// (no defaults: both or neither). A second fixture (big.fsdb: long repeated text) checks that
// text windows are bounded. One worker per helper, one helper at a time (host memory).
// cap.fsdb is the fixture again under another name, so nothing of it is in the store cache.
// long.fsdb (two strings, every change 6000 bytes) checks that a window of the page's usual
// size (2 to 3 tiles of 1024 buckets) and a whole load fit the text budget by cutting shorter.
// Usage: node values-check.js <installed helper dir> <fixture.fsdb> <big.fsdb> <cap.fsdb> <long.fsdb>
'use strict';
const { spawn } = require('node:child_process');
const zlib = require('node:zlib');
const path = require('node:path');

const [dir, fixture, bigFixture, capFixture, longFixture] = process.argv.slice(2);
let fails = 0, passes = 0;
const check = (ok, what) => { if (ok) { passes++; console.log('ok   ' + what); } else { fails++; console.log('FAIL ' + what); } };
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function startHelper(extra = []) {
  const p = spawn('bash', [path.join(dir, 'cmux-helper-v2.sh'), '--workers', '1', ...extra], { stdio: ['pipe', 'pipe', 'ignore'] });
  let buf = Buffer.alloc(0), want = null, nextId = 1;
  const pending = new Map();
  let ready;
  const readyP = new Promise((r) => { ready = r; });
  p.stdout.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (want) {
        if (buf.length < want.n) { return; }
        const bin = buf.subarray(0, want.n); buf = buf.subarray(want.n);
        const m = want.m; want = null;
        deliver(m, bin);
        continue;
      }
      const nl = buf.indexOf(10);
      if (nl < 0) { return; }
      const line = buf.subarray(0, nl).toString(); buf = buf.subarray(nl + 1);
      let m; try { m = JSON.parse(line); } catch (e) { continue; }
      if (m.binLength) { want = { m, n: m.binLength }; continue; }
      deliver(m, null);
    }
  });
  function deliver(m, bin) {
    if (m.id === 0) { if (m.ready) { ready(); } return; }
    if (m.partial) { return; }
    const r = pending.get(m.id);
    if (r) { pending.delete(m.id); r({ m, bin }); }
  }
  const req = (cmd, args = {}) => new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    p.stdin.write(JSON.stringify({ id, cmd, ...args }) + '\n');
  });
  const gone = new Promise((r) => p.on('exit', r));
  return { req, ready: readyP, stop: () => { p.stdin.end(); setTimeout(() => p.kill(), 3000).unref(); return gone; } };
}

// The window reply's signals, records decoded the way the page decodes them.
function decodeWindow({ m, bin }, widths = []) {
  if (m.error) { return [{ h: { error: m.error }, recs: [] }]; }
  let off = 0;
  return m.result.signals.map((h, i) => {
    if (h.error) { return { h, recs: [] }; }
    const raw = zlib.inflateRawSync(bin.subarray(off, off + h.bytes)); off += h.bytes;
    off += h.bucketBytes;
    const recs = [];
    let t = 0;
    for (let o = 0; o < raw.length;) {
      t += Number(raw.readBigUInt64LE(o));
      if (h.text) {
        const len = raw.readUInt32LE(o + 8);
        recs.push([t, raw.subarray(o + 12, o + 12 + len).toString('utf8')]); o += 12 + len;
      } else {
        const w = widths[i] || 1;
        recs.push([t, raw.subarray(o + 8, o + 8 + w).toString('latin1')]); o += 8 + w;
      }
    }
    return { h, recs };
  });
}

async function varsOf(h, scopePathParts) {
  const open = await h.req('children', { scopeOffsetIdx: scopePathParts.idx, scopePath: scopePathParts.path });
  return open.m.result;
}

async function findVar(h, top, fullPath) {
  const parts = fullPath.split('.');
  let scope = top.find((s) => s.name === parts[0]);
  let p = parts[0];
  for (let i = 1; scope && i < parts.length; i++) {
    const r = await varsOf(h, { idx: scope.scopeOffsetIdx, path: p });
    if (i === parts.length - 1) { return (r.vars || []).find((v) => v.name === parts[i]); }
    scope = (r.scopes || []).find((s) => s.name === parts[i]);
    p += '.' + parts[i];
  }
  return undefined;
}

const LONG = Array.from({ length: 300 }, (_, i) => String.fromCharCode(97 + (i % 26))).join('');
const NAIVE = 'naïve ü';
const EURO = '\u20ac'.repeat(2000);           // big.fsdb's long value: 6000 bytes
const EURO_SHOWN = '\u20ac'.repeat(1365) + '\u2026';  // as a window shows it: 4 KB at a character boundary, then an ellipsis

async function main() {
  const h = startHelper();
  await h.ready;
  const o = await h.req('open', { file: fixture });
  check(!o.m.error, 'the helper opens the fixture: ' + (o.m.error || 'ok'));
  if (o.m.error) { return; }
  const top = o.m.result.top;
  const kids = await varsOf(h, { idx: top[0].scopeOffsetIdx, path: top[0].name });
  const v = Object.fromEntries((kids.vars || []).map((x) => [x.name, x]));
  const enc = (n) => v[n] && [v[n].encoding, v[n].type];
  check(eq(enc('msg'), ['String', 'string']), `a string variable is listed as String: ${JSON.stringify(enc('msg'))}`);
  check(eq(enc('r'), ['Real', 'real']) && eq(enc('f'), ['Real', 'real']), `reals are listed as Real: ${JSON.stringify([enc('r'), enc('f')])}`);
  check(eq(enc('ev'), ['BitVector', 'event']) && eq(enc('clk'), ['BitVector', 'wire']), `events and wires stay BitVectors: ${JSON.stringify([enc('ev'), enc('clk')])}`);
  const id = (n) => v[n].signalId;

  const msgAt = [[0, 'idle'], [5, 'idle'], [10, 'store'], [25, 'store'], [35, ''], [45, LONG], [55, NAIVE], [99, 'idle']];
  const rAt = [[0, '1.5'], [15, '-2.25'], [35, '0.1'], [45, '1' + '0'.repeat(300)], [55, '0.0000001'], [65, '-0'], [75, '3'], [85, '123456.789']];
  const fAt = [[0, '0.5'], [15, '0.1'], [25, '-3.25']];
  async function values(stage) {
    for (const [name, table] of [['msg', msgAt], ['r', rAt], ['f', fAt]]) {
      const got = [];
      let cold = 0;
      for (const [t] of table) { const r = await h.req('valueAt', { signalIds: [id(name)], t }); got.push(r.m.result ? r.m.result.values[0] : r.m.error); cold += r.m.result ? r.m.result.cold : 0; }
      const want = table.map((x) => x[1]);
      check(eq(got, want), `${stage} valueAt of ${name}: ${eq(got, want) ? want.length + ' values' : JSON.stringify(got).slice(0, 300)}`);
      if (stage === 'cold') { check(cold === table.length, `... all read cold: ${cold}/${table.length}`); }
    }
  }
  await values('cold');

  // A short range of cold signals: the ranged (view-window) walk.
  const rg = decodeWindow(await h.req('window', { signals: [{ signalId: id('msg'), width: 1 }, { signalId: id('r'), width: 1 }], t0: 40, t1: 60, buckets: 64 }));
  check(rg[0].h && rg[0].h.ranged === true && rg[0].h.text === true && eq(rg[0].recs, [[40, LONG], [50, NAIVE]]),
    `a ranged cold window of msg is text: ${JSON.stringify(rg[0].h)} ${JSON.stringify(rg[0].recs).slice(0, 120)}`);
  check(rg[1].h && rg[1].h.text === true && eq(rg[1].recs, [[40, '1' + '0'.repeat(300)], [50, '0.0000001']]), `... and of r: ${JSON.stringify(rg[1].recs).slice(0, 120)}`);
  check(rg[1].h && rg[1].h.min === undefined && rg[1].h.max === undefined, `... a ranged real window has no min/max (a slice's range would rescale the row): ${JSON.stringify([rg[1].h.min, rg[1].h.max])}`);
  await new Promise((r) => setTimeout(r, 500));  // (the background whole walks)

  const names = ['msg', 'r', 'f', 'ev', 'n'];
  const all = decodeWindow(await h.req('window', { signals: names.map((n) => ({ signalId: id(n), width: v[n].width })), t0: 0, t1: 201, buckets: 1024 }), names.map((n) => v[n].width));
  const [wm, wr, wf, we, wn] = all;
  check(wm.h.exact && wm.h.kind === 'string' && eq(wm.recs, [[0, 'idle'], [10, 'store'], [30, ''], [40, LONG], [50, NAIVE], [60, 'idle']]),
    `msg's window: same-time changes collapse to the last, repeats dropped: ${JSON.stringify(wm.recs.map((x) => [x[0], x[1].slice(0, 8)]))}`);
  check(wr.h.kind === 'real' && eq(wr.recs.map((x) => x[1]), ['1.5', '-2.25', '0.1', '1' + '0'.repeat(300), '0.0000001', '-0', '3', '123456.789']) && wr.h.min === -2.25 && wr.h.max === 1e300,
    `r's window: reals as the viewer prints a VCD's (shortest digits, no exponent), min/max: ${JSON.stringify(wr.recs.map((x) => x[1].slice(0, 12)))} ${wr.h.min} ${wr.h.max}`);
  check(eq(wf.recs, [[0, '0.5'], [10, '0.1'], [20, '-3.25']]), `f (4-byte float) prints as a float: ${JSON.stringify(wf.recs)}`);
  check(!we.h.text && eq(we.recs.map((x) => x[0]), [0, 15, 35]), `each event is a change (a repeat is not dropped): ${JSON.stringify(we.recs)}`);
  check(!wn.h.text && wn.recs.length === 2 && wn.recs[1][1] === '00000000000000000000000000001001', `bit vectors are unchanged: ${JSON.stringify(wn.recs)}`);
  await values('stored');

  const dec = decodeWindow(await h.req('window', { signals: [{ signalId: id('msg'), width: 1 }], t0: 0, t1: 201, buckets: 1 }))[0];
  const counts = dec.h.bucketBytes === 4;
  check(!dec.h.exact && dec.h.count === 6 && counts && eq(dec.recs, [[0, 'idle'], [10, 'store'], [60, 'idle']]),
    `a decimated window of msg: the bucket's first and last change, as text: ${JSON.stringify(dec.h)} ${JSON.stringify(dec.recs)}`);

  const edge = async (n, t, dir, kind) => { const r = await h.req('edge', { signalId: id(n), t, dir, kind }); return r.m.result ? r.m.result.t : r.m.error; };
  const edges = [await edge('msg', 10, 1, 'any'), await edge('msg', 50, -1, 'any'), await edge('msg', 10, 1, 'rise'), await edge('r', 60, 1, 'fall'), await edge('ev', 15, 1, 'any')];
  check(eq(edges, [30, 40, 30, 70, 35]), `edges: every string/real change is one (rise/fall = any), events repeat: ${JSON.stringify(edges)}`);

  const s = await h.req('search', { signalId: id('msg'), t: 0, dir: 1, value: '1' });
  check(/searchText/.test(s.m.error || ''), `a bit-pattern search on a string says to use searchText: ${s.m.error || JSON.stringify(s.m.result)}`);
  const st = async (n, pattern, t = 0, dir = 1) => { const r = await h.req('searchText', { signalId: id(n), t, dir, inclusive: true, format: 'string', pattern }); return r.m.result ? r.m.result.t : r.m.error; };
  const texts = [await st('msg', '^na'), await st('msg', 'STORE'), await st('msg', 'idle', 60, -1), await st('r', '^-0$'), await st('r', 'e'), await st('msg', '(')];
  check(eq(texts, [50, 10, 60, 60, null, null]), `searchText format string: a case-insensitive regex over the text, an invalid one matches nothing: ${JSON.stringify(texts)}`);

  const odd = decodeWindow(await h.req('window', { signals: [{ signalId: id('odd'), width: 4 }, { signalId: id('clk'), width: 1 }], t0: 0, t1: 201, buckets: 64 }), [4, 1]);
  check(odd[0].h.error && /unsupported/.test(odd[0].h.error) && odd[0].h.permanent === true && odd[1].recs.length > 10,
    `an encoding the reader can't give is a permanent error for that signal only: ${JSON.stringify(odd[0].h)}`);
  const transient = decodeWindow(await h.req('window', { signals: [{ signalId: id('clk'), width: 1 }], t0: 0, t1: 201, buckets: 64 }))[0];
  check(transient.h && !transient.h.error && transient.h.permanent === undefined, 'a readable signal has no permanent flag');
  const oddV = await h.req('valueAt', { signalIds: [id('odd')], t: 5 });
  check(oddV.m.result && oddV.m.result.values[0] === null, `valueAt of it is null: ${JSON.stringify(oddV.m.result)}`);

  const cnt = await h.req('count', { signalIds: [id('msg'), id('r')], exact: true });
  check(cnt.m.result && cnt.m.result.counts[0].count === 6 && cnt.m.result.counts[1].count === 8, `count of msg and r: ${JSON.stringify(cnt.m.result)}`);
  const der = await h.req('derive', { expr: 'top.r + 1' });
  check(/real signal/.test(der.m.error || ''), `a real in an expression is refused: ${der.m.error || 'derived'}`);
  check(eq(enc('P'), ['Real', 'parameter']) && eq(enc('tm'), ['Real', 'time']), `a parameter and a time var are listed as Real: ${JSON.stringify([enc('P'), enc('tm')])}`);
  for (const e of ['top.P + 1', 'top.tm + 1']) {
    const d = await h.req('derive', { expr: e });
    check(!d.m.error, `... but they are bit vectors, and derive ${e}: ${d.m.error || 'ok'}`);
  }
  const sa = await h.req('searchAll', { value: '1', t: 0, dir: 1, scope: 'top' });
  const fin = sa.m.result || {};
  check(sa.m.final === true && (fin.unreadable || []).length === 0 && !fin.errors && fin.matches && fin.matches.length > 0,
    `searchAll over the scope skips strings and reals: ${JSON.stringify({ matches: fin.matches && fin.matches.length, unreadable: fin.unreadable, errors: fin.errors, incomplete: fin.incomplete })}`);
  await h.stop();

  // A store cap smaller than any signal: the whole walk fails, but a short range still loads
  // through the ranged cold path, so the error must not be final for the page.
  const c = startHelper(['--cache-mb', '0.0002']);
  await c.ready;
  const co = await c.req('open', { file: capFixture });
  check(!co.m.error, 'a helper with a tiny store opens the fixture: ' + (co.m.error || 'ok'));
  const L1 = await c.req('searchAll', { value: '1', t: 20, dir: 1, scope: 'top' });
  const evHit = ((L1.m.result || {}).matches || []).find((x) => x.signalId === id('ev'));
  check(evHit && evHit.t === 35, `searchAll on a cold event finds a repeated occurrence (ev 1@15, 1@35, after 20): ${JSON.stringify(evHit)}`);
  const big1 = decodeWindow(await c.req('window', { signals: [{ signalId: id('clk'), width: 1 }], t0: 0, t1: 201, buckets: 64 }))[0];
  check(/larger than/.test(big1.h.error || '') && big1.h.permanent === undefined, `over the store cap: an error, not a permanent one: ${JSON.stringify(big1.h)}`);
  const big2 = decodeWindow(await c.req('window', { signals: [{ signalId: id('clk'), width: 1 }], t0: 40, t1: 60, buckets: 64 }))[0];
  check(!big2.h.error && big2.h.ranged === true && big2.recs.length === 4, `... and a zoomed-in range of it loads (ranged): ${JSON.stringify(big2.h)}`);
  await c.stop();

  // Long repeated text: a window carries at most 4 KB of each value (the store keeps it once).
  const b = startHelper();
  await b.ready;
  const bo = await b.req('open', { file: bigFixture });
  check(!bo.m.error, 'the helper opens the long-text fixture: ' + (bo.m.error || 'ok'));
  if (!bo.m.error) {
    const bk = await varsOf(b, { idx: bo.m.result.top[0].scopeOffsetIdx, path: bo.m.result.top[0].name });
    const bid = (bk.vars || []).find((x) => x.name === 'big').signalId;
    const short = decodeWindow(await b.req('window', { signals: [{ signalId: bid, width: 1 }], t0: 0, t1: 20, buckets: 64 }))[0];
    check(eq(short.recs, [[0, EURO_SHOWN], [5, ''], [10, EURO_SHOWN], [15, '']]), `a window cuts long text at 4 KB on a character boundary and marks it: ${JSON.stringify(short.recs.map((x) => [x[0], x[1].length, x[1].slice(-2)]))}`);
    const full = await b.req('valueAt', { signalIds: [bid], t: 2 });
    check(full.m.result && full.m.result.values[0] === EURO, `valueAt keeps the whole text: ${full.m.result ? full.m.result.values[0].length : full.m.error}`);
    const stx = await b.req('searchText', { signalId: bid, t: 1, dir: 1, inclusive: true, format: 'string', pattern: '\u20ac{2000}$' });
    check(stx.m.result && stx.m.result.t === 10, `searchText matches the whole text: ${JSON.stringify(stx.m.result || stx.m.error)}`);
    await new Promise((r) => setTimeout(r, 1500));  // the background whole walk
    const dec2 = await b.req('window', { signals: [{ signalId: bid, width: 1 }], t0: 0, t1: 50000, buckets: 1024 });
    const d2 = decodeWindow(dec2)[0];
    const sent = d2.recs.reduce((a, x) => a + 12 + Buffer.byteLength(x[1]), 0);
    check(!d2.h.error && !d2.h.exact && sent < 16e6 && d2.h.textMean > 2000 && d2.h.textMean < 2100,
      `a decimated window of it is bounded and says the mean text per change: ${JSON.stringify({ exact: d2.h.exact, sent, textMean: d2.h.textMean })}`);
  }
  await b.stop();

  // A 1 MB text budget: the cut scales down to fit the records a window carries, and a window
  // that can't fit even at the shortest cut is refused (retryable), not built.
  const sentOf = (d) => d.recs.reduce((a, x) => a + 12 + Buffer.byteLength(x[1]), 0);
  const cutOk = (d, max) => d.recs.every((x) => x[1] === '' || (x[1].endsWith('\u2026') && Buffer.byteLength(x[1]) <= max));
  const sb = startHelper(['--text-budget-mb', '1']);
  await sb.ready;
  const so = await sb.req('open', { file: bigFixture });
  check(!so.m.error, 'a helper with a 1 MB text budget opens the long-text fixture: ' + (so.m.error || 'ok'));
  if (!so.m.error) {
    const sk = await varsOf(sb, { idx: so.m.result.top[0].scopeOffsetIdx, path: so.m.result.top[0].name });
    const sid = (sk.vars || []).find((x) => x.name === 'big').signalId;
    const d1 = decodeWindow(await sb.req('window', { signals: [{ signalId: sid, width: 1 }], t0: 0, t1: 50000, buckets: 1024 }))[0];
    const longest = Math.max(0, ...d1.recs.map((x) => Buffer.byteLength(x[1])));
    check(!d1.h.error && sentOf(d1) <= (1 << 20) && cutOk(d1, 1024) && longest > 256,
      `under a 1 MB budget a 1024-bucket window fits by cutting each value shorter: ${JSON.stringify({ err: d1.h.error, sent: sentOf(d1), longest })}`);
    const ex = decodeWindow(await sb.req('window', { signals: [{ signalId: sid, width: 1 }], t0: 0, t1: 50000, buckets: 6000 }))[0];
    check(/budget/.test(ex.h.error || '') && ex.h.permanent === undefined && ex.recs.length === 0,
      `a window that can't fit its budget even at the shortest cut is refused (retryable), not built: ${JSON.stringify(ex.h)}`);
  }
  await sb.stop();

  // Every change long text, default budget: the page's 2 to 3 tile requests, a whole load, and
  // two such strings in one request all fit (16 MB per reply), cut shorter where needed.
  if (longFixture) {
    const L = startHelper();
    await L.ready;
    const lo = await L.req('open', { file: longFixture });
    check(!lo.m.error, 'the helper opens the all-long-text fixture: ' + (lo.m.error || 'ok'));
    if (!lo.m.error) {
      const lk = await varsOf(L, { idx: lo.m.result.top[0].scopeOffsetIdx, path: lo.m.result.top[0].name });
      const lid = (n) => (lk.vars || []).find((x) => x.name === n).signalId;
      const MiB16 = 16 << 20;
      for (const B of [1024, 2048, 3072]) {
        const d = decodeWindow(await L.req('window', { signals: [{ signalId: lid('big'), width: 1 }], t0: 0, t1: 50000, buckets: B }))[0];
        check(!d.h.error && !d.h.exact && d.recs.length === 2 * B + 1 && sentOf(d) <= MiB16 && cutOk(d, 4099),
          `a ${B}-bucket window of long text fits the reply budget: ${JSON.stringify({ err: d.h.error, n: d.recs.length, sent: sentOf(d) })}`);
      }
      const whole = decodeWindow(await L.req('window', { signals: [{ signalId: lid('big'), width: 1 }], t0: 0, t1: 49996, buckets: 5001 }))[0];
      check(!whole.h.error && whole.h.exact && whole.recs.length === 10000 && sentOf(whole) <= MiB16 && cutOk(whole, 4099),
        `a whole load of it (exact, 10000 changes) fits, cut shorter: ${JSON.stringify({ err: whole.h.error, n: whole.recs.length, sent: sentOf(whole) })}`);
      const both = decodeWindow(await L.req('window', { signals: [{ signalId: lid('big'), width: 1 }, { signalId: lid('big2'), width: 1 }], t0: 0, t1: 50000, buckets: 3072 }));
      const sum = both.reduce((a, d) => a + sentOf(d), 0);
      check(both.length === 2 && both.every((d) => !d.h.error && d.recs.length === 6145) && sum <= MiB16,
        `two long-text strings in one 3072-bucket request share the reply budget: ${JSON.stringify({ errs: both.map((d) => d.h.error), sum })}`);
    }
    await L.stop();
  }

  const dump = process.env.FSDB_VALUES_DUMP, expect = process.env.FSDB_VALUES_EXPECT;
  if (dump && expect) {
    const k = expect.indexOf('=');
    const vpath = expect.slice(0, k), want = expect.slice(k + 1);
    const g = startHelper();
    await g.ready;
    const go = await g.req('open', { file: dump });
    check(!go.m.error, 'the helper opens the dump: ' + (go.m.error || 'ok'));
    const sv = go.m.result && await findVar(g, go.m.result.top, vpath);
    check(!!sv && sv.encoding === 'String', `the dump's ${vpath} is listed as String: ${JSON.stringify(sv)}`);
    if (sv) {
      const cv = await g.req('valueAt', { signalIds: [sv.signalId], t: 0 });
      check(cv.m.result && cv.m.result.values[0] === want, `its value at 0, read cold: ${JSON.stringify(cv.m.result || cv.m.error)}`);
      const end = go.m.result.metadata.timeEnd;
      const w = decodeWindow(await g.req('window', { signals: [{ signalId: sv.signalId, width: sv.width }], t0: 0, t1: end + 1, buckets: 1024 }))[0];
      check(w.h && !w.h.error && w.h.text === true && w.recs[0][1] === want, `its window: ${JSON.stringify(w.h)} ${JSON.stringify(w.recs.slice(0, 3))}`);
      const again = decodeWindow(await g.req('window', { signals: [{ signalId: sv.signalId, width: sv.width }], t0: 0, t1: end + 1, buckets: 1024 }))[0];
      check(again.h && !again.h.error && eq(again.recs, w.recs), 'asked again, the same answer (no "retrying" error)');
    }
    await g.stop();
  }
}

main().catch((e) => { fails++; console.log('FAIL ' + (e && e.stack || e)); }).finally(() => {
  console.log(`${passes} passed, ${fails} failed`);
  console.log(fails === 0 ? 'FSDB VALUES CHECKS PASSED' : `FSDB VALUES CHECKS FAILED: ${fails}`);
  setTimeout(() => process.exit(fails === 0 ? 0 : 1), 200);
});
