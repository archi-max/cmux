// The viewer page's window cache (vaporview fork src/webview/window_cache.ts) in node, with its
// page globals stubbed: which window requests it sends, and how it treats their timeouts.
//   node page-cache.mjs <vaporview fork folder>
// Bundles window_cache.ts with the fork's esbuild into a scratch file; no browser, no helper.
//  M4  a prefetch request (level-out, either side) past the window timeout is cancelled without
//      calling the rows slow (no backoff, no "helper is slow" notice, no batch splitting), and it
//      gets a longer timeout of its own: on a 10 GB dump, deprioritized prefetch replies came at
//      11-18 s, past the 10 s window timeout.
//  L14 a cold row (a ranged read, which costs by its span) batched with a warm one is asked
//      for level-out only over the view, not over the warm row's wider span.
//  M6  after a pan onto tiles a prefetch request is still reading, those (now visible) tiles are
//      asked for as visible, not left on the deprioritized prefetch; and a prefetch that expires
//      leaves nothing un-asked: its tiles are asked again without any user action.
//  L16 the window timeout's RTT samples come from visible replies only: a deprioritized prefetch
//      reply (11-18 s on a 10 GB dump, by design) must not stretch the visible timeout.
//  L17 a prefetch that expires is asked again with a doubled timeout of its own, not the same one:
//      a prefetch that always takes longer than 3x looped (expire, cancel, re-send, ~every 30 s),
//      throwing the helper's work away each time.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const fork = path.resolve(process.argv[2] || '');
const src = path.join(fork, 'src/webview/window_cache.ts');
if (!fs.existsSync(src)) { console.error('usage: node page-cache.mjs <vaporview fork folder>'); process.exit(2); }
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'page-cache-'));
const stub = path.join(tmp, 'globals.mjs');
fs.writeFileSync(stub, `
export class NetlistVariable { constructor(signalId, width) { this.signalId = signalId; this.width = width; this.rowId = signalId; } getValueAtTime() { return []; } getWaveformData() { return null; } }
export const sent = [];
export const viewport = { timeScrollLeft: 0, timeScrollRight: 0, pixelTime: 1, timeStop: 1, pseudoScrollTop: 0, viewerHeight: 1000,
  getRowIdBounds: (rowId) => [rowId * 20, rowId * 20 + 20], renderAllWaveforms() {} };
export const viewerState = { visibleSignalsFlat: [], displayedSignalsFlat: [], markerTime: null };
export const rowHandler = { rowItems: {}, setValueFormat() {} };
export const labelsPanel = { valueAtMarker: {}, renderValueDisplay() {} };
export const vscodeWrapper = { sendV2Request: (m) => sent.push(m), outputLog() {} };
export const styles = {};
export const events = { isBatchMode: false, redrawVariable() {}, emit() {} };
export const dataManager = { valueChangeData: {}, valueChangeDataTemp: {}, removeGlitchTransitions: (r) => r };
export const setRenderBounds = () => {}, copyWaveDrom = () => {}, searchesBitPattern = () => false, aliasSearchSource = () => null;
export const ActionType = new Proxy({}, { get: (o, k) => String(k) });
export const StateChangeType = new Proxy({}, { get: (o, k) => String(k) });
`);
const out = path.join(tmp, 'wc.mjs');
const plugin = `{name:'stub',setup(b){b.onResolve({filter:/^\\.\\.?\\//},(a)=>a.importer.endsWith('window_cache.ts')?{path:${JSON.stringify(pathToFileURL(stub).href)},external:true}:undefined)}}`;
execFileSync(process.execPath, ['-e', `require('esbuild').build({entryPoints:[${JSON.stringify(src)}],bundle:true,format:'esm',platform:'node',outfile:${JSON.stringify(out)},plugins:[${plugin}],logLevel:'error'}).catch(e=>{console.error(e);process.exit(1)})`], { cwd: fork, stdio: 'inherit' });
globalThis.requestAnimationFrame = () => 0;  // (redraws are the page's: none here)
const { WindowCache } = await import(pathToFileURL(out).href);
const g = await import(pathToFileURL(stub).href);

