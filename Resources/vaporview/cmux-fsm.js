// cmux: the waveform viewer's state machine pane. cmux (native) finds a state register's machine
// with whichever engine it has (WaveformFSMEngines.swift: Verdi's FSM analysis where the dump and
// a Verdi seat are, Yosys's fsm passes over the design, or the dump alone with the states slang
// knows) and hands the model here. The pane draws the graph, marks the state at the marker,
// moves the marker to a transition's next occurrence, and counts entries and transitions over
// the dump. Written for cmux (GPL-3.0, like cmux).
//
// cmux is asked with { type: 'fsmRequest', path } (Show State Machine on a row) and answers
// through window.cmuxWaveform.fsm:
//   show({ path, status })                   a message instead of a graph (looking, not found)
//   show({ path, model, note })              model: FsmModel.pageObject() (FsmModel.swift)
//     { signal, width, engine: 'verdi' | 'yosys' | 'observed', controls, reset?, resetSignal?,
//       states: [{ bits, name? }], transitions: [{ from: bits | '*', to, condition? }], counts? }
//   hide()
//   state() -> { open, path, current: { bits, name } | null, nodes: [{ bits, name, visits, listed }],
//                edges: [{ from, to, condition, count, observed }] }
// A click on a transition moves the marker to its next occurrence (Shift: the one before), a click
// on a state to its next entry. Transitions the dump takes that the model lacks are dashed, and so
// is every transition of a model from the dump alone. Self loops never show in the dump's
// changes, so they have no count and nothing to jump to.
(function () {
  'use strict';
  const host = window.cmuxWaveform.host;
  const link = window.cmuxWaveform.link;
  const S = () => window.cmuxWaveform.strings || {};
  // More changes than this aren't read (the pane would hold them all on the page's thread).
  const MAX_CHANGES = 2000000;
  let maxChanges = MAX_CHANGES;
  const MIN_WIDTH = 200;
  const SVG = 'http://www.w3.org/2000/svg';
  const NODE_W = 104;
  const NODE_H = 38;
  const LAYER_GAP = 74;
  const COLUMN_GAP = 28;
  const MARGIN = 28;

  let current = null;   // { path, model, note, status }
  let data = null;      // { key, times: Float64Array, codes: [bits | null], visits, counts, tooMany }
  let loading = null;
  let drawn = null;     // { nodes, edges } as last drawn
  let width = null;     // the width the user dragged the pane to (px), kept while the page lives
  try { width = Number(sessionStorage.getItem('cmux.fsm.width')) || null; } catch (e) { width = null; }

  // ---- pure ----

  const pathKey = (path) => JSON.stringify((path || []).map(String));

  // A dump value as `width` bits, or null when it isn't a known code (x, z, a real).
  function code(value, width) {
    let s = String(value == null ? '' : value).toLowerCase();
    if (!/^[01]+$/.test(s)) { return null; }
    if (s.length > width) { s = s.slice(s.length - width); }
    return s.padStart(width, '0');
  }

  // The model with the reset Yosys leaves out of its cell (`*` -> reset) added back.
  function transitionsOf(model) {
    const list = (model.transitions || []).map((t) => ({ from: String(t.from), to: String(t.to), condition: t.condition || '' }));
    if (model.reset && !list.some((t) => t.from === '*') && model.engine !== 'observed') {
      list.push({ from: '*', to: String(model.reset), condition: model.resetSignal || '' });
    }
    return list;
  }

  // Entries and transitions over the dump: `times`/`codes` are its changes.
  function tally(codes) {
    const visits = new Map();
    const counts = new Map();
    let previous = null;
    for (const c of codes) {
      if (c !== null && c !== previous) {
        visits.set(c, (visits.get(c) || 0) + 1);
        const key = (previous === null ? '*' : previous) + '>' + c;
        counts.set(key, (counts.get(key) || 0) + 1);
      }
      previous = c;
    }
    return { visits, counts };
  }

  // Index of the last change at or before `time`, -1 before the first.
  function indexAt(times, time) {
    let lo = 0;
    let hi = times.length - 1;
    let found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (times[mid] <= time) { found = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return found;
  }

  // The change that took the register from `from` ('*': not a state) to `to` after `time`
  // (backward: before it), or null.
  function occurrence(d, from, to, time, backward) {
    const takes = (i) => {
      if (d.codes[i] !== to) { return false; }
      const before = i > 0 ? d.codes[i - 1] : null;
      if (before === to) { return false; }
      return from === null || (from === '*' ? before === null : before === from);
    };
    if (backward) {
      for (let i = indexAt(d.times, time - 1e-9 * Math.max(1, Math.abs(time))); i >= 0; i--) {
        if (d.times[i] < time && takes(i)) { return d.times[i]; }
      }
    } else {
      for (let i = Math.max(0, indexAt(d.times, time) + 1); i < d.times.length; i++) {
        if (takes(i)) { return d.times[i]; }
      }
    }
    return null;
  }

  // Nodes and edges to draw: the model's, the dump's codes and transitions it lacks, and a layer
  // for each node (breadth first from the reset state; unreached ones below).
  function graph(model, d) {
    const nodes = [];
    const byBits = new Map();
    const addNode = (bits, name, listed) => {
      if (byBits.has(bits)) { return byBits.get(bits); }
      const node = { bits, name: name || '', listed, visits: d ? d.visits.get(bits) || 0 : 0 };
      nodes.push(node);
      byBits.set(bits, node);
      return node;
    };
    (model.states || []).forEach((s) => addNode(String(s.bits), s.name, true));
    const edges = transitionsOf(model).map((t) => Object.assign(t, { observed: model.engine === 'observed' }));
    const seen = new Set(edges.map((e) => e.from + '>' + e.to));
    if (d) {
      Array.from(d.visits.keys()).sort().forEach((bits) => addNode(bits, '', false));
      for (const key of Array.from(d.counts.keys()).sort()) {
        if (seen.has(key)) { continue; }
        const [from, to] = key.split('>');
        edges.push({ from, to, condition: '', observed: true });
        seen.add(key);
      }
    }
    edges.forEach((e) => {
      e.count = d && e.from !== e.to ? d.counts.get(e.from + '>' + e.to) || 0 : null;
      addNode(e.to, '', false);
      if (e.from !== '*') { addNode(e.from, '', false); }
    });
    // Layers.
    const start = model.reset && byBits.has(String(model.reset)) ? String(model.reset)
      : (edges.find((e) => e.from === '*') || {}).to || (nodes[0] && nodes[0].bits);
    const layer = new Map();
    if (start !== undefined) {
      layer.set(start, 0);
      const queue = [start];
      while (queue.length) {
        const at = queue.shift();
        for (const e of edges) {
          if (e.from === at && !layer.has(e.to)) { layer.set(e.to, layer.get(at) + 1); queue.push(e.to); }
        }
      }
    }
    let deepest = Math.max(-1, ...layer.values());
    nodes.forEach((n) => { if (!layer.has(n.bits)) { layer.set(n.bits, ++deepest); } });
    nodes.forEach((n) => { n.layer = layer.get(n.bits); });
    return { nodes, edges, byBits };
  }

  // ---- the dump's changes ----

  async function load() {
    const want = current;
    const generation = host.loadGeneration;
    const key = pathKey(want.path) + '|' + generation + '|' + want.model.width + '|' + maxChanges;
    if (data && data.key === key) { return data; }
    if (loading && loading.key === key) { return loading.promise; }
    const promise = (async () => {
      const v = await host.findLinkItem(want.path, true);
      const changes = v ? await host.signalChanges(v, maxChanges) : null;
      const width = Number(want.model.width) || (v && v.width) || 1;
      const times = new Float64Array(changes ? changes.length : 0);
      const codes = [];
      (changes || []).forEach(([t, value], i) => { times[i] = Number(t); codes.push(code(value, width)); });
      const { visits, counts } = tally(codes);
      return { key, generation, times, codes, visits, counts, missing: !v, tooMany: !!v && !changes };
    })();
    loading = { key, promise };
    try {
      const result = await promise;
      if (loading && loading.key === key) { data = result; }
      return result;
    } finally {
      if (loading && loading.key === key) { loading = null; }
    }
  }

  function markerTime() {
    const t = link.markerTime();
    return t === null || t === undefined ? null : Number(t);
  }

  function currentAt(d, time) {
    if (!d || time === null) { return { index: -1, bits: null }; }
    const i = indexAt(d.times, time);
    return { index: i, bits: i >= 0 ? d.codes[i] : null };
  }

  // ---- the pane ----

  let pane = null;
  function ensurePane() {
    if (pane) { return pane; }
    const el = document.createElement('div');
    el.id = 'fsm';
    el.hidden = true;
    const head = document.createElement('div');
    head.className = 'fsm-head';
    const title = document.createElement('span');
    title.className = 'fsm-title';
    const close = document.createElement('span');
    close.className = 'fsm-close codicon codicon-close';
    close.setAttribute('role', 'button');
    close.addEventListener('click', hide);
    head.append(title, close);
    const signal = document.createElement('div');
    signal.className = 'fsm-signal';
    const now = document.createElement('div');
    now.className = 'fsm-current';
    const body = document.createElement('div');
    body.className = 'fsm-body';
    const foot = document.createElement('div');
    foot.className = 'fsm-note';
    const countsNote = document.createElement('div');
    countsNote.className = 'fsm-note fsm-counts-note';
    const grip = document.createElement('div');
    grip.className = 'fsm-grip';
    grip.setAttribute('role', 'separator');
    grip.setAttribute('aria-orientation', 'vertical');
    grip.addEventListener('mousedown', startResize);
    el.append(grip, head, signal, now, body, countsNote, foot);
    if (width) { el.style.width = width + 'px'; }
    body.addEventListener('click', onClick);
    document.getElementById('panes').appendChild(el);
    pane = { el, title, close, grip, signal, now, body, countsNote, foot };
    return pane;
  }

  // The grip on the pane's left edge: dragging it left widens the pane (up to 70% of the panes).
  function startResize(event) {
    if (event.button !== 0 || !pane) { return; }
    event.preventDefault();
    const startX = event.clientX;
    const startW = pane.el.getBoundingClientRect().width;
    const room = pane.el.parentElement ? pane.el.parentElement.getBoundingClientRect().width : Infinity;
    pane.el.classList.add('resizing');
    const move = (e) => {
      const next = Math.round(Math.max(MIN_WIDTH, Math.min(room * 0.7, startW + (startX - e.clientX))));
      pane.el.style.width = next + 'px';
      width = next;
    };
    const up = (e) => {
      move(e);
      window.removeEventListener('mousemove', move, true);
      window.removeEventListener('mouseup', up, true);
      pane.el.classList.remove('resizing');
      try { sessionStorage.setItem('cmux.fsm.width', String(width)); } catch (error) { /* not kept */ }
    };
    window.addEventListener('mousemove', move, true);
    window.addEventListener('mouseup', up, true);
  }

  function svgEl(name, attrs, parent) {
    const el = document.createElementNS(SVG, name);
    Object.entries(attrs || {}).forEach(([k, v]) => el.setAttribute(k, String(v)));
    if (parent) { parent.appendChild(el); }
    return el;
  }

  const nodeLabel = (n) => n.name || n.bits;

  function draw(g, d) {
    const p = ensurePane();
    p.body.textContent = '';
    // Positions: a row per layer, centred.
    const layers = new Map();
    g.nodes.forEach((n) => { if (!layers.has(n.layer)) { layers.set(n.layer, []); } layers.get(n.layer).push(n); });
    const widest = Math.max(1, ...Array.from(layers.values()).map((l) => l.length));
    const hasReset = g.edges.some((e) => e.from === '*');
    const top = MARGIN + (hasReset ? 30 : 0);
    const loopRoom = 120;
    const totalW = MARGIN * 2 + widest * NODE_W + (widest - 1) * COLUMN_GAP + loopRoom;
    const layerCount = Math.max(1, ...g.nodes.map((n) => n.layer + 1));
    const totalH = top + layerCount * NODE_H + (layerCount - 1) * (LAYER_GAP - NODE_H) + MARGIN;
    for (const [, list] of layers) {
      list.sort((a, b) => (a.listed === b.listed ? a.bits.localeCompare(b.bits) : a.listed ? -1 : 1));
      const rowW = list.length * NODE_W + (list.length - 1) * COLUMN_GAP;
      list.forEach((n, i) => {
        n.x = MARGIN + (totalW - loopRoom - MARGIN * 2 - rowW) / 2 + i * (NODE_W + COLUMN_GAP);
        n.y = top + n.layer * LAYER_GAP;
      });
    }
    const svg = svgEl('svg', { width: totalW, height: totalH, viewBox: `0 0 ${totalW} ${totalH}`, class: 'fsm-graph' });
    const defs = svgEl('defs', {}, svg);
    const arrow = svgEl('marker', { id: 'fsm-arrow', viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
    svgEl('path', { d: 'M0,0 L10,5 L0,10 z', class: 'fsm-arrowhead' }, arrow);
    const edgeLayer = svgEl('g', {}, svg);
    const nodeLayer = svgEl('g', {}, svg);
    // Edges.
    const rightEdge = totalW - loopRoom;
    let backLane = 0;
    for (const e of g.edges) {
      const to = g.byBits.get(e.to);
      if (!to) { continue; }
      let path;
      let lx;
      let ly;
      if (e.from === '*') {
        const cx = to.x + NODE_W / 2;
        svgEl('circle', { cx, cy: to.y - 26, r: 4, class: 'fsm-reset-dot' }, edgeLayer);
        path = `M${cx},${to.y - 22} L${cx},${to.y}`;
        lx = cx + 6; ly = to.y - 12;
      } else {
        const from = g.byBits.get(e.from);
        if (!from) { continue; }
        if (from === to) {
          const x = from.x + NODE_W;
          const y = from.y + NODE_H / 2;
          path = `M${x},${y - 8} C${x + 34},${y - 30} ${x + 34},${y + 30} ${x},${y + 8}`;
          lx = x + 30; ly = y + 4;
        } else if (to.layer > from.layer) {
          const x1 = from.x + NODE_W / 2 + (to.x - from.x) * 0.12;
          const y1 = from.y + NODE_H;
          const x2 = to.x + NODE_W / 2 - (to.x - from.x) * 0.12;
          const y2 = to.y;
          const my = (y1 + y2) / 2;
          path = `M${x1},${y1} C${x1},${my} ${x2},${my} ${x2},${y2}`;
          lx = (x1 + x2) / 2 + 4; ly = my;
        } else {
          // Back or sideways: out on the right, round to the target's right side.
          backLane += 1;
          // Each its own lane, its label beside it at its own height.
          const out = Math.min(rightEdge + loopRoom - 40, Math.max(from.x, to.x) + NODE_W + 10 + 18 * backLane);
          const y1 = from.y + NODE_H / 2 + 6;
          const y2 = to.y + NODE_H / 2 - 6;
          path = `M${from.x + NODE_W},${y1} C${out},${y1} ${out},${y2} ${to.x + NODE_W},${y2}`;
          lx = out - 4; ly = (y1 + y2) / 2 + (backLane % 2 ? -7 : 7) * Math.min(3, backLane);
        }
      }
      const gEdge = svgEl('g', { class: 'fsm-edge' + (e.observed ? ' observed' : ''), 'data-from': e.from, 'data-to': e.to }, edgeLayer);
      const titleEl = svgEl('title', {}, gEdge);
      titleEl.textContent = [e.condition, e.observed ? S().fsmObservedTooltip || 'Seen in the waveform; not in the model' : '']
        .filter(Boolean).join(' · ');
      svgEl('path', { d: path, class: 'fsm-hit' }, gEdge);
      svgEl('path', { d: path, class: 'fsm-line', 'marker-end': 'url(#fsm-arrow)' }, gEdge);
      const label = [e.condition, e.count ? '×' + e.count : ''].filter(Boolean).join('  ');
      if (label) {
        const t = svgEl('text', { x: lx, y: ly, class: 'fsm-edge-label' }, gEdge);
        t.textContent = label;
      }
    }
    // Nodes.
    for (const n of g.nodes) {
      const gNode = svgEl('g', { class: 'fsm-node' + (n.listed ? '' : ' unlisted'), 'data-bits': n.bits, transform: `translate(${n.x},${n.y})` }, nodeLayer);
      const titleEl = svgEl('title', {}, gNode);
      titleEl.textContent = n.listed ? n.bits : (S().fsmUnlistedTooltip || 'Not in the model') + ': ' + n.bits;
      svgEl('rect', { width: NODE_W, height: NODE_H, rx: 8, ry: 8 }, gNode);
      const name = svgEl('text', { x: NODE_W / 2, y: 16, class: 'fsm-node-name' }, gNode);
      name.textContent = nodeLabel(n);
      const sub = svgEl('text', { x: NODE_W / 2, y: 30, class: 'fsm-node-sub' }, gNode);
      sub.textContent = (n.name ? n.bits : '') + (d ? (n.name ? '  ' : '') + '×' + n.visits : '');
    }
    p.body.appendChild(svg);
    drawn = g;
  }

  // time: the marker's (a markerSet event's own time: the viewer's markerTime may not have it yet).
  function markCurrent(time) {
    if (!pane || !drawn || !current || !current.model) { return; }
    // The dump's changes as drawn; after a reload they're the old file's until render() reads the new one.
    const d = data && data.generation === host.loadGeneration ? data : null;
    const at = currentAt(d, time === undefined ? markerTime() : time);
    pane.body.querySelectorAll('.fsm-node.current, .fsm-edge.last').forEach((el) => el.classList.remove('current', 'last'));
    let text = S().fsmNoState || 'No state at the marker';
    if (at.bits !== null) {
      const node = drawn.byBits.get(at.bits);
      const el = pane.body.querySelector(`.fsm-node[data-bits="${at.bits}"]`);
      if (el) { el.classList.add('current'); }
      text = (S().fsmCurrent || 'State: %@').replace('%@', node && node.name ? `${node.name} (${at.bits})` : at.bits);
      const before = at.index > 0 ? d.codes[at.index - 1] : null;
      const from = before === null ? '*' : before;
      const edge = pane.body.querySelector(`.fsm-edge[data-from="${from}"][data-to="${at.bits}"]`);
      if (edge) { edge.classList.add('last'); }
    }
    pane.now.textContent = text;
  }

  async function render() {
    const p = ensurePane();
    const shown = current;
    p.el.hidden = false;
    p.title.textContent = S().fsmTitle || 'State Machine';
    p.close.title = S().fsmClose || 'Close';
    p.grip.title = S().fsmResize || 'Drag to resize';
    p.signal.textContent = (shown.path || []).join('.');
    p.foot.textContent = shown.note || '';
    if (!shown.model) {
      drawn = null;
      p.now.textContent = '';
      p.countsNote.textContent = '';
      p.body.textContent = '';
      const status = document.createElement('div');
      status.className = 'fsm-status';
      status.textContent = shown.status || '';
      p.body.appendChild(status);
      return;
    }
    let d = null;
    try { d = await load(); } catch (error) { host.log(error); }
    if (current !== shown) { return; }
    if (d && d.tooMany) { p.foot.textContent = [shown.note, S().fsmTooManyChanges || 'Too many changes to count.'].filter(Boolean).join(' · '); }
    const counted = d && !d.tooMany && !d.missing;
    // Phase 1 counts the dump's changes; a self loop (no change) has none.
    p.countsNote.textContent = counted ? S().fsmCountsNote || 'Counts are entries into a state and transitions taken, not clock cycles.' : '';
    draw(graph(shown.model, counted ? d : null), d);
    markCurrent();
  }

  async function onClick(event) {
    const target = event.target && event.target.closest ? event.target.closest('.fsm-edge, .fsm-node') : null;
    if (!target || !current || !current.model) { return; }
    const d = await load();
    if (d.tooMany) {
      window.cmuxUI.toast(S().fsmTooManyToSearch || 'Too many changes to search from here.', 'info');
      return;
    }
    const time = markerTime() ?? -Infinity;
    const backward = !!event.shiftKey;
    let found;
    if (target.classList.contains('fsm-edge')) {
      const from = target.getAttribute('data-from');
      const to = target.getAttribute('data-to');
      found = from === to ? null : occurrence(d, from, to, time, backward);
    } else {
      found = occurrence(d, null, target.getAttribute('data-bits'), time, backward);
    }
    if (found === null) {
      window.cmuxUI.toast(backward ? S().fsmNoEarlier || 'Not earlier in the waveform.' : S().fsmNoLater || 'Not later in the waveform.', 'info');
      return;
    }
    link.setMarker(found);
  }

  function show(info) {
    const i = info || {};
    current = { path: Array.isArray(i.path) ? i.path.map(String) : String(i.path || '').split('.'), model: i.model || null,
      note: i.note ? String(i.note) : '', status: i.status ? String(i.status) : '' };
    return render();
  }

  function hide() {
    current = null;
    drawn = null;
    if (pane) { pane.el.hidden = true; pane.body.textContent = ''; }
  }

  // refresh: asked again after a reload; cmux leaves the graph up until its answer.
  function request(path, refresh) {
    const segments = Array.isArray(path) ? path.map(String) : String(path || '').split('.');
    host.toNative(refresh ? { type: 'fsmRequest', path: segments, refresh: true } : { type: 'fsmRequest', path: segments });
  }

  // A reload (a new simulation, Auto Reload): an open pane draws the new dump's counts and state at
  // once, with the model it has, and asks cmux for the model again (the design may have changed too).
  host.openedListeners.push(() => {
    if (!current) { return; }
    if (current.model) { render(); }
    request(current.path, true);
  });

  host.viewerEventListeners.push((m) => {
    if (m.eventType !== 'markerSet') { return; }
    const time = m.eventData && Number(m.eventData.time);
    markCurrent(Number.isFinite(time) ? time : undefined);
  });

  async function state() {
    if (!current) { return { open: false, path: null, current: null, nodes: [], edges: [] }; }
    if (!current.model) { return { open: true, path: current.path.slice(), current: null, nodes: [], edges: [], status: current.status }; }
    const d = await load();
    const g = graph(current.model, d && !d.tooMany && !d.missing ? d : null);
    const at = currentAt(d, markerTime());
    const node = at.bits !== null ? g.byBits.get(at.bits) : null;
    return {
      open: true,
      path: current.path.slice(),
      current: at.bits === null ? null : { bits: at.bits, name: node && node.name ? node.name : null },
      nodes: g.nodes.map((n) => ({ bits: n.bits, name: n.name || null, visits: n.visits, listed: n.listed })),
      edges: g.edges.map((e) => ({ from: e.from, to: e.to, condition: e.condition || null, count: e.count, observed: e.observed })),
    };
  }

  // Test hook (run.sh fsm): a lower change cap; null for the default.
  function setMaxChangesForTesting(n) { maxChanges = n === null || n === undefined ? MAX_CHANGES : Number(n); }

  const api = Object.freeze({ show, hide, state, request: (path) => request(path, false), isOpen: () => !!current, setMaxChangesForTesting });
  Object.defineProperty(window.cmuxWaveform, 'fsm', { value: api, writable: false, configurable: false, enumerable: true });
})();
