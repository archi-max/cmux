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
    loading: null,
    stepping: false,
    playing: false,
    rate: 10,
    lastCycleKey: null,
    locals: { path: null, request: 0, groupId: null, label: null },
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
    if (state.loading) { return state.loading; }
    state.loading = (async () => {
      try {
        if (!state.clock || state.edgesFor && state.edgesFor[1] !== backend) {
          // A reload brings a new netlist: find the clock again by path.
          const path = state.clock ? host.pathOf(state.clock) : null;
          state.clock = (path && await host.findLinkItem(path, true)) || (state.clockChosen ? null : await defaultClock());
          if (!state.clock) { state.clockChosen = false; state.clock = await defaultClock(); }
        }
        for (;;) {
          if (!state.clock) { state.edges = null; return null; }
          const clock = state.clock;
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
        state.loading = null;
      }
    })();
    return state.loading;
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

  function post(event) {
    host.toNative(Object.assign({ type: 'debugger', event }, publicState()));
  }

  function moveMarker(time) {
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
    const edges = await ensureEdges();
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

  function scheduleTick() {
    clearTimeout(playTimer);
    playTimer = setTimeout(tick, Math.max(16, Math.min(250, 1000 / state.rate)));
  }

  function tick() {
    if (!state.playing || !state.edges) { return; }
    const edges = state.edges;
    const target = Math.min(edges.length - 1,
      playOrigin.index + Math.floor((performance.now() - playOrigin.at) * state.rate / 1000));
    const time = markerTime();
    if (time === null || edges[target] !== time) { moveMarker(edges[target]); }
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
    playOrigin = { index, at: performance.now() };
    if (!state.playing) { state.playing = true; render(); post('state'); }
    if (time === null || edges[index] !== time) { moveMarker(edges[index]); }
    scheduleTick();
    return publicState();
  }

  function pause() {
    clearTimeout(playTimer);
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
      const reached = Math.min(state.edges.length - 1,
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
    const v = path ? await host.findLinkItem(path, true) : await defaultClock();
    if (path && (!v || Number(v.width) !== 1)) { return null; }
    state.clock = v;
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
    if (!el) { state.locals.groupId = null; state.locals.label = null; }
    return el || null;
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
  host.isTransientGroup = (d) => !!d && d.dataType === 'signal-group' && state.locals.label !== null
    && d.groupName === state.locals.label && localsElement() !== null;

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

  async function setLocals(query) {
    const path = (query || {}).path || null;
    const key = path ? JSON.stringify(path) : null;
    if (!path) { clearLocalsGroup(); return true; }
    // Only while stepping; a reload or an undo that dropped the group gets it back on the next call.
    if (!state.stepping) { return false; }
    if (key === state.locals.path && localsElement()) { return true; }
    const request = ++state.locals.request;
    const scope = await host.findLinkItem(path, false);
    if (request !== state.locals.request) { return false; }
    if (!scope || scope.kind !== 'scope') { return false; }
    const vars = (await host.getChildren(scope)).filter((c) => c.kind === 'var').slice(0, MAX_LOCALS);
    if (request !== state.locals.request) { return false; }
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
  });

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
    strip.append(playButton, text, rate);
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
  }

  // Rows came or went (Locals refilled, a signal pinned): light the highlighted signals' new rows.
  host.contextListeners.push(() => {
    if (state.highlightIds.size) { queueMicrotask(matchHighlightedRows); }
  });

  // The marker moved (a step, play, a click): draw the counter, tell cmux the cycle.
  host.viewerEventListeners.push((m) => {
    if (m.eventType !== 'markerSet') { return; }
    const time = m.eventData && Number(m.eventData.time);
    if (Number.isFinite(time)) { marker.fromEvent = time; marker.contextThen = contextMarker(); }
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
  });
  Object.defineProperty(waveform, 'debugger', { value: api, writable: false, configurable: false, enumerable: true });
  window.cmuxDebugger = { localsName, isLocals: host.isTransientGroup, savedLocals: localsGroupSaved,
    isPlaying: () => state.playing };
})();