let fails = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) { fails++; } };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// A page with rows (id: {cold}), its view at [L, R] of a dump of `stop`, every visible tile
// already drawn, so the next ensure() sends only prefetch.
function page(rows, L, R, stop) {
  g.sent.length = 0;
  Object.assign(g.viewport, { timeScrollLeft: L, timeScrollRight: R, timeStop: stop, pixelTime: (R - L) / 1000 });
  g.viewerState.visibleSignalsFlat = rows.map((r) => r.id); g.viewerState.displayedSignalsFlat = rows.map((r) => r.id);
  rows.forEach((r) => { g.rowHandler.rowItems[r.id] = new g.NetlistVariable(r.id, 1); });
  const wc = new WindowCache();
  wc.enabled = true; wc.hybrid = false; wc.windowTimeoutMs = 200; wc.firstLoadTimeoutMs = 200;
  wc.takeSignals(rows.map((r) => ({ signalId: r.id, signalWidth: 1 })));
  const tiles = wc.wantedTiles();
  for (const r of rows) {
    const s = wc.signals.get(r.id);
    s.answered = true; s.cold = !!r.cold;
    tiles.filter((t) => t.priority === 0).forEach((t) => s.windows.set(t.key, { exact: false, t0: t.t0, t1: t.t1, lastUsed: 0, bytes: 0 }));
  }
  if (wc.timer) { clearTimeout(wc.timer); wc.timer = null; }
  return { wc, tiles };
}

// M4: prefetch past the window timeout.
{
  const { wc } = page([{ id: 1 }, { id: 2 }], 400000, 500000, 1e6);
  wc.ensure();
  const pre = g.sent.filter((m) => m.prefetch);
  check(pre.length > 0 && g.sent.every((m) => m.prefetch), `only prefetch is sent once the view is drawn: ${pre.length} requests`);
  await wait(300);  // 1.5x the window timeout
  const s1 = wc.signals.get(1);
  check(s1.timeouts === 0 && s1.slowUntil === 0, `a prefetch request past the window timeout doesn't mark its rows slow: timeouts ${s1.timeouts}`);
  check(pre.every((m) => wc.inflight.has(m.id)), `... it has a longer timeout of its own: ${pre.filter((m) => wc.inflight.has(m.id)).length} of ${pre.length} still in flight at 1.5x`);
  await wait(1200);
  check(pre.every((m) => !wc.inflight.has(m.id)) && s1.timeouts === 0 && wc.signals.get(2).timeouts === 0, `... and expires in the end, still without slow(): ${pre.filter((m) => wc.inflight.has(m.id)).length} left, timeouts ${s1.timeouts}/${wc.signals.get(2).timeouts}`);
  wc.reset && wc.reset();
}

// L14: a cold row batched with a warm one.
{
  const L = 400000, R = 500000;
  const { wc, tiles } = page([{ id: 1 }, { id: 2, cold: true }], L, R, 1e6);
  wc.ensure();
  const lvl = tiles.find((t) => t.priority === 1).level;
  const out1 = tiles.filter((t) => t.priority === 1 && t.t1 > L && t.t0 < R);
  const lo = Math.min(...out1.map((t) => t.t0)), hi = Math.max(...out1.map((t) => t.t1));
  const levelOut = g.sent.filter((m) => m.prefetch && (m.t1 - m.t0) / m.buckets === 2 ** lvl);
  const coldReqs = levelOut.filter((m) => m.signals.some((x) => x.signalId === 2));
  const warmSpan = levelOut.filter((m) => m.signals.some((x) => x.signalId === 1)).reduce((a, m) => a + (m.t1 - m.t0), 0);
  check(levelOut.length > 0 && warmSpan > hi - lo, `the warm row's level-out covers more than the view: ${warmSpan} > ${hi - lo}`);
  check(coldReqs.length > 0 && coldReqs.every((m) => m.t0 >= lo && m.t1 <= hi), `the cold row's level-out stays over the view [${lo}, ${hi}]: ${JSON.stringify(coldReqs.map((m) => [m.t0, m.t1, m.signals.map((x) => x.signalId)]))}`);
  wc.reset && wc.reset();
}

