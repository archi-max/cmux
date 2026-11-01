// cmux's driver tracing, page side (design: status/tracex-design.md, phase P1): Trace Driver on
// a waveform row (its menu, Ctrl+T through cmux) or from the SystemVerilog editor shows the
// active driver of the signal at the marker in a panel over the waveform: the statement that
// drove the value, the branch taken, and the fan-in with values at the time it was sampled, each
// traced one more step with a click. cmux-trace.js does the work; this file is the dump provider
// (host.js), the native requests (the design model comes from cmux-sv-model through cmux) and
// the panel.
//
// cmux calls window.cmuxWaveform.trace through callAsyncJavaScript:
//   driver({ path, time })        path: dump segments (null: the selected row); time: null for the
//                                 marker. Asks cmux for the design path, then traces.
//   driverOfDesign({ designPath, designPrefix, dumpPrefix, time })   from the editor (cmux mapped it)
//   reply({ id, ok, result, error, message })   cmux's answer to a request the page posted
//   status(text)                  progress while cmux prepares the design model (a first build)
//   back() | forward() | close() | state()
//   settled()                     resolves (to state()) once the Verdi checks under way are done
// and posts { type: 'trace', event: 'resolve' | 'model' | 'step' | 'update' | 'open' | 'closed', id?, ... }
// ('update': a shown step filled in with Verdi's answer; cmux does not move the editor for it).
(function () {
  const waveform = window.cmuxWaveform;
  const host = waveform.host;
  const S = () => waveform.strings || {};
  const format = (text, ...args) => {
    let i = 0;
    return String(text || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? Number(n.slice(0, -1)) - 1 : i++]));
  };
  // Changes read per signal for edges and "since" (larger: the signal's step says so).
  const MAX_CHANGES = 2000000;
  // Changes kept per trace session, all signals together (a whole-signal FSDB helper reads long ones).
  const CACHED_CHANGES = 8000000;
  // Native requests that get no answer in this long fail (the sidecar may be building: minutes).
  const REQUEST_TIMEOUT_MS = 45 * 60 * 1000;

  // ---- native requests ----
  let nextId = 1;
  const pending = new Map();
  function request(event, body) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(Object.assign(new Error('timeout'), { code: 'timeout' })); }, REQUEST_TIMEOUT_MS);
      pending.set(id, { resolve, reject, timer });
      host.toNative(Object.assign({ type: 'trace', event, id }, body));
    });
  }
  function reply(answer) {
    const a = answer || {};
    const p = pending.get(Number(a.id));
    if (!p) { return false; }
    pending.delete(Number(a.id));
    clearTimeout(p.timer);
    if (a.ok) { p.resolve(a.result); } else { p.reject(Object.assign(new Error(a.message || a.error || 'failed'), { code: a.error, message: a.message })); }
    return true;
  }

  // ---- the dump, by design path ----
  // A trace session: the prefixes cmux mapped the design onto the dump with, its caches.
  let session = null;
  function newSession(designPrefix, dumpPrefix) {
    return { designPrefix: designPrefix || '', dumpPrefix: dumpPrefix || '', backend: host.currentBackend, vars: new Map(), changes: new Map(), edges: new Map(), kind: dumpKind(), engine: null };
  }
  const segs = (p) => (p ? String(p).split('.') : []);
  // The prefixes are whole segments; either may be empty (the dump adds or drops a wrapper scope).
  function toDump(designPath) {
    const s = session;
    const p = s.designPrefix;
    if (!p || designPath === p || designPath.startsWith(p + '.')) {
      const rest = p ? designPath.slice(p.length).replace(/^\./, '') : designPath;
      return [s.dumpPrefix, rest].filter(Boolean).join('.');
    }
    return designPath;
  }
  async function varOf(designPath) {
    const s = session;
    if (s.vars.has(designPath)) { return s.vars.get(designPath); }
    const v = await host.findLinkItem(dumpSegments(toDump(designPath)), true);
    const found = v && v.kind !== 'scope' ? v : null;
    s.vars.set(designPath, found);
    return found;
  }
  // `a.b[3].c`: segments a, b[3], c (a generate or array index stays on its segment).
  function dumpSegments(path) { return segs(path); }

  // How the open dump answers history questions:
  //  'v2'     a windowed FSDB helper (WINDOWING.md): edge queries in the helper, nothing downloaded;
  //  'whole'  a v1 FSDB helper: whole signals, so each signal is read once (values from its changes
  //           too, not a second read through rawValuesAt);
  //  'local'  a file the page reads itself (VCD, FST, GHW): rawValuesAt plus changes.
  function dumpKind() {
    const b = host.currentBackend;
    if (b && typeof b.windowed === 'function' && typeof b.v2 === 'function' && b.windowed()) { return 'v2'; }
    return b && typeof b.changes === 'function' ? 'whole' : 'local';
  }
  let nextV2Id = 1;
  // One v2 query through the viewer's relay: its result, or undefined when the helper failed it.
  async function v2(req) {
    const b = session.backend;
    const answer = await b.v2(Object.assign({ id: 2000000000 + nextV2Id++ }, req));
    const r = answer && answer.reply;
    if (!r || r.error) { if (r && r.error) { host.log(new Error('trace ' + req.cmd + ': ' + r.error)); } return undefined; }
    return r.result;
  }
  // The last time before `t` that `v` changed (edge 'any'), or rose/fell (1-bit), from the helper; cached.
  async function v2Edge(v, t, kind) {
    const s = session;
    const key = v.netlistId + ':' + kind + ':' + t;
    if (s.edges.has(key)) { return s.edges.get(key); }
    const r = await v2({ cmd: 'edge', signalId: v.signalId, t, dir: -1, kind });
    const at = r === undefined ? undefined : (r.t === null || r.t === undefined ? null : Number(r.t));
    s.edges.set(key, at);
    return at;
  }

  // One read per signal: a read already under way is shared (a step asks for its leaves together).
  // A signal only a Verdi check read (`background`) is evicted before the ones our steps read, so
  // following Verdi's port hops does not push a step's signals out (cp3: ex_mem read again).
  function changesOf(v, background) {
    const s = session;
    if (!s.background) { s.background = new Set(); }
    if (!background) { s.background.delete(v.netlistId); }
    if (s.changes.has(v.netlistId)) { return Promise.resolve(s.changes.get(v.netlistId)); }
    if (!s.reading) { s.reading = new Map(); }
    if (s.reading.has(v.netlistId)) { return s.reading.get(v.netlistId); }
    if (background) { s.background.add(v.netlistId); }
    const read = readChanges(s, v).finally(() => { s.reading.delete(v.netlistId); });
    s.reading.set(v.netlistId, read);
    return read;
  }
  async function readChanges(s, v) {
    const changes = await host.signalChanges(v, MAX_CHANGES);
    const out = Array.isArray(changes) ? changes : null;
    s.changes.set(v.netlistId, out);
    // Keep at most CACHED_CHANGES changes across signals: Verdi checks' first, then the oldest read.
    s.cached = (s.cached || 0) + (out ? out.length : 0);
    const drop = (id) => {
      const list = s.changes.get(id);
      s.changes.delete(id);
      s.background.delete(id);
      s.cached -= list ? list.length : 0;
    };
    for (const id of [...s.background]) {
      if (s.cached <= CACHED_CHANGES) { break; }
      if (id !== v.netlistId && s.changes.has(id)) { drop(id); }
    }
    for (const id of [...s.changes.keys()]) {
      if (s.cached <= CACHED_CHANGES || id === v.netlistId) { break; }
      drop(id);
    }
    return out;
  }
  const bitsOf = (value, width) => {
    const t = String(value);
    return t.length >= width ? t : (t[0] === 'x' || t[0] === 'z' ? t[0] : '0').repeat(width - t.length) + t;
  };
  function indexAt(changes, time) {
    let lo = 0, hi = changes.length - 1, at = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (Number(changes[mid][0]) <= time) { at = mid; lo = mid + 1; } else { hi = mid - 1; } }
    return at;
  }
  const isEdge = (prev, now, edge) => {
    const pos = (prev === '0' && now !== '0') || ((prev === 'x' || prev === 'z') && now === '1');
    const neg = (prev === '1' && now !== '1') || ((prev === 'x' || prev === 'z') && now === '0');
    return edge === 'PosEdge' ? pos : edge === 'NegEdge' ? neg : pos || neg;
  };
  // The dump provider; `background` marks what Verdi checks read (evicted before the rest).
  function makeDump(background) {
  return {
    async values(paths, time) {
      // Every leaf at once: a whole-signal helper reads them in parallel (its workers), not one by one.
      const unique = [...new Set(paths)];
      const vars = new Map(await Promise.all(unique.map(async (p) => [p, await varOf(p)])));
      const list = [...new Set([...vars.values()].filter(Boolean))];
      let raw = new Map();
      if (session.kind !== 'whole') {
        try { raw = (await host.rawValuesAt(time, list)) || new Map(); } catch (error) { host.log(error); }
      }
      const read = await Promise.all([...vars].map(async ([p, v]) => {
        if (!v) { return [p, undefined]; }
        const width = Number(v.width) || 1;
        let bits = raw.get(v.netlistId);
        if (bits === undefined || bits === null) {
          const changes = await changesOf(v, background);
          const i = changes ? indexAt(changes, time) : -1;
          bits = i >= 0 ? changes[i][1] : (changes ? 'x'.repeat(width) : undefined);
        }
        return [p, bits === undefined || bits === null ? undefined : bitsOf(bits, width).toLowerCase()];
      }));
      return new Map(read);
    },
    async lastChange(p, time) {
      const v = await varOf(p);
      if (!v) { return null; }
      if (session.kind === 'v2') {
        // Integer times: the last change at or before `time` is the last one before time + 1.
        const at = await v2Edge(v, Math.floor(time) + 1, 'any');
        if (at !== undefined) { return at === null ? 0 : at; }
      }
      const changes = await changesOf(v, background);
      if (!changes) { return null; }
      const i = indexAt(changes, time);
      return i < 0 ? 0 : Number(changes[i][0]);
    },
    async prevEdge(p, time, edge) {
      const v = await varOf(p);
      if (!v) { return null; }
      const width = Number(v.width) || 1;
      // The helper's rise/fall is a change to 1/0 (x to 1 counts, 0 to x does not); a wide
      // clock (its last bit) is read from its changes.
      if (session.kind === 'v2' && width === 1) {
        const at = await v2Edge(v, Math.floor(time) + 1, edge === 'PosEdge' ? 'rise' : edge === 'NegEdge' ? 'fall' : 'any');
        if (at !== undefined) { return at; }
      }
      const changes = await changesOf(v, background);
      if (!changes) { return null; }
      for (let i = indexAt(changes, time); i > 0; i--) {
        const prev = bitsOf(changes[i - 1][1], width).slice(-1).toLowerCase();
        const now = bitsOf(changes[i][1], width).slice(-1).toLowerCase();
        if (isEdge(prev, now, edge)) { return Number(changes[i][0]); }
      }
      return null;
    },
  };
  }
  const dump = makeDump(false);
  const models = {
    instance: (path) => request('model', { cmd: 'instance', path }),
    lookup: (path) => request('model', { cmd: 'lookup', path }),
    writers: (path) => request('model', { cmd: 'writers', path }),
  };
  // The session's answers kept, so the engines of its Verdi checks do not ask cmux again.
  function sessionModels(s) {
    const kept = new Map();
    const keep = (cmd) => (path) => {
      const key = cmd + ':' + path;
      if (!kept.has(key)) { kept.set(key, models[cmd](path).catch((error) => { kept.delete(key); throw error; })); }
      return kept.get(key);
    };
    s.models = { instance: keep('instance'), lookup: keep('lookup'), writers: keep('writers') };
    return s.models;
  }
  // The dump for a Verdi check's own engine: no new reads once the check is late or stale (a read
  // under way still finishes; the helper serves one at a time, so a step after it would wait).
  function guardedDump(stop) {
    const d = makeDump(true);
    const guard = (f) => (...args) => (stop() ? Promise.reject(Object.assign(new Error('stale'), { code: 'stale' })) : f(...args));
    return { values: guard(d.values), lastChange: guard(d.lastChange), prevEdge: guard(d.prevEdge) };
  }

  // ---- tracing ----
  // The steps shown, and where in them the panel is (Back/Forward).
  const history = { steps: [], at: -1 };
  let running = 0;

  const markerTime = () => {
    const w = host.viewerContext.webview;
    return w && w.markerTime !== undefined && w.markerTime !== null ? Number(w.markerTime) : null;
  };

  async function driver(query) {
    const q = query || {};
    const path = Array.isArray(q.path) ? q.path.map(String) : waveform.link.selectedSignal();
    const time = q.time !== undefined && q.time !== null ? Number(q.time) : markerTime();
    const s = S();
    if (!path || !path.length) { showError(s.traceNoSignal); return null; }
    if (time === null || !Number.isFinite(time)) { showError(s.traceNoMarker); return null; }
    showBusy(format(s.traceResolving, path.join('.')));
    let mapped;
    try {
      mapped = await request('resolve', { dumpPath: path });
    } catch (error) {
      showError(error.message || s.traceFailed);
      return null;
    }
    return driverOfDesign(Object.assign({ time }, mapped));
  }

  async function driverOfDesign(query) {
    const q = query || {};
    const time = q.time !== undefined && q.time !== null ? Number(q.time) : markerTime();
    if (!q.designPath) { showError(S().traceNoSignal); return null; }
    if (time === null || !Number.isFinite(time)) { showError(S().traceNoMarker); return null; }
    if (!session || session.backend !== host.currentBackend || session.kind !== dumpKind() || session.designPrefix !== (q.designPrefix || '') || session.dumpPrefix !== (q.dumpPrefix || '')) {
      session = newSession(q.designPrefix, q.dumpPrefix);
      session.options = { xprop: q.xprop || 'auto' };
      session.engine = window.cmuxTrace.createEngine({ models: sessionModels(session), dump, options: session.options });
    }
    history.steps = history.steps.slice(0, history.at + 1);
    return traceStep(q.designPath, time, true);
  }

  async function traceStep(designPath, time, push) {
    const s = S();
    const run = ++running;
    showBusy(format(s.traceRunning, designPath, number(time)));
    // Verdi (when this dump may have it) is asked while our engine runs, not after it.
    const dumpPath = toDump(designPath);
    const verdi = session.kind === 'local' ? null : askVerdi(dumpPath, time);
    let step;
    try {
      step = await session.engine.active(designPath, time);
    } catch (error) {
      host.log(error);
      if (run === running) { showError(error.message || s.traceFailed); }
      return null;
    }
    if (run !== running) { return null; }
    step.dumpPath = dumpPath;
    step.engine = { name: 'cmux' };
    // Ours is shown now; Verdi's answer fills the step in later (verdiCheck), never before.
    if (verdi && !step.error) { step.engine.verdi = 'checking'; verdiCheck(step, time, verdi, run); }
    if (push) { history.steps.push(step); history.at = history.steps.length - 1; }
    render();
    host.toNative({ type: 'trace', event: 'step', step: plain(step) });
    return plain(step);
  }

  // ---- the Verdi engine (an FSDB on an SSH host with a KDB next to it) ----
  // cmux asks the host's Verdi for the active driver (srcActiveTrace: the statement of the value's
  // last transition, through port connections). It confirms our step; when ours is a port hop, our
  // chain is followed to the statement Verdi names (the hops are listed); when the two differ and
  // the value has not changed since an earlier time, ours (the statement active at t) stays first
  // and Verdi's is shown second; any other difference makes the step approximate.
  // A step's Verdi check (the answer and our port-hop following to it) gets this long after ours
  // is shown; past it the step says "Verdi: not checked (timed out)". cp3: Verdi answers in well
  // under a second once warm (it was asked when the step started), a port hop on a whole-signal
  // helper takes up to ~30 s.
  const VERDI_BUDGET_MS = 10000;
  const verdiBudget = () => (Number(waveform.traceVerdiBudgetMs) > 0 ? Number(waveform.traceVerdiBudgetMs) : VERDI_BUDGET_MS);
  const checks = new Set();
  // Fills `step` (shown, in the history) in with Verdi's answer when it comes within the budget;
  // drops it when a newer trace has started (or the panel closed) meanwhile.
  function verdiCheck(step, time, asked, run) {
    const deadline = Date.now() + verdiBudget();
    const late = { timedOut: true };
    let timer;
    const limit = new Promise((resolve) => { timer = setTimeout(() => resolve(late), Math.max(0, deadline - Date.now())); });
    const stop = () => run !== running || Date.now() > deadline;
    const engine = window.cmuxTrace.createEngine({ models: session.models, dump: guardedDump(stop), options: session.options });
    const check = Promise.race([withVerdi(step, time, asked, stop, engine), limit]).then((out) => {
      if (run !== running) { step.engine.verdi = 'dropped'; return; }
      let shown = step;
      if (out === late || !out) {
        step.engine.verdi = 'timedOut';
      } else {
        const i = history.steps.indexOf(step);
        if (i >= 0) { history.steps[i] = out; }
        shown = out;
      }
      if (history.steps[history.at] === shown) { render(); }
      host.toNative({ type: 'trace', event: 'update', step: plain(shown) });
    }).catch((error) => { host.log(error); step.engine.verdi = 'timedOut'; })
      .finally(() => { clearTimeout(timer); checks.delete(check); });
    checks.add(check);
  }
  // Resolves when every Verdi check under way has finished (cmux and the checks wait on this).
  async function settled() {
    while (checks.size) { await Promise.allSettled([...checks]); }
    return state();
  }
  const sameFile = (a, b) => !!a && !!b && (a === b || String(a).split('/').pop() === String(b).split('/').pop());
  const isPort = (st) => !!st.driver && (st.driver.kind === 'portIn' || st.driver.kind === 'portOut');
  // Verdi's answer (null when the request failed); the step's budget bounds the wait.
  function askVerdi(signal, time) {
    return request('engine', { cmd: 'active', signal, time }).catch((error) => { host.log(error); return null; });
  }
  // `shown` with Verdi's answer merged in, as a new step (the shown one is left as it is); null
  // when `stop()` says the check is late or stale before the port hops are followed.
  async function withVerdi(shown, time, asked, stop, engine) {
    const step = Object.assign({}, shown, { engine: { name: 'cmux' } });
    let v = null;
    try {
      v = await asked;
    } catch (error) { host.log(error); }
    if (stop()) { return null; }
    const state = (v && v.state) || 'none';
    step.engine.verdi = state;
    if (state === 'unavailable') { step.engine.reason = v.reason || ''; step.engine.message = v.message || ''; }
    if (state !== 'ready') { return step; }
    if (v.notFound || !v.file || !(Number(v.line) > 0)) { step.engine.verdiNotFound = true; return step; }
    const at = { file: String(v.file), line: Number(v.line), scope: v.scope || '' };
    step.engine.verdiLoc = at;
    const same = (st) => !!(st && st.stmt && st.stmt.loc && st.stmt.loc.line === at.line && sameFile(st.stmt.loc.file, at.file));
    if (same(step)) { step.engine.name = 'verdi'; return step; }
    if (isPort(step)) {
      const via = [];
      let cur = step;
      for (let hop = 0; hop < 8 && isPort(cur); hop++) {
        const next = (cur.fanin || []).filter((f) => f.path);
        if (next.length !== 1) { break; }
        via.push({ signal: cur.signal, src: cur.stmt ? cur.stmt.src : '', loc: cur.stmt ? cur.stmt.loc : null });
        try { cur = await engine.active(next[0].path, time); } catch (error) { if (stop()) { return null; } throw error; }
        if (stop()) { return null; }
        if (cur.error) { break; }
      }
      if (cur !== step && same(cur)) {
        const out = Object.assign({}, cur, { signal: step.signal, dumpPath: step.dumpPath, value: step.value, time: step.time, via, viaSignal: cur.signal });
        out.engine = { name: 'verdi', verdi: 'ready', verdiLoc: at };
        return out;
      }
    }
    step.engine.verdiDiffers = true;
    const unchanged = step.since !== null && step.since !== undefined && Number(step.since) < Number(time);
    if (!unchanged) {
      step.reasons = (step.reasons || []).concat([{ code: 'enginesDiffer', path: where(at) }]);
      if (step.trust === 'exact' || step.trust === 'computed') { step.trust = 'approximate'; }
    }
    return step;
  }

  function back() { if (history.at > 0) { history.at--; render(); post(); } return state(); }
  function forward() { if (history.at < history.steps.length - 1) { history.at++; render(); post(); } return state(); }
  function post() { const st = history.steps[history.at]; if (st) { host.toNative({ type: 'trace', event: 'step', step: plain(st) }); } }
  function close() {
    running++;
    history.steps = []; history.at = -1;
    if (panel) { panel.hidden = true; }
    host.toNative({ type: 'trace', event: 'closed' });
    return state();
  }
  function state() {
    const st = history.steps[history.at];
    return { open: !!(panel && !panel.hidden), steps: history.steps.length, at: history.at, step: st ? plain(st) : null };
  }
  const plain = (x) => JSON.parse(JSON.stringify(x, (k, v) => (typeof v === 'bigint' ? v.toString() : v)));
  const number = (n) => (Number.isFinite(Number(n)) ? Number(n).toLocaleString() : String(n));

  // ---- the panel ----
  let panel = null;
  function ensurePanel() {
    if (panel) { return panel; }
    const style = document.createElement('style');
    style.textContent = `
      #cmux-trace { position: absolute; left: 8px; right: 8px; bottom: 8px; max-height: 45%; display: flex; flex-direction: column;
        background: var(--vscode-editorWidget-background); color: var(--vscode-foreground); border: 1px solid var(--vscode-widget-border);
        border-radius: 6px; box-shadow: 0 4px 16px rgba(0, 0, 0, 0.35); font-size: 12px; z-index: 50; }
      #cmux-trace[hidden] { display: none; }
      #cmux-trace .head { display: flex; align-items: center; gap: 8px; padding: 4px 8px; border-bottom: 1px solid var(--vscode-widget-border); }
      #cmux-trace .title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
      #cmux-trace .body { overflow: auto; padding: 4px 8px 6px; user-select: text; -webkit-user-select: text; }
      #cmux-trace .code { font-family: var(--vscode-editor-font-family); white-space: pre-wrap; }
      #cmux-trace .muted { color: var(--vscode-descriptionForeground); }
      #cmux-trace .badge { padding: 0 6px; border-radius: 8px; font-size: 11px; border: 1px solid var(--vscode-widget-border); }
      #cmux-trace .badge.exact, #cmux-trace .badge.computed { color: var(--vscode-testing-iconPassed, #73c991); }
      #cmux-trace .badge.approximate { color: var(--vscode-editorWarning-foreground, #cca700); }
      #cmux-trace .badge.inconsistent { color: var(--vscode-editorError-foreground, #f14c4c); }
      #cmux-trace a { color: var(--vscode-textLink-foreground); cursor: pointer; text-decoration: none; }
      #cmux-trace a:hover { text-decoration: underline; }
      #cmux-trace table { border-collapse: collapse; margin-top: 4px; }
      #cmux-trace td { padding: 1px 10px 1px 0; vertical-align: top; }
      #cmux-trace tr.fanin { cursor: pointer; }
      #cmux-trace tr.fanin:hover, #cmux-trace tr.fanin:focus { background: var(--vscode-list-hoverBackground); outline: none; }
      #cmux-trace .x { color: var(--vscode-editorError-foreground, #f14c4c); }
      #cmux-trace ul { margin: 2px 0; padding-left: 16px; }`;
    document.head.appendChild(style);
    panel = document.createElement('div');
    panel.id = 'cmux-trace';
    panel.hidden = true;
    panel.setAttribute('role', 'dialog');
    panel.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { e.preventDefault(); close(); }
      if (e.key === 'ArrowLeft' && e.altKey) { e.preventDefault(); back(); }
      if (e.key === 'ArrowRight' && e.altKey) { e.preventDefault(); forward(); }
    });
    (document.getElementById('main') || document.body).appendChild(panel);
    return panel;
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text !== undefined && text !== null) { e.textContent = String(text); }
    return e;
  }
  function button(label, title, run, disabled) {
    const b = window.cmuxUI && window.cmuxUI.button ? window.cmuxUI.button(label, run) : el('button', 'cmux-button', label);
    if (!(window.cmuxUI && window.cmuxUI.button)) { b.addEventListener('click', run); }
    b.title = title || '';
    b.disabled = !!disabled;
    return b;
  }
  function head(titleText) {
    const p = ensurePanel();
    p.textContent = '';
    const h = el('div', 'head');
    const s = S();
    h.append(el('span', 'title', titleText));
    const st = history.steps[history.at];
    if (st && st.trust) {
      const b = el('span', 'badge ' + st.trust, s['traceTrust_' + st.trust] || st.trust);
      b.title = s['traceTrustHelp_' + st.trust] || '';
      h.append(b);
    }
    h.append(button('‹', s.traceBack, back, history.at <= 0), button('›', s.traceForward, forward, history.at >= history.steps.length - 1),
      button('×', s.traceClose, close));
    p.append(h);
    p.hidden = false;
    return p;
  }
  let busy = false;
  function showBusy(text) { const p = head(S().traceTitle || ''); p.append(el('div', 'body muted', text)); busy = true; }
  function showError(text) { const p = head(S().traceTitle || ''); p.append(el('div', 'body', text || S().traceFailed)); busy = false; }

  const where = (loc) => (loc ? `${String(loc.file).split('/').pop()}:${loc.line}` : '');
  const valueText = (bits) => (bits === null || bits === undefined ? '?' : bitsShown(bits));
  function bitsShown(bits) {
    const b = String(bits);
    if (b.length <= 4 || /[xz]/.test(b) && b.length <= 16) { return `${b.length}'b${b}`; }
    if (!/[xz]/.test(b)) { return `${b.length}'h${BigInt('0b' + b).toString(16)}`; }
    // Hex digits, x or z for a digit whose bits all are, X or Z when some are.
    let out = '';
    for (let i = b.length; i > 0; i -= 4) {
      const d = b.slice(Math.max(0, i - 4), i);
      out = (/^[01]+$/.test(d) ? parseInt(d, 2).toString(16) : /^x+$/.test(d) ? 'x' : /^z+$/.test(d) ? 'z' : /x/.test(d) ? 'X' : 'Z') + out;
    }
    return `${b.length}'h${out}`;
  }
  function open(loc) { if (loc) { host.toNative({ type: 'trace', event: 'open', loc }); } }

  function driverText(st) {
    const s = S();
    const d = st.driver || {};
    switch (d.kind) {
      case 'assign': return s.traceKindAssign;
      case 'proc': return format(s.traceKindProc, st.procKind || d.procKind || '');
      case 'portIn': return format(s.traceKindPortIn, d.port, d.instance);
      case 'portOut': return format(s.traceKindPortOut, d.port, d.instance);
      case 'initial': return s.traceKindInitial;
      case 'topInput': return s.traceKindTopInput;
      case 'undriven': return s.traceKindUndriven;
      case 'initializer': return s.traceKindInitializer;
      default: return s.traceKindNone;
    }
  }

  // Which engine answered, and Verdi's own answer when it differs or isn't there.
  function engineLine(st) {
    const s = S();
    const e = st.engine || { name: 'cmux' };
    const div = el('div', 'muted engine');
    div.dataset.engine = e.name;
    let text = e.name === 'verdi' ? s.traceEngineVerdi : s.traceEngineCmux;
    if (e.verdi === 'starting') { text += ' · ' + s.traceVerdiStarting; }
    if (e.verdi === 'checking') { text += ' · ' + s.traceVerdiChecking; }
    if (e.verdi === 'timedOut') { text += ' · ' + s.traceVerdiTimedOut; }
    if (e.verdi === 'unavailable') { text += ' · ' + format(s['traceVerdiUnavailable_' + e.reason] || s.traceVerdiUnavailable, e.message || ''); }
    if (e.verdiNotFound) { text += ' · ' + s.traceVerdiNotFound; }
    div.append(el('span', '', text));
    if (st.via && st.via.length) { div.append(el('span', '', ' · ' + format(s.traceThroughPorts, st.via.map((h) => h.signal).join(' → ')))); }
    if (e.verdiDiffers && e.verdiLoc) {
      div.append(el('span', '', ' · ' + s.traceVerdiLastChange + ' '));
      const a = el('a', '', where(e.verdiLoc));
      a.addEventListener('click', () => open({ file: e.verdiLoc.file, line: e.verdiLoc.line }));
      div.append(a);
    }
    return div;
  }

  function reasonText(r) {
    const s = S();
    const key = 'traceReason_' + r.code;
    const text = s[key];
    if (!text) { return r.code; }
    return format(text, r.path || r.src || (r.time !== undefined ? number(r.time) : '') || r.count || r.why || r.error || '', r.predicted ? valueText(r.predicted) : '');
  }

  function render() {
    const st = history.steps[history.at];
    busy = false;
    if (!st) { if (panel) { panel.hidden = true; } return; }
    const s = S();
    const p = head(format(s.traceStepTitle, st.signal, valueText(st.value), number(st.time)));
    const body = el('div', 'body');
    if (st.error) {
      body.append(el('div', '', s['traceError_' + st.error] || st.error));
      p.append(body);
      return;
    }
    // Driver kind, where, when.
    const line = el('div');
    line.append(el('span', '', driverText(st) + ' '));
    if (st.driver && st.driver.writer) { line.append(el('span', 'muted', format(S().traceWriter, st.driver.writer) + ' ')); }
    const loc = st.stmt && st.stmt.loc;
    if (loc) { const a = el('a', '', where(loc)); a.title = s.traceOpen || ''; a.addEventListener('click', () => open(loc)); line.append(a); }
    if (st.activation) {
      line.append(el('span', 'muted', ' · ' + format(s.traceActivation, st.activation.trigger ? `${st.activation.trigger.edge === 'NegEdge' ? 'negedge' : 'posedge'} ${st.activation.trigger.path}` : '', number(st.activation.time), number(st.sample))));
    } else if (st.since !== null && st.since !== undefined) {
      line.append(el('span', 'muted', ' · ' + format(s.traceSince, number(st.since))));
    }
    body.append(line);
    body.append(engineLine(st));
    if (st.stmt && st.stmt.src) { body.append(el('div', 'code', st.stmt.src)); }
    for (const m of st.merged || []) { const a = el('div', 'code muted', '↔ ' + m.src); body.append(a); }
    // The branch taken.
    if (st.decisions && st.decisions.length) {
      const ul = el('ul');
      for (const d of st.decisions) {
        const li = el('li', 'code');
        const taken = d.taken === 'merge' ? s.traceTakenMerge : d.taken === 'then' ? s.traceTakenThen : d.taken === 'else' ? s.traceTakenElse
          : d.taken === 'default' ? s.traceTakenDefault : format(s.traceTakenItem, d.item || String(d.taken));
        li.textContent = `${d.kind === 'if' ? 'if' : 'case'} (${d.src}) = ${valueText(d.value)} → ${taken}`;
        if (d.xCond) { li.classList.add('x'); li.title = s.traceXCondition || ''; }
        if (d.loc) { li.style.cursor = 'pointer'; li.addEventListener('click', () => open(d.loc)); }
        ul.append(li);
      }
      body.append(ul);
    }
    // The fan-in, each a further step.
    if (st.fanin && st.fanin.length) {
      body.append(el('div', 'muted', s.traceFanin));
      const table = el('table');
      for (const f of st.fanin) {
        const tr = el('tr', 'fanin');
        tr.tabIndex = 0;
        const name = f.local ? format(s.traceLocal, f.name) : f.path || f.name;
        const v = el('td', 'code' + (/[xz]/.test(String(f.value)) ? ' x' : ''), f.dumped === false && !f.local ? '?' : valueText(f.value));
        tr.append(el('td', 'code', name), v, el('td', 'muted', '@' + number(f.time)), el('td', 'muted', s['traceRole_' + f.role] || f.role));
        if (f.via) { tr.title = format(s.traceVia, f.via.src); }
        const go = () => {
          if (f.local) { if (f.via && f.via.loc) { open(f.via.loc); } return; }
          if (f.path) { history.steps = history.steps.slice(0, history.at + 1); traceStep(f.path, f.time, true); }
        };
        tr.addEventListener('click', go);
        tr.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
        tr.dataset.path = f.path || '';
        table.append(tr);
      }
      body.append(table);
    }
    if (st.root === 'testbench') { body.append(el('div', 'muted', s.traceRootTestbench)); }
    // What the trust rests on.
    const reasons = (st.reasons || []).filter((r) => r.code !== 'multiDriven' || (st.drivers || []).length > 1);
    if (reasons.length) {
      const ul = el('ul', 'muted');
      const seen = new Set();
      for (const r of reasons) { const t = reasonText(r); if (!seen.has(t)) { seen.add(t); ul.append(el('li', '', t)); } }
      body.append(ul);
    }
    p.append(body);
  }

  // ---- the waveform row's menu ----
  function rowMenuItems(context) {
    const c = context || {};
    if (c.webviewSection !== 'signal' || c.netlistId === undefined) { return []; }
    const v = host.netlistItem(c.netlistId);
    if (!v) { return []; }
    const path = host.pathOf(v);
    return [{ label: S().traceDriverMenu || '', keybinding: S().traceDriverKey || '', run: () => driver({ path }) }];
  }

  // A reload drops the session (its variables and changes are the old file's).
  function backendChanged() { session = null; }

  // Shown only while a trace is waiting (not over a step already shown).
  function status(text) { if (panel && !panel.hidden && busy) { showBusy(String(text || '')); } return true; }

  const api = Object.freeze({ driver, driverOfDesign, reply, status, back, forward, close, state, settled, backendChanged });
  Object.defineProperty(waveform, 'trace', { value: api, writable: false, configurable: false, enumerable: true });
  window.cmuxTraceUI = { rowMenuItems };
})();
