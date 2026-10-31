// Ship-gate measurements for run.sh windowed-fsdb, run inside cmux's waveform page (host.js)
// on a real remote FSDB. window.__cmuxBench({ scopes, signals, panMs, zoomMs }) adds every
// variable of `scopes` plus the `signals` paths, then measures, with real wheel and key
// events into the viewer frame:
//   earlyPan   frame times while panning for 5 s right after the add (signals still loading)
//   firstDraw  add -> each windowed row's first draw (windowed); v1LoadMs: add -> all loaded (whole)
//   pan, zoom  frame times of continuous pan and pinch zoom once loaded
//   jump       viewport jump -> exact refinement (windowed)
//   nextEdge   ArrowRight near the marker, `n` far from anything loaded
// Same method as the standalone bench (spike-webview/www-window/bench.js), against cmux's page.
(function () {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const pct = (a, p) => { if (!a.length) { return null; } const s = [...a].sort((x, y) => x - y); return +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(2); };
  const summary = (a) => ({ n: a.length, p50: pct(a, 0.5), p95: pct(a, 0.95), max: a.length ? +Math.max(...a).toFixed(2) : null });
  const host = () => window.cmuxWaveform.host;
  const iframe = document.getElementById('viewer');
  const vw = () => iframe.contentWindow;
  const wc = () => vw().__vvWindowing && vw().__vvWindowing.enabled ? vw().__vvWindowing : null;
  const scrollArea = () => vw().document.getElementById('scrollArea');
  const toViewer = (msg) => host().toWebview(msg);
  const waitFor = async (cond, ms = 20000) => { const t0 = performance.now(); while (!cond()) { if (performance.now() - t0 > ms) { return false; } await sleep(10); } return true; };

  let lastMarker = null;
  const markerWaiters = [];
  host().contextListeners.push((m) => {
    if (m.markerTime !== lastMarker) { lastMarker = m.markerTime; markerWaiters.splice(0).forEach((w) => w(m.markerTime)); }
  });
  const nextMarker = (ms = 3000) => new Promise((r) => { markerWaiters.push(r); setTimeout(() => r(undefined), ms); });

  async function frames(ms, perFrame) {
    const w = vw(), deltas = [];
    const renderBefore = wc() ? wc().stats.renderMs.length : 0;
    await new Promise((resolve) => {
      let last = null, start = null, i = 0;
      const tick = (ts) => {
        if (last !== null) { deltas.push(ts - last); }
        last = ts; if (start === null) { start = ts; }
        if (ts - start >= ms) { resolve(); return; }
        perFrame(i++);
        w.requestAnimationFrame(tick);
      };
      w.requestAnimationFrame(tick);
    });
    const render = wc() ? wc().stats.renderMs.slice(renderBefore) : [];
    return { frame: summary(deltas), render: summary(render), droppedOver20ms: deltas.filter((d) => d > 20).length };
  }
  function wheel(opts) {
    const el = scrollArea();
    const r = el.getBoundingClientRect();
    el.dispatchEvent(new (vw().WheelEvent)('wheel', { bubbles: true, cancelable: true, deltaMode: 0, clientX: r.left + r.width / 2, clientY: r.top + 40, ...opts }));
  }
  function key(k) { vw().dispatchEvent(new (vw().KeyboardEvent)('keydown', { key: k, bubbles: true, cancelable: true })); }

  async function variables(scopes, signals) {
    const out = [];
    for (const s of scopes) {
      const scope = await host().findItem(s);
      if (scope && scope.kind === 'scope') { (await host().getChildren(scope)).filter((c) => c.kind === 'var').forEach((v) => out.push(v)); }
    }
    for (const p of signals) { const v = await host().findItem(p, undefined, undefined, true); if (v) { out.push(v); } }
    return out;
  }

  window.__cmuxBench = async function ({ scopes = [], signals = [], panMs = 3000, zoomMs = 4000 }) {
    const R = { windowed: !!wc() };
    const T = host().doc.metadata.timeEnd;
    const vars = await variables(scopes, signals);
    R.signals = vars.length;
    const addSent = performance.now();
    host().addVariables(vars);
    await waitFor(() => scrollArea(), 10000);
    toViewer({ command: 'setViewportRange', startTime: Math.floor(T * 0.3), endTime: Math.floor(T * 0.3 + T / 256) });
    const r0 = wc() ? wc().stats.refineMs.length : 0;
    R.earlyPanStartMs = Math.round(performance.now() - addSent);
    R.earlyPan = await frames(5000, () => wheel({ deltaX: 12 }));
    R.earlyRefine = wc() ? summary(wc().stats.refineMs.slice(r0)) : null;
    if (wc()) {
      const windowedRows = () => vars.filter((v) => wc().isWindowed(v.signalId)).length;
      await waitFor(() => wc().stats.firstDrawMs.length >= Math.min(windowedRows(), vars.length), 60000);
      R.firstDrawMs = summary(wc().stats.firstDrawMs);
      await waitFor(() => wc().hybridPendingCount() === 0, 180000);
      const st = wc().stats;
      R.hybrid = { promoted: st.promoted, promoteMs: summary(st.promoteMs), settledMs: Math.round(performance.now() - addSent), windowedRows: windowedRows() };
    } else {
      const ids = new Set(vars.map((v) => v.signalId));
      await waitFor(() => window.cmuxWaveform.stats.filter((e) => ids.has(e.signalId)).length >= ids.size, 900000);
      R.v1LoadMs = Math.round(performance.now() - addSent);
    }
    await sleep(500);
    toViewer({ command: 'setViewportRange', startTime: Math.floor(T * 0.5), endTime: Math.floor(T * 0.5 + T / 512) });
    await sleep(600);
    R.pan = await frames(panMs, () => wheel({ deltaX: 12 }));
    await sleep(500);
    toViewer({ command: 'setViewportRange', startTime: 0, endTime: T });
    await sleep(800);
    R.zoom = await frames(zoomMs, (i) => wheel({ ctrlKey: true, deltaY: (Math.floor(i / 60) % 2 === 0 ? -1 : 1) * 4 }));
    await sleep(800);
    if (wc()) {
      wc().stats.refineMs.splice(0);
      for (let k = 0; k < 12; k++) {
        const width = T / 2 ** (2 + (k % 6) * 2);
        const start = Math.floor(((k * 0.6180339) % 1) * (T - width));
        toViewer({ command: 'setViewportRange', startTime: start, endTime: start + width });
        await waitFor(() => wc().stats.refineMs.length > k, 3000);
        await sleep(50);
      }
      R.jumpRefineMs = summary(wc().stats.refineMs.splice(0));
    }
    toViewer({ command: 'setViewportRange', startTime: T * 0.4, endTime: T * 0.4 + T / 4096 });
    await sleep(600);
    toViewer({ command: 'setSelectedSignal', netlistId: vars[0].netlistId });
    await sleep(200);
    const near = [], far = [];
    toViewer({ command: 'setMarker', time: Math.floor(T * 0.4) + 17, markerType: 0 });
    await nextMarker(); await sleep(100);
    for (let k = 0; k < 10; k++) { const t0 = performance.now(); key('ArrowRight'); if (await nextMarker() !== undefined) { near.push(performance.now() - t0); } await sleep(30); }
    for (let k = 0; k < 5; k++) {
      toViewer({ command: 'setMarker', time: Math.floor(T * (0.05 + 0.17 * k)) + 3, markerType: 0 });
      await nextMarker(); await sleep(50);
      const t0 = performance.now(); key('n'); if (await nextMarker() !== undefined) { far.push(performance.now() - t0); } await sleep(30);
    }
    R.nextEdgeNearMs = summary(near);
    R.nextEdgeFarMs = summary(far);
    R.relay = window.cmuxWaveform.v2Stats();
    return R;
  };
})();