// M6: a pan onto prefetched tiles, then idle; then the helper answers. On a virtual clock (setTimeout
// and performance.now replaced), so nothing depends on wall-clock timing.
{
  const real = { setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout, perf: globalThis.performance };
  let vnow = 1e6, tid = 0;
  const timers = new Map();
  globalThis.setTimeout = (fn, ms = 0, ...a) => { const id = { tid: ++tid, unref() { return this; }, ref() { return this; }, hasRef() { return true; } }; timers.set(id, { at: vnow + Math.max(0, ms), fn: () => fn(...a) }); return id; };
  globalThis.clearTimeout = (id) => { timers.delete(id); };
  Object.defineProperty(globalThis, 'performance', { value: { now: () => vnow }, configurable: true, writable: true });
  const drain = async () => { for (let k = 0; k < 20; k++) { await new Promise((r) => setImmediate(r)); } };  // (replies decode via streams)
  // Runs every timer due up to vnow + ms, in time order; after each one, check().
  const advance = async (ms, check) => {
    const end = vnow + ms;
    for (;;) {
      let next = null;
      for (const [id, t] of timers) { if (t.at <= end && (!next || t.at < next[1].at)) { next = [id, t]; } }
      if (!next) { break; }
      timers.delete(next[0]); vnow = Math.max(vnow, next[1].at);
      next[1].fn(); await drain(); check && check();
    }
    vnow = end;
  };
  const zlib = await import('node:zlib');
  let answer = false;
  const reply = (m) => {
    if (!answer || m.cmd !== 'window') { return; }
    const signals = [], bins = [];
    for (const x of m.signals) {
      const rec = Buffer.alloc(9); rec.writeBigUInt64LE(BigInt(m.t0), 0); rec[8] = 0x30;
      const z = zlib.deflateRawSync(rec); bins.push(z);
      signals.push({ signalId: x.signalId, exact: true, count: 1, bytes: z.length, bucketBytes: 0, min: 0, max: 1 });
    }
    setImmediate(() => wc.handleReply({ reply: { id: m.id, result: { signals } }, bin: new Uint8Array(Buffer.concat(bins)) }));
  };
  const send0 = g.vscodeWrapper.sendV2Request;
  g.vscodeWrapper.sendV2Request = (m) => { g.sent.push(m); reply(m); };

  const L = 400000, R = 500000, W = R - L;
  const { wc } = page([{ id: 1 }], L, R, 1e6);
  wc.ensure();
  const pre = g.sent.filter((m) => m.prefetch);
  g.sent.length = 0;
  Object.assign(g.viewport, { timeScrollLeft: L + W, timeScrollRight: R + W });  // one screen right
  wc.ensure();
  const vis = wc.wantedTiles().filter((t) => t.priority === 0);
  const s1 = wc.signals.get(1);
  const inflightHas = (t, vis0) => [...wc.inflight.values()].some((f) => (!vis0 || f.priority === 0) && f.tiles.some((x) => x.key === t.key));
  const asked = () => vis.filter((t) => inflightHas(t, true)).length;
  check(pre.length > 0 && asked() === vis.filter((t) => !s1.windows.has(t.key)).length,
    `after a pan onto prefetched tiles, every visible tile not drawn is asked for as visible: ${asked()} of ${vis.filter((t) => !s1.windows.has(t.key)).length} (${g.sent.filter((m) => m.cmd === 'window' && !m.prefetch).length} visible requests)`);
  // Nothing answers for 120 s (virtual), so every request expires; a visible expiry backs the row
  // off (slow()) and schedules an ensure at its end (+5 ms). After every timer, a visible tile must
  // be drawn, in flight, or waiting on a timer due by the end of the row's backoff + 10 ms.
  let bad = 0, firstBad = '';
  const invariant = () => {
    const by = Math.max(vnow, s1.slowUntil) + 10;
    const reask = [...timers.values()].some((t) => t.at <= by);
    for (const t of vis) {
      if (s1.windows.has(t.key) || inflightHas(t, false)) { continue; }
      if (reask) { continue; }
      bad++; if (!firstBad) { firstBad = `${t.key} at +${Math.round(vnow - 1e6)} ms (slowUntil ${Math.round(s1.slowUntil - vnow)} ms ahead, ${timers.size} timers)`; }
    }
  };
  await advance(120000, invariant);
  check(!bad, `... and with requests expiring and no user action, no visible tile is left un-asked (virtual 120 s, after every timer): ${bad} misses${firstBad ? ', first ' + firstBad : ''}`);
  // Then the helper answers: the row loads, with no user action.
  answer = true;
  const t0 = vnow;
  let loadedAt = null;
  await advance(120000, () => { if (loadedAt === null && vis.every((t) => s1.windows.has(t.key))) { loadedAt = vnow; } });
  check(loadedAt !== null, `... and once the helper answers, the row loads by itself: after ${loadedAt === null ? 'never (120 s)' : Math.round(loadedAt - t0) + ' ms'} (virtual)`);
  wc.reset && wc.reset();
  g.vscodeWrapper.sendV2Request = send0;
  globalThis.setTimeout = real.setTimeout; globalThis.clearTimeout = real.clearTimeout;
  Object.defineProperty(globalThis, 'performance', { value: real.perf, configurable: true, writable: true });
}

