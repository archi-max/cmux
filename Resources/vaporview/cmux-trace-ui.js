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
//   progress({ stage, host, startedAt, percent?, sourceBytes?, message?, log? })   the first-time
//                                 design model build: stage upload | fetch | configure | compile |
//                                 install | load | done | failed. While it builds the panel shows
//                                 it, and another trace asks nothing new (it points at the panel).
//   back() | forward() | close() | state()
//   settled()                     resolves (to state()) once the Verdi checks under way are done
//   xRoot({ path, time } | { designPath, designPrefix, dumpPrefix, time })   Trace X to Root: the
//                                 chain of steps the x came along (cmuxTrace.xChain), listed as
//                                 they are found; resolves to { steps, end, root, approximate }
// and posts { type: 'trace', event: 'resolve' | 'model' | 'step' | 'update' | 'open' | 'closed' | 'buildInfo', id?, ... }
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
  // Changes kept per trace session, all signals together (a whole-signal FSDB helper reads long
  // ones), bounded by their bits: each change costs its value's width plus 32 for its time and
  // entry. About what 8M changes of a 32-bit signal took; a 512-bit signal keeps ~470k changes.
  const CACHED_BITS = 256e6;
  const cachedBits = () => (Number(waveform.traceCacheBits) > 0 ? Number(waveform.traceCacheBits) : CACHED_BITS);
  // Native requests that get no answer in this long fail (the sidecar may be building: minutes).
  const REQUEST_TIMEOUT_MS = 45 * 60 * 1000;

  // ---- native requests ----
  let nextId = 1;
  const pending = new Map();
  function request(event, body) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(Object.assign(new Error('timeout'), { code: 'timeout' })); }, REQUEST_TIMEOUT_MS);
      pending.set(id, { resolve, reject, timer, event });
      host.toNative(Object.assign({ type: 'trace', event, id }, body));
    });
  }
  function reply(answer) {
    const a = answer || {};
    const p = pending.get(Number(a.id));
    if (!p) { return false; }
    pending.delete(Number(a.id));
    clearTimeout(p.timer);
    // A design answer means the design model is up: a build under way is over (its done may come later).
    if (a.ok && (p.event === 'resolve' || p.event === 'model') && building()) { endBuild(); }
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
  const v2Id = () => 2000000000 + nextV2Id++;
  // One v2 query through the viewer's relay: its result, or undefined when the helper failed it
  // (or it was cancelled). A Verdi check's (`bg`) queries are kept in bg.pending while the helper
  // has them, so the check can cancel what is left when it ends.
  async function v2(req, bg) {
    // A stopped check asks nothing more (its caller falls back to changesOf, which is stale then).
    if (bg && bg.stop && bg.stop()) { return undefined; }
    const b = session.backend;
    const id = v2Id();
    const pending = bg && bg.pending;
    if (pending) { pending.add(id); }
    let answer;
    try { answer = await b.v2(Object.assign({ id }, req)); } finally { if (pending) { pending.delete(id); } }
    const r = answer && answer.reply;
    if (r && r.cancelled) { return undefined; }
    if (r && r.error && /larger than|store limit/i.test(String(r.error)) && req.signalId !== undefined) {
      // Over the helper's store limit (about 244 MB of history): a whole read, capped only by its
      // change count, would be about a GB of values in the page, so the signal stays unknown.
      if (!session.refused) { session.refused = new Set(); }
      session.refused.add(req.signalId);
    }
    if (!r || r.error) { if (r && r.error) { host.log(new Error('trace ' + req.cmd + ': ' + r.error)); } return undefined; }
    return r.result;
  }
  // A signal helper v2 refused to index (over its store limit): unknown rather than read whole.
  const refusedByHelper = (v) => !!(session.refused && session.refused.has(v.signalId));
  // Cancels a Verdi check's queries the helper still has (it would keep a worker busy for nothing).
  function cancelPending(s, bg) {
    if (!bg || !bg.pending || !bg.pending.size || s.kind !== 'v2') { return; }
    for (const target of [...bg.pending]) {
      Promise.resolve(s.backend.v2({ cmd: 'cancel', id: v2Id(), target })).catch(() => {});
    }
    bg.pending.clear();
  }
  // The last time before `t` that `v` changed (edge 'any'), or rose/fell (1-bit), from the helper;
  // cached (a failed or cancelled query is not).
  async function v2Edge(v, t, kind, bg) {
    const s = session;
    const key = v.netlistId + ':' + kind + ':' + t;
    if (s.edges.has(key)) { return s.edges.get(key); }
    const r = await v2({ cmd: 'edge', signalId: v.signalId, t, dir: -1, kind }, bg);
    if (r === undefined) { return undefined; }
    const at = r.t === null || r.t === undefined ? null : Number(r.t);
    s.edges.set(key, at);
    return at;
  }
  // The last `edge` of a wide signal's last bit at or before `time`, from the helper: from the
  // run of the last bit in effect at `time`, back over the runs (the last change before a run
  // whose last bit differs, by search; the run starts at the next change) until one starts with
  // an edge. Undefined when the helper fails (the caller reads the changes instead).
  async function v2WideEdge(v, width, time, edge, bg) {
    const id = v.signalId, rest = '?'.repeat(width - 1);
    const now = await v2({ cmd: 'valueAt', signalIds: [id], t: time }, bg);
    const value = now && Array.isArray(now.values) ? now.values[0] : undefined;
    // A value of another width than the netlist's, or a last bit other than 0/1/x/z, can't be
    // searched for: the caller reads the changes instead.
    if (typeof value !== 'string' || value.length !== width) { return undefined; }
    let bit = value.slice(-1).toLowerCase();
    if (!'01xz'.includes(bit)) { return undefined; }
    let before = Math.floor(time) + 1;
    for (let run = 0; run < 16; run++) {
      let at = null, was = null;
      for (const c of ['0', '1', 'x', 'z']) {
        if (c === bit) { continue; }
        const r = await v2({ cmd: 'search', signalId: id, t: before, dir: -1, value: rest + c, wildcard: '?' }, bg);
        if (r === undefined) { return undefined; }
        if (r.t !== null && r.t !== undefined && (at === null || Number(r.t) > at)) { at = Number(r.t); was = c; }
      }
      if (at === null) { return null; }
      const start = await v2({ cmd: 'edge', signalId: id, t: at, dir: 1, kind: 'any' }, bg);
      if (start === undefined || start.t === null || start.t === undefined) { return undefined; }
      if (isEdge(was, bit, edge)) { return Number(start.t); }
      bit = was;
      before = at;
    }
    return undefined;
  }

  // One read per signal: a read already under way is shared (a step asks for its leaves together).
  // A Verdi check's reads (`bg`: { stop, maxBits, hint }) are background reads: they wait until no
  // step of ours is running and go one at a time (the v1 helper serves one read at a time, so a
  // step behind them would wait); one whose history would be larger than maxBits (width x changes,
  // the changes estimated by `hint`, the traced signal's, which a port passes on) is refused on v1,
  // whose single reader it would hold. On v2 such a read happens only when the helper's queries
  // can't answer; once started it runs to the end (the check's budget only keeps new ones from
  // starting), so one that ends after its check stopped is not kept, and one over V2_MAX_BITS
  // (width x changes, the helper's count; a memory guard far above a 512-bit bus at MAX_CHANGES)
  // is refused as large. A signal only a Verdi check read is evicted before the ones our steps read.
  const VERDI_MAX_BITS = 64e6;
  const V2_MAX_BITS = 2e9;
  function changesOf(v, bg) {
    const s = session, id = v.netlistId;
    if (!s.background) { s.background = new Set(); }
    if (!bg) { s.background.delete(id); }
    if (s.changes.has(id)) { return Promise.resolve(s.changes.get(id)); }
    if (!s.reading) { s.reading = new Map(); }
    const under = s.reading.get(id);
    if (under && (under.started || bg)) { return under.promise; }
    const entry = { started: !bg };
    const done = () => { if (s.reading.get(id) === entry) { s.reading.delete(id); } };
    if (!bg) {
      // Ours: now (a background read of it still waiting in line is overtaken).
      entry.promise = readChanges(s, v).finally(done);
    } else {
      const width = Number(v.width) || 1;
      const count = Number.isFinite(bg.hint) ? bg.hint : null;
      const bits = count !== null ? count * width : (width > 64 ? Infinity : 0);
      if (s.kind !== 'v2' && bits > bg.maxBits) { return Promise.reject(Object.assign(new Error('large'), { code: 'large' })); }
      entry.promise = inLine(s, async () => {
        if (bg.stop()) { throw Object.assign(new Error('stale'), { code: 'stale' }); }
        if (s.changes.has(id)) { return s.changes.get(id); }
        const now = s.reading.get(id);
        if (now && now !== entry) { return now.promise; }
        if (s.kind === 'v2' && await overV2Ceiling(v, bg)) { throw Object.assign(new Error('large'), { code: 'large' }); }
        if (bg.stop()) { throw Object.assign(new Error('stale'), { code: 'stale' }); }
        entry.started = true;
        s.background.add(id);
        const out = await readChanges(s, v);
        // Ended after its check stopped, and no step of ours asked for it: not kept.
        if (bg.stop() && s.background.has(id)) { dropChanges(s, id); }
        return out;
      }).finally(done);
    }
    s.reading.set(id, entry);
    return entry.promise;
  }
  // Whether a check's whole read of `v` on v2 would be over the memory ceiling (width x changes):
  // asked of the helper only when the width alone could get there. A count the helper doesn't
  // know without a walk (not stored yet) is asked for exactly; one it can't give is taken as over.
  async function overV2Ceiling(v, bg) {
    const max = Number(waveform.traceVerdiV2MaxBits) > 0 ? Number(waveform.traceVerdiV2MaxBits) : V2_MAX_BITS;
    const width = Number(v.width) || 1;
    if (width * MAX_CHANGES <= max) { return false; }
    const countOf = async (exact) => {
      const r = await v2(exact ? { cmd: 'count', signalIds: [v.signalId], exact: true } : { cmd: 'count', signalIds: [v.signalId] }, bg);
      const c = r && Array.isArray(r.counts) ? r.counts[0] : null;
      return c && c.count !== null && c.count !== undefined && Number.isFinite(Number(c.count)) ? c : null;
    };
    // A stopped check isn't refused as large: its caller says it is stale.
    const stopped = () => !!(bg && bg.stop && bg.stop());
    const c = (await countOf(false)) || (stopped() ? null : await countOf(true));
    if (!c) { return !stopped(); }
    // Over MAX_CHANGES the helper sends a count, no values: nothing to hold.
    const count = Number(c.count);
    return count <= MAX_CHANGES && count * (Number(c.bits) || width) > max;
  }
  // Runs `read` after the background reads before it, once no step of ours is running.
  function inLine(s, read) {
    const turn = (s.line || Promise.resolve()).then(() => idle(s)).then(read);
    s.line = turn.catch(() => {});
    return turn;
  }
  function idle(s) { return s.steps > 0 ? new Promise((resolve) => { (s.idle = s.idle || []).push(resolve); }) : Promise.resolve(); }
  function stepStarted(s) { s.steps = (s.steps || 0) + 1; }
  function stepEnded(s) {
    s.steps = Math.max(0, (s.steps || 0) - 1);
    if (!s.steps && s.idle) { const w = s.idle; s.idle = []; w.forEach((resolve) => resolve()); }
  }
  async function readChanges(s, v) {
    const changes = await host.signalChanges(v, MAX_CHANGES);
    const out = Array.isArray(changes) ? changes : null;
    s.changes.set(v.netlistId, out);
    // Keep at most CACHED_BITS across signals: Verdi checks' reads go first, then the oldest; the
    // one just read stays.
    if (!s.bitsOf) { s.bitsOf = new Map(); }
    const bits = out ? out.length * ((Number(v.width) || 1) + 32) : 0;
    s.bitsOf.set(v.netlistId, bits);
    s.cached = (s.cached || 0) + bits;
    const max = cachedBits();
    const drop = (id) => dropChanges(s, id);
    for (const id of [...s.background]) {
      if (s.cached <= max) { break; }
      if (id !== v.netlistId && s.changes.has(id)) { drop(id); }
    }
    for (const id of [...s.changes.keys()]) {
      if (s.cached <= max) { break; }
      if (id !== v.netlistId) { drop(id); }
    }
    return out;
  }
  function dropChanges(s, id) {
    s.changes.delete(id);
    s.background.delete(id);
    s.cached = (s.cached || 0) - ((s.bitsOf && s.bitsOf.get(id)) || 0);
    if (s.bitsOf) { s.bitsOf.delete(id); }
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
  // The dump provider; `background` ({ stop, maxBits, hint }): a Verdi check's (see changesOf).
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
        if ((bits === undefined || bits === null) && session.kind === 'v2') {
          // The helper's batch had no value for it (or failed): asked again on its own.
          const r = await v2({ cmd: 'valueAt', signalIds: [v.signalId], t: time }, background);
          const one = r && Array.isArray(r.values) ? r.values[0] : undefined;
          if (typeof one === 'string') { bits = one; }
        }
        if ((bits === undefined || bits === null) && !(session.kind === 'v2' && refusedByHelper(v))) {
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
        if (refusedByHelper(v)) { return null; }
        // Integer times: the last change at or before `time` is the last one before time + 1.
        const at = await v2Edge(v, Math.floor(time) + 1, 'any', background);
        if (at !== undefined) { return at === null ? 0 : at; }
        if (refusedByHelper(v)) { return null; }
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
      // clock's edge (its last bit) is searched for.
      if (session.kind === 'v2' && refusedByHelper(v)) { return null; }
      if (session.kind === 'v2' && width === 1) {
        const at = await v2Edge(v, Math.floor(time) + 1, edge === 'PosEdge' ? 'rise' : edge === 'NegEdge' ? 'fall' : 'any', background);
        if (at !== undefined) { return at; }
      }
      if (session.kind === 'v2' && width > 1) {
        const at = await v2WideEdge(v, width, time, edge, background);
        if (at !== undefined) { return at; }
      }
      if (session.kind === 'v2' && refusedByHelper(v)) { return null; }
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
  function guardedDump(stop, hint) {
    const max = Number(waveform.traceVerdiMaxBits) > 0 ? Number(waveform.traceVerdiMaxBits) : VERDI_MAX_BITS;
    const bg = { stop, maxBits: max, hint, pending: new Set() };
    const d = makeDump(bg);
    const guard = (f) => (...args) => (stop() ? Promise.reject(Object.assign(new Error('stale'), { code: 'stale' })) : f(...args));
    return { values: guard(d.values), lastChange: guard(d.lastChange), prevEdge: guard(d.prevEdge), background: bg };
  }

  // ---- tracing ----
  // The steps shown, and where in them the panel is (Back/Forward).
  const history = { steps: [], at: -1 };
  let running = 0;

  const markerTime = () => {
    const w = host.viewerContext.webview;
    return w && w.markerTime !== undefined && w.markerTime !== null ? Number(w.markerTime) : null;
  };

  // A waveform path (dump segments, null: the selected row) at a time (null: the marker), as a
  // design query: cmux resolves it. Null (the panel says why) when it can't.
  async function resolved(query) {
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
      if (build && build.failed) { renderBuild(); } else { showError(error.message || s.traceFailed); }
      return null;
    }
    return Object.assign({ time }, mapped);
  }

  async function driver(query) {
    if (heldByBuild()) { return null; }
    lastEntry = () => driver(query);
    stopChain();
    const q = await resolved(query);
    return q ? driverOfDesign(q) : null;
  }
  // From the editor (cmux mapped the path); a click while the design model builds points at it.
  function fromEditor(query) {
    if (heldByBuild()) { return null; }
    lastEntry = () => fromEditor(query);
    return driverOfDesign(query);
  }

  // The design query's time (null: the panel says why not), with the session for its dump.
  function designQuery(query) {
    const q = query || {};
    const time = q.time !== undefined && q.time !== null ? Number(q.time) : markerTime();
    if (!q.designPath) { showError(S().traceNoSignal); return null; }
    if (time === null || !Number.isFinite(time)) { showError(S().traceNoMarker); return null; }
    if (!session || session.backend !== host.currentBackend || session.kind !== dumpKind() || session.designPrefix !== (q.designPrefix || '') || session.dumpPrefix !== (q.dumpPrefix || '')) {
      session = newSession(q.designPrefix, q.dumpPrefix);
      session.options = { xprop: q.xprop || 'auto' };
      session.engine = window.cmuxTrace.createEngine({ models: sessionModels(session), dump, options: session.options });
    }
    return time;
  }

  async function driverOfDesign(query) {
    const time = designQuery(query);
    if (time === null) { return null; }
    stopChain();
    history.steps = history.steps.slice(0, history.at + 1);
    return traceStep(query.designPath, time, true);
  }

  // ---- Trace X to Root ----
  // The chain shown (null: the panel shows the history's step). Its steps come as they are found;
  // a new trace, Close or Cancel stops it.
  let chain = null;
  function stopChain() { if (chain) { chain.cancelled = true; chain = null; } }
  async function xRoot(query) {
    if (heldByBuild()) { return null; }
    lastEntry = () => xRoot(query);
    stopChain();
    const q = query && query.designPath ? query : await resolved(query);
    if (!q) { return null; }
    const time = designQuery(q);
    if (time === null) { return null; }
    stopChain();
    running++;
    const s = session;
    const c = { designPath: q.designPath, time, steps: [], end: null, root: -1, approximate: false, running: true, cancelled: false };
    chain = c;
    renderChain();
    const live = () => !c.cancelled && chain === c && session === s;
    // A candidate: our engine only. A step of the chain: confirmed by Verdi when the dump has it,
    // within the step's Verdi budget (past it the step stays ours, "not checked").
    const probe = async (path, at) => {
      stepStarted(s);
      try { return await s.engine.active(path, at); } finally { stepEnded(s); }
    };
    const step = async (path, at) => {
      const dumpPath = toDump(path);
      const verdi = s.kind === 'local' ? null : askVerdi(dumpPath, at);
      let st = await probe(path, at);
      st.dumpPath = dumpPath;
      st.engine = { name: 'cmux' };
      if (verdi && !st.error && live()) { st = await chainVerdi(s, st, at, verdi, live); }
      return st;
    };
    // Each step says when it was found (ms after the start) and how long it took (with its candidates).
    const t0 = Date.now();
    let prev = t0;
    const out = await window.cmuxTrace.xChain({ path: q.designPath, time }, {
      step, probe, cancelled: () => !live(), maxSteps: waveform.traceXChainSteps,
      onStep: (e) => {
        const now = Date.now();
        Object.assign(e, { dumpPath: e.step.dumpPath || toDump(e.signal), at: now - t0, ms: now - prev });
        prev = now;
        c.steps.push(e);
        if (chain === c) { renderChain(); }
      },
    });
    Object.assign(c, { end: out.end, root: out.root, approximate: out.approximate, running: false });
    if (chain === c) { renderChain(); }
    return plain({ steps: c.steps, end: c.end, root: c.root, approximate: c.approximate });
  }
  // A chain step with Verdi's answer merged in (withVerdi), or as it was, marked not checked.
  async function chainVerdi(s, st, time, asked, live) {
    const deadline = Date.now() + verdiBudget();
    let timer;
    const stop = () => !live() || Date.now() >= deadline;
    const v = s.vars.get(st.signal);
    const known = v && s.changes.get(v.netlistId);
    const checkDump = guardedDump(stop, Array.isArray(known) ? known.length : undefined);
    const engine = window.cmuxTrace.createEngine({ models: s.models, dump: checkDump, options: s.options });
    const late = { timedOut: true };
    const limit = new Promise((resolve) => { timer = setTimeout(() => resolve(late), verdiBudget()); });
    try {
      const out = await Promise.race([withVerdi(st, time, asked, stop, engine), limit]);
      if (out && !out.large && out !== late) { return out; }
      st.engine.verdi = out && out.large ? 'large' : 'timedOut';
      return st;
    } catch (error) {
      host.log(error);
      st.engine.verdi = 'timedOut';
      return st;
    } finally { clearTimeout(timer); cancelPending(s, checkDump.background); }
  }

  async function traceStep(designPath, time, push) {
    const s = S();
    const run = ++running;
    showBusy(format(s.traceRunning, designPath, number(time)));
    // Verdi (when this dump may have it) is asked while our engine runs, not after it.
    const dumpPath = toDump(designPath);
    const verdi = session.kind === 'local' ? null : askVerdi(dumpPath, time);
    let step;
    const ours = session;
    stepStarted(ours);
    try {
      step = await session.engine.active(designPath, time);
    } catch (error) {
      host.log(error);
      if (run === running) { showError(error.message || s.traceFailed); }
      return null;
    } finally { stepEnded(ours); }
    if (run !== running) { return null; }
    step.dumpPath = dumpPath;
    step.engine = { name: 'cmux' };
    // Ours is shown now; Verdi's answer fills the step in later (verdiCheck), never before.
    if (verdi && !step.error) { step.engine.verdi = 'checking'; verdiCheck(step, time, verdi); }
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
  // is shown; past it the step says "Verdi: not checked (timed out)". On a CPU design Verdi answers in well
  // under a second once warm (it was asked when the step started), a port hop on a whole-signal
  // helper takes up to ~30 s.
  const VERDI_BUDGET_MS = 10000;
  const verdiBudget = () => (Number(waveform.traceVerdiBudgetMs) > 0 ? Number(waveform.traceVerdiBudgetMs) : VERDI_BUDGET_MS);
  const checks = new Set();
  // Fills `step` in with Verdi's answer when it comes within the budget, while the step is in the
  // history (Back to it keeps the check); dropped once the step is not (a branch, close()).
  function verdiCheck(step, time, asked) {
    const deadline = Date.now() + verdiBudget();
    const late = { timedOut: true };
    let timer;
    // Done once its budget is up or it has settled: from then on it reads and asks nothing.
    let done = false;
    const limit = new Promise((resolve) => { timer = setTimeout(() => { done = true; resolve(late); }, Math.max(0, deadline - Date.now())); });
    const gone = () => !history.steps.includes(step);
    const stop = () => done || gone() || Date.now() >= deadline;
    const v = session.vars.get(step.signal);
    const known = v && session.changes.get(v.netlistId);
    const hint = Array.isArray(known) ? known.length : undefined;
    const checkDump = guardedDump(stop, hint), checkSession = session;
    const engine = window.cmuxTrace.createEngine({ models: session.models, dump: checkDump, options: session.options });
    let shown = step;
    const check = Promise.race([withVerdi(step, time, asked, stop, engine), limit]).then((out) => {
      if (gone()) { step.engine.verdi = 'dropped'; return; }
      if (out === late || !out) {
        step.engine.verdi = 'timedOut';
      } else if (out.large) {
        step.engine.verdi = 'large';
      } else {
        const i = history.steps.indexOf(step);
        if (i >= 0) { history.steps[i] = out; }
        shown = out;
      }
      if (history.steps[history.at] === shown) { render(); }
      host.toNative({ type: 'trace', event: 'update', step: plain(shown) });
    }).catch((error) => { host.log(error); step.engine.verdi = 'timedOut'; })
      .finally(() => {
        done = true; clearTimeout(timer); cancelPending(checkSession, checkDump.background); checks.delete(check);
        // (A filled-in step replaced `step` in the history: `shown` is the one still there.)
        if (history.steps.includes(shown)) { prefetchLeaves(checkSession, shown); }
      });
    checks.add(check);
  }
  // Resolves when every Verdi check under way has finished (cmux and the checks wait on this).
  async function settled() {
    while (checks.size) { await Promise.allSettled([...checks]); }
    return state();
  }
  const sameFile = (a, b) => !!a && !!b && (a === b || String(a).split('/').pop() === String(b).split('/').pop());
  const isPort = (st) => !!st.driver && (st.driver.kind === 'portIn' || st.driver.kind === 'portOut');
  // Verdi's answer (null when the request failed); the step's budget bounds the wait. A prefetched
  // answer for the same signal and time is used (status/tracex-verdi-pool.md, phase A).
  function askVerdi(signal, time) {
    const s = session;
    const key = signal + '@' + time;
    const known = s.verdiAnswers && s.verdiAnswers.get(key);
    if (known) {
      s.verdiAnswers.delete(key);
      s.prefetchHits = (s.prefetchHits || 0) + 1;
      return known.then((r) => r || engineRequest(s, signal, time));
    }
    // Asked now: not prefetched as well later.
    if (s.prefetch) { s.prefetch = s.prefetch.filter((q) => q.key !== key); }
    return engineRequest(s, signal, time);
  }
  // A background request (a prefetch) gets a shorter timeout natively, and its failure doesn't
  // make the next clicks go without Verdi. Each answer says how many requests cmux's pool runs at
  // once for this dump (`pool`).
  function engineRequest(s, signal, time, background) {
    s.verdiInFlight = (s.verdiInFlight || 0) + 1;
    const body = background ? { cmd: 'active', signal, time, background: true } : { cmd: 'active', signal, time };
    return request('engine', body)
      .then((r) => { const n = r && Math.floor(Number(r.pool)); if (n >= 1) { s.verdiPool = n; } return r; })
      .catch((error) => { host.log(error); return null; })
      .finally(() => { s.verdiInFlight--; pumpPrefetch(s); });
  }

  // ---- Verdi prefetch (status/tracex-verdi-pool.md) ----
  // Once a step's check has settled, Verdi is asked about the step's fan-in leaves (the next click's
  // candidates) while it would sit idle: on one session only when no step or check of ours is
  // asking, with N sessions (traceVerdiSessions, clamped to cmux's pool) up to N requests at once. Answers are kept per
  // trace session (a reload or another dump starts a new one), only when Verdi was ready.
  // Off by default until the pool A/B (one session: a click can wait behind one prefetch call).
  const VERDI_PREFETCH = 0;
  const prefetchCount = () => {
    const n = Number(waveform.traceVerdiPrefetch);
    return waveform.traceVerdiPrefetch !== undefined && Number.isFinite(n) && n >= 0 ? Math.floor(n) : VERDI_PREFETCH;
  };
  // traceVerdiSessions, at most the pool cmux reported for this dump (one until it says more).
  // Prefetched answers kept per trace session, the oldest going first (traceVerdiAnswers for tests).
  const VERDI_ANSWERS = 64;
  const answersKept = () => (Number(waveform.traceVerdiAnswers) >= 1 ? Math.floor(Number(waveform.traceVerdiAnswers)) : VERDI_ANSWERS);
  const verdiSessions = (s) => {
    const n = Math.floor(Number(waveform.traceVerdiSessions));
    return Math.min(n >= 1 ? Math.min(n, 8) : 1, (s && s.verdiPool) || 1);
  };
  const ROLE_ORDER = { data: 0, index: 1, control: 2, clock: 3 };
  function prefetchLeaves(s, step) {
    if (s !== session || s.kind === 'local' || !step || !Array.isArray(step.fanin)) { return; }
    const max = prefetchCount();
    if (!max) { return; }
    if (!s.verdiAnswers) { s.verdiAnswers = new Map(); }
    const leaves = step.fanin.filter((f) => f.path && f.dumped !== false && Number.isFinite(Number(f.time)))
      .sort((a, b) => (ROLE_ORDER[a.role] ?? 4) - (ROLE_ORDER[b.role] ?? 4));
    const queue = [];
    for (const f of leaves) {
      const key = toDump(f.path) + '@' + f.time;
      if (s.verdiAnswers.has(key) || queue.some((q) => q.key === key)) { continue; }
      queue.push({ key, signal: toDump(f.path), time: f.time });
      if (queue.length >= max) { break; }
    }
    // The newest step's leaves replace the ones still waiting.
    s.prefetch = queue;
    pumpPrefetch(s);
  }
  function pumpPrefetch(s) {
    if (s !== session || !s.prefetch || !s.prefetch.length) { return; }
    const n = verdiSessions(s);
    while (s.prefetch.length && (s.verdiInFlight || 0) < n && (n > 1 || (!checks.size && !s.steps))) {
      const { key, signal, time } = s.prefetch.shift();
      if (s.verdiAnswers.has(key)) { continue; }
      s.prefetched = (s.prefetched || 0) + 1;
      const p = engineRequest(s, signal, time, true).then((r) => {
        if (!r || r.state !== 'ready') { if (s.verdiAnswers.get(key) === p) { s.verdiAnswers.delete(key); } return null; }
        return r;
      });
      s.verdiAnswers.set(key, p);
      for (const k of s.verdiAnswers.keys()) {
        if (s.verdiAnswers.size <= answersKept()) { break; }
        s.verdiAnswers.delete(k);
      }
    }
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
        try { cur = await engine.active(next[0].path, time); } catch (error) {
          if (stop()) { return null; }
          if (error && error.code === 'large') { return { large: true }; }
          throw error;
        }
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

  function back() { stopChain(); if (history.at > 0) { history.at--; render(); post(); } return state(); }
  function forward() { stopChain(); if (history.at < history.steps.length - 1) { history.at++; render(); post(); } return state(); }
  function post() { const st = history.steps[history.at]; if (st) { host.toNative({ type: 'trace', event: 'step', step: plain(st) }); } }
  function close() {
    running++;
    stopChain();
    history.steps = []; history.at = -1;
    // No more prefetching for a closed panel; its answers go too.
    if (session) { session.prefetch = []; if (session.verdiAnswers) { session.verdiAnswers.clear(); } }
    if (panel) { panel.hidden = true; }
    host.toNative({ type: 'trace', event: 'closed' });
    return state();
  }
  function state() {
    const st = history.steps[history.at];
    return { open: !!(panel && !panel.hidden), steps: history.steps.length, at: history.at, step: st ? plain(st) : null,
      prefetch: { asked: (session && session.prefetched) || 0, used: (session && session.prefetchHits) || 0,
        kept: (session && session.verdiAnswers && session.verdiAnswers.size) || 0,
        queued: ((session && session.prefetch) || []).map((q) => q.signal) },
      cache: { signals: session && session.changes ? session.changes.size : 0, bits: (session && session.cached) || 0 },
      chain: chain ? { running: chain.running, steps: chain.steps.length, end: chain.end ? chain.end.code : null } : null };
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
      #cmux-trace ul { margin: 2px 0; padding-left: 16px; }
      #cmux-trace tr.xstep { cursor: pointer; }
      #cmux-trace tr.xstep:hover, #cmux-trace tr.xstep:focus { background: var(--vscode-list-hoverBackground); outline: none; }
      #cmux-trace tr.xstep.root td { font-weight: 600; }
      #cmux-trace tr.xstep.root { background: var(--vscode-list-inactiveSelectionBackground); }
      #cmux-trace ul.stages { list-style: none; padding-left: 2px; }
      #cmux-trace li.stage .mark { display: inline-block; width: 14px; }
      #cmux-trace li.stage.pending { color: var(--vscode-descriptionForeground); }
      #cmux-trace li.stage.current { font-weight: 600; }
      #cmux-trace li.stage.done .mark { color: var(--vscode-testing-iconPassed, #73c991); }
      #cmux-trace .bar { display: inline-block; width: 120px; height: 4px; margin-left: 8px; vertical-align: middle; border-radius: 2px;
        background: var(--vscode-widget-border); overflow: hidden; }
      #cmux-trace .bar .fill { display: block; height: 100%; background: var(--vscode-progressBar-background, #0e70c0); }
      #cmux-trace pre.build-log { margin: 2px 0 6px; max-height: 12em; overflow: auto; }
      #cmux-trace .build-actions { display: flex; align-items: center; gap: 10px; }
      #cmux-trace.pulse { animation: cmux-trace-pulse 0.6s ease-in-out 2; }
      @keyframes cmux-trace-pulse { 50% { box-shadow: 0 0 0 3px var(--vscode-focusBorder, #007fd4); } }`;
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
    if (e.verdi === 'large') { text += ' · ' + s.traceVerdiLarge; }
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
    if (chain) { renderChain(); return; }
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

  // The chain: a row per step (signal = value at its time, its statement, why it follows the one
  // before, trust), the root highlighted; a row opens its statement and shows the signal at its
  // time in the waveform. Then why it ended, or how far it has got.
  function renderChain() {
    const c = chain;
    if (!c) { return; }
    busy = false;
    const s = S();
    const p = ensurePanel();
    p.textContent = '';
    const h = el('div', 'head');
    h.append(el('span', 'title', format(s.traceXTitle, c.designPath, number(c.time))));
    if (!c.running && c.steps.length) {
      const trust = c.approximate ? 'approximate' : 'exact';
      const b = el('span', 'badge ' + trust, s['traceTrust_' + trust] || trust);
      b.title = s['traceTrustHelp_' + trust] || '';
      h.append(b);
    }
    if (c.running) { const b = button(s.traceXCancel || '', s.traceXCancel, () => { c.cancelled = true; }); b.classList.add('xcancel'); h.append(b); }
    if (c.steps.length) { const b = button(s.traceXAdd || '', s.traceXAdd, () => addChainSignals(c)); b.classList.add('xadd'); h.append(b); }
    h.append(button('×', s.traceClose, close));
    p.append(h);
    const body = el('div', 'body');
    const table = el('table');
    c.steps.forEach((e, i) => {
      const st = e.step || {};
      const tr = el('tr', 'xstep' + (i === c.root ? ' root' : ''));
      tr.tabIndex = 0;
      tr.dataset.path = e.signal || '';
      const loc = st.stmt && st.stmt.loc;
      const whyText = e.why.code === 'earliest' ? format(s.traceXWhy_earliest, e.why.count) : s['traceXWhy_' + e.why.code] || e.why.code;
      const role = e.why.role && e.why.code !== 'start' ? ' · ' + (s['traceRole_' + e.why.role] || e.why.role) : '';
      tr.append(el('td', 'muted', String(i + 1)), el('td', 'code', e.signal), el('td', 'code' + (/[xz]/.test(String(e.value)) ? ' x' : ''), valueText(e.value)),
        el('td', 'muted', '@' + number(e.time)), el('td', '', where(loc)), el('td', 'muted', whyText + role),
        el('td', 'badge ' + (e.trust || ''), s['traceTrust_' + e.trust] || e.trust || ''));
      if (i === c.root) { tr.append(el('td', 'badge', s.traceXRootBadge || '')); }
      if (st.stmt && st.stmt.src) { tr.title = st.stmt.src; }
      const go = () => { open(loc); showInWaveform(e); };
      tr.addEventListener('click', go);
      tr.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); go(); } });
      table.append(tr);
    });
    body.append(table);
    const endCode = c.end && c.end.code;
    const last = c.steps[c.steps.length - 1];
    const endText = c.running ? format(s.traceXRunning, c.steps.length)
      : format(s['traceXEnd_' + endCode] || endCode || '', endCode === 'budget' ? String(c.steps.length) : endCode === 'noX' ? c.designPath : (c.end && c.end.signal) || '');
    body.append(el('div', 'muted', endText));
    if (last && !c.running && c.root >= 0) {
      const reasons = ((last.step && last.step.reasons) || []).filter((r) => r.code !== 'multiDriven');
      if (reasons.length) { const ul = el('ul', 'muted'); for (const r of reasons) { ul.append(el('li', '', reasonText(r))); } body.append(ul); }
    }
    p.append(body);
    p.hidden = false;
  }
  // The step's signal in the waveform (added unless shown, selected) with the marker at its time.
  async function showInWaveform(e) {
    const path = dumpSegments(e.dumpPath || toDump(e.signal));
    try { await waveform.link.addSignal(path); } catch (error) { host.log(error); }
    waveform.link.setMarker(e.time);
  }
  async function addChainSignals(c) {
    for (const e of c.steps) {
      try { await waveform.link.addSignal(dumpSegments(e.dumpPath || toDump(e.signal))); } catch (error) { host.log(error); }
    }
  }

  // ---- the waveform row's menu ----
  function rowMenuItems(context) {
    const c = context || {};
    if (c.webviewSection !== 'signal' || c.netlistId === undefined) { return []; }
    const v = host.netlistItem(c.netlistId);
    if (!v) { return []; }
    const path = host.pathOf(v);
    return [{ label: S().traceDriverMenu || '', keybinding: S().traceDriverKey || '', run: () => driver({ path }) },
      { label: S().traceXRootMenu || '', keybinding: S().traceXRootKey || '', run: () => xRoot({ path }) }];
  }

  // A reload drops the session (its variables and changes are the old file's).
  function backendChanged() { session = null; }

  // Shown only while a trace is waiting (not over a step already shown).
  function status(text) { if (!build && panel && !panel.hidden && busy) { showBusy(String(text || '')); } return true; }

  // ---- the first-time design model build ----
  // cmux builds cmux-sv-model once per host and cmux version; its progress calls come while the
  // trace's resolve (or model request) waits. The build is the page's own state so that another
  // click while it builds shows it again rather than "Finding…".
  const STAGES = ['upload', 'fetch', 'configure', 'compile', 'install', 'load'];
  let build = null;
  let buildDone = null;
  let lastEntry = null;
  const building = () => !!build && !build.failed;
  // A new trace while the design model builds asks nothing new and points at the build; after a
  // failed build it starts over (the failure is shown again if it fails again).
  function heldByBuild() {
    if (build && build.failed) { build = null; }
    if (!building()) { return false; }
    focusBuild();
    return true;
  }
  const sizeText = (n) => {
    const b = Number(n) || 0;
    if (b < 1024) { return `${b} B`; }
    if (b < 1024 * 1024) { return `${Math.round(b / 1024)} KB`; }
    return `${(b / (1024 * 1024)).toFixed(1)} MB`;
  };
  const elapsedText = (startedAt) => {
    const sec = Math.max(0, Math.floor((Date.now() - Number(startedAt)) / 1000));
    return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
  };
  function endBuild() {
    stopTicking();
    if (build) { buildDone = build.startedAt; }
    build = null;
  }
  function stopTicking() { if (build && build.timer) { clearInterval(build.timer); build.timer = null; } }
  function progress(p) {
    const q = p || {};
    const stage = String(q.stage || '');
    const startedAt = Number.isFinite(Number(q.startedAt)) ? Number(q.startedAt) : null;
    if (stage === 'done') {
      if (startedAt !== null && build && build.startedAt !== startedAt) { return true; }
      buildDone = startedAt !== null ? startedAt : build && build.startedAt;
      endBuild();
      return true;
    }
    if (stage !== 'failed' && startedAt !== null && startedAt === buildDone) { return true; }
    if (!build || (startedAt !== null && build.startedAt !== startedAt)) {
      stopTicking();
      build = { startedAt: startedAt !== null ? startedAt : Date.now(), stage: 'upload', percent: null, sourceBytes: null };
    }
    build.host = q.host === undefined ? build.host : q.host;
    if (stage === 'failed') {
      stopTicking();
      build.failed = { message: String(q.message || ''), log: String(q.log || '') };
    } else if (STAGES.includes(stage)) {
      build.failed = null;
      build.stage = stage;
      build.percent = Number.isFinite(Number(q.percent)) && q.percent !== null ? Math.max(0, Math.min(100, Math.round(Number(q.percent)))) : (stage === 'compile' ? build.percent : null);
      if (q.sourceBytes !== undefined) { build.sourceBytes = Number(q.sourceBytes); }
      if (!build.timer) {
        build.timer = setInterval(() => {
          const e = panel && panel.querySelector('.build-elapsed');
          if (e && build) { e.textContent = format(S().traceBuildElapsed || '%@', elapsedText(build.startedAt)); }
        }, 1000);
      }
    } else {
      return false;
    }
    renderBuild();
    return true;
  }
  function focusBuild() {
    renderBuild();
    const p = ensurePanel();
    p.classList.remove('pulse');
    void p.offsetWidth;
    p.classList.add('pulse');
    setTimeout(() => p.classList.remove('pulse'), 1200);
    p.focus();
  }
  function buildInfoLink() {
    const a = el('a', 'buildinfo', S().traceBuildWhat || '');
    a.href = '#';
    a.addEventListener('click', (e) => { e.preventDefault(); host.toNative({ type: 'trace', event: 'buildInfo' }); });
    return a;
  }
  function renderBuild() {
    if (!build) { return; }
    const s = S();
    const local = !build.host;
    busy = false;
    if (build.failed) {
      const p = head(local ? s.traceBuildFailedTitleLocal : format(s.traceBuildFailedTitle, build.host));
      const body = el('div', 'body');
      if (build.failed.message) { body.append(el('div', '', build.failed.message)); }
      const lines = build.failed.log.split('\n').filter((l) => l.trim()).slice(-20);
      if (lines.length) {
        body.append(el('div', 'muted', s.traceBuildLog || ''));
        body.append(el('pre', 'code build-log', lines.join('\n')));
      }
      const row = el('div', 'build-actions');
      const retry = button(s.traceBuildRetry || '', '', () => {
        const again = lastEntry;
        build = null;
        if (again) { again(); }
      });
      retry.classList.add('retry');
      row.append(retry, buildInfoLink());
      body.append(row);
      p.append(body);
      return;
    }
    const p = head(local ? s.traceBuildTitleLocal : format(s.traceBuildTitle, build.host));
    const body = el('div', 'body');
    const list = el('ul', 'stages');
    const at = STAGES.indexOf(build.stage);
    STAGES.forEach((name, i) => {
      const state = i < at ? 'done' : i === at ? 'current' : 'pending';
      const label = name === 'upload' ? format(s.traceBuildStage_upload, sizeText(build.sourceBytes || 0)) : (s['traceBuildStage_' + name] || name);
      const li = el('li', 'stage ' + state);
      li.dataset.stage = name;
      li.dataset.state = state;
      li.append(el('span', 'mark', state === 'done' ? '✓' : state === 'current' ? '›' : '·'), el('span', '', label));
      if (name === 'compile' && state === 'current' && build.percent !== null) {
        li.append(el('span', 'muted', ` ${build.percent}%`));
        const bar = el('span', 'bar');
        const fill = el('span', 'fill');
        fill.style.width = `${build.percent}%`;
        bar.append(fill);
        li.append(bar);
      }
      list.append(li);
    });
    body.append(list);
    body.append(el('div', 'muted build-elapsed', format(s.traceBuildElapsed || '%@', elapsedText(build.startedAt))));
    const foot = el('div', 'muted');
    foot.append(el('span', '', (s.traceBuildOnce || '') + ' '), buildInfoLink());
    body.append(foot);
    p.append(body);
  }

  const api = Object.freeze({ driver, driverOfDesign: fromEditor, xRoot, reply, status, progress, back, forward, close, state, settled, backendChanged });
  Object.defineProperty(waveform, 'trace', { value: api, writable: false, configurable: false, enumerable: true });
  window.cmuxTraceUI = { rowMenuItems };
})();
