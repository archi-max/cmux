// Part of cmux's waveform viewer, written for cmux. GPL-3.0, as VaporView
// (https://github.com/Lramseyer/vaporview), whose viewer it extends; see LICENSE.
//
// The netlist pane's size: a drag edge on its right side (like the state machine pane's
// grip), a thin rail when it is collapsed, and Show or Hide Netlist.
//   - Dragging the edge resizes the pane, from MIN_WIDTH to MAX_SHARE of the panes; let go
//     under COLLAPSE_BELOW and it collapses to the rail.
//   - A double-click on the edge collapses it; a click on the rail opens it again at the
//     width it had (a drag that starts on the rail opens it as wide as dragged).
//   - The width and whether it is collapsed are part of the session (cmux-commands.js keeps
//     them as `cmuxNetlist: { width, collapsed }`), so a reload, a restore and a session file
//     bring them back.
//
// window.cmuxNetlistPane:
//   toggle()             collapse or open (Show or Hide Netlist)
//   show()               open it if collapsed (searching, Show in Netlist)
//   state()              { width, collapsed }
//   apply(state)         from a session; anything malformed is ignored
//   onChange(callback)   called after the user changes it

(function () {
  const MIN_WIDTH = 120;
  const COLLAPSE_BELOW = 60;
  const MAX_SHARE = 0.6;
  const DEFAULT_WIDTH = 220;
  // A press that moves less than this is a click.
  const CLICK_SLOP = 3;

  const strings = () => (window.cmuxWaveform && window.cmuxWaveform.strings) || {};
  let pane = null;
  let grip = null;
  let width = DEFAULT_WIDTH;
  let collapsed = false;
  let changed = () => {};

  function room() {
    const panes = pane && pane.parentElement;
    const w = panes ? panes.getBoundingClientRect().width : 0;
    return w > 0 ? w * MAX_SHARE : Infinity;
  }
  const clamp = (w) => Math.round(Math.max(MIN_WIDTH, Math.min(room(), w)));

  function draw() {
    if (!pane) { return; }
    pane.classList.toggle('collapsed', collapsed);
    pane.style.width = collapsed ? '' : width + 'px';
    if (grip) {
      grip.title = (collapsed ? strings().netlistRail : strings().netlistGrip) || '';
      grip.setAttribute('aria-expanded', String(!collapsed));
    }
  }

  function set(next, notify) {
    const w = Number.isFinite(next.width) ? clamp(next.width) : width;
    const c = typeof next.collapsed === 'boolean' ? next.collapsed : collapsed;
    if (w === width && c === collapsed) { return; }
    width = w;
    collapsed = c;
    draw();
    if (notify) { changed(); }
  }

  function startDrag(event) {
    if (event.button !== 0 || !pane) { return; }
    event.preventDefault();
    const startX = event.clientX;
    const wasCollapsed = collapsed;
    const startW = collapsed ? 0 : pane.getBoundingClientRect().width;
    let moved = false;
    // The viewer frame takes no pointer events while dragging (body.cmux-netlist-resizing):
    // over it the host page would see neither the moves nor the release.
    pane.classList.add('resizing');
    document.body.classList.add('cmux-netlist-resizing');
    const follow = (e) => {
      if (Math.abs(e.clientX - startX) >= CLICK_SLOP) { moved = true; }
      if (!moved) { return; }
      const w = startW + (e.clientX - startX);
      pane.classList.toggle('collapsed', w < COLLAPSE_BELOW);
      pane.style.width = w < COLLAPSE_BELOW ? '' : clamp(w) + 'px';
    };
    const end = (e) => {
      window.removeEventListener('mousemove', move, true);
      window.removeEventListener('mouseup', up, true);
      window.removeEventListener('blur', blur);
      pane.classList.remove('resizing');
      document.body.classList.remove('cmux-netlist-resizing');
      if (!e) { draw(); return; }
      if (moved) {
        const w = startW + (e.clientX - startX);
        // Collapsed by dragging: it opens again at the width it had before the drag.
        if (w < COLLAPSE_BELOW) { set({ collapsed: true }, true); } else { set({ width: w, collapsed: false }, true); }
      } else if (wasCollapsed) {
        set({ collapsed: false }, true);
      } else if (e.detail >= 2) {
        set({ collapsed: true }, true);
      }
    };
    // A move with no button held: the release happened where the page didn't see it.
    const move = (e) => { if (e.buttons === 0) { end(e); } else { follow(e); } };
    const up = (e) => { follow(e); end(e); };
    const blur = () => end(null);
    window.addEventListener('mousemove', move, true);
    window.addEventListener('mouseup', up, true);
    window.addEventListener('blur', blur);
  }

  function install() {
    pane = document.getElementById('netlist');
    if (!pane || grip) { return; }
    grip = document.createElement('div');
    grip.className = 'netlist-grip';
    grip.setAttribute('role', 'separator');
    grip.setAttribute('aria-orientation', 'vertical');
    grip.addEventListener('mousedown', startDrag);
    pane.appendChild(grip);
    draw();
  }

  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', install); } else { install(); }

  window.cmuxNetlistPane = {
    toggle: () => set({ collapsed: !collapsed }, true),
    show: () => set({ collapsed: false }, true),
    state: () => ({ width, collapsed }),
    apply: (state) => {
      if (!state || typeof state !== 'object') { return; }
      set({ width: Number(state.width), collapsed: state.collapsed }, false);
    },
    onChange: (callback) => { changed = typeof callback === 'function' ? callback : () => {}; },
    // The strings come with each file: the edge's tooltip follows them.
    refresh: draw,
  };
})();