// L16: prefetch replies don't feed the visible timeout.
{
  const { wc } = page([{ id: 1 }, { id: 2 }], 400000, 500000, 1e6);
  const base = wc.windowTimeout([]);
  for (let k = 0; k < 25; k++) {
    wc.ensure();
    const pre = g.sent.filter((m) => m.prefetch && m.cmd === 'window' && wc.inflight.has(m.id));
    g.sent.length = 0;
    for (const m of pre) { wc.inflight.get(m.id).sentAt -= 5000; wc.handleReply({ reply: { id: m.id, result: { signals: [] } }, bin: new Uint8Array(0) }); }
    await wait(5);
    // (the prefetched tiles dropped again, the visible ones kept: the next ensure sends only prefetch)
    const vis = new Set(wc.wantedTiles().filter((t) => t.priority === 0).map((t) => t.key));
    for (const s of wc.signals.values()) {
      for (const k of [...s.windows.keys()]) { if (!vis.has(k)) { s.windows.delete(k); } }
      vis.forEach((k) => { if (!s.windows.has(k)) { s.windows.set(k, { exact: false, t0: 0, t1: 0, lastUsed: 0, bytes: 0 }); } });
      s.inflight.clear(); s.fails = 0; s.failUntil = 0; s.solo = false;
    }
    if (wc.timer) { clearTimeout(wc.timer); wc.timer = null; }
  }
  const after = wc.windowTimeout([]);
  check(wc.stats.replies >= 20 && after === base, `${wc.stats.replies} prefetch replies at 5 s don't stretch the visible window timeout: ${base} -> ${after} ms`);
  wc.reset && wc.reset();
}

// L17: an expired prefetch is asked again with a doubled timeout.
{
  const { wc } = page([{ id: 1 }], 400000, 500000, 1e6);
  wc.ensure();
  const first = g.sent.filter((m) => m.prefetch).map((m) => m.id);
  await wait(700);  // past the first prefetch timeout (3 x 200 ms)
  const again = g.sent.filter((m) => m.prefetch && !first.includes(m.id)).map((m) => m.id);
  await wait(700);  // past the same timeout again, within twice it
  const held = again.filter((id) => wc.inflight.has(id)).length;
  check(first.length > 0 && again.length > 0 && held === again.length,
    `an expired prefetch is asked again with a longer timeout: ${held} of ${again.length} re-asked requests still in flight at ~1.2x the first timeout`);
  wc.reset && wc.reset();
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `PAGE CACHE CHECKS FAILED: ${fails}` : 'PAGE CACHE CHECKS PASSED');
setTimeout(() => process.exit(fails ? 1 : 0), 50);
