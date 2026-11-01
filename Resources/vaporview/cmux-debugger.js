// cmux's waveform debugger, page side (FEATURES.md section F, phase 1): the dump
// is a recorded run, stepped one clock cycle at a time like a debugger steps a
// program. Written for cmux; it drives VaporView's viewer frame only through
// the messages VaporView's webview already accepts (setMarker, setViewportTo,
// add-variable, newSignalGroup, remove-signal, editSignalGroup).
//
// cmux calls window.cmuxWaveform.debugger through callAsyncJavaScript:
//   state() -> { clock, cycle, count, time, edgeTime, previousTime, playing, rate, stepping }
//   cycleAt({ time }) -> the same for another time (the cycle values were read at)
//   step({ by })                     marker to the clock's posedge `by` cycles away (by < 0: back)
//   jump({ to: 'first' | 'last' })   marker to the first or last posedge
//   play({ rate }) | pause() | togglePlay() | setRate({ rate }) | changeRate({ by })   rate in cycles per second
//   setClock({ path }) -> path | null          a 1-bit signal's dump path (segments); null: the default
//   useSelectedAsClock() -> path | null        the selected row's signal
//   stop()                           leaves stepping: pauses, removes Locals and the highlights
//   setLocals({ path })              Locals group = the signals of dump scope `path` (null: empty)
//   highlightRows({ paths })         rows (and their transition at the marker) the editor highlights
// and posts { type: 'debugger', event: 'cycle' | 'state', ...state() } when the
// cycle or the play state changes while stepping.
(function () {
  const waveform = window.cmuxWaveform;
  const host = waveform.host;
  const S = () => waveform.strings || {};
  const iframe = document.getElementById('viewer');

  // Clock names looked for under the top scopes (then one level down, below a
  // simulator wrapper such as TOP), case-insensitively, in this order.
  const CLOCK_NAMES = ['clk', 'clock', 'clk_i', 'clock_i', 'i_clk', 'clk_in', 'aclk', 'hclk', 'pclk'];
  const RATES = [1, 2, 5, 10, 20, 50, 100, 200, 500];
  // A clock with more posedges than this is not stepped (keeps memory bounded).
  const MAX_EDGES = 10000000;
  const MAX_LOCALS = 64;

  const state = {
    clock: null,        // the netlist variable
    clockChosen: false, // set by the user (not the default)
    edges: null,        // Float64Array of posedge times, ascending
    edgesFor: null,     // [clock, backend] the edges were read for
    clockFor: null,     // the backend whose netlist state.clock is from
    loading: null,
    loadingFor: null,   // the backend a load in progress reads from
    stepping: false,
    playing: false,
    rate: 10,
    lastCycleKey: null,
    locals: { path: null, request: 0, groupId: null, label: null, busy: false, vars: null, pinnedKey: null },
    highlightIds: new Set(),  // netlistIds the editor highlights
    highlightRequest: 0,
    highlighted: [],    // their rowIds as drawn
  };

  // ---- clock and posedges ----
  async function defaultClock() {
    const tops = host.doc.netlist.filter((t) => t.kind === 'scope');
    const pick = (items) => {
      for (const name of CLOCK_NAMES) {
        const v = items.find((c) => c.kind === 'var' && String(c.name).toLowerCase() === name && Number(c.width) === 1);
        if (v) { return v; }
      }
      return null;
    };
    for (const top of tops) {
      const v = pick(await host.getChildren(top));
      if (v) { return v; }
    }
    for (const top of tops) {
      for (const child of (await host.getChildren(top)).filter((c) => c.kind === 'scope').slice(0, 16)) {
        const v = pick(await host.getChildren(child));
        if (v) { return v; }
      }
    }
    return null;
  }

  // Times where the clock goes to 1 from anything else (0, x, z).
  function posedges(changes) {
    const out = [];
    let previous = null;
    for (const [time, value] of changes) {
      const high = String(value) === '1';
      if (high && previous !== null && previous !== '1') { out.push(Number(time)); }
      previous = String(value);
      if (out.length > MAX_EDGES) { throw new Error('too many clock edges'); }
    }
    return Float64Array.from(out);
  }

  async function ensureEdges() {
    const backend = host.currentBackend;
    if (!backend || !host.doc.metadata) { return null; }
    if (state.edges && state.edgesFor && state.edgesFor[1] === backend && state.edgesFor[0] === state.clock) { return state.edges; }
    // A load from a backend a reload closed fails; a new backend starts its own.
    if (state.loading && state.loadingFor === backend) { return state.loading; }
    state.loadingFor = backend;
    const load = state.loading = (async () => {
      try {
        if (!state.clock || state.clockFor !== backend) {
          // A reload brings a new netlist: find the clock again by path.
          const path = state.clock ? host.pathOf(state.clock) : null;
          state.clock = (path && await host.findLinkItem(path, true)) || (state.clockChosen ? null : await defaultClock());
          if (!state.clock) { state.clockChosen = false; state.clock = await defaultClock(); }
          state.clockFor = backend;
        }
        for (;;) {
          if (!state.clock) { state.edges = null; return null; }
          const clock = state.clock;
          // A reload since: this clock belongs to the closed backend's netlist.
          if (host.currentBackend !== backend) { throw Object.assign(new Error('closed'), { cmuxClosed: true }); }
          const fast = host.signalPosedges(clock, MAX_EDGES);
          let edges;
          if (fast) {
            edges = await fast;
          } else {
            const changes = await host.signalChanges(clock, MAX_EDGES * 2);
            edges = changes ? posedges(changes) : new Float64Array(0);
          }
          // The clock was changed while its edges were read: read the new one's.
          if (state.clock !== clock) { continue; }
          state.edges = edges;
          state.edgesFor = [clock, backend];
          return state.edges;
        }
      } finally {
        if (state.loading === load) { state.loading = null; state.loadingFor = null; }
      }
    })();
    return load;
  }

  // Index of the last posedge at or before `time`, -1 before the first.
  function edgeIndexAt(edges, time) {
    let lo = 0, hi = edges.length - 1, at = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (edges[mid] <= time) { at = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return at;
  }

  // The viewer reports a marker move (markerSet) before its context catches up,
  // so the event's time wins until the context says something newer.
  const marker = { fromEvent: null, contextThen: null };
  const contextMarker = () => {
    const w = host.viewerContext.webview;
    return w && w.markerTime !== undefined && w.markerTime !== null ? Number(w.markerTime) : null;
  };
  const markerTime = () => {
    const fromContext = contextMarker();
    if (marker.fromEvent !== null && fromContext === marker.contextThen) { return marker.fromEvent; }
    marker.fromEvent = null;
    return fromContext;
  };

  // Cycle n is the n-th posedge (1-based); before the first it is 0. The cycle
  // ending at the marker started at the posedge before it (previousTime).
  function cycleInfo(time) {
    const edges = state.edges;
    const base = { clock: state.clock ? host.pathOf(state.clock) : null, count: edges ? edges.length : 0,
      playing: state.playing, rate: state.rate, stepping: state.stepping, time };
    if (!edges || time === null) { return Object.assign(base, { cycle: null, edgeTime: null, previousTime: null }); }
    const index = edgeIndexAt(edges, time);
    const previousTime = index > 0 ? edges[index - 1] : (index === 0 && edges[0] > 0 ? 0 : null);
    return Object.assign(base, { cycle: index + 1, edgeTime: index >= 0 ? edges[index] : null, previousTime });
  }

  function publicState() { return cycleInfo(markerTime()); }

  function post(event, extra) {
    const info = publicState();
    host.toNative(Object.assign({ type: 'debugger', event }, info, extra || {}));
    // cmux's listings show the commits at the marker's cycle (none after Stop).
    if (CB && (event === 'cycle' || event === 'state')) { CB.postCurrent(state.stepping ? info.edgeTime : null); }
  }

  // While playing, each move straight from the page (the viewer's markerSet, and so the cycle
  // event, lags when it is busy): `missed` when it gave up waiting for the editors on `left`.
  function postMoved(movedTo, left, missed) {
    post('moved', { movedTo, left, missed });
  }

  // Times the debugger sent the marker to lately: a markerSet at any other time is the user's.
  const sentTimes = [];

  function moveMarker(time) {
    sentTimes.push(time);
    if (sentTimes.length > 32) { sentTimes.shift(); }
    // Until the viewer reports it, the marker is where it was sent (a second
    // quick step starts from here, not from the old marker).
    marker.fromEvent = time;
    marker.contextThen = contextMarker();
    host.toWebview({ command: 'setMarker', time, markerType: 0 });
    // Pans only when the time is out of view.
    host.toWebview({ command: 'setViewportTo', time });
    // The viewer's markerSet event follows; the counter is drawn from it.
  }

  // Why the last start() returned null: 'closed' | 'tooManyEdges' | 'noClock' | 'noEdges'.
  let startFailure = null;
  async function start() {
    const backend = host.currentBackend;
    let edges;
    startFailure = 'closed';
    try {
      edges = await ensureEdges();
    } catch (error) {
      // A reload closed the backend mid-read: it owns the page now, and says nothing.
      if (error && error.cmuxClosed || host.currentBackend !== backend) { return null; }
      // Past MAX_EDGES (or the reader failed): say so rather than stall or run out of memory.
      host.log(error);
      startFailure = 'tooManyEdges';
      window.cmuxUI.toast(S().debuggerTooManyEdges || '', 'warning');
      return null;
    }
    if (host.currentBackend !== backend) { return null; }
    if (!edges) {
      startFailure = 'noClock';
      window.cmuxUI.toast(S().debuggerNoClock || '', 'warning');
      return null;
    }
    if (!edges.length) {
      startFailure = 'noEdges';
      window.cmuxUI.toast(S().debuggerNoEdges || '', 'warning');
      return null;
    }
    startFailure = null;
    if (!state.stepping) { state.stepping = true; render(); post('state'); }
    return edges;
  }

  async function step(query) {
    const asked = Number((query || {}).by);
    const by = Number.isFinite(asked) ? Math.trunc(asked) : 1;
    // Instruction mode (cmux-machine.js): F10 / Shift-F10 go by commit, not by cycle.
    const machine = window.cmuxMachine;
    if (machine && by !== 0 && !(query || {}).cycle && machine.instructionMode()) {
      if (!await start()) { return publicState(); }
      pause();
      await machine.stepCommit({ by });
      return publicState();
    }
    const edges = await start();
    if (!edges) { return publicState(); }
    pause();
    const time = markerTime();
    let index;
    if (time === null) {
      index = by > 0 ? by - 1 : (by < 0 ? edges.length + by : 0);
    } else {
      const at = edgeIndexAt(edges, time);
      // From between two edges, one step back lands on the edge before.
      index = by > 0 || (by === 0 && at >= 0) ? at + by : (edges[at] === time ? at + by : at + by + 1);
    }
    index = Math.max(0, Math.min(edges.length - 1, index));
    moveMarker(edges[index]);
    return cycleInfo(edges[index]);
  }

  async function jump(query) {
    const edges = await start();
    if (!edges) { return publicState(); }
    pause();
    const time = (query || {}).to === 'last' ? edges[edges.length - 1] : edges[0];
    moveMarker(time);
    return cycleInfo(time);
  }

  // ---- play ----
  // Each tick puts the marker on the cycle wall-clock time says it should be at,
  // so a slow redraw skips cycles instead of falling behind.
  let playTimer = 0;
  let playOrigin = null;  // { index, at }

  function scheduleTick(ms) {
    clearTimeout(playTimer);
    playTimer = setTimeout(tick, ms === undefined ? Math.max(16, Math.min(250, 1000 / state.rate)) : Math.max(0, ms));
  }

  // Waiting for the editors (cmux's setting): play moves one cycle at a time, the next
  // once cmux says the editors drew this one (rtlShown), at most RTL_WAIT_MS later.
  const RTL_WAIT_MS = 250;
  let rtlStatus = { text: '', tooltip: '', ok: false, wait: false };
  let rtlPending = null;  // { time, at }: moved there, the editors haven't drawn it yet
  let playIndex = 0;      // the edge play is on
  let lastMoveAt = 0;

  function setRtlStatus(query) {
    const q = query || {};
    const wait = !!q.wait;
    // Back to wall-clock pace: from the cycle reached.
    if (rtlStatus.wait && !wait && state.playing) { playOrigin = { index: playIndex, at: performance.now() }; }
    rtlStatus = { text: String(q.text || ''), tooltip: String(q.tooltip || ''), ok: !!q.ok, wait };
    if (!wait) { rtlPending = null; }
    render();
    return true;
  }

  function rtlShown(query) {
    const time = Number((query || {}).time);
    if (rtlPending && rtlPending.time === time) {
      rtlPending = null;
      if (state.playing && rtlStatus.wait) { scheduleTick(1000 / state.rate - (performance.now() - lastMoveAt)); }
    }
    return true;
  }

  function waitingTick(edges) {
    const now = performance.now();
    if (rtlPending && now - rtlPending.at < RTL_WAIT_MS) {
      scheduleTick(RTL_WAIT_MS - (now - rtlPending.at));
      return;
    }
    const gap = 1000 / state.rate;
    if (now - lastMoveAt < gap) {
      scheduleTick(gap - (now - lastMoveAt));
      return;
    }
    const next = Math.min(edges.length - 1, playIndex + 1);
    const stop = playStop && playStop.index > playIndex && next >= playStop.index ? playStop : null;
    const left = edges[playIndex];
    const missed = rtlPending !== null;
    playIndex = next;
    lastMoveAt = now;
    rtlPending = { time: edges[next], at: now };
    moveMarker(edges[next]);
    postMoved(edges[next], left, missed);
    if (stop) { pause(); announceHit(stop, edges); return; }
    if (next >= edges.length - 1) { playEnded(); return; }
    scheduleTick(gap);
  }

  let playBackend = null;
  let playStarts = 0;

  // Play reached the last edge: a hit after it (no edge to land on) is said, as continue says it.
  function playEnded() {
    const after = playStop && playStop.index >= (state.edges || []).length ? playStop : null;
    pause();
    if (after) { window.cmuxUI.toast(format(S().debuggerHitAfterLastEdge, breakpointName(after.bp), timeText(after.time)), 'info'); }
  }

  function tick() {
    if (!state.playing || !state.edges) { return; }
    // The file was reloaded: its edges may differ, so play stops.
    if (host.currentBackend !== playBackend) { pause(); return; }
    const edges = state.edges;
    if (rtlStatus.wait) { waitingTick(edges); return; }
    let target = Math.min(edges.length - 1,
      playOrigin.index + Math.floor((performance.now() - playOrigin.at) * state.rate / 1000));
    // A breakpoint hit on the way (or skipped over by this tick): play stops there.
    const stop = playStop && playStop.index > playIndex && target >= playStop.index ? playStop : null;
    if (stop) { target = stop.index; }
    const left = edges[playIndex];
    playIndex = target;
    const time = markerTime();
    if (time === null || edges[target] !== time) {
      moveMarker(edges[target]);
      postMoved(edges[target], left, false);
    }
    if (stop) { pause(); announceHit(stop, edges); return; }
    if (target >= edges.length - 1) { playEnded(); return; }
    scheduleTick();
  }

  async function play(query) {
    if (query && query.rate) { setRate({ rate: query.rate }); }
    const edges = await start();
    if (!edges) { return publicState(); }
    const time = markerTime();
    let index = time === null ? 0 : Math.max(0, edgeIndexAt(edges, time));
    if (index >= edges.length - 1) { index = 0; }
    // Where play stops: the first breakpoint hit ahead (found before play starts, so a fast
    // first tick cannot pass it). A pause or another play meanwhile wins.
    const started = ++playStarts;
    const backend = host.currentBackend;
    playStopRequest++;
    // From before the first edge (or from the start again), a hit landing on edge 0 counts.
    const from = time === null || time < edges[0] || index !== Math.max(0, edgeIndexAt(edges, time)) ? null : edges[index];
    const found = breakpoints.some((b) => b.enabled) ? await findHit(edges, from, 1) : null;
    playStop = found && !found.loading ? found : null;
    if (started !== playStarts || host.currentBackend !== backend) { return publicState(); }
    if (playStop && playStop.index === index) {
      // The hit is where play starts: it stops there at once.
      moveMarker(edges[index]);
      const stop = playStop;
      playStop = null;
      announceHit(stop, edges);
      return Object.assign(publicState(), { hit: stop.bp.id });
    }
    playOrigin = { index, at: performance.now() };
    playIndex = index;
    rtlPending = null;
    lastMoveAt = performance.now();
    playBackend = host.currentBackend;
    if (!state.playing) { state.playing = true; render(); post('state'); }
    if (time === null || edges[index] !== time) { moveMarker(edges[index]); }
    scheduleTick();
    return publicState();
  }

  function pause() {
    clearTimeout(playTimer);
    playStarts++;
    playStopRequest++;
    playStop = null;
    if (!state.playing) { return publicState(); }
    state.playing = false;
    render();
    post('state');
    return publicState();
  }

  function togglePlay() { return state.playing ? pause() : play(); }

  function setRate(query) {
    const rate = Number((query || {}).rate);
    if (!(rate > 0)) { return publicState(); }
    const now = performance.now();
    if (state.playing && playOrigin && state.edges) {
      // Keep the cycle reached so far as the new origin.
      const reached = rtlStatus.wait ? playIndex : Math.min(state.edges.length - 1,
        playOrigin.index + Math.floor((now - playOrigin.at) * state.rate / 1000));
      playOrigin = { index: reached, at: now };
    }
    state.rate = Math.min(RATES[RATES.length - 1], Math.max(RATES[0], rate));
    render();
    post('state');
    if (state.playing) { scheduleTick(); }
    return publicState();
  }

  function changeRate(query) {
    const by = Math.sign(Number((query || {}).by) || 0);
    let i = RATES.findIndex((r) => r >= state.rate);
    if (i < 0) { i = RATES.length; }
    // Off the list (30): faster is the next one up (50), slower the next one down (20).
    const next = RATES[i] === state.rate ? i + by : (by > 0 ? i : i - 1);
    return setRate({ rate: RATES[Math.max(0, Math.min(RATES.length - 1, next))] });
  }

  // ---- clock choice ----
  async function setClock(query) {
    const path = (query || {}).path;
    const backend = host.currentBackend;
    const v = path ? await host.findLinkItem(path, true) : await defaultClock();
    if (path && (!v || Number(v.width) !== 1)) { return null; }
    state.clock = v;
    state.clockFor = backend;
    state.clockChosen = !!path;
    state.edges = null;
    state.edgesFor = null;
    await ensureEdges();
    render();
    post('state');
    return v ? host.pathOf(v) : null;
  }

  async function useSelectedAsClock() {
    const selected = waveform.link.selectedSignal();
    if (!selected) { return null; }
    const path = await setClock({ path: selected });
    if (!path) { window.cmuxUI.toast(S().debuggerClockNotBit || '', 'warning'); }
    return path;
  }

  function stop() {
    pause();
    lastHitId = null;
    renderBreakpoints();
    state.stepping = false;
    state.highlightRequest++;
    state.highlightIds = new Set();
    matchHighlightedRows();
    clearLocalsGroup();
    render();
    post('state');
    return publicState();
  }

  // ---- frame DOM: rows as VaporView drew them ----
  const frameDocument = () => iframe.contentDocument;

  function rowContext(element) {
    try {
      return JSON.parse((element.getAttribute('data-vscode-context') || '').replace(/%x20/g, ' '));
    } catch (error) {
      return null;
    }
  }

  // The top-level group rows VaporView drew.
  function topGroups() {
    const d = frameDocument();
    if (!d) { return []; }
    return Array.from(d.querySelectorAll('.waveform-label.waveform-group'))
      .filter((el) => !(el.parentElement && el.parentElement.closest('.waveform-group')));
  }

  const groupLabel = (el) => {
    const label = el.querySelector(':scope > .waveform-row p');
    return label ? label.textContent : null;
  };

  // The Locals group cmux made, by the id VaporView gave it (a group of the
  // user's with the same name is never touched). Null once it is gone.
  function localsElement() {
    if (state.locals.groupId === null) { return null; }
    const el = topGroups().find((g) => { const c = rowContext(g); return c && c.groupId === state.locals.groupId; });
    if (!el) { state.locals.groupId = null; state.locals.label = null; return null; }
    // The user may have renamed it.
    state.locals.label = groupLabel(el);
    return el;
  }

  // Sends `msg` to the viewer frame and lets it run now, without passing the
  // VaporView events it raises (selection changes) on to cmux.
  function dispatchQuietly(msg) {
    const frameWindow = iframe.contentWindow;
    if (!frameWindow) { return; }
    host.quietEvents++;
    try {
      frameWindow.dispatchEvent(new frameWindow.MessageEvent('message', { data: msg }));
    } finally {
      host.quietEvents--;
    }
  }

  // ---- Locals: the signals of the instance at the editor's caret ----
  const localsName = () => S().debuggerLocals || 'Locals';

  // Saved signal lists name groups but carry no ids: Locals is the top-level group with its label while it exists.
  host.isTransientGroup = (d) => !!d && d.dataType === 'signal-group' && localsElement() !== null
    && d.groupName === state.locals.label;

  // Where a row added next to the selection goes when the selection is in Locals: the end of the top level.
  host.topLevelIndexOutsideTransient = () => {
    const group = localsElement();
    if (!group || !group.querySelector('.labels-group .is-selected')) { return undefined; }
    const list = (host.viewerContext.webview && host.viewerContext.webview.displayedSignals) || [];
    return list.length;
  };

  function localsGroupSaved() {
    const list = (host.viewerContext.webview && host.viewerContext.webview.displayedSignals) || [];
    return list.find((d) => host.isTransientGroup(d)) || null;
  }

  // Removes the Locals rows one by one (by row id, never by netlist id, so
  // pinned rows of the same signals stay), then the group row if asked.
  // Returns whether the group was collapsed (it is expanded to reach its rows).
  function clearLocals(removeGroup) {
    let group = localsElement();
    if (!group) { return false; }
    const context = rowContext(group);
    if (!context) { return false; }
    const collapsed = group.classList.contains('collapsed-group');
    if (collapsed) {
      dispatchQuietly({ command: 'editSignalGroup', groupId: context.groupId, isExpanded: true });
      group = localsElement();
      if (!group) { return false; }
    }
    const children = Array.from(group.querySelectorAll(':scope > .labels-group > .waveform-label'))
      .map(rowContext).filter((c) => c && c.rowId !== undefined);
    for (const child of children) {
      dispatchQuietly({ command: 'remove-signal', rowId: child.rowId, removeAllSelected: false });
    }
    if (removeGroup) {
      dispatchQuietly({ command: 'remove-signal', rowId: context.rowId, removeAllSelected: false });
      state.locals.groupId = null;
      state.locals.label = null;
    }
    return collapsed;
  }

  function clearLocalsGroup() {
    state.locals.request++;
    state.locals.path = null;
    clearLocals(true);
  }

  function localsWanted(all) {
    const pinned = host.pinnedIds ? host.pinnedIds() : new Set();
    return all.filter((v) => !pinned.has(v.netlistId)).slice(0, MAX_LOCALS);
  }

  // Which of the scope's signals are shown outside Locals.
  function pinnedKey(all) {
    const pinned = host.pinnedIds ? host.pinnedIds() : new Set();
    return all.filter((v) => pinned.has(v.netlistId)).map((v) => v.netlistId).sort().join(',');
  }

  // A signal of the scope pinned or unpinned outside Locals leaves Locals or
  // comes back to it. Only then: a Locals row the user deleted stays deleted,
  // and a refill the viewer doesn't take as asked isn't retried.
  function refreshLocals() {
    if (!state.stepping || !state.locals.path || state.locals.busy || !state.locals.vars) { return; }
    if (!localsElement() || pinnedKey(state.locals.vars) === state.locals.pinnedKey) { return; }
    const key = state.locals.path;
    const request = ++state.locals.request;
    state.locals.busy = true;
    fillLocals(JSON.parse(key), key, request).catch(() => false)
      .finally(() => { if (request === state.locals.request) { state.locals.busy = false; } });
  }

  async function setLocals(query) {
    const path = (query || {}).path || null;
    const key = path ? JSON.stringify(path) : null;
    // The shown instance is where Evaluate and watches look names up.
    const scope = Array.isArray(path) ? path.map(String) : null;
    if (JSON.stringify(scope) !== JSON.stringify(evalScope)) { evalScope = scope; refreshWatches(); }
    if (!path) { clearLocalsGroup(); return true; }
    // Only while stepping; a reload or an undo that dropped the group gets it back on the next call.
    if (!state.stepping) { return false; }
    if (key === state.locals.path && localsElement()) { return true; }
    const request = ++state.locals.request;
    state.locals.busy = true;
    try {
      return await fillLocals(path, key, request);
    } finally {
      if (request === state.locals.request) { state.locals.busy = false; }
    }
  }

  async function fillLocals(path, key, request) {
    const scope = await host.findLinkItem(path, false);
    if (request !== state.locals.request) { return false; }
    if (!scope || scope.kind !== 'scope') { return false; }
    const all = (await host.getChildren(scope)).filter((c) => c.kind === 'var');
    if (request !== state.locals.request) { return false; }
    // A signal shown outside Locals (pinned) isn't shown in it too.
    state.locals.vars = all;
    state.locals.pinnedKey = pinnedKey(all);
    const vars = localsWanted(all);
    const w = host.viewerContext.webview;
    const selected = w && w.selectedSignal !== undefined && w.selectedSignal !== null ? w.selectedSignal : null;
    let collapsed = false;
    if (localsElement()) {
      collapsed = clearLocals(false);
    } else {
      const before = new Set(topGroups().map((g) => (rowContext(g) || {}).groupId));
      dispatchQuietly({ command: 'newSignalGroup', groupName: localsName(), groupPath: undefined, parentGroupId: undefined,
        eventRowId: undefined, moveSelected: false, showRenameInput: false });
      // VaporView renames it when the user has a group of that name already.
      const made = topGroups().find((g) => { const c = rowContext(g); return c && !before.has(c.groupId); });
      if (made) { state.locals.groupId = rowContext(made).groupId; state.locals.label = groupLabel(made); }
    }
    const group = localsElement();
    if (!group) { return false; }
    state.locals.path = key;
    if (vars.length) {
      dispatchQuietly({ command: 'add-variable', signalList: vars.map((v) => ({ signalId: v.signalId, signalWidth: v.width,
        signalName: v.name, scopePath: v.scopePath, netlistId: v.netlistId, type: v.type, encoding: v.encoding,
        enumType: v.enumType, msb: v.msb, lsb: v.lsb })), groupPath: [state.locals.label] });
      // Adding selects the new rows; give the user's selection back.
      if (selected !== null) { dispatchQuietly({ command: 'setSelectedSignal', netlistId: selected }); }
    }
    if (collapsed) { dispatchQuietly({ command: 'editSignalGroup', groupId: state.locals.groupId, isExpanded: false }); }
    matchHighlightedRows();
    return true;
  }

  // ---- highlighted rows: what the editor highlights this cycle ----
  let styleElement = null;
  let overlay = null;

  function ensureFrameStyle() {
    const d = frameDocument();
    if (!d || !d.head) { return null; }
    if (!styleElement || styleElement.ownerDocument !== d || !styleElement.isConnected) {
      styleElement = d.createElement('style');
      styleElement.id = 'cmux-debugger-style';
      d.head.appendChild(styleElement);
    }
    return styleElement;
  }

  async function highlightRows(query) {
    const paths = Array.isArray((query || {}).paths) ? query.paths.slice(0, 500) : [];
    const request = ++state.highlightRequest;
    const ids = new Set();
    for (const p of paths) {
      const v = await host.findLinkItem(p, true);
      // A newer call (or stop) came in meanwhile: it wins.
      if (request !== state.highlightRequest) { return state.highlighted.length; }
      if (v) { ids.add(v.netlistId); }
    }
    state.highlightIds = ids;
    return matchHighlightedRows();
  }

  // The rows showing the highlighted signals, again whenever rows come and go.
  function matchHighlightedRows() {
    const ids = state.highlightIds;
    const d = frameDocument();
    const rows = [];
    if (d && ids.size) {
      for (const el of d.querySelectorAll('.waveform-label')) {
        const c = rowContext(el);
        if (c && c.webviewSection === 'signal' && ids.has(c.netlistId) && Number.isInteger(c.rowId)) { rows.push(c.rowId); }
      }
    }
    state.highlighted = rows;
    const style = ensureFrameStyle();
    if (style) {
      style.textContent = rows.map((id) => `#label-${id} > .waveform-row, #value-${id}`).join(',\n')
        + (rows.length ? ' { background: rgba(255, 166, 0, 0.22) !important; box-shadow: inset 3px 0 0 rgb(255, 166, 0); }' : '')
        + '\n.cmux-debugger-transition { position: absolute; pointer-events: none; z-index: 5; box-sizing: border-box;'
        + ' border: 2px solid rgb(255, 166, 0); border-radius: 3px; }';
    }
    placeTransitions();
    return rows.length;
  }

  // A box around each highlighted row's waveform where the marker crosses it.
  function placeTransitions() {
    const d = frameDocument();
    if (!d) { return; }
    const scrollArea = d.getElementById('scrollArea');
    const markerLabel = d.getElementById('main-marker-label');
    if (!scrollArea) { return; }
    if (!overlay || overlay.ownerDocument !== d || !overlay.isConnected) {
      overlay = d.createElement('div');
      overlay.id = 'cmux-debugger-transitions';
      overlay.style.cssText = 'position: absolute; inset: 0; pointer-events: none; overflow: hidden; z-index: 5;';
      (scrollArea.parentElement || scrollArea).appendChild(overlay);
    }
    overlay.textContent = '';
    if (!state.highlighted.length || !markerLabel || markerTime() === null) { return; }
    const parentRect = overlay.getBoundingClientRect();
    const areaRect = scrollArea.getBoundingClientRect();
    const x = areaRect.left + (parseFloat(markerLabel.style.left) || 0) - parentRect.left;
    if (x < areaRect.left - parentRect.left || x > areaRect.right - parentRect.left) { return; }
    for (const id of state.highlighted) {
      const row = d.querySelector(`#label-${id} > .waveform-row`);
      if (!row) { continue; }
      const r = row.getBoundingClientRect();
      if (r.bottom < areaRect.top || r.top > areaRect.bottom || r.height === 0) { continue; }
      const box = d.createElement('div');
      box.className = 'cmux-debugger-transition';
      box.style.left = (x - 6) + 'px';
      box.style.top = (r.top - parentRect.top + 1) + 'px';
      box.style.width = '12px';
      box.style.height = Math.max(4, r.height - 2) + 'px';
      overlay.appendChild(box);
    }
  }

  let placeQueued = false;
  function queuePlace() {
    if (placeQueued || !state.highlighted.length) { return; }
    placeQueued = true;
    requestAnimationFrame(() => { placeQueued = false; placeTransitions(); });
  }

  iframe.addEventListener('load', () => {
    styleElement = null;
    overlay = null;
    const d = frameDocument();
    if (!d) { return; }
    d.addEventListener('scroll', queuePlace, true);
    d.addEventListener('wheel', queuePlace, { capture: true, passive: true });
    iframe.contentWindow.addEventListener('resize', queuePlace);
    // A group folded or unfolded by message sends no context update: its rows came or went.
    iframe.contentWindow.addEventListener('message', (e) => {
      const m = e.data;
      if (m && m.command === 'editSignalGroup' && m.isExpanded !== undefined && state.highlightIds.size) {
        setTimeout(matchHighlightedRows, 0);
      }
    });
  });

  // ---- breakpoints: break when a dump signal changes or equals a value ----
  // A hit at change time t lands on the first posedge at or after t, where the new value is
  // sampled (a registered change lands on its own posedge). Continue goes to the nearest hit
  // landing after the marker, reverse continue to the nearest landing before it, so each always
  // moves. Signals' changes come from host.signalChanges (what the viewer was given when shown).
  const MAX_BREAKPOINT_CHANGES = 1000000;
  const MAX_LINE_PATHS = 64;
  // { id, path, kind: 'change' | 'equals', value, pattern, enabled, times, timesFor }, and the
  // line breakpoints cmux sets (setLineBreakpoints): { id, kind: 'line', key, label, paths, ... }.
  const breakpoints = [];
  let nextBreakpointId = 1;
  // Text breakpoints (cmux-debugger-text.js): { id, kind: 'text', path, format, pattern, caseSensitive,
  // anyRegisterNames, enabled, times, timesFor, condition }; at most this many enabled.
  const TB = waveform.debuggerText;
  const MAX_TEXT_BREAKPOINTS = 32;
  const signalKind = (k) => (k === 'equals' || k === 'change' || (k === 'text' && TB) ? k : null);
  const textFields = (q) => ({ format: String(q.format || 'hexadecimal'), pattern: String(q.pattern || ''),
    caseSensitive: !!q.caseSensitive, anyRegisterNames: q.anyRegisterNames !== false });
  const enabledTexts = () => breakpoints.filter((b) => b.kind === 'text' && b.enabled).length;
  // Commit breakpoints (cmux-debugger-commits.js): { id, kind: 'pc' | 'commitText' | 'write', pcs, channel,
  // key (a listing's, which cmux owns), pattern, caseSensitive, anyRegisterNames, loc, enabled, condition }; no path.
  const CB = waveform.debuggerCommits;
  const isCommit = (b) => !!(CB && CB.isKind(b.kind));
  const MAX_COMMIT_BREAKPOINTS = { pc: 1024, commitText: 32, write: 256 };
  const enabledOfKind = (kind) => breakpoints.filter((b) => b.kind === kind && b.enabled).length;
  const commitFields = (kind, q) => {
    const f = CB.fields(kind, q);
    return kind === 'pc' ? { pcs: f.pcs, channel: f.channel } : kind === 'write' ? { loc: f.loc }
      : { pattern: f.pattern, caseSensitive: f.caseSensitive, anyRegisterNames: f.anyRegisterNames };
  };
  const pathsOf = (b) => (b.kind === 'line' ? b.paths : b.path ? [b.path] : []);
  let lastHitId = null;
  let lastHitBackend = null;  // a reload clears the hit mark
  let continueRequest = 0;
  const changeCache = new Map();  // JSON path -> { backend, changes } (null changes: past the cap)

  // An SV-style value as one character per bit, most significant first ('0', '1', 'x', 'z'
  // or '?' for any bit), `width` bits; null when it is not a value or does not fit.
  function parseValue(text, width) {
    const s = String(text || '').trim().toLowerCase().replace(/_/g, '');
    let bits;
    const sized = /^(\d*)'(s?)([bodh])([0-9a-fxz?]+)$/.exec(s);
    if (/^[xz?]$/.test(s)) {
      bits = s;
    } else if (/^\d+$/.test(s)) {
      bits = BigInt(s).toString(2);
    } else if (sized) {
      const [, size, , base, digits] = sized;
      if (base === 'd') {
        // A single x, z or ? decimal digit is allowed (4'dx).
        if (/^[xz?]$/.test(digits)) { bits = digits; } else if (!/^\d+$/.test(digits)) { return null; } else { bits = BigInt(digits).toString(2); }
      } else {
        const per = base === 'b' ? 1 : (base === 'o' ? 3 : 4);
        bits = '';
        for (const c of digits) {
          if ('xz?'.includes(c)) { bits += c.repeat(per); continue; }
          const n = parseInt(c, 16);
          if (!(n < (1 << per))) { return null; }
          bits += n.toString(2).padStart(per, '0');
        }
      }
      if (size) {
        const n = Number(size);
        if (!(n > 0)) { return null; }
        bits = fitBits(bits, n);
        if (bits === null) { return null; }
        // A sized value's x/z extension stops at its size; widening it is zero-extension (unsigned).
        if (n < width) { bits = '0'.repeat(width - n) + bits; }
      }
    } else {
      return null;
    }
    return fitBits(bits, width);
  }

  // Extends (by the top bit when it is x, z or ?, else 0) or cuts to `width` bits; null when
  // what is cut is not all zeros (or all the same x, z or ?).
  function fitBits(bits, width) {
    if (bits.length <= width) {
      const pad = 'xz?'.includes(bits[0]) ? bits[0] : '0';
      return pad.repeat(width - bits.length) + bits;
    }
    const cut = bits.slice(0, bits.length - width);
    const kept = bits.slice(bits.length - width);
    if (/^0*$/.test(cut) || ('xz?'.includes(kept[0]) && cut.split('').every((c) => c === kept[0]))) { return kept; }
    return null;
  }

  function valueBits(value, width) {
    const s = String(value).toLowerCase();
    if (s.length >= width) { return s.slice(s.length - width); }
    const pad = s[0] === 'x' || s[0] === 'z' ? s[0] : '0';
    return pad.repeat(width - s.length) + s;
  }

  function matches(bits, pattern) {
    for (let i = 0; i < pattern.length; i++) {
      if (pattern[i] !== '?' && pattern[i] !== bits[i]) { return false; }
    }
    return true;
  }

  const baseName = (bp) => (bp.kind === 'line' ? bp.label : bp.kind === 'text' ? TB.label(bp) : isCommit(bp) ? CB.label(bp) : (bp.kind === 'equals'
    ? format(S().debuggerBreakpointEquals, bp.path.join('.'), bp.value)
    : format(S().debuggerBreakpointChanges, bp.path.join('.'))));
  const breakpointName = (bp) => (bp.condition ? format(S().debuggerBreakpointIf, baseName(bp), bp.condition) : baseName(bp));

  const isLastHit = (bp) => bp.id === lastHitId && lastHitBackend === host.currentBackend;
  const publicBreakpoint = (bp) => ({ id: bp.id, kind: bp.kind, enabled: bp.enabled, hit: isLastHit(bp), label: breakpointName(bp),
    path: bp.path ? bp.path.slice() : null, value: bp.kind === 'equals' ? bp.value : null,
    format: bp.kind === 'text' ? bp.format : null, pattern: bp.kind === 'text' || bp.kind === 'commitText' ? bp.pattern : null,
    caseSensitive: bp.kind === 'text' || bp.kind === 'commitText' ? bp.caseSensitive : null,
    anyRegisterNames: bp.kind === 'text' || bp.kind === 'commitText' ? bp.anyRegisterNames : null,
    pcs: bp.kind === 'pc' ? bp.pcs.slice() : null, channel: bp.kind === 'pc' ? bp.channel : null, loc: bp.kind === 'write' ? bp.loc : null,
    key: bp.kind === 'line' || bp.kind === 'pc' ? bp.key || null : null, paths: bp.kind === 'line' ? bp.paths.map((p) => p.slice()) : null,
    condition: bp.condition || null, conditionError: bp.conditionError || null,
    // The paths a line's search reads (its units' with a condition).
    searchedPaths: bp.kind === 'line' ? (bp.condition && bp.units ? bp.units : [bp]).reduce((n, u) => n + u.paths.length, 0) : null });

  // A condition as given: trimmed, '' for none; { error, at, message } when it does not parse.
  function checkCondition(text) {
    const condition = String(text === undefined || text === null ? '' : text).trim();
    if (!condition) { return { condition: '' }; }
    const parsed = X.parse(condition);
    if (parsed.error) { return { error: parsed.error, at: parsed.at, message: exprMessage(parsed.error, parsed.at) }; }
    return { condition };
  }

  // A breakpoint's warnings (signal gone, too many changes, a bad value) are said once each.
  function warnOnce(bp, text) {
    bp.warned = bp.warned || new Set();
    if (bp.warned.has(text)) { return; }
    bp.warned.add(text);
    window.cmuxUI.toast(text, 'warning');
  }

  // A condition that does not parse is kept (and shown as an error): the breakpoint never hits
  // until it is fixed, and why is said once per breakpoint and text.
  const conditionErrorsSaid = new Set();
  function conditionOf(bp, raw, name) {
    const checked = checkCondition(raw);
    bp.condition = checked.error ? String(raw).trim() : (checked.condition || null);
    bp.conditionError = checked.error ? checked.message : null;
    const said = (bp.key || (bp.path ? JSON.stringify(bp.path) : name)) + '\u0000' + bp.condition;
    if (checked.error && !conditionErrorsSaid.has(said)) {
      conditionErrorsSaid.add(said);
      window.cmuxUI.toast(format(S().debuggerConditionError, name, checked.message), 'warning');
    }
  }

  // cmux owns line breakpoints: the list's checkbox and remove button tell it.
  const toldLine = (bp, extra) => host.toNative(Object.assign({ type: 'debugger', event: 'lineBreakpoint', key: bp.key,
    enabled: bp.enabled, removed: false }, extra || {}));
  // And a listing's PC breakpoints (cmux-debugger-commits.js; keyed by the listing's mark).
  const toldPc = (bp, extra) => host.toNative(Object.assign({ type: 'debugger', event: 'pcBreakpoint', key: bp.key,
    enabled: bp.enabled, removed: false }, extra || {}));
  const told = (bp, extra) => { if (bp.kind === 'line') { toldLine(bp, extra); } else if (bp.kind === 'pc' && bp.key) { toldPc(bp, extra); } };

  // The signal breakpoints of a restored session (cmux), in place of the page's; checked when
  // searched, since the file may not be open yet.
  function restoreBreakpoints(query) {
    const items = Array.isArray((query || {}).items) ? query.items : [];
    const listingOwned = (b) => b.kind === 'line' || (b.kind === 'pc' && b.key);
    for (let i = breakpoints.length - 1; i >= 0; i--) { if (!listingOwned(breakpoints[i])) { breakpoints.splice(i, 1); } }
    const restored = [];
    for (const item of items) {
      if (CB && CB.isKind(item.kind)) {
        const bp = Object.assign({ id: nextBreakpointId++, kind: item.kind, key: null, value: null, enabled: item.enabled !== false,
          times: null, timesFor: null, condition: null, conditionError: null }, commitFields(item.kind, item));
        if (CB.check(bp.kind, bp)) { continue; }
        if (bp.enabled && restored.filter((b) => b.kind === bp.kind && b.enabled).length >= MAX_COMMIT_BREAKPOINTS[bp.kind]) { bp.enabled = false; }
        conditionOf(bp, item.condition, baseName(bp));
        restored.push(bp);
        continue;
      }
      const path = Array.isArray(item.path) ? item.path.map(String) : null;
      const kind = signalKind(item.kind);
      if (!path || !path.length || !kind) { continue; }
      const bp = { id: nextBreakpointId++, path, kind, value: kind === 'equals' ? String(item.value || '') : null,
        pattern: null, enabled: item.enabled !== false, times: null, timesFor: null, condition: null, conditionError: null };
      if (kind === 'text') {
        Object.assign(bp, textFields(item));
        // Past the cap: kept, but off.
        if (bp.enabled && restored.filter((b) => b.kind === 'text' && b.enabled).length >= MAX_TEXT_BREAKPOINTS) { bp.enabled = false; }
      }
      conditionOf(bp, item.condition, baseName(bp));
      restored.push(bp);
    }
    breakpoints.unshift(...restored);
    if (lastHitId !== null && !breakpoints.some((b) => b.id === lastHitId)) { lastHitId = null; }
    breakpointsChanged();
    return restored.map(publicBreakpoint);
  }

  // At most `limit` of the lists' items, taken from each list in turn (each keeps its order).
  function capAcross(lists, limit) {
    const out = lists.map(() => []);
    let left = limit;
    for (let k = 0; left > 0 && lists.some((l) => l.length > k); k++) {
      lists.forEach((list, i) => { if (left > 0 && k < list.length) { out[i].push(list[k]); left--; } });
    }
    return out;
  }

  // The editors' line breakpoints (cmux): replaces the page's, keeps the signal breakpoints.
  function setLineBreakpoints(query) {
    const items = Array.isArray((query || {}).items) ? query.items : [];
    const old = new Map(breakpoints.filter((b) => b.kind === 'line').map((b) => [b.key, b]));
    for (let i = breakpoints.length - 1; i >= 0; i--) { if (breakpoints[i].kind === 'line') { breakpoints.splice(i, 1); } }
    const lines = [];
    for (const item of items) {
      const key = String(item.key || '');
      if (!key || lines.some((b) => b.key === key)) { continue; }
      const allPaths = (Array.isArray(item.paths) ? item.paths : []).filter(Array.isArray).map((p) => p.map(String));
      const groups = (Array.isArray(item.groups) ? item.groups : []).filter((g) => g && Array.isArray(g.paths) && Array.isArray(g.scope))
        .map((g) => ({ scope: g.scope.map(String), paths: g.paths.filter(Array.isArray).map((p) => p.map(String)) }));
      // Each path may hold up to 1M changes while its times are built: a line watches at most 64,
      // in all its instances together (taken from each in turn, so every instance is watched).
      const capped = groups.length > 1 ? capAcross(groups.map((g) => g.paths), MAX_LINE_PATHS) : null;
      const paths = capped ? capped.flat() : allPaths.slice(0, MAX_LINE_PATHS);
      const total = groups.length > 1 ? groups.reduce((n, g) => n + g.paths.length, 0) : allPaths.length;
      const before = old.get(key);
      const same = before && JSON.stringify(before.paths) === JSON.stringify(paths);
      const scope = Array.isArray(item.scope) ? item.scope.map(String) : null;
      const bp = { id: before ? before.id : nextBreakpointId++, kind: 'line', key, label: String(item.label || key), paths,
        enabled: item.enabled !== false, times: same ? before.times : null, timesFor: same ? before.timesFor : null,
        condition: null, conditionError: null, scope, pathsTotal: total, warned: before ? before.warned : undefined,
        // Why it has no paths, when cmux knows: the line watches nothing, or its file is too large to scan.
        unwatched: item.unwatched === 'nothing' || item.unwatched === 'tooLarge' ? item.unwatched : null };
      conditionOf(bp, item.condition, bp.label);
      // Break in any instance with a condition: each instance's changes are tested in its own scope.
      bp.warned = bp.warned || new Set();
      bp.units = groups.length > 1 ? groups.map((g, i) => {
        const unitPaths = capped[i];
        const was = same && before.units && before.units[i];
        const keep = was && JSON.stringify(was.paths) === JSON.stringify(unitPaths);
        return { kind: 'line', key, label: bp.label, paths: unitPaths, scope: g.scope.map(String), condition: bp.condition,
          conditionError: bp.conditionError, enabled: true, warned: bp.warned, times: keep ? was.times : null, timesFor: keep ? was.timesFor : null };
      }) : null;
      // cmux draws a line whose condition does not parse as an error.
      // (Also a new bad text: cmux forgets the error when it changes the condition.)
      if (!!bp.conditionError !== !!(before && before.conditionError) || (bp.conditionError && (!before || before.condition !== bp.condition))) {
        host.toNative({ type: 'debugger', event: 'lineBreakpoint', key: bp.key, conditionError: !!bp.conditionError });
      }
      lines.push(bp);
    }
    if (lastHitId !== null && !breakpoints.some((b) => b.id === lastHitId) && !lines.some((b) => b.id === lastHitId)) { lastHitId = null; }
    breakpoints.push(...lines);
    breakpointsChanged();
    return lines.map(publicBreakpoint);
  }

  // A listing's PC breakpoints (cmux, WaveformDebuggerAsmBreakpoints.swift): replace cmux's, keep the page's.
  // items: [{ key, listingLabel, pcs, channel?, enabled, condition? }]
  // Whether cmux has a listing for this dump (an open one, or one beside the dump): rows then offer
  // Show Value as Address in Listing.
  let listingAvailable = false;
  const refusedMarks = new Set();  // key + pcs of marks refused (said once)

  function setPcBreakpoints(query) {
    listingAvailable = !!(query || {}).listing;
    if (!CB) { return []; }
    const items = Array.isArray((query || {}).items) ? query.items : [];
    const old = new Map(breakpoints.filter((b) => b.kind === 'pc' && b.key).map((b) => [b.key, b]));
    for (let i = breakpoints.length - 1; i >= 0; i--) { if (breakpoints[i].kind === 'pc' && breakpoints[i].key) { breakpoints.splice(i, 1); } }
    const marks = [];
    for (const item of items) {
      const key = String(item.key || '');
      const fields = commitFields('pc', item);
      const error = CB.check('pc', fields);
      // A mark cmux can't search (a PC from 2^53 up): said once, not placed.
      if (key && error === 'addressTooLarge' && !refusedMarks.has(key + '\u0000' + fields.pcs.join())) {
        refusedMarks.add(key + '\u0000' + fields.pcs.join());
        const name = CB.label(Object.assign({ kind: 'pc', listingLabel: String(item.listingLabel || key) }, fields));
        window.cmuxUI.toast(format(S().debuggerCommitError, name, CB.errorText(error)), 'warning');
      }
      if (!key || marks.some((b) => b.key === key) || error) { continue; }
      const before = old.get(key);
      const bp = Object.assign({ id: before ? before.id : nextBreakpointId++, kind: 'pc', key, listingLabel: String(item.listingLabel || key),
        value: null, enabled: item.enabled !== false, times: null, timesFor: null, condition: null, conditionError: null,
        warned: before ? before.warned : undefined }, fields);
      conditionOf(bp, item.condition, baseName(bp));
      if (!!bp.conditionError !== !!(before && before.conditionError) || (bp.conditionError && (!before || before.condition !== bp.condition))) {
        host.toNative({ type: 'debugger', event: 'pcBreakpoint', key, conditionError: !!bp.conditionError });
      }
      marks.push(bp);
    }
    if (lastHitId !== null && !breakpoints.some((b) => b.id === lastHitId) && !marks.some((b) => b.id === lastHitId)) { lastHitId = null; }
    breakpoints.push(...marks);
    breakpointsChanged();
    return marks.map(publicBreakpoint);
  }

  const signalOf = async (path) => (await host.findLinkItem(path, true)) || null;

  async function addBreakpoint(query) {
    const q = query || {};
    if (CB && CB.isKind(q.kind)) { return addCommitBreakpoint(q); }
    const path = Array.isArray(q.path) ? q.path.map(String) : null;
    const kind = signalKind(q.kind);
    if (!path || !path.length || !kind) { return null; }
    const v = await signalOf(path);
    if (!v) {
      window.cmuxUI.toast(format(S().debuggerBreakpointSignalGone, path.join('.')), 'warning');
      return null;
    }
    const value = kind === 'equals' ? String(q.value || '').trim() : null;
    const pattern = kind === 'equals' ? parseValue(value, Number(v.width) || 1) : null;
    if (kind === 'equals' && !pattern) {
      window.cmuxUI.toast(format(S().debuggerBadValue, value, number(Number(v.width) || 1)), 'warning');
      return null;
    }
    const checked = checkCondition(q.condition);
    if (checked.error) {
      window.cmuxUI.toast(format(S().debuggerConditionError, path.join('.'), checked.message), 'warning');
      return null;
    }
    const condition = checked.condition || null;
    if (kind === 'text') { return addTextBreakpoint(path, q, condition); }
    const width = Number(v.width) || 1;
    const same = breakpoints.find((b) => b.kind === kind && JSON.stringify(b.path) === JSON.stringify(path)
      && (kind !== 'equals' || parseValue(b.value, width) === pattern) && (b.condition || null) === condition);
    if (same) {
      same.enabled = true;
      breakpointsChanged();
      return publicBreakpoint(same);
    }
    const bp = { id: nextBreakpointId++, path, kind, value, pattern, enabled: true, times: null, timesFor: null, condition };
    breakpoints.push(bp);
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  // A text breakpoint (Break When Text Matches…): checked, the same one enabled again.
  function addTextBreakpoint(path, q, condition) {
    const fields = textFields(q);
    const checked = TB.spec(fields);
    if (checked.error) {
      window.cmuxUI.toast(format(S().debuggerTextError, TB.label(Object.assign({ path }, fields)), TB.errorText(checked.error)), 'warning');
      return null;
    }
    const same = breakpoints.find((b) => b.kind === 'text' && JSON.stringify(b.path) === JSON.stringify(path) && b.format === fields.format
      && b.pattern === fields.pattern && b.caseSensitive === fields.caseSensitive && b.anyRegisterNames === fields.anyRegisterNames
      && (b.condition || null) === condition);
    if (!(same && same.enabled) && enabledTexts() >= MAX_TEXT_BREAKPOINTS) {
      window.cmuxUI.toast(format(S().debuggerTextTooMany, number(MAX_TEXT_BREAKPOINTS)), 'warning');
      return null;
    }
    if (same) {
      same.enabled = true;
      breakpointsChanged();
      return publicBreakpoint(same);
    }
    const bp = Object.assign({ id: nextBreakpointId++, path, kind: 'text', value: null, enabled: true, times: null, timesFor: null, condition }, fields);
    breakpoints.push(bp);
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  // A commit breakpoint (Break at Address…, Break When Next Instruction Matches…, Break When Written…):
  // checked, the same one enabled again.
  function addCommitBreakpoint(q) {
    const kind = q.kind;
    const fields = commitFields(kind, q);
    const error = CB.check(kind, fields);
    const checked = checkCondition(q.condition);
    // Refused: named as it was given.
    const given = error === 'address' || error === 'addressTooLarge' ? { pcs: [].concat(q.pcs ?? q.pc ?? []).map(String) } : error === 'location' ? { loc: String(q.loc ?? '') } : {};
    const name = CB.label(Object.assign({ kind }, fields, given));
    if (error) {
      window.cmuxUI.toast(format(S().debuggerCommitError, name, CB.errorText(error)), 'warning');
      return null;
    }
    if (checked.error) {
      window.cmuxUI.toast(format(S().debuggerConditionError, name, checked.message), 'warning');
      return null;
    }
    const condition = checked.condition || null;
    const same = breakpoints.find((b) => b.kind === kind && !b.key && JSON.stringify(commitFields(kind, b)) === JSON.stringify(fields)
      && (b.condition || null) === condition);
    if (!(same && same.enabled) && enabledOfKind(kind) >= MAX_COMMIT_BREAKPOINTS[kind]) {
      window.cmuxUI.toast(format(S().debuggerCommitTooMany, number(MAX_COMMIT_BREAKPOINTS[kind])), 'warning');
      return null;
    }
    if (same) {
      same.enabled = true;
      breakpointsChanged();
      return publicBreakpoint(same);
    }
    const bp = Object.assign({ id: nextBreakpointId++, kind, key: null, value: null, enabled: true, times: null, timesFor: null,
      condition, conditionError: null }, fields);
    breakpoints.push(bp);
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  // setCommitBreakpoint({ id, pattern?, caseSensitive?, anyRegisterNames?, loc?, pcs? }): a commit
  // breakpoint's fields changed (its list menu); one that does not check is refused (said, the old kept).
  function setCommitBreakpoint(query) {
    const q = query || {};
    const bp = breakpoints.find((b) => b.id === Number(q.id) && isCommit(b) && !b.key);
    if (!bp) { return null; }
    const fields = commitFields(bp.kind, Object.assign({}, bp, Object.fromEntries(Object.entries(q).filter(([k, v]) => v !== undefined && k !== 'id'))));
    const error = CB.check(bp.kind, fields);
    if (error) {
      window.cmuxUI.toast(format(S().debuggerCommitError, CB.label(Object.assign({ kind: bp.kind }, fields)), CB.errorText(error)), 'warning');
      return null;
    }
    Object.assign(bp, fields, { warned: null });
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  // The three ways to add one, as prompts (the list's and View > Waveform Debugger's Add Instruction Breakpoint…).
  async function promptCommitBreakpoint(query) {
    const s = S();
    const kind = (query || {}).kind;
    const prompts = {
      pc: { title: s.debuggerAddressPrompt, placeholder: s.debuggerAddressPlaceholder },
      commitText: { title: s.debuggerCommitTextPrompt, placeholder: s.debuggerTextPlaceholder },
      write: { title: s.debuggerWrittenPrompt, placeholder: s.debuggerWrittenPlaceholder },
    };
    if (!CB || !prompts[kind]) { return null; }
    try {
      const text = await window.cmuxUI.prompt({ title: prompts[kind].title || '', placeholder: prompts[kind].placeholder || '' });
      if (text === undefined || !String(text).trim().length) { return null; }
      const value = String(text);
      if (kind === 'pc') {
        const pcs = value.split(/[\s,]+/).filter(Boolean);
        return addBreakpoint({ kind, pcs: pcs.map((p) => CB.parseAddress(p) || p) });
      }
      if (kind === 'write') { return addBreakpoint({ kind, loc: CB.parseLocation(value) || value }); }
      return addBreakpoint({ kind, pattern: value });
    } catch (error) {
      host.log(error);
      return null;
    }
  }

  const commitMenuItems = () => {
    const s = S();
    return [
      { label: s.debuggerBreakAtAddress || '', run: () => promptCommitBreakpoint({ kind: 'pc' }) },
      { label: s.debuggerBreakOnCommitText || '', run: () => promptCommitBreakpoint({ kind: 'commitText' }) },
      { label: s.debuggerBreakWhenWritten || '', run: () => promptCommitBreakpoint({ kind: 'write' }) },
    ];
  };
  // View > Waveform Debugger > Add Instruction Breakpoint…: the three, as a menu in the viewer.
  function chooseCommitBreakpoint(query) {
    if (!CB) { return false; }
    const q = query || {};
    const x = Number.isFinite(q.x) ? q.x : Math.round(window.innerWidth / 2);
    const y = Number.isFinite(q.y) ? q.y : Math.round(window.innerHeight / 3);
    window.cmuxUI.showMenu(commitMenuItems(), x, y);
    return true;
  }

  // setTextBreakpoint({ id, pattern?, caseSensitive?, anyRegisterNames?, format? }): a text breakpoint's
  // fields changed (its list menu); one that does not check is refused (said, the old kept).
  function setTextBreakpoint(query) {
    const q = query || {};
    const bp = breakpoints.find((b) => b.id === Number(q.id) && b.kind === 'text');
    if (!bp) { return null; }
    const fields = textFields(Object.assign({}, bp, Object.fromEntries(Object.entries(q).filter(([k, v]) => v !== undefined && k !== 'id'))));
    const checked = TB.spec(fields);
    if (checked.error) {
      window.cmuxUI.toast(format(S().debuggerTextError, TB.label(Object.assign({ path: bp.path }, fields)), TB.errorText(checked.error)), 'warning');
      return null;
    }
    Object.assign(bp, fields, { times: null, timesFor: null, warned: null });
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  function removeBreakpoint(query) {
    const i = breakpoints.findIndex((b) => b.id === Number((query || {}).id));
    if (i < 0) { return false; }
    const [bp] = breakpoints.splice(i, 1);
    if (bp.id === lastHitId) { lastHitId = null; }
    told(bp, { removed: true });
    breakpointsChanged();
    return true;
  }

  function setBreakpointEnabled(query) {
    const q = query || {};
    const bp = breakpoints.find((b) => b.id === Number(q.id));
    if (!bp) { return false; }
    if (isCommit(bp) && q.enabled && !bp.enabled && enabledOfKind(bp.kind) >= MAX_COMMIT_BREAKPOINTS[bp.kind]) {
      window.cmuxUI.toast(format(S().debuggerCommitTooMany, number(MAX_COMMIT_BREAKPOINTS[bp.kind])), 'warning');
      return false;
    }
    if (bp.kind === 'text' && q.enabled && !bp.enabled && enabledTexts() >= MAX_TEXT_BREAKPOINTS) {
      window.cmuxUI.toast(format(S().debuggerTextTooMany, number(MAX_TEXT_BREAKPOINTS)), 'warning');
      return false;
    }
    bp.enabled = !!q.enabled;
    told(bp);
    breakpointsChanged();
    return true;
  }

  // setBreakpointCondition({ id, condition }): '' clears it; one that does not parse is refused
  // (said, and the old one kept). Line breakpoints' conditions are cmux's (it is told).
  function setBreakpointCondition(query) {
    const q = query || {};
    const bp = breakpoints.find((b) => b.id === Number(q.id));
    if (!bp) { return null; }
    const checked = checkCondition(q.condition);
    if (checked.error) {
      window.cmuxUI.toast(format(S().debuggerConditionError, baseName(bp), checked.message), 'warning');
      return { error: checked.error, at: checked.at, message: checked.message };
    }
    bp.condition = checked.condition || null;
    bp.conditionError = null;
    if (bp.units) { for (const u of bp.units) { u.condition = bp.condition; u.conditionError = null; } }
    bp.warned = null;
    told(bp, { condition: bp.condition });
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  function breakpointsChanged() {
    // Changes no breakpoint watches any more are let go (each may hold up to 1M).
    const watched = new Set();
    // A disabled one's are let go too (read again when it is enabled).
    for (const b of breakpoints.filter((x) => x.enabled)) { for (const path of pathsOf(b)) { watched.add(JSON.stringify(path)); } }
    for (const key of Array.from(changeCache.keys())) { if (!watched.has(key)) { changeCache.delete(key); } }
    // cmux keeps the signal breakpoints for the workspace's session (restoreBreakpoints).
    host.toNative({ type: 'debugger', event: 'breakpoints', items: breakpoints.filter((b) => b.kind !== 'line' && !(b.kind === 'pc' && b.key))
      .map((b) => Object.assign({ path: b.path ? b.path.slice() : [], kind: b.kind, value: b.kind === 'equals' ? b.value : null, enabled: b.enabled,
        condition: b.condition || null }, b.kind === 'text' ? textFields(b) : isCommit(b) ? commitFields(b.kind, b) : {})) });
    renderBreakpoints();
    // Play does not stop on a breakpoint just disabled or removed while the next one is searched.
    if (playStop && (!playStop.bp.enabled || !breakpoints.includes(playStop.bp))) { playStop = null; }
    if (state.playing) { refreshPlayStop(); }
  }

  // A condition's signals' changes (it reads values at each landing): a small cache of its own,
  // the most recently used kept (each may hold up to 1M changes).
  const conditionCache = new Map();
  const MAX_CONDITION_SIGNALS = 16;
  // And at most this many changes in all (one signal may hold MAX_BREAKPOINT_CHANGES).
  const MAX_CONDITION_CHANGES = 2000000;
  let maxConditionChanges = MAX_CONDITION_CHANGES;
  const cachedChanges = () => { let n = 0; for (const e of conditionCache.values()) { n += e.changes ? e.changes.length : 0; } return n; };
  async function conditionChangesOf(path, backend) {
    for (const [key, entry] of conditionCache) { if (entry.backend !== backend) { conditionCache.delete(key); } }
    const key = JSON.stringify(path);
    const cached = conditionCache.get(key);
    if (cached) { conditionCache.delete(key); conditionCache.set(key, cached); return cached; }
    const v = await signalOf(path);
    if (!v) { return null; }
    const changes = await host.signalChanges(v, MAX_BREAKPOINT_CHANGES);
    if (changes === undefined) { return { backend, changes: undefined, width: Number(v.width) || 1 }; }
    const entry = { backend, changes: changes && changes.length <= MAX_BREAKPOINT_CHANGES ? changes : null, width: Number(v.width) || 1 };
    if (host.currentBackend === backend) {
      conditionCache.set(key, entry);
      while (conditionCache.size > MAX_CONDITION_SIGNALS || (conditionCache.size > 1 && cachedChanges() > maxConditionChanges)) {
        conditionCache.delete(conditionCache.keys().next().value);
      }
    }
    return entry;
  }

  // A signal's changes for the current backend ({ changes, width }; changes null past the cap),
  // or null when it is not in the file.
  async function changesOf(path, backend) {
    for (const [key, entry] of changeCache) { if (entry.backend !== backend) { changeCache.delete(key); } }
    const key = JSON.stringify(path);
    const cached = changeCache.get(key);
    if (cached) { return cached; }
    const v = await signalOf(path);
    if (!v) { return null; }
    const changes = await host.signalChanges(v, MAX_BREAKPOINT_CHANGES);
    // Undefined: not read yet, so not kept (null, or more than the cap: too many, kept).
    if (changes === undefined) { return { backend, changes: undefined, width: Number(v.width) || 1 }; }
    const entry = { backend, changes: changes && changes.length <= MAX_BREAKPOINT_CHANGES ? changes : null, width: Number(v.width) || 1 };
    if (host.currentBackend === backend) { changeCache.set(key, entry); }
    return entry;
  }

  // A breakpoint has its times: the raw changes of its paths are let go, unless another
  // breakpoint still has to build its times from them.
  function releaseChanges(paths, bp, backend) {
    for (const path of paths) {
      const key = JSON.stringify(path);
      const wants = (b) => b !== bp && b.timesFor !== backend && pathsOf(b).some((p) => JSON.stringify(p) === key);
      // A line searched per instance builds its times per instance (its units), not as a whole.
      const needed = breakpoints.some((b) => b.enabled && (b.condition && b.units ? b.units.some(wants) : wants(b)));
      if (!needed) { changeCache.delete(key); }
    }
  }

  // The times `changes` hits a change (or equals, with `pattern`) breakpoint at.
  function timesOf(entry, kind, pattern) {
    const out = [];
    let previous = null;
    let previousMatched = false;
    entry.changes.forEach(([time, value], i) => {
      const bits = valueBits(value, entry.width);
      if (kind !== 'equals') {
        if (i > 0 && bits !== previous) { out.push(Number(time)); }
      } else {
        const now = matches(bits, pattern);
        if (now && (i === 0 || !previousMatched)) { out.push(Number(time)); }
        previousMatched = now;
      }
      previous = bits;
    });
    return out;
  }

  // The times a breakpoint hits at (ascending), for the current backend; null when its signal
  // is gone or changes too often, saying so. A line hits when any of its signals changes (those
  // not in the file are left out: the line's list row says when none are).
  async function hitTimes(bp) {
    const backend = host.currentBackend;
    // Still loading: nothing to say yet (a warning now would hide the real one later).
    if (!host.dataReady()) { return undefined; }
    // A commit breakpoint's times are kept with the commit index they came from.
    if (isCommit(bp)) { return CB.times(bp, (text) => warnOnce(bp, text)); }
    if (bp.timesFor === backend && bp.times) { return bp.times; }
    const paths = bp.kind === 'line' ? bp.paths : [bp.path];
    let times = [];
    let found = 0;
    let incomplete = false;
    for (const path of paths) {
      const entry = await changesOf(path, backend);
      if (host.currentBackend !== backend) { return null; }
      if (!entry) {
        if (bp.kind !== 'line') { warnOnce(bp, format(S().debuggerBreakpointSignalGone, path.join('.'))); }
        continue;
      }
      // Not read yet (the backend is still loading): asked again on the next search.
      if (entry.changes === undefined) { incomplete = true; continue; }
      if (!entry.changes) {
        warnOnce(bp, format(S().debuggerTooManyChanges, path.join('.')));
        continue;
      }
      if (bp.kind === 'text') {
        const textTimes = await TB.times(bp, entry, (text) => warnOnce(bp, text));
        if (host.currentBackend !== backend) { return null; }
        if (!textTimes) { continue; }
        found++;
        times = times.concat(Array.from(textTimes));
        releaseChanges([path], bp, backend);
        continue;
      }
      // A restored value is read once the signal's width is known, and again when a reload changed it.
      if (bp.kind === 'equals' && (!bp.pattern || bp.pattern.length !== entry.width)) {
        bp.pattern = parseValue(bp.value, entry.width);
        if (!bp.pattern) {
          warnOnce(bp, format(S().debuggerBadValue, bp.value, number(entry.width)));
          continue;
        }
      }
      found++;
      times = times.concat(timesOf(entry, bp.kind, bp.pattern));
      // Its times are taken: its raw changes go now, not after every path's are held at once.
      releaseChanges([path], bp, backend);
    }
    if (!found) { return incomplete ? undefined : null; }
    times.sort((a, b) => a - b);
    const unique = Float64Array.from(times.filter((t, i) => i === 0 || t !== times[i - 1]));
    if (incomplete) { return unique; }
    bp.times = unique;
    bp.timesFor = backend;
    return bp.times;
  }

  // Index of the first posedge at or after `time` (edges.length: none).
  function landingIndex(edges, time) {
    let lo = 0, hi = edges.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (edges[mid] < time) { lo = mid + 1; } else { hi = mid; }
    }
    return lo;
  }

  // The hit of `times` nearest the marker at `from` in direction `dir`: { time, index } (index:
  // the posedge it lands on), or null. Forward: changes after the marker's posedge (they land
  // after the marker); reverse: changes at or before the last posedge before the marker.
  function nearestHit(times, edges, from, dir) {
    const firstAfter = (limit) => {
      let lo = 0, hi = times.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (times[mid] <= limit) { lo = mid + 1; } else { hi = mid; } }
      return lo;
    };
    if (dir > 0) {
      const at = from === null ? -1 : edgeIndexAt(edges, from);
      const i = firstAfter(at >= 0 ? edges[at] : -Infinity);
      if (i >= times.length) { return null; }
      // index edges.length: after the last posedge, so no cycle to land on (any hit that has one is nearer).
      return { time: times[i], index: landingIndex(edges, times[i]) };
    }
    if (from === null) { return null; }
    let before = edgeIndexAt(edges, from);
    if (before >= 0 && edges[before] === from) { before--; }
    if (before < 0) { return null; }
    const i = firstAfter(edges[before]) - 1;
    return i >= 0 ? { time: times[i], index: landingIndex(edges, times[i]) } : null;
  }

  // A breakpoint's condition as a test of a landing time (true when some known bit is 1, as an
  // SV if takes it); null when it has none, false when it cannot be evaluated (said once),
  // undefined while one of its signals is not read yet. Names
  // are looked up in the breakpoint's scope (a signal's own, a line's instance), then from the top.
  async function conditionTest(bp, backend) {
    if (!bp.condition) { return null; }
    const say = (message) => { warnOnce(bp, format(S().debuggerConditionError, baseName(bp), message)); return false; };
    const parsed = X.parse(bp.condition);
    if (parsed.error) { return say(exprMessage(parsed.error, parsed.at)); }
    const scope = bp.kind === 'line' ? (bp.scope || (bp.paths[0] ? bp.paths[0].slice(0, -1) : null)) : bp.path ? bp.path.slice(0, -1) : (isCommit(bp) ? CB.scopeOf(bp) : null);
    const prepared = await machineEnv(parsed.ast, (m) => m.prepare());
    if (prepared && prepared.error) { return say(prepared.error.message); }
    const paths = X.names(parsed.ast).filter((path) => !isMachineName(path));
    const vars = await resolveNames(paths, scope);
    for (const path of paths) {
      if (!vars.has(JSON.stringify(path))) { return say(exprMessage('unknownName', null, path.join('.'))); }
    }
    const series = new Map();
    for (const v of new Set(vars.values())) {
      const entry = await conditionChangesOf(host.pathOf(v), backend);
      if (host.currentBackend !== backend || !entry) { return false; }
      if (entry.changes === undefined) { return undefined; }
      if (!entry.changes) { return say(format(S().debuggerTooManyChanges, host.pathOf(v).join('.'))); }
      series.set(v.netlistId, entry.changes);
    }
    const env = (time) => (path) => {
      const v = vars.get(JSON.stringify(path));
      if (!v) { return null; }
      const width = Number(v.width) || 1;
      const bits = valueIn(series.get(v.netlistId), time);
      return { width, msb: v.msb, lsb: v.lsb, value: X.fromBits(bits === undefined ? 'x' : String(bits), width) };
    };
    return (time) => {
      // A register or memory with no value yet (before its first write) is false, not an error.
      const m = prepared ? machineWrap(prepared.env.envAt(time)) : null;
      const r = X.evaluate(parsed.ast, m ? m.wrap(env(time)) : env(time));
      if (r.error && m && m.env.missing) { return false; }
      if (r.error) { say(exprMessage(r.error, r.at)); return false; }
      return X.truthy(r.value);
    };
  }

  // nearestHit for a conditional breakpoint: the nearest whose condition holds at its landing
  // posedge (a hit past the last posedge has none, so it never holds). Yields now and then.
  async function nearestTrueHit(times, edges, from, dir, test) {
    const first = nearestHit(times, edges, from, dir);
    if (!first) { return null; }
    let i = times.indexOf(first.time);
    const tried = new Map();
    for (let n = 0; i >= 0 && i < times.length; i += dir, n++) {
      if (n && n % 4000 === 0) { await new Promise((r) => setTimeout(r, 0)); }
      const index = landingIndex(edges, times[i]);
      if (index >= edges.length) { if (dir > 0) { return null; } continue; }
      if (!tried.has(index)) { tried.set(index, test(edges[index])); }
      if (tried.get(index)) { return { time: times[i], index }; }
    }
    return null;
  }

  // The nearest hit of the enabled breakpoints: { bp, time, index } or null.
  async function findHit(edges, from, dir) {
    let best = null;
    const backend = host.currentBackend;
    let loading = false;
    // A condition that does not parse never holds (the list shows it as an error).
    for (const bp of breakpoints.filter((b) => b.enabled && !b.conditionError)) {
      // In any instance with a condition: each instance's hits, tested in its own scope.
      for (const unit of bp.condition && bp.units ? bp.units : [bp]) {
        const times = await hitTimes(unit);
        if (times === undefined) { loading = true; continue; }
        if (!times) { continue; }
        const test = await conditionTest(unit, backend);
        if (test === false) { continue; }
        // A condition's signal not read yet: still loading, not "no hit".
        if (test === undefined) { loading = true; continue; }
        const hit = test ? await nearestTrueHit(times, edges, from, dir, test) : nearestHit(times, edges, from, dir);
        if (!hit) { continue; }
        const nearer = !best || (dir > 0 ? hit.index < best.index || (hit.index === best.index && hit.time < best.time)
          : hit.index > best.index || (hit.index === best.index && hit.time > best.time));
        if (nearer) { best = Object.assign({ bp }, hit); }
      }
    }
    return best || (loading ? { loading: true } : null);
  }

  const timeText = (time) => {
    const metadata = host.doc.metadata || {};
    return number(time * (Number(metadata.timeScale) || 1)) + ' ' + (metadata.timeUnit || '');
  };

  function announceHit(found, edges) {
    lastHitId = found.bp.id;
    lastHitBackend = host.currentBackend;
    renderBreakpoints();
    window.cmuxUI.toast(format(S().debuggerBreakpointHit, breakpointName(found.bp), timeText(found.time), number(found.index + 1)), 'info');
    return { id: found.bp.id, time: found.time, landed: edges[found.index], cycle: found.index + 1 };
  }

  // Run to a PC's next (dir 1) or previous (-1) commit, without a breakpoint (a listing's gutter menu).
  async function runToPc(query) {
    const q = query || {};
    const dir = Number(q.dir) < 0 ? -1 : 1;
    if (!CB) { return Object.assign(publicState(), { hit: null, reason: 'none' }); }
    const bp = Object.assign({ kind: 'pc', key: null, enabled: true }, commitFields('pc', q));
    if (CB.check('pc', bp)) { return Object.assign(publicState(), { hit: null, reason: 'address' }); }
    const request = ++continueRequest;
    const edges = await start();
    if (!edges) { return Object.assign(publicState(), { hit: null, reason: startFailure || 'noClock' }); }
    pause();
    const backend = host.currentBackend;
    const times = await CB.times(bp, (text) => window.cmuxUI.toast(text, 'warning'));
    if (request !== continueRequest || host.currentBackend !== backend) { return Object.assign(publicState(), { hit: null, reason: 'superseded' }); }
    if (!times) { return Object.assign(publicState(), { hit: null, reason: 'noStream' }); }
    const hit = nearestHit(times, edges, markerTime(), dir);
    if (!hit || hit.index >= edges.length) {
      window.cmuxUI.toast((dir > 0 ? S().debuggerNoHitForward : S().debuggerNoHitBack) || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: dir > 0 ? 'end' : 'start' });
    }
    moveMarker(edges[hit.index]);
    CB.landed(bp, hit.time);
    return Object.assign(cycleInfo(edges[hit.index]), { hit: { time: hit.time, landed: edges[hit.index], cycle: hit.index + 1 }, reason: 'hit' });
  }

  // F5 (with `orTogglePlay`: Play/Pause when no breakpoint is enabled) and Shift-F5 (dir -1).
  async function continueRun(query) {
    const q = query || {};
    const dir = Number(q.dir) < 0 ? -1 : 1;
    // F5 while playing pauses (as a debugger's Pause does); continue again from there.
    if (q.orTogglePlay && state.playing) { return Object.assign(pause(), { hit: null, reason: 'paused' }); }
    if (!breakpoints.some((b) => b.enabled)) {
      if (q.orTogglePlay && dir > 0) { return Object.assign(await togglePlay(), { hit: null, reason: 'play' }); }
      window.cmuxUI.toast(S().debuggerNoBreakpoints || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: 'none' });
    }
    const request = ++continueRequest;
    const edges = await start();
    if (!edges) { return Object.assign(publicState(), { hit: null, reason: startFailure || 'noClock' }); }
    pause();
    const backend = host.currentBackend;
    const found = await findHit(edges, markerTime(), dir);
    // A newer continue, or a reload, since: it says what happened.
    if (request !== continueRequest || host.currentBackend !== backend) { return Object.assign(publicState(), { hit: null, reason: 'superseded' }); }
    if (found && found.loading) {
      window.cmuxUI.toast(S().debuggerLoading || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: 'loading' });
    }
    if (!found) {
      window.cmuxUI.toast((dir > 0 ? S().debuggerNoHitForward : S().debuggerNoHitBack) || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: dir > 0 ? 'end' : 'start' });
    }
    if (found.index >= edges.length) {
      window.cmuxUI.toast(format(S().debuggerHitAfterLastEdge, breakpointName(found.bp), timeText(found.time)), 'info');
      return Object.assign(publicState(), { hit: null, reason: 'afterLastEdge', time: found.time });
    }
    moveMarker(edges[found.index]);
    // A commit breakpoint: the Machine section shows the commit that hit (several may share the cycle).
    if (isCommit(found.bp)) { CB.landed(found.bp, found.time); }
    const hit = announceHit(found, edges);
    return Object.assign(cycleInfo(edges[found.index]), { hit, reason: 'hit' });
  }

  // Play stops at the first hit ahead of where it started (or where the breakpoints last changed).
  let playStop = null;    // { bp, time, index }
  let playStopRequest = 0;
  async function refreshPlayStop() {
    const request = ++playStopRequest;
    const edges = state.edges;
    if (!edges) { playStop = null; return; }
    const found = breakpoints.some((b) => b.enabled) ? await findHit(edges, edges[playIndex], 1) : null;
    if (request !== playStopRequest || state.edges !== edges) { return; }
    if (found && found.loading) { playStop = null; return; }
    // Play went past it while it was searched: search again from where play is (play never moves back).
    if (found && found.index <= playIndex && state.playing) { refreshPlayStop(); return; }
    playStop = found;
  }

  // ---- the breakpoint list, at the bottom of the netlist pane ----
  let breakpointList = null;
  function renderBreakpoints() {
    const pane = document.getElementById('netlist');
    if (!pane) { return; }
    if (!breakpointList) {
      breakpointList = document.createElement('div');
      breakpointList.id = 'cmux-breakpoints';
      breakpointList.style.cssText = 'flex: none; max-height: 35%; overflow: auto; border-top: 1px solid var(--vscode-widget-border); padding-bottom: 4px;';
    }
    if (breakpointList.parentElement !== pane) { pane.appendChild(breakpointList); }
    if (watchList && watchList.parentElement === pane && breakpointList.nextElementSibling !== watchList) { breakpointList.after(watchList); }
    breakpointList.hidden = !breakpoints.length;
    breakpointList.textContent = '';
    if (!breakpoints.length) { return; }
    const title = document.createElement('h2');
    title.style.cssText = 'margin: 0; padding: 6px 10px 4px; font-weight: 600; text-transform: uppercase; font-size: 11px; color: var(--vscode-descriptionForeground);';
    title.textContent = S().debuggerBreakpoints || '';
    breakpointList.appendChild(title);
    for (const bp of breakpoints) {
      const row = document.createElement('div');
      row.className = 'cmux-breakpoint' + (isLastHit(bp) ? ' hit' : '');
      row.style.cssText = 'display: flex; align-items: center; gap: 4px; padding: 1px 6px; line-height: 20px; white-space: nowrap;'
        + (isLastHit(bp) ? ' font-weight: 600;' : '');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = bp.enabled;
      box.addEventListener('change', () => setBreakpointEnabled({ id: bp.id, enabled: box.checked }));
      const label = document.createElement('span');
      label.className = 'label';
      label.style.cssText = 'flex: 1; overflow: hidden; text-overflow: ellipsis;' + (bp.enabled ? '' : ' opacity: 0.6;');
      label.textContent = breakpointName(bp);
      // A condition that does not parse: shown as an error, and why.
      if (bp.conditionError) { label.classList.add('condition-error'); label.style.color = 'var(--vscode-errorForeground, #f48771)'; }
      label.title = bp.conditionError ? format(S().debuggerConditionError, baseName(bp), bp.conditionError)
        : bp.kind === 'line' && !bp.paths.length ? format(bp.unwatched === 'nothing' ? S().debuggerLineNothingToWatch
          : bp.unwatched === 'tooLarge' ? S().debuggerLineFileTooLarge : S().debuggerLineNotPlaced, bp.label)
        : (bp.kind === 'line' && bp.pathsTotal > bp.paths.length
          ? format(S().debuggerLinePathsCapped, label.textContent, number(bp.paths.length), number(bp.pathsTotal)) : label.textContent);
      const remove = document.createElement('span');
      remove.className = 'remove codicon codicon-close';
      remove.style.cursor = 'pointer';
      remove.title = S().debuggerRemoveBreakpoint || '';
      remove.addEventListener('click', () => removeBreakpoint({ id: bp.id }));
      row.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        window.cmuxUI.showMenu(breakpointMenuItems(bp), e.clientX, e.clientY);
      });
      row.append(box, label, remove);
      breakpointList.appendChild(row);
    }
  }

  // A commit breakpoint's own list items: its address, pattern or location; then the three adds.
  function commitListItems(bp) {
    if (!isCommit(bp)) { return []; }
    const s = S();
    const edit = (title, value, apply) => async () => {
      try {
        const text = await window.cmuxUI.prompt({ title: title || '', value });
        if (text !== undefined && String(text).trim().length) { apply(String(text)); }
      } catch (error) {
        host.log(error);
      }
    };
    const own = bp.key ? [] : bp.kind === 'pc'
      ? [{ label: s.debuggerEditAddress || '', run: edit(s.debuggerAddressPrompt, bp.pcs.join(', '),
        (t) => setCommitBreakpoint({ id: bp.id, pcs: t.split(/[\s,]+/).filter(Boolean) })) }]
      : bp.kind === 'write'
        ? [{ label: s.debuggerEditLocation || '', run: edit(s.debuggerWrittenPrompt, CB.locationText(bp.loc),
          (t) => setCommitBreakpoint({ id: bp.id, loc: CB.parseLocation(t) || t })) }]
        : [{ label: s.debuggerEditTextPattern || '', run: edit(s.debuggerCommitTextPrompt, bp.pattern, (t) => setCommitBreakpoint({ id: bp.id, pattern: t })) },
          { label: (bp.caseSensitive ? '\u2713 ' : '') + (s.debuggerTextMatchCase || ''), run: () => setCommitBreakpoint({ id: bp.id, caseSensitive: !bp.caseSensitive }) },
          { label: (bp.anyRegisterNames ? '\u2713 ' : '') + (s.debuggerTextAnyRegisterNames || ''),
            run: () => setCommitBreakpoint({ id: bp.id, anyRegisterNames: !bp.anyRegisterNames }) }];
    return own.concat(commitMenuItems());
  }

  // The list row's menu: the condition, and remove.
  function breakpointMenuItems(bp) {
    const s = S();
    const text = bp.kind !== 'text' ? [] : [
      { label: s.debuggerEditTextPattern || '', run: async () => {
        try {
          const pattern = await window.cmuxUI.prompt({ title: format(s.debuggerTextPrompt, bp.path.join('.'), TB.formatName(bp.format)), value: bp.pattern });
          if (pattern !== undefined && String(pattern).length) { setTextBreakpoint({ id: bp.id, pattern: String(pattern) }); }
        } catch (error) {
          host.log(error);
        }
      } },
      { label: (bp.caseSensitive ? '\u2713 ' : '') + (s.debuggerTextMatchCase || ''), run: () => setTextBreakpoint({ id: bp.id, caseSensitive: !bp.caseSensitive }) },
    ].concat(TB.isRiscv(bp.format) ? [{ label: (bp.anyRegisterNames ? '\u2713 ' : '') + (s.debuggerTextAnyRegisterNames || ''),
      run: () => setTextBreakpoint({ id: bp.id, anyRegisterNames: !bp.anyRegisterNames }) }] : []);
    return text.concat(commitListItems(bp), [
      { label: s.debuggerEditCondition || '', run: async () => {
        try {
          const text = await window.cmuxUI.prompt({ title: s.debuggerConditionPrompt || '', value: bp.condition || '', placeholder: 'state == 3' });
          if (text !== undefined) { setBreakpointCondition({ id: bp.id, condition: text }); }
        } catch (error) {
          host.log(error);
        }
      } },
      { label: s.debuggerRemoveBreakpoint || '', run: () => removeBreakpoint({ id: bp.id }) },
    ]);
  }

  // The waveform row's menu items (cmux-commands.js adds them to the viewer's context menu).
  function rowMenuItems(context) {
    const c = context || {};
    if (c.webviewSection !== 'signal' || c.netlistId === undefined) { return []; }
    const v = host.netlistItem(c.netlistId);
    if (!v) { return []; }
    const path = host.pathOf(v);
    const s = S();
    return [
      { label: s.debuggerBreakWhenChanges || '', run: () => addBreakpoint({ path, kind: 'change' }) },
      { label: s.debuggerBreakWhenEquals || '', run: async () => {
        try {
          const value = await window.cmuxUI.prompt({ title: format(s.debuggerBreakEqualsPrompt, path.join('.')), placeholder: s.debuggerBreakEqualsPlaceholder || '' });
          if (value !== undefined && String(value).trim()) { await addBreakpoint({ path, kind: 'equals', value }); }
        } catch (error) {
          host.log(error);
        }
      } },
    ].concat(TB ? [{ label: s.debuggerBreakWhenTextMatches || '', run: async () => {
      try {
        const textFormat = TB.formatOf(v.netlistId);
        const pattern = await window.cmuxUI.prompt({ title: format(s.debuggerTextPrompt, path.join('.'), TB.formatName(textFormat)),
          placeholder: s.debuggerTextPlaceholder || '' });
        if (pattern !== undefined && String(pattern).length) { await addBreakpoint({ path, kind: 'text', format: textFormat, pattern: String(pattern) }); }
      } catch (error) {
        host.log(error);
      }
    } }] : [], [
      { label: s.debuggerAddWatch || '', run: () => addWatch({ expr: pathExpression(path) }) },
    ], showAddressItems(v, path), window.cmuxMachine ? window.cmuxMachine.rowMenuItems(c) : []);
  }

  // Show Value as Address in Listing: an 8- to 64-bit row's value at the marker, as a PC, revealed in
  // cmux's listing (`{ event: 'showAddress', pc, name }`; cmux says when no listing has it).
  function showAddressItems(v, path) {
    const width = Number(v.width) || 1;
    if (!listingAvailable || width < 8 || width > 64) { return []; }
    const s = S();
    return [{ label: s.debuggerShowValueAsAddress || '', run: async () => {
      const time = markerTime();
      const bits = time === null ? undefined : (await bitsAt([v], time)).get(v.netlistId);
      const name = path.join('.');
      if (bits === undefined || !/^[01]+$/.test(bits)) {
        window.cmuxUI.toast(format(s.debuggerAddressUnknown, name), 'warning');
        return;
      }
      host.toNative({ type: 'debugger', event: 'showAddress', pc: '0x' + BigInt('0b' + bits).toString(16), name });
    } }];
  }

  // A dump path as an expression: a segment that is not an identifier (or gen[3]) is escaped.
  function pathExpression(path) {
    return path.map((seg) => (/^[A-Za-z_][A-Za-z0-9_$]*(\[\d+\])?$/.test(seg) ? seg : '\\' + seg + ' ')).join('.').trim();
  }

  // ---- expressions: Evaluate and watches (cmux-expr.js) ----
  // An expression is evaluated at the marker in the shown instance's scope (setLocals' path, or
  // one given): each name is looked up there first, then as a dump path from the top.
  const X = window.cmuxExpr;
  let evalScope = null;
  const RADIX = { binary: 'binary', octal: 'octal', decimal: 'decimal', signed: 'decimal' };

  function exprMessage(error, at, detail) {
    const s = S();
    const limits = { tooLong: X.MAX_TEXT, tooManySignals: X.MAX_SIGNALS, tooWide: X.MAX_WIDTH };
    const reason = format(s['debuggerExpr' + error[0].toUpperCase() + error.slice(1)],
      detail !== undefined ? detail : (limits[error] !== undefined ? number(limits[error]) : ''));
    return at === null || at === undefined ? reason : format(s.debuggerExprError, reason, number(at + 1));
  }

  function nameAt(node, at) {
    if (!node || typeof node !== 'object') { return null; }
    if (node.t === 'name') { return node.at === at ? node.path.join('.') : null; }
    for (const key of ['c', 'l', 'e', 'i', 'r', 'a', 'b']) { const found = nameAt(node[key], at); if (found) { return found; } }
    for (const part of node.parts || []) { const found = nameAt(part, at); if (found) { return found; } }
    return null;
  }

  // The variables for `paths` (as written): in `scope` first, then from the top. JSON path -> var.
  async function resolveNames(paths, scope) {
    const out = new Map();
    for (const path of paths) {
      let v = scope && scope.length ? await host.findLinkItem(scope.concat(path), true) : null;
      if (!v || v.kind === 'scope') { v = await host.findLinkItem(path, true); }
      if (v && v.kind !== 'scope') { out.set(JSON.stringify(path), v); }
    }
    return out;
  }

  function valueIn(changes, time) {
    let lo = 0, hi = changes.length - 1, at = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (Number(changes[mid][0]) <= time) { at = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return at >= 0 ? changes[at][1] : undefined;
  }

  // The bits each variable has at `time` (netlistId -> bits): a point query, else its changes.
  async function bitsAt(vars, time) {
    const out = new Map();
    let raw = new Map();
    try { raw = (await host.rawValuesAt(time, vars)) || new Map(); } catch (error) { host.log(error); }
    for (const v of vars) {
      let bits = raw.get(v.netlistId);
      if (bits === undefined) {
        const entry = await conditionChangesOf(host.pathOf(v), host.currentBackend);
        if (entry && entry.changes) { bits = valueIn(entry.changes, time); }
      }
      if (bits !== undefined && bits !== null) { out.set(v.netlistId, String(bits)); }
    }
    return out;
  }

  // ---- machine state names: $a0 / $x5 / $pc / $mstatus / $mem32(addr) (cmux-machine.js) ----
  const isMachineName = (path) => !!window.cmuxMachine && window.cmuxMachine.isName(path);
  function usesMachine(node) {
    if (!node || typeof node !== 'object') { return false; }
    if (node.t === 'mem') { return true; }
    if (node.t === 'name') { return isMachineName(node.path); }
    for (const key of ['c', 'l', 'e', 'i', 'r', 'a', 'b']) { if (usesMachine(node[key])) { return true; } }
    return (node.parts || []).some(usesMachine);
  }
  // A machine env's lookup around a signal lookup: { env, wrap(lookup) }.
  function machineWrap(env) {
    if (!env) { return null; }
    return { env, wrap: (lookup) => {
      const fn = (path) => {
        if (!isMachineName(path)) { return lookup(path); }
        const v = env.value(path[0]);
        if (v && v.missing) { env.missing = path[0]; return null; }
        return v;
      };
      fn.memory = env.memory;
      return fn;
    } };
  }
  // null: the expression has no machine names; { error }: it has, but there is no commit stream.
  async function machineEnv(ast, get) {
    if (!usesMachine(ast)) { return null; }
    const m = window.cmuxMachine;
    const env = m ? await get(m) : null;
    if (!env) {
      const why = (m && m.problem()) || S().machineNoStream || '';
      return { error: { error: 'noValue', at: null, message: why } };
    }
    return env.envAt ? { env } : machineWrap(env);
  }

  // { value (text), width, bits, decimal, raw } or { error, at, message }.
  async function evaluateAt(text, scope, time) {
    const parsed = X.parse(text);
    if (parsed.error) { return { error: parsed.error, at: parsed.at, message: exprMessage(parsed.error, parsed.at) }; }
    if (time === null) { return { error: 'noMarker', at: null, message: exprMessage('noMarker', null) }; }
    const machine = await machineEnv(parsed.ast, (m) => m.envAt(time));
    if (machine && machine.error) { return machine.error; }
    const paths = X.names(parsed.ast).filter((path) => !isMachineName(path));
    const vars = await resolveNames(paths, scope);
    const bits = await bitsAt(Array.from(new Set(vars.values())), time);
    // A signal with no value here (too many changes to read) says so, not "not in this waveform".
    for (const [key, v] of vars) {
      if (!bits.has(v.netlistId)) { return { error: 'noValue', at: null, message: exprMessage('noValue', null, JSON.parse(key).join('.')) }; }
    }
    const lookup = (path) => {
      const v = vars.get(JSON.stringify(path));
      if (!v) { return null; }
      const width = Number(v.width) || 1;
      return { width, msb: v.msb, lsb: v.lsb, value: X.fromBits(bits.get(v.netlistId), width) };
    };
    const result = X.evaluate(parsed.ast, machine ? machine.wrap(lookup) : lookup);
    if (result.error && machine && machine.env.missing) {
      return { error: 'noValue', at: null, message: exprMessage('noValue', null, machine.env.missing) };
    }
    if (result.error) {
      const name = result.error === 'unknownName' ? nameAt(parsed.ast, result.at) : undefined;
      return { error: result.error, at: result.at, message: exprMessage(result.error, result.at, name === null ? undefined : name) };
    }
    const value = result.value;
    // One signal shown in the viewer: in its row's radix.
    const single = parsed.ast.t === 'name' ? vars.get(JSON.stringify(parsed.ast.path)) : null;
    const radix = (single && RADIX[host.shownFormats().get(single.netlistId)]) || 'hex';
    return { value: X.format(value, radix), width: value.w, bits: X.toBits(value), decimal: X.format(value, 'decimal'), raw: value };
  }

  // evaluate({ expr, scope, time, show }): at the marker (or `time`) in the shown instance (or
  // `scope`); `show` puts it in the strip's field (Evaluate Expression…, the editor's Evaluate at Cycle).
  let evalShown = 0;
  async function evaluate(query) {
    const q = query || {};
    // Only the latest shown evaluation is shown (an older one may finish later).
    const shownAs = q.show ? ++evalShown : 0;
    const text = String(q.expr === undefined || q.expr === null ? '' : q.expr);
    const scope = Array.isArray(q.scope) ? q.scope.map(String) : evalScope;
    const time = q.time !== undefined && q.time !== null && Number.isFinite(Number(q.time)) ? Number(q.time) : markerTime();
    let r;
    try {
      // gdb's commands (info registers, p/x, x/8xw $sp, x/4i $pc) go to the machine state.
      const gdb = window.cmuxMachine && window.cmuxMachine.isGdb(text.trim())
        ? await window.cmuxMachine.gdb({ text, time }) : null;
      r = gdb ? { gdb: true, lines: gdb.lines, value: gdb.lines[0] || '', error: gdb.error ? 'gdb' : null, message: gdb.lines[0] || '' }
        : await evaluateAt(text, scope, time);
    } catch (error) {
      host.log(error);
      r = { error: 'noValue', at: null, message: exprMessage('noValue', null, text) };
    }
    const out = Object.assign({ expr: text, scope: scope ? scope.slice() : null, time }, r);
    delete out.raw;
    if (q.show) { remember(text); if (shownAs === evalShown) { showEvaluation(text, out); } }
    return out;
  }

  // The palette's Evaluate Expression…: asks, then shows it in the strip (or a toast when not stepping).
  async function promptEvaluate() {
    const s = S();
    let text;
    try { text = await window.cmuxUI.prompt({ title: s.debuggerEvaluate || '', placeholder: s.debuggerEvaluateTooltip || '', value: evalHistory[evalHistory.length - 1] || '' }); } catch (error) { host.log(error); return null; }
    if (text === undefined || text === null || !String(text).trim()) { return null; }
    return evaluate({ expr: String(text).trim(), show: true });
  }

  // The palette's Add Watch….
  async function promptAddWatch() {
    let text;
    try { text = await window.cmuxUI.prompt({ title: S().debuggerAddWatch || '', placeholder: 'state == 3' }); } catch (error) { host.log(error); return null; }
    if (text === undefined || text === null || !String(text).trim()) { return null; }
    return addWatch({ expr: String(text) });
  }

  // ---- the strip's Evaluate field: Enter evaluates, up and down go through the history ----
  const evalHistory = [];
  let historyAt = null;
  let historyDraft = '';

  function remember(text) {
    const i = evalHistory.indexOf(text);
    if (i >= 0) { evalHistory.splice(i, 1); }
    evalHistory.push(text);
    if (evalHistory.length > 50) { evalHistory.shift(); }
    historyAt = null;
  }

  function onEvalKey(e) {
    const input = e.target;
    if (e.key === 'Enter') {
      e.preventDefault();
      const text = input.value.trim();
      if (!text) { return; }
      evaluate({ expr: text, show: true });
    } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      if (!evalHistory.length) { return; }
      e.preventDefault();
      if (historyAt === null) {
        if (e.key === 'ArrowDown') { return; }
        historyDraft = input.value;
        historyAt = evalHistory.length;
      }
      historyAt = Math.max(0, historyAt + (e.key === 'ArrowUp' ? -1 : 1));
      if (historyAt >= evalHistory.length) { historyAt = null; input.value = historyDraft; return; }
      input.value = evalHistory[historyAt];
    } else if (e.key === 'Escape') {
      input.blur();
    }
  }

  function showEvaluation(text, r) {
    const s = S();
    const shown = r.error ? r.message : (r.gdb ? r.value + (r.lines.length > 1 ? ' …' : '') : format(s.debuggerEvalResult, r.value, number(r.width)));
    const el = state.stepping ? ensureStrip() : null;
    const box = el && el.querySelector('.cmux-eval');
    if (!box) { window.cmuxUI.toast(text + ' ' + shown, r.error ? 'warning' : 'info'); return; }
    const input = box.querySelector('input');
    if (input.value.trim() !== text) { input.value = text; }
    const result = box.querySelector('.result');
    result.textContent = shown;
    result.title = r.gdb ? r.lines.join('\n') : (r.error ? '' : format(s.debuggerEvalTooltip, r.bits, r.decimal));
    result.style.color = r.error ? 'var(--vscode-editorWarning-foreground, #cca700)' : '';
    result.dataset.expr = text;
  }

  // ---- watches: expressions refreshed whenever the marker moves ----
  const watches = [];  // { id, expr, text, value (cmuxExpr value | null), error, changed, time }
  let nextWatchId = 1;
  let watchRunning = false;
  let watchDirty = false;

  const publicWatch = (w) => ({ id: w.id, expr: w.expr, value: w.text, error: w.error, changed: w.changed });

  function watchesChanged() {
    // cmux keeps them for the workspace's session (restoreWatches).
    host.toNative({ type: 'debugger', event: 'watches', items: watches.map((w) => w.expr) });
    renderWatches();
    refreshWatches();
  }

  const newWatch = (expr) => ({ id: nextWatchId++, expr, text: '', value: null, error: null, changed: false, time: null });

  function addWatch(query) {
    const expr = String((query || {}).expr || '').trim();
    if (!expr) { return null; }
    const w = newWatch(expr);
    watches.push(w);
    watchesChanged();
    return publicWatch(w);
  }

  function removeWatch(query) {
    const i = watches.findIndex((w) => w.id === Number((query || {}).id));
    if (i < 0) { return false; }
    watches.splice(i, 1);
    watchesChanged();
    return true;
  }

  function editWatch(query) {
    const q = query || {};
    const w = watches.find((x) => x.id === Number(q.id));
    const expr = String(q.expr || '').trim();
    if (!w || !expr) { return null; }
    Object.assign(w, { expr, text: '', value: null, error: null, changed: false, time: null });
    watchesChanged();
    return publicWatch(w);
  }

  // A restored session's watches, in place of the page's.
  function restoreWatches(query) {
    const items = Array.isArray((query || {}).items) ? query.items : [];
    watches.length = 0;
    for (const item of items) { const expr = String(item || '').trim(); if (expr) { watches.push(newWatch(expr)); } }
    watchesChanged();
    return watches.map(publicWatch);
  }

  // One refresh at a time; a move meanwhile runs another once it is done (play keeps them current).
  function refreshWatches() {
    if (!watches.length) { return; }
    if (watchRunning) { watchDirty = true; return; }
    watchRunning = true;
    setTimeout(async () => {
      try {
        do { watchDirty = false; await refreshWatchesOnce(); } while (watchDirty);
      } catch (error) {
        host.log(error);
      } finally {
        watchRunning = false;
      }
    }, 0);
  }

  async function refreshWatchesOnce() {
    const time = markerTime();
    const list = watches.slice();
    const results = [];
    for (const w of list) { results.push(await evaluateAt(w.expr, evalScope, time).catch((error) => ({ error: 'noValue', at: null, message: String(error) }))); }
    list.forEach((w, k) => {
      const r = results[k];
      if (!watches.includes(w)) { return; }
      // Changed since the marker was last somewhere else (a refresh at the same time keeps the mark).
      if (r.error) {
        Object.assign(w, { text: r.message, value: null, error: r.error, changed: false });
      } else {
        if (w.time !== time) { w.changed = w.value !== null && !X.same(w.value, r.raw); }
        Object.assign(w, { text: r.value, value: r.raw, error: null });
      }
      w.time = time;
    });
    renderWatches();
  }

  let watchList = null;
  function renderWatches() {
    const pane = document.getElementById('netlist');
    if (!pane) { return; }
    if (!watchList) {
      watchList = document.createElement('div');
      watchList.id = 'cmux-watches';
      watchList.style.cssText = 'flex: none; max-height: 35%; overflow: auto; border-top: 1px solid var(--vscode-widget-border); padding-bottom: 4px;';
    }
    if (watchList.parentElement !== pane) { pane.appendChild(watchList); }
    // Under the breakpoints.
    if (breakpointList && breakpointList.parentElement === pane && breakpointList.nextElementSibling !== watchList) { breakpointList.after(watchList); }
    watchList.hidden = !watches.length;
    watchList.textContent = '';
    if (!watches.length) { return; }
    const s = S();
    const title = document.createElement('h2');
    title.style.cssText = 'margin: 0; padding: 6px 10px 4px; font-weight: 600; text-transform: uppercase; font-size: 11px; color: var(--vscode-descriptionForeground);';
    title.textContent = s.debuggerWatch || '';
    watchList.appendChild(title);
    for (const w of watches) {
      const row = document.createElement('div');
      row.className = 'cmux-watch' + (w.changed ? ' changed' : '');
      row.style.cssText = 'display: flex; align-items: center; gap: 6px; padding: 1px 6px 1px 10px; line-height: 20px; white-space: nowrap;'
        + (w.changed ? ' background: rgba(255, 166, 0, 0.22); box-shadow: inset 3px 0 0 rgb(255, 166, 0);' : '');
      const label = document.createElement('span');
      label.className = 'label';
      label.style.cssText = 'flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis;';
      label.textContent = w.expr;
      label.title = w.expr;
      const value = document.createElement('span');
      value.className = 'value';
      value.style.cssText = 'flex: 0 1 auto; overflow: hidden; text-overflow: ellipsis; font-family: var(--vscode-editor-font-family, monospace);'
        + (w.error ? ' color: var(--vscode-editorWarning-foreground, #cca700);' : '');
      value.textContent = w.text;
      value.title = w.text;
      const remove = document.createElement('span');
      remove.className = 'remove codicon codicon-close';
      remove.style.cursor = 'pointer';
      remove.title = s.debuggerRemoveWatch || '';
      remove.addEventListener('click', () => removeWatch({ id: w.id }));
      const edit = async () => {
        try {
          const expr = await window.cmuxUI.prompt({ title: s.debuggerEditWatch || '', value: w.expr });
          if (expr !== undefined && String(expr).trim()) { editWatch({ id: w.id, expr }); }
        } catch (error) {
          host.log(error);
        }
      };
      label.addEventListener('dblclick', edit);
      row.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        window.cmuxUI.showMenu(watchMenuItems(w, edit), e.clientX, e.clientY);
      });
      row.append(label, value, remove);
      watchList.appendChild(row);
    }
  }

  function watchMenuItems(w, edit) {
    const s = S();
    return [
      { label: s.debuggerEditWatch || '', run: edit },
      { label: s.debuggerRemoveWatch || '', run: () => removeWatch({ id: w.id }) },
    ];
  }

  // ---- status strip: cycle counter and play controls ----
  let strip = null;
  function ensureStrip() {
    if (strip) { return strip; }
    const status = document.getElementById('status');
    const anchor = document.getElementById('status-delta');
    if (!status) { return null; }
    strip = document.createElement('span');
    strip.id = 'status-cycle';
    strip.hidden = true;
    strip.style.cssText = 'display: inline-flex; align-items: center; gap: 6px;';
    const playButton = document.createElement('span');
    playButton.className = 'codicon codicon-play';
    playButton.style.cursor = 'pointer';
    playButton.addEventListener('click', () => { togglePlay(); });
    const text = document.createElement('span');
    text.className = 'text';
    const rate = document.createElement('span');
    rate.className = 'rate';
    rate.style.cursor = 'pointer';
    rate.addEventListener('click', (e) => { changeRate({ by: e.shiftKey || e.altKey ? -1 : 1 }); });
    // What the editors do with the cycle (cmux says: setRtlStatus).
    const rtl = document.createElement('span');
    rtl.className = 'rtl';
    rtl.hidden = true;
    // Evaluate: an expression at the marker (cmux-expr.js), a history, + adds it as a watch.
    const evalBox = document.createElement('span');
    evalBox.className = 'cmux-eval';
    evalBox.style.cssText = 'display: inline-flex; align-items: center; gap: 4px;';
    const evalIcon = document.createElement('span');
    evalIcon.className = 'codicon codicon-symbol-variable';
    const evalInput = document.createElement('input');
    evalInput.type = 'text';
    evalInput.spellcheck = false;
    evalInput.style.cssText = 'width: 14em; height: 16px; padding: 0 4px; font: inherit; color: inherit; border-radius: 2px;'
      + ' background: var(--vscode-input-background, transparent); border: 1px solid var(--vscode-input-border, var(--vscode-widget-border));';
    evalInput.addEventListener('keydown', onEvalKey);
    const evalResult = document.createElement('span');
    evalResult.className = 'result';
    const evalAdd = document.createElement('span');
    evalAdd.className = 'add codicon codicon-add';
    evalAdd.style.cursor = 'pointer';
    evalAdd.addEventListener('click', () => {
      const expr = evalInput.value.trim() || evalResult.dataset.expr || '';
      if (expr) { addWatch({ expr }); }
    });
    evalBox.append(evalIcon, evalInput, evalResult, evalAdd);
    strip.append(playButton, text, rate, rtl, evalBox);
    status.insertBefore(strip, anchor || null);
    return strip;
  }

  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }

  const number = (n) => Number(n).toLocaleString();

  function render() {
    const el = ensureStrip();
    if (!el) { return; }
    el.hidden = !state.stepping;
    if (!state.stepping) { return; }
    const info = publicState();
    const metadata = host.doc.metadata || {};
    const unit = metadata.timeUnit || '';
    const scale = Number(metadata.timeScale) || 1;
    const s = S();
    const time = info.edgeTime === null ? '' : number(info.edgeTime * scale) + ' ' + unit;
    el.querySelector('.text').textContent = info.cycle === null ? (s.debuggerNoCycle || '')
      : format(s.debuggerCycle, number(info.cycle), number(info.count), time);
    el.querySelector('.text').title = info.clock ? format(s.debuggerClockTooltip, info.clock.join('.')) : '';
    const playButton = el.querySelector('.codicon');
    playButton.className = 'codicon ' + (state.playing ? 'codicon-debug-pause' : 'codicon-play');
    playButton.title = state.playing ? (s.debuggerPause || '') : (s.debuggerPlay || '');
    const rate = el.querySelector('.rate');
    rate.textContent = format(s.debuggerRate, number(state.rate));
    rate.title = s.debuggerRateTooltip || '';
    const rtl = el.querySelector('.rtl');
    rtl.hidden = !rtlStatus.text;
    rtl.textContent = rtlStatus.text;
    rtl.title = rtlStatus.tooltip;
    rtl.style.opacity = rtlStatus.ok ? '' : '0.75';
    rtl.style.color = rtlStatus.ok ? '' : 'var(--vscode-editorWarning-foreground, #cca700)';
    const evalInput = el.querySelector('.cmux-eval input');
    evalInput.placeholder = s.debuggerEvaluate || '';
    evalInput.title = s.debuggerEvaluateTooltip || '';
    el.querySelector('.cmux-eval .add').title = s.debuggerAddWatch || '';
  }

  // Rows came or went (Locals refilled, a signal pinned, a group folded): light the highlighted signals' rows.
  // A restore (undo, reload) dropped Locals: put it back.
  let rowsSignature = '';
  const signature = (list) => (list || []).map((d) => (d.dataType === 'signal-group'
    ? '[' + d.groupName + (d.collapseState === 1 ? '-' : '+') + ':' + signature(d.children) + ']'
    : String(d.netlistId))).join(',');
  host.contextListeners.push((m) => {
    if (m.displayedSignals) {
      const next = signature(m.displayedSignals);
      if (next !== rowsSignature) {
        rowsSignature = next;
        if (state.highlightIds.size) { queueMicrotask(matchHighlightedRows); }
      }
    }
    if (state.stepping && state.locals.path && !state.locals.busy && localsElement()) {
      setTimeout(refreshLocals, 0);
    } else if (state.stepping && state.locals.path && !state.locals.busy && !localsElement()) {
      const path = JSON.parse(state.locals.path);
      setTimeout(() => {
        if (state.stepping && !state.locals.busy && !localsElement() && state.locals.path === JSON.stringify(path)) {
          state.locals.path = null;
          setLocals({ path });
        }
      }, 0);
    }
  });

  // The marker moved (a step, play, a click): draw the counter, tell cmux the cycle.
  host.viewerEventListeners.push((m) => {
    if (m.eventType !== 'markerSet') { return; }
    const time = m.eventData && Number(m.eventData.time);
    if (Number.isFinite(time)) { marker.fromEvent = time; marker.contextThen = contextMarker(); }
    // The user put the marker somewhere else: play stops there.
    if (state.playing && Number.isFinite(time) && !sentTimes.includes(time)) { pause(); }
    refreshWatches();
    if (!state.stepping) { return; }
    render();
    queuePlace();
    const info = publicState();
    // With a commit stream (cmux-machine.js): the marker cycle's commits and the current one.
    const commits = window.cmuxMachine ? window.cmuxMachine.cycleCommits(info.edgeTime) : null;
    const key = info.time + ':' + info.cycle + ':' + (commits ? commits.current : '');
    if (key === state.lastCycleKey) { return; }
    state.lastCycleKey = key;
    post('cycle', commits || undefined);
  });

  const api = Object.freeze({
    state: async () => { if (state.stepping) { await ensureEdges(); } return publicState(); },
    cycleAt: async (query) => {
      if (state.stepping) { await ensureEdges(); }
      const time = Number((query || {}).time);
      return cycleInfo(Number.isFinite(time) ? time : null);
    },
    step, jump, play, pause, togglePlay, setRate, changeRate, setClock, useSelectedAsClock, stop, setLocals, highlightRows,
    setRtlStatus, rtlShown,
    continue: continueRun, addBreakpoint, removeBreakpoint, setBreakpointEnabled, setBreakpointCondition, setLineBreakpoints, restoreBreakpoints,
    setTextBreakpoint, setCommitBreakpoint, promptCommitBreakpoint, chooseCommitBreakpoint, setPcBreakpoints, runToPc,
    // cmux's listings: the current commit's PC, a sample of the commits, and cmux's own warnings.
    currentCommitPc: () => (CB && state.stepping ? CB.currentPc(publicState().edgeTime) : null),
    commitSample: (query) => (CB ? CB.sample((query || {}).limit) : null),
    say: (query) => { const q = query || {}; if (q.text) { window.cmuxUI.toast(String(q.text), q.level === 'warning' ? 'warning' : 'info'); } return true; },
    breakpoints: () => breakpoints.map(publicBreakpoint),
    // The kinds addBreakpoint takes (cmux-machine.js's row menus offer Break When Written when 'write' is one).
    breakpointKinds: () => ['change', 'equals'].concat(TB ? ['text'] : [], CB ? ['pc', 'commitText', 'write'] : []),
    // host.js: a load finished (a reload's new backend): the list drops the old hit mark.
    backendChanged: () => { if (window.cmuxMachine) { window.cmuxMachine.backendChanged(); } renderBreakpoints(); refreshWatches(); },
    // cmux-machine.js: the current commit moved inside the marker's cycle (cmux hears the new `current`).
    commitMoved: () => {
      if (!state.stepping || !window.cmuxMachine) { return false; }
      const info = publicState();
      const commits = window.cmuxMachine.cycleCommits(info.edgeTime);
      const key = info.time + ':' + info.cycle + ':' + (commits ? commits.current : '');
      if (key === state.lastCycleKey) { return false; }
      state.lastCycleKey = key;
      post('cycle', commits || undefined);
      return true;
    },
    // cmux-machine.js: the clock's posedges, the marker (as the debugger knows it) and a move.
    edges: () => ensureEdges(),
    // The clock the edges are of, as a dotted path (null: none yet).
    clockPath: () => (state.clock ? host.pathOf(state.clock).join('.') : null),
    markerTime: () => markerTime(),
    moveTo: async (query) => {
      const time = Number((query || {}).time);
      if (!Number.isFinite(time) || !await start()) { return false; }
      pause();
      moveMarker(time);
      return true;
    },
    cacheSizes: () => ({ changes: changeCache.size, conditions: conditionCache.size, conditionChanges: cachedChanges() }),
    // The harness: a smaller cap on the conditions' cache (null: the real one).
    setConditionChangeCap: (n) => { maxConditionChanges = n === null || n === undefined ? MAX_CONDITION_CHANGES : Number(n); },
    // The harness: which breakpoint play stops at (null: none).
    playStopId: () => (playStop ? playStop.bp.id : null),
    evaluate, promptEvaluate, promptAddWatch, addWatch, removeWatch, editWatch, restoreWatches, watches: () => watches.map(publicWatch),
  });
  Object.defineProperty(waveform, 'debugger', { value: api, writable: false, configurable: false, enumerable: true });
  window.cmuxDebugger = { localsName, isLocals: host.isTransientGroup, savedLocals: localsGroupSaved,
    isPlaying: () => state.playing, locals: () => Object.assign({}, state.locals), rowMenuItems };
})();
