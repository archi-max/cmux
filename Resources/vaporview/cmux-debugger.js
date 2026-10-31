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
    host.toNative(Object.assign({ type: 'debugger', event }, publicState(), extra || {}));
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

  async function start() {
    const backend = host.currentBackend;
    let edges;
    try {
      edges = await ensureEdges();
    } catch (error) {
      // A reload closed the backend mid-read: it owns the page now, and says nothing.
      if (error && error.cmuxClosed || host.currentBackend !== backend) { return null; }
      // Past MAX_EDGES (or the reader failed): say so rather than stall or run out of memory.
      host.log(error);
      window.cmuxUI.toast(S().debuggerTooManyEdges || '', 'warning');
      return null;
    }
    if (host.currentBackend !== backend) { return null; }
    if (!edges) {
      window.cmuxUI.toast(S().debuggerNoClock || '', 'warning');
      return null;
    }
    if (!edges.length) {
      window.cmuxUI.toast(S().debuggerNoEdges || '', 'warning');
      return null;
    }
    if (!state.stepping) { state.stepping = true; render(); post('state'); }
    return edges;
  }

  async function step(query) {
    const asked = Number((query || {}).by);
    const by = Number.isFinite(asked) ? Math.trunc(asked) : 1;
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
    const stop = playStop && next >= playStop.index ? playStop : null;
    const left = edges[playIndex];
    const missed = rtlPending !== null;
    playIndex = next;
    lastMoveAt = now;
    rtlPending = { time: edges[next], at: now };
    moveMarker(edges[next]);
    postMoved(edges[next], left, missed);
    if (stop) { pause(); announceHit(stop, edges); return; }
    if (next >= edges.length - 1) { pause(); return; }
    scheduleTick(gap);
  }

  let playBackend = null;
  let playStarts = 0;

  function tick() {
    if (!state.playing || !state.edges) { return; }
    // The file was reloaded: its edges may differ, so play stops.
    if (host.currentBackend !== playBackend) { pause(); return; }
    const edges = state.edges;
    if (rtlStatus.wait) { waitingTick(edges); return; }
    let target = Math.min(edges.length - 1,
      playOrigin.index + Math.floor((performance.now() - playOrigin.at) * state.rate / 1000));
    // A breakpoint hit on the way (or skipped over by this tick): play stops there.
    const stop = playStop && target >= playStop.index ? playStop : null;
    if (stop) { target = stop.index; }
    const left = edges[playIndex];
    playIndex = target;
    const time = markerTime();
    if (time === null || edges[target] !== time) {
      moveMarker(edges[target]);
      postMoved(edges[target], left, false);
    }
    if (stop) { pause(); announceHit(stop, edges); return; }
    if (target >= edges.length - 1) { pause(); return; }
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
    playStop = breakpoints.some((b) => b.enabled) ? await findHit(edges, edges[index], 1) : null;
    if (started !== playStarts || host.currentBackend !== backend) { return publicState(); }
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
  // { id, path, kind: 'change' | 'equals', value, pattern, enabled, times, timesFor }, and the
  // line breakpoints cmux sets (setLineBreakpoints): { id, kind: 'line', key, label, paths, ... }.
  const breakpoints = [];
  let nextBreakpointId = 1;
  let lastHitId = null;
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
        if (!/^\d+$/.test(digits)) { return null; }
        bits = BigInt(digits).toString(2);
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

  const breakpointName = (bp) => (bp.kind === 'line' ? bp.label : (bp.kind === 'equals'
    ? format(S().debuggerBreakpointEquals, bp.path.join('.'), bp.value)
    : format(S().debuggerBreakpointChanges, bp.path.join('.'))));

  const publicBreakpoint = (bp) => ({ id: bp.id, kind: bp.kind, enabled: bp.enabled, hit: bp.id === lastHitId, label: breakpointName(bp),
    path: bp.path ? bp.path.slice() : null, value: bp.kind === 'equals' ? bp.value : null,
    key: bp.kind === 'line' ? bp.key : null, paths: bp.kind === 'line' ? bp.paths.map((p) => p.slice()) : null });

  // cmux owns line breakpoints: the list's checkbox and remove button tell it.
  const toldLine = (bp, extra) => host.toNative(Object.assign({ type: 'debugger', event: 'lineBreakpoint', key: bp.key,
    enabled: bp.enabled, removed: false }, extra || {}));

  // The editors' line breakpoints (cmux): replaces the page's, keeps the signal breakpoints.
  function setLineBreakpoints(query) {
    const items = Array.isArray((query || {}).items) ? query.items : [];
    const old = new Map(breakpoints.filter((b) => b.kind === 'line').map((b) => [b.key, b]));
    for (let i = breakpoints.length - 1; i >= 0; i--) { if (breakpoints[i].kind === 'line') { breakpoints.splice(i, 1); } }
    const lines = [];
    for (const item of items) {
      const key = String(item.key || '');
      if (!key || lines.some((b) => b.key === key)) { continue; }
      const paths = (Array.isArray(item.paths) ? item.paths : []).filter(Array.isArray).map((p) => p.map(String));
      const before = old.get(key);
      const same = before && JSON.stringify(before.paths) === JSON.stringify(paths);
      lines.push({ id: before ? before.id : nextBreakpointId++, kind: 'line', key, label: String(item.label || key), paths,
        enabled: item.enabled !== false, times: same ? before.times : null, timesFor: same ? before.timesFor : null });
    }
    if (lastHitId !== null && !breakpoints.some((b) => b.id === lastHitId) && !lines.some((b) => b.id === lastHitId)) { lastHitId = null; }
    breakpoints.push(...lines);
    breakpointsChanged();
    return lines.map(publicBreakpoint);
  }

  const signalOf = async (path) => (await host.findLinkItem(path, true)) || null;

  async function addBreakpoint(query) {
    const q = query || {};
    const path = Array.isArray(q.path) ? q.path.map(String) : null;
    const kind = q.kind === 'equals' ? 'equals' : (q.kind === 'change' ? 'change' : null);
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
    const same = breakpoints.find((b) => b.kind === kind && b.value === value && JSON.stringify(b.path) === JSON.stringify(path));
    if (same) {
      same.enabled = true;
      breakpointsChanged();
      return publicBreakpoint(same);
    }
    const bp = { id: nextBreakpointId++, path, kind, value, pattern, enabled: true, times: null, timesFor: null };
    breakpoints.push(bp);
    breakpointsChanged();
    return publicBreakpoint(bp);
  }

  function removeBreakpoint(query) {
    const i = breakpoints.findIndex((b) => b.id === Number((query || {}).id));
    if (i < 0) { return false; }
    const [bp] = breakpoints.splice(i, 1);
    if (bp.id === lastHitId) { lastHitId = null; }
    if (bp.kind === 'line') { toldLine(bp, { removed: true }); }
    breakpointsChanged();
    return true;
  }

  function setBreakpointEnabled(query) {
    const q = query || {};
    const bp = breakpoints.find((b) => b.id === Number(q.id));
    if (!bp) { return false; }
    bp.enabled = !!q.enabled;
    if (bp.kind === 'line') { toldLine(bp); }
    breakpointsChanged();
    return true;
  }

  function breakpointsChanged() {
    // Changes no breakpoint watches any more are let go (each may hold up to 1M).
    const watched = new Set();
    for (const b of breakpoints) { for (const path of (b.kind === 'line' ? b.paths : [b.path])) { watched.add(JSON.stringify(path)); } }
    for (const key of Array.from(changeCache.keys())) { if (!watched.has(key)) { changeCache.delete(key); } }
    renderBreakpoints();
    if (state.playing) { refreshPlayStop(); }
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
    const entry = { backend, changes: changes && changes.length <= MAX_BREAKPOINT_CHANGES ? changes : null, width: Number(v.width) || 1 };
    if (host.currentBackend === backend) { changeCache.set(key, entry); }
    return entry;
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
    if (bp.timesFor === backend && bp.times) { return bp.times; }
    const paths = bp.kind === 'line' ? bp.paths : [bp.path];
    let times = [];
    let found = 0;
    for (const path of paths) {
      const entry = await changesOf(path, backend);
      if (host.currentBackend !== backend) { return null; }
      if (!entry) {
        if (bp.kind !== 'line') { window.cmuxUI.toast(format(S().debuggerBreakpointSignalGone, path.join('.')), 'warning'); }
        continue;
      }
      if (!entry.changes) {
        window.cmuxUI.toast(format(S().debuggerTooManyChanges, path.join('.')), 'warning');
        continue;
      }
      found++;
      times = times.concat(timesOf(entry, bp.kind, bp.pattern));
    }
    if (!found) { return null; }
    times.sort((a, b) => a - b);
    bp.times = Float64Array.from(times.filter((t, i) => i === 0 || t !== times[i - 1]));
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
      const index = landingIndex(edges, times[i]);
      return index < edges.length ? { time: times[i], index } : null;
    }
    if (from === null) { return null; }
    let before = edgeIndexAt(edges, from);
    if (before >= 0 && edges[before] === from) { before--; }
    if (before < 0) { return null; }
    const i = firstAfter(edges[before]) - 1;
    return i >= 0 ? { time: times[i], index: landingIndex(edges, times[i]) } : null;
  }

  // The nearest hit of the enabled breakpoints: { bp, time, index } or null.
  async function findHit(edges, from, dir) {
    let best = null;
    for (const bp of breakpoints.filter((b) => b.enabled)) {
      const times = await hitTimes(bp);
      if (!times) { continue; }
      const hit = nearestHit(times, edges, from, dir);
      if (!hit) { continue; }
      const nearer = !best || (dir > 0 ? hit.index < best.index || (hit.index === best.index && hit.time < best.time)
        : hit.index > best.index || (hit.index === best.index && hit.time > best.time));
      if (nearer) { best = Object.assign({ bp }, hit); }
    }
    return best;
  }

  const timeText = (time) => {
    const metadata = host.doc.metadata || {};
    return number(time * (Number(metadata.timeScale) || 1)) + ' ' + (metadata.timeUnit || '');
  };

  function announceHit(found, edges) {
    lastHitId = found.bp.id;
    renderBreakpoints();
    window.cmuxUI.toast(format(S().debuggerBreakpointHit, breakpointName(found.bp), timeText(found.time), number(found.index + 1)), 'info');
    return { id: found.bp.id, time: found.time, landed: edges[found.index], cycle: found.index + 1 };
  }

  // F5 (with `orTogglePlay`: Play/Pause when no breakpoint is enabled) and Shift-F5 (dir -1).
  async function continueRun(query) {
    const q = query || {};
    const dir = Number(q.dir) < 0 ? -1 : 1;
    if (!breakpoints.some((b) => b.enabled)) {
      if (q.orTogglePlay && dir > 0) { return Object.assign(await togglePlay(), { hit: null, reason: 'play' }); }
      window.cmuxUI.toast(S().debuggerNoBreakpoints || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: 'none' });
    }
    const request = ++continueRequest;
    const edges = await start();
    if (!edges) { return Object.assign(publicState(), { hit: null, reason: 'noClock' }); }
    pause();
    const backend = host.currentBackend;
    const found = await findHit(edges, markerTime(), dir);
    // A newer continue, or a reload, since: it says what happened.
    if (request !== continueRequest || host.currentBackend !== backend) { return Object.assign(publicState(), { hit: null, reason: 'superseded' }); }
    if (!found) {
      window.cmuxUI.toast((dir > 0 ? S().debuggerNoHitForward : S().debuggerNoHitBack) || '', 'info');
      return Object.assign(publicState(), { hit: null, reason: dir > 0 ? 'end' : 'start' });
    }
    moveMarker(edges[found.index]);
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
    if (request === playStopRequest && state.edges === edges) { playStop = found; }
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
    breakpointList.hidden = !breakpoints.length;
    breakpointList.textContent = '';
    if (!breakpoints.length) { return; }
    const title = document.createElement('h2');
    title.style.cssText = 'margin: 0; padding: 6px 10px 4px; font-weight: 600; text-transform: uppercase; font-size: 11px; color: var(--vscode-descriptionForeground);';
    title.textContent = S().debuggerBreakpoints || '';
    breakpointList.appendChild(title);
    for (const bp of breakpoints) {
      const row = document.createElement('div');
      row.className = 'cmux-breakpoint' + (bp.id === lastHitId ? ' hit' : '');
      row.style.cssText = 'display: flex; align-items: center; gap: 4px; padding: 1px 6px; line-height: 20px; white-space: nowrap;'
        + (bp.id === lastHitId ? ' font-weight: 600;' : '');
      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = bp.enabled;
      box.addEventListener('change', () => setBreakpointEnabled({ id: bp.id, enabled: box.checked }));
      const label = document.createElement('span');
      label.className = 'label';
      label.style.cssText = 'flex: 1; overflow: hidden; text-overflow: ellipsis;' + (bp.enabled ? '' : ' opacity: 0.6;');
      label.textContent = breakpointName(bp);
      label.title = bp.kind === 'line' && !bp.paths.length ? format(S().debuggerLineNotPlaced, bp.label) : label.textContent;
      const remove = document.createElement('span');
      remove.className = 'remove codicon codicon-close';
      remove.style.cursor = 'pointer';
      remove.title = S().debuggerRemoveBreakpoint || '';
      remove.addEventListener('click', () => removeBreakpoint({ id: bp.id }));
      row.append(box, label, remove);
      breakpointList.appendChild(row);
    }
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
        const value = await window.cmuxUI.prompt({ title: format(s.debuggerBreakEqualsPrompt, path.join('.')), placeholder: s.debuggerBreakEqualsPlaceholder || '' });
        if (value !== undefined && String(value).trim()) { await addBreakpoint({ path, kind: 'equals', value }); }
      } },
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
    strip.append(playButton, text, rate, rtl);
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
    if (!state.stepping) { return; }
    render();
    queuePlace();
    const info = publicState();
    const key = info.time + ':' + info.cycle;
    if (key === state.lastCycleKey) { return; }
    state.lastCycleKey = key;
    post('cycle');
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
    continue: continueRun, addBreakpoint, removeBreakpoint, setBreakpointEnabled, setLineBreakpoints,
    breakpoints: () => breakpoints.map(publicBreakpoint),
  });
  Object.defineProperty(waveform, 'debugger', { value: api, writable: false, configurable: false, enumerable: true });
  window.cmuxDebugger = { localsName, isLocals: host.isTransientGroup, savedLocals: localsGroupSaved,
    isPlaying: () => state.playing, locals: () => Object.assign({}, state.locals), rowMenuItems };
})();
