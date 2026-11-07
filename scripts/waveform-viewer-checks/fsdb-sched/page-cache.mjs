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

// M6: a pan onto prefetched tiles, then idle.
{
  const L = 400000, R = 500000, W = R - L;
  const { wc } = page([{ id: 1 }], L, R, 1e6);
  wc.ensure();
  const pre = g.sent.filter((m) => m.prefetch);
  g.sent.length = 0;
  Object.assign(g.viewport, { timeScrollLeft: L + W, timeScrollRight: R + W });  // one screen right
  wc.ensure();
  const vis = wc.wantedTiles().filter((t) => t.priority === 0);
  const s1 = wc.signals.get(1);
  const asked = () => vis.filter((t) => [...wc.inflight.values()].some((f) => f.priority === 0 && f.tiles.some((x) => x.key === t.key))).length;
  const drawnOrAsked = () => vis.filter((t) => s1.windows.has(t.key) || [...wc.inflight.values()].some((f) => f.tiles.some((x) => x.key === t.key))).length;
  check(pre.length > 0 && asked() === vis.filter((t) => !s1.windows.has(t.key)).length,
    `after a pan onto prefetched tiles, every visible tile not drawn is asked for as visible: ${asked()} of ${vis.filter((t) => !s1.windows.has(t.key)).length} (${g.sent.filter((m) => m.cmd === 'window' && !m.prefetch).length} visible requests)`);
  // Nothing answers, so every request expires. A visible one marks the row slow, which is the
  // existing backoff; the row then waits and an ensure is scheduled. Sampled over 2.5 s, a visible
  // tile must always be drawn, in flight, or on a row that is backing off.
  let worst = vis.length;
  for (let k = 0; k < 25; k++) { await wait(100); const ok = s1.slowUntil > performance.now() ? vis.length : drawnOrAsked(); worst = Math.min(worst, ok); }
  check(worst === vis.length, `... and with requests expiring and no user action, no visible tile is left un-asked: at worst ${worst} of ${vis.length}`);
  wc.reset && wc.reset();
}

fs.rmSync(tmp, { recursive: true, force: true });
console.log(fails ? `PAGE CACHE CHECKS FAILED: ${fails}` : 'PAGE CACHE CHECKS PASSED');
setTimeout(() => process.exit(fails ? 1 : 0), 50);
