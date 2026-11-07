// cmux: live simulation (the liveSimulation setting, off by default; FSDB panels only).
//
// Reruns the simulator that wrote the open dump, through cmux's FSDB helper (fsdb-helper-v2/sim.js;
// cmux pins the run to the dump's own folder), and shows its value changes as they happen: the rows
// on screen are watched (a row scrolled into view is watched from then, missing before), their data is the
// simulation's, and the time range grows with the simulation, the view following the right edge.
// Ending live mode reloads the dump. A reload, another file or closing the viewer ends the simulation.
//
// Time without a record of a live row (before its watch, after an unwatch, changes the helper dropped, history
// the viewer evicted) is missing coverage: drawn apart from x, and no query answers there (liveValue).
// window.cmuxWaveform.sim:
//   open()  run(cycles)  step()  until(expr, maxCycles)  stop()  close()   (promises)
//   liveValue(signalId, t)  a live row's value, null without an exact answer, undefined if not live
//   state()    {phase: 'off' | 'idle' | 'opening' | 'ready', running, t, period, stopped, error}
//   watched()  the hierarchical names being watched
// host.js calls configure(config) on each open or reload and backendClosed() when the dump closes.
(function () {
  const wf = window.cmuxWaveform;
  const host = () => wf.host;
  const str = (k, fallback) => (wf.strings && wf.strings[k]) || fallback;
  const fmt = (s, v) => String(s).replace('%@', String(v));
  const RUN_CYCLES = 1e9;            // Run: until Stop
  const UNTIL_CYCLES = 1e7;
  const ID0 = 700000;                // request ids apart from the viewer's own

  let config = null;
  let st = { phase: 'off', running: false, t: 0, period: 0, stopped: null, error: null };
  let session = 0;                   // bumps on each open/close: old loops stop
  let nextId = ID0;
  // path -> {simSignal, signalId, width, from}; simSignal -> path
  let watches = new Map(), bySim = new Map(), unknown = new Set();
  let syncing = false, syncTimer = null;

  const enabled = () => !!(config && config.format === 'fsdb' && config.fsdb && config.fsdb.url
    && window.cmuxCommands && window.cmuxCommands.settings().liveSimulation === true);
  const live = () => { const f = document.getElementById('viewer').contentWindow; return f && f.__vvLive ? f.__vvLive : null; };

  async function request(cmd, args = {}) {
    if (!config || !config.fsdb) { throw new Error('no FSDB helper'); }
    const response = await fetch(config.fsdb.url, { method: 'POST', body: JSON.stringify({ id: nextId++, cmd, ...args }) });
    const all = new Uint8Array(await response.arrayBuffer());
    let reply, bin = null;
    if ((response.headers.get('content-type') || '').startsWith('application/octet-stream')) {
      const n = new DataView(all.buffer, all.byteOffset).getUint32(0, true);
      reply = JSON.parse(new TextDecoder().decode(all.subarray(4, 4 + n)));
      bin = all.subarray(4 + n);
    } else {
      reply = JSON.parse(new TextDecoder().decode(all));
    }
    if (reply.error) { const e = new Error(reply.error); if (reply.needsFlag) { e.needsFlag = reply.needsFlag; } throw e; }
    return { result: reply.result || {}, bin };
  }

  // ---- controls (the status strip)
  const el = (id) => document.getElementById(id);
  function render() {
    const bar = el('sim-controls');
    if (!bar) { return; }
    bar.hidden = !enabled();
    const ready = st.phase === 'ready';
    el('sim-open').hidden = ready || st.phase === 'opening';
    for (const id of ['sim-run', 'sim-step', 'sim-until', 'sim-until-expr']) { el(id).hidden = !ready; el(id).disabled = st.running; }
    el('sim-stop').hidden = !ready; el('sim-stop').disabled = !st.running;
    el('sim-close').hidden = !ready;
    el('sim-info').textContent = st.error ? fmt(str('simOpenFailed', 'Live simulation: %@'), st.error)
      : ready ? fmt(str('simTime', 't=%@'), st.t) : '';
  }
  function setupControls() {
    const bar = el('sim-controls');
    if (!bar || bar.dataset.ready) { return; }
    bar.dataset.ready = '1';
    const label = { 'sim-open': 'simLive', 'sim-run': 'simRun', 'sim-stop': 'simStop', 'sim-step': 'simStep', 'sim-until': 'simUntil', 'sim-close': 'simClose' };
    Object.entries(label).forEach(([id, k]) => { el(id).textContent = str(k, el(id).textContent); });
    el('sim-until-expr').placeholder = str('simUntilPlaceholder', '');
    const quiet = (p) => p.catch(() => {});
    el('sim-open').onclick = () => quiet(api.open());
    el('sim-run').onclick = () => quiet(api.run(RUN_CYCLES));
    el('sim-step').onclick = () => quiet(api.step());
    el('sim-stop').onclick = () => quiet(api.stop());
    el('sim-until').onclick = () => quiet(api.until(el('sim-until-expr').value));
    el('sim-until-expr').onkeydown = (e) => { if (e.key === 'Enter') { quiet(api.until(el('sim-until-expr').value)); } };
    el('sim-close').onclick = () => quiet(api.close());
  }

  // ---- watching what is on screen
  function scheduleSync(ms = 250) {
    if (syncTimer) { return; }
    syncTimer = setTimeout(() => { syncTimer = null; sync(); }, ms);
  }
  async function sync() {
    const my = session;
    if (st.phase !== 'ready' || syncing) { if (st.phase === 'ready') { scheduleSync(); } return; }
    const L = live();
    if (!L) { scheduleSync(); return; }
    syncing = true;
    try {
      const rows = L.rows();
      const want = new Map();
      rows.forEach((r) => { if (r.visible && r.path && !unknown.has(r.path) && !want.has(r.path)) { want.set(r.path, r); } });
      const add = [...want.keys()].filter((p) => !watches.has(p));
      const drop = [...watches.keys()].filter((p) => !want.has(p));
      if (drop.length) {
        const ids = drop.map((p) => watches.get(p).simSignal);
        const { result } = await request('sim.unwatch', { simSignals: ids });
        if (my !== session) { return; }
        const t = typeof result.t === 'number' ? result.t : st.t;
        drop.forEach((p) => { const w = watches.get(p); watches.delete(p); bySim.delete(w.simSignal); if (w.got) { L.gap(w.signalId, t); } });
      }
      if (add.length) {
        const { result } = await request('sim.watch', { signals: add });
        if (my !== session) { return; }
        (result.watch || []).forEach((w, i) => {
          const p = add[i], row = want.get(p);
          if (!w || w.width !== row.width) { unknown.add(p); return; }
          const entry = { simSignal: w.simSignal, signalId: row.signalId, width: w.width, from: result.t || 0, got: false };
          watches.set(p, entry); bySim.set(w.simSignal, p);
        });
      }
    } catch (e) {
      if (my === session) { st.error = String(e.message || e); render(); }
    } finally {
      syncing = false;
      if (my === session && st.phase === 'ready') { scheduleSync(300); }
    }
  }

  // ---- the poll loop: changes, the time, the end of a run
  async function pollLoop(my) {
    while (my === session && st.phase === 'ready') {
      let r;
      try { r = await request('sim.poll', { waitMs: st.running ? 200 : 1000 }); } catch (e) {
        if (my !== session) { return; }
        st.error = String(e.message || e); render();
        await new Promise((res) => setTimeout(res, 1000));
        continue;
      }
      if (my !== session) { return; }
      const L = live();
      const res = r.result;
      let tMax = typeof res.t === 'number' ? res.t : st.t;
      // Changes the helper had to drop (its buffer was full): missing from there until the signal's next record.
      for (const g of res.gaps || []) {
        const p = bySim.get(g.simSignal);
        const w = p ? watches.get(p) : null;
        if (w && L && L.missing) { L.missing(w.signalId, g.from); w.got = true; }
      }
      let off = 0;
      for (const s of res.signals || []) {
        const p = bySim.get(s.simSignal);
        const w = p ? watches.get(p) : null;
        if (!w || !r.bin) { off += s.bytes; continue; }
        const dv = new DataView(r.bin.buffer, r.bin.byteOffset + off, s.bytes);
        const recs = [];
        let t = 0;
        for (let o = 0; o + 8 + w.width <= s.bytes; o += 8 + w.width) {
          t += Number(dv.getBigUint64(o, true));
          let v = '';
          for (let k = 0; k < w.width; k++) { v += String.fromCharCode(r.bin[off + o + 8 + k]); }
          recs.push([t, v]);
        }
        off += s.bytes;
        if (recs.length && L) { L.append(w.signalId, w.width, recs, w.from); w.got = true; tMax = Math.max(tMax, t); }
      }
      if (res.stop) {
        st.running = false; st.stopped = res.stop.stopped;
        if (typeof res.stop.t === 'number') { tMax = Math.max(tMax, res.stop.t); st.t = res.stop.t; }
        if (res.stop.error) { st.error = res.stop.error; }
      }
      if (!res.stop && tMax > st.t) { st.t = tMax; }
      if (res.exited) { st.error = st.error || 'the simulation exited'; st.phase = 'idle'; session++; }
      if (L) { L.extend(Math.max(tMax, st.t)); }
      render();
    }
  }

  async function startRun(cmd, args) {
    if (st.phase !== 'ready') { throw new Error('no live simulation'); }
    if (st.running) { throw new Error('a run is in flight'); }
    st.running = true; st.stopped = null; st.error = null; render();
    try { await request(cmd, args); } catch (e) { st.running = false; st.error = String(e.message || e); render(); throw e; }
  }

  function reset() {
    session++;
    watches = new Map(); bySim = new Map(); unknown = new Set();
    if (syncTimer) { clearTimeout(syncTimer); syncTimer = null; }
    st = { phase: enabled() ? 'idle' : 'off', running: false, t: 0, period: 0, stopped: null, error: null };
  }

  const api = {
    state: () => ({ ...st }),
    // A live row's value at t for queries (host.js valuesAt): undefined when the signal isn't live (the dump
    // answers), null where there is no exact answer (missing coverage, past the simulation's time).
    liveValue(signalId, t) {
      const L = st.phase === 'ready' ? live() : null;
      return L && L.valueAt ? L.valueAt(signalId, Number(t)) : undefined;
    },
    watched: () => [...watches.keys()],
    async open() {
      if (!enabled()) { throw new Error('live simulation is off'); }
      if (st.phase === 'ready' || st.phase === 'opening') { return; }
      reset();
      const my = session;
      st.phase = 'opening'; render();
      try {
        // The clock cycles count in: the debugger's (chosen or default), so Step steps the same clock.
        const dbg = wf.debugger;
        const clock = dbg && dbg.clockOrDefaultPath ? await dbg.clockOrDefaultPath().catch(() => null) : null;
        const { result } = await request('sim.open', clock ? { clock } : {});
        if (my !== session) { request('sim.close').catch(() => {}); return; }
        st = { phase: 'ready', running: false, t: result.t || 0, period: result.period || 0, stopped: null, error: null };
      } catch (e) {
        if (my === session) { st.phase = 'idle'; st.error = String(e.message || e); render(); }
        throw e;
      }
      render();
      pollLoop(my);
      sync();
    },
    run: (cycles) => startRun('sim.run', { cycles: Number(cycles) || 1 }),
    step: () => startRun('sim.run', { cycles: 1 }),
    until: (expr, maxCycles) => startRun('sim.until', { expr: String(expr || ''), maxCycles: Number(maxCycles) || UNTIL_CYCLES }),
    async stop() { if (st.phase === 'ready' && st.running) { await request('sim.stop'); } },
    // End live mode: the simulation ends and the dump comes back.
    async close() {
      if (st.phase !== 'ready' && st.phase !== 'opening') { return; }
      reset(); render();
      await request('sim.close').catch(() => {});
      const L = live();
      if (L) { L.end(); }
      wf.reload();
    },
    // host.js: an open or reload of the panel.
    configure(next) { config = next; reset(); setupControls(); render(); },
    // host.js: the dump's backend closed (reload, another file): the simulation ends with it.
    backendClosed() {
      if (st.phase === 'ready' || st.phase === 'opening') { request('sim.close').catch(() => {}); }
      reset(); render();
    },
  };
  wf.sim = api;
  window.addEventListener('pagehide', () => { if (st.phase === 'ready') { api.backendClosed(); } });
})();
