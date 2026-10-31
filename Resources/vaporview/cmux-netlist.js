// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/extension_core/tree_view.ts@59107c6 and the NetlistSearchQuickPick in src/extension_core/document.ts@59107c6.
//
// The netlist panel VS Code shows as a TreeView next to the viewer: a lazy
// scope/variable tree with selection, inline add and show-in-viewer buttons,
// the netlist item context menu, drag into the viewer, and search over the
// whole hierarchy (or one scope) by instance path.
//
// Data comes only through the host (window.cmuxWaveform.host): getChildren,
// search and addVariables, so the tree does not care which backend reads the
// file.
//
// window.cmuxNetlist:
//   render(topItems)            draw the top level (expands the first level)
//   clear()
//   reveal(netlistId)           expand to a loaded variable and select it
//   focusSearch(scopeItem?)     Cmd+F / Search Scope
//   setDisplayed(netlistIds)    mark the variables shown in the viewer
//   selectedItems()

(function () {
  const host = () => window.cmuxWaveform.host;
  const strings = () => window.cmuxWaveform.strings || {};

  let treeEl = null;
  let resultsEl = null;
  let searchInput = null;
  let searchScopeEl = null;
  let searchScope = null;
  let topItems = [];
  let displayed = new Set();
  let selected = [];
  let lastClicked = null;
  const rowsByItem = new Map();

  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }

  function bitRange(item) {
    if (item.kind !== 'var' || item.msb === undefined || item.msb < 0 || (item.width <= 1 && item.msb === item.lsb && item.msb <= 0)) { return ''; }
    return item.msb === item.lsb ? `[${item.msb}]` : `[${item.msb}:${item.lsb}]`;
  }

  function instancePath(item) {
    return item.scopePath.concat([item.name]).join('.');
  }

  function sortChildren(items) {
    const settings = window.cmuxCommands && window.cmuxCommands.settings();
    if (!settings || !settings.sortNetlist) { return items; }
    // VaporView sorts scopes first, then parameters, then the other variables, each by name.
    const rank = (x) => (x.kind === 'scope' ? 0 : x.type === 'Parameter' ? 1 : 2);
    return items.slice().sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name, undefined, { numeric: true }));
  }

  // ---- tree ----
  function init() {
    if (treeEl) { return; }
    treeEl = document.getElementById('tree');
    const bar = document.getElementById('netlist-search');
    searchInput = bar.querySelector('input');
    searchScopeEl = bar.querySelector('.scope');
    resultsEl = document.getElementById('netlist-results');
    searchInput.placeholder = strings().netlistSearchPlaceholder || '';
    searchInput.addEventListener('input', () => runSearch());
    searchInput.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        if (searchInput.value) { searchInput.value = ''; runSearch(); } else { setSearchScope(null); searchInput.blur(); }
      } else if (e.key === 'ArrowDown') {
        const first = resultsEl.querySelector('.row');
        if (first) { e.preventDefault(); first.focus(); }
      } else if (e.key === 'Enter') {
        const first = resultsEl.querySelector('.row');
        if (first) { e.preventDefault(); first.click(); }
      }
    });
    bar.querySelector('.clear-scope').addEventListener('click', () => { setSearchScope(null); searchInput.focus(); });
    treeEl.addEventListener('keydown', onTreeKey);
    treeEl.tabIndex = 0;
  }

  function clear() {
    init();
    treeEl.textContent = '';
    resultsEl.textContent = '';
    rowsByItem.clear();
    selected = [];
    topItems = [];
  }

  // A search typed before (a reload, the file still opening) runs again on
  // the new netlist.
  function render(items) {
    clear();
    topItems = items;
    renderLevel(sortChildren(items), treeEl, 0, true);
    if (searchInput && searchInput.value.trim()) { runSearch(); }
  }

  function renderLevel(items, container, depth, autoExpand) {
    for (const item of items) {
      const row = makeRow(item, depth, false);
      container.appendChild(row);
      if (item.kind === 'scope') {
        const kids = document.createElement('div');
        kids.className = 'children';
        container.appendChild(kids);
        row._children = kids;
        if (autoExpand && depth < 1) { toggle(item, true); }
      }
    }
  }

  function makeRow(item, depth, isResult) {
    const row = document.createElement('div');
    row.className = 'row ' + item.kind + (displayed.has(item.netlistId) && item.kind === 'var' ? ' displayed' : '');
    row.style.paddingLeft = 6 + depth * 12 + 'px';
    row.tabIndex = -1;
    const label = document.createElement('span');
    label.className = 'name';
    label.textContent = isResult ? item.label : item.name;
    row.appendChild(label);
    const range = bitRange(item);
    if (range) {
      const r = document.createElement('span');
      r.className = 'range';
      r.textContent = ' ' + range;
      row.appendChild(r);
    }
    if (item.detail) {
      const d = document.createElement('span');
      d.className = 'detail';
      d.textContent = ' ' + item.detail;
      row.appendChild(d);
    }
    if (item.kind === 'var' && !isResult) {
      const actions = document.createElement('span');
      actions.className = 'actions';
      actions.append(
        actionButton('codicon-eye', strings()['command.showInViewer'], () => window.cmuxCommands.run('vaporview.showInViewer', item)),
        actionButton('codicon-add', strings()['command.addVariable'], () => window.cmuxCommands.run('vaporview.addVariable', item)),
      );
      row.appendChild(actions);
      row.draggable = true;
      row.addEventListener('dragstart', (e) => onDragStart(e, item));
      row.title = instancePath(item) + range;
    }
    if (!isResult) {
      rowsByItem.set(item, row);
      row._item = item;
      row.addEventListener('mousedown', (e) => { if (e.button === 0) { select(item, e); } });
      row.addEventListener('click', (e) => {
        if (e.target.closest('.actions')) { return; }
        if (item.kind === 'scope' && !e.shiftKey && !e.metaKey) { toggle(item); }
      });
      row.addEventListener('dblclick', (e) => {
        if (item.kind === 'var' && !e.target.closest('.actions')) { window.cmuxCommands.run('vaporview.addVariable', item); }
      });
      row.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        if (!selected.includes(item)) { select(item, {}); }
        window.cmuxCommands.showNetlistMenu(item, e.clientX, e.clientY);
      });
    }
    return row;
  }

  function actionButton(icon, title, onClick) {
    const b = document.createElement('span');
    b.className = 'action codicon ' + icon;
    b.title = title || '';
    b.addEventListener('mousedown', (e) => e.stopPropagation());
    b.addEventListener('click', (e) => { e.stopPropagation(); onClick(); });
    return b;
  }

  async function toggle(item, open) {
    const row = rowsByItem.get(item);
    if (!row || !row._children) { return; }
    const willOpen = open === undefined ? !row.classList.contains('open') : open;
    if (willOpen === row.classList.contains('open')) { return; }
    row.classList.toggle('open', willOpen);
    if (!willOpen) { row._children.textContent = ''; return; }
    try {
      const children = await host().getChildren(item);
      if (!row.classList.contains('open')) { return; }
      row._children.textContent = '';
      const depth = (parseInt(row.style.paddingLeft, 10) - 6) / 12 + 1;
      renderLevel(sortChildren(children), row._children, depth, false);
    } catch (error) {
      host().fail(error);
    }
  }

  function visibleRows() {
    return [...treeEl.querySelectorAll('.row')].filter((r) => r.offsetParent !== null);
  }

  function select(item, e) {
    const rows = visibleRows();
    if (e.shiftKey && lastClicked && rowsByItem.has(lastClicked)) {
      const a = rows.indexOf(rowsByItem.get(lastClicked));
      const b = rows.indexOf(rowsByItem.get(item));
      const [lo, hi] = a < b ? [a, b] : [b, a];
      selected = rows.slice(lo, hi + 1).map((r) => r._item);
    } else if (e.metaKey) {
      selected = selected.includes(item) ? selected.filter((x) => x !== item) : selected.concat([item]);
      lastClicked = item;
    } else {
      selected = [item];
      lastClicked = item;
    }
    rowsByItem.forEach((row, it) => row.classList.toggle('selected', selected.includes(it)));
    treeEl.focus({ preventScroll: true });
  }

  function onTreeKey(e) {
    const rows = visibleRows();
    const current = lastClicked && rowsByItem.get(lastClicked);
    let index = rows.indexOf(current);
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      index = Math.max(0, Math.min(rows.length - 1, index + (e.key === 'ArrowDown' ? 1 : -1)));
      if (rows[index]) { select(rows[index]._item, { shiftKey: e.shiftKey }); rows[index].scrollIntoView({ block: 'nearest' }); }
    } else if ((e.key === 'ArrowRight' || e.key === 'ArrowLeft') && lastClicked && lastClicked.kind === 'scope') {
      e.preventDefault();
      toggle(lastClicked, e.key === 'ArrowRight');
    } else if (e.key === 'Enter' && selected.length) {
      e.preventDefault();
      const vars = selected.filter((x) => x.kind === 'var');
      if (vars.length) { window.cmuxCommands.run('vaporview.addSelected'); } else if (lastClicked) { toggle(lastClicked); }
    }
  }

  // Expands the tree down to an already-loaded variable and selects it.
  async function reveal(netlistId) {
    const item = host().netlistItem(netlistId);
    if (!item) { return false; }
    clearSearch();
    let items = topItems;
    for (const name of item.scopePath) {
      const scope = items.find((x) => x.kind === 'scope' && x.name === name);
      if (!scope) { return false; }
      await toggle(scope, true);
      items = await host().getChildren(scope);
    }
    const target = items.find((x) => x.netlistId === netlistId) || item;
    const row = rowsByItem.get(target);
    if (!row) { return false; }
    select(target, {});
    row.scrollIntoView({ block: 'center' });
    return true;
  }

  function setDisplayed(netlistIds) {
    displayed = new Set(netlistIds);
    rowsByItem.forEach((row, it) => { if (it.kind === 'var') { row.classList.toggle('displayed', displayed.has(it.netlistId)); } });
  }

  // ---- drag into the viewer ----
  // VaporView's webview accepts drops whose 'codeeditors' data lists resources
  // (vscode_wrapper.ts handleDrop); host.js maps them back to netlist items.
  function onDragStart(e, item) {
    const items = selected.includes(item) ? selected.filter((x) => x.kind === 'var') : [item];
    const resources = items.map((x) => ({ resource: { scheme: 'waveform', cmuxNetlistId: x.netlistId, path: instancePath(x) } }));
    e.dataTransfer.setData('codeeditors', JSON.stringify(resources));
    e.dataTransfer.setData('text/plain', items.map((x) => instancePath(x) + bitRange(x)).join('\n'));
    e.dataTransfer.effectAllowed = 'copy';
  }

  // ---- search ----
  let searchSerial = 0;

  function setSearchScope(scope) {
    searchScope = scope;
    searchScopeEl.textContent = scope ? format(strings().netlistSearchScope, instancePath(scope)) : '';
    searchScopeEl.parentElement.classList.toggle('scoped', !!scope);
    runSearch();
  }

  function focusSearch(scope) {
    init();
    if (scope !== undefined) { setSearchScope(scope && scope.kind === 'scope' ? scope : null); }
    searchInput.focus();
    searchInput.select();
  }

  function clearSearch() {
    if (!searchInput || !searchInput.value) { return; }
    searchInput.value = '';
    runSearch();
  }

  async function runSearch() {
    const query = searchInput.value.trim();
    const serial = ++searchSerial;
    document.getElementById('netlist').classList.toggle('searching', !!query);
    resultsEl.textContent = '';
    if (!query) { return; }
    let result;
    try {
      result = await host().search(query, searchScope);
    } catch (error) {
      host().fail(error);
      return;
    }
    if (serial !== searchSerial) { return; }
    const s = strings();
    const status = document.createElement('div');
    status.className = 'search-status';
    const total = result.totalResults, shown = result.searchResults.length;
    status.textContent = total === 0 ? s.netlistNoResults
      : shown !== total ? format(s.netlistResultsShown, shown, total) : format(s.netlistResultCount, total);
    resultsEl.appendChild(status);
    const prefixLength = searchScope ? instancePath(searchScope).length : 0;
    for (const r of result.searchResults) {
      const item = {
        kind: r.isVar ? 'var' : 'scope',
        label: r.instancePath.slice(r.instancePath.lastIndexOf('.') + 1) + (r.isVar ? rangeOf(r) : ''),
        detail: (prefixLength ? '..' : '') + r.instancePath.slice(prefixLength) + (r.type ? ' · ' + r.type : ''),
      };
      const row = makeRow(item, 0, true);
      row.addEventListener('click', () => {
        if (r.isVar) {
          window.cmuxCommands.addSignalByName(r.instancePath, r.msb >= 0 ? r.msb : undefined, r.lsb >= 0 ? r.lsb : undefined);
        } else {
          searchInput.value = r.instancePath + '.';
          searchInput.focus();
          runSearch();
        }
      });
      row.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); row.click(); }
        if (e.key === 'ArrowDown' && row.nextElementSibling) { e.preventDefault(); row.nextElementSibling.focus(); }
        if (e.key === 'ArrowUp') { e.preventDefault(); (row.previousElementSibling && row.previousElementSibling.classList.contains('row') ? row.previousElementSibling : searchInput).focus(); }
      });
      resultsEl.appendChild(row);
    }
  }

  function rangeOf(r) {
    if (r.msb === undefined || r.msb < 0) { return ''; }
    return r.msb === r.lsb ? `[${r.msb}]` : `[${r.msb}:${r.lsb}]`;
  }

  window.cmuxNetlist = {
    render, clear, reveal, focusSearch, setDisplayed, instancePath, bitRange,
    selectedItems: () => selected.slice(),
  };
})();
