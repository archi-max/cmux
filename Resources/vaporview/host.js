// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/extension_core/document.ts@59107c6 and src/extension_core/viewer_provider.ts@59107c6.
//
// The extension-host half of VaporView for cmux: owns the wellen worker,
// answers the viewer frame's messages, and draws the netlist (VS Code shows
// it in a native TreeView, outside the webview).
//
// cmux drives this page through window.cmuxWaveform:
//   open({ url, size, format, strings })  start loading the served file
//   setTheme({ kind, background, foreground })
// and hears back on window.webkit.messageHandlers.cmuxWaveform:
//   { type: 'ready' } | { type: 'opened' } | { type: 'error', message }
//   { type: 'copy', text } | { type: 'log', message }

(function () {
  const nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmuxWaveform;
  const toNative = (msg) => { if (nativeHandler) { nativeHandler.postMessage(msg); } };

  const iframe = document.getElementById('viewer');
  const treeEl = document.getElementById('tree');
  const messageEl = document.getElementById('message');

  let theme = { kind: 'dark', background: null, foreground: null };
  let strings = {};
  let worker = null;
  let nextCallId = 1;
  const pending = new Map();
  const doc = { uri: '', documentId: 'cmux-waveform', metadata: null, netlist: [] };
  let webviewReady = false;
  let initSent = false;

  // ---- theme ----
  function applyThemeTo(targetDocument) {
    const root = targetDocument.documentElement;
    root.setAttribute('data-cmux-theme', theme.kind);
    for (const [name, value] of [
      ['--vscode-editor-background', theme.background],
      ['--vscode-foreground', theme.foreground],
      ['--vscode-editor-foreground', theme.foreground],
      // VaporView reads this one from the root's inline style, as VS Code sets it.
      ['--vscode-editorOverviewRuler-selectionHighlightForeground', 'rgba(160, 160, 160, 0.8)'],
    ]) {
      if (value) { root.style.setProperty(name, value); } else { root.style.removeProperty(name); }
    }
  }

  function setTheme(next) {
    theme = { kind: next.kind === 'light' ? 'light' : 'dark', background: next.background || null, foreground: next.foreground || null };
    applyThemeTo(document);
    const frameDocument = iframe.contentDocument;
    if (frameDocument && frameDocument.documentElement) {
      applyThemeTo(frameDocument);
      // VaporView re-reads the CSS variables and repaints its canvases.
      toWebview({ command: 'updateColorPalette', colorPalette: [], errorColorPalette: ['#C00000'], themeValid: false });
    }
  }

  // ---- messages ----
  function showMessage(title, detail) {
    messageEl.querySelector('.title').textContent = title || '';
    messageEl.querySelector('.detail').textContent = detail || '';
    messageEl.classList.toggle('visible', !!(title || detail));
  }

  function fail(error) {
    const detail = String((error && error.message) || error);
    showMessage(strings.openFailed, detail);
    toNative({ type: 'error', message: detail });
  }

  function toWebview(msg) {
    if (iframe.contentWindow) { iframe.contentWindow.postMessage(msg, '*'); }
  }

  function call(method, args) {
    const id = nextCallId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      worker.postMessage({ id, method, args });
    });
  }

  function startWorker() {
    worker = new Worker('wellen-worker.js');
    worker.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'toWebview') { toWebview(m.msg); return; }
      if (m.type === 'log') { toNative({ type: 'log', message: m.text }); return; }
      if (m.type === 'result') {
        const p = pending.get(m.id);
        pending.delete(m.id);
        if (!p) { return; }
        if (m.error) { p.reject(new Error(m.error)); } else { p.resolve(m.result); }
      }
    };
    worker.onerror = (e) => { fail(e.message); };
  }

  function sendInit() {
    if (initSent || !webviewReady || !doc.metadata || !doc.metadata.timeTableLoaded) { return; }
    initSent = true;
    toWebview({ command: 'setConfigSettings', scrollingMode: 'Auto', rulerLines: true, enableAnimations: true,
      animationDuration: 50, defaultTimeUnit: 'none', defaultNameType: 'fullPath',
      customColorPalette: ['#CCCCCC', '#CCCCCC', '#CCCCCC', '#CCCCCC'] });
    toWebview({ command: 'initViewport', metadata: doc.metadata, documentId: doc.documentId, uri: doc.uri,
      colorPalette: [], errorColorPalette: ['#C00000'], themeValid: false, autoReload: false });
  }

  // What VS Code would hold for its menus and keybindings: the context keys the
  // webview sets (setContext) and its latest webview context (contextUpdate:
  // selected rows, markers, the right-clicked item). An in-page context menu
  // and keyboard layer can read these later.
  const viewerContext = { keys: {}, webview: null };

  // VS Code commands the webview executes (executeCommand). Only setContext is
  // handled; menu and keybinding commands can register here.
  const commandHandlers = {
    setContext: ([key, value]) => { viewerContext.keys[key] = value; },
  };

  const webviewHandlers = {
    ready: () => { webviewReady = true; sendInit(); },
    initialized: () => { toNative({ type: 'opened' }); },
    fetchDataFromFile: async (m) => {
      const signals = m.requestList.filter((r) => r.type === 'signal').map((r) => r.signalId);
      const enums = m.requestList.filter((r) => r.type === 'enum').map((r) => r.netlistId);
      if (enums.length) { await call('getenumdata', { netlistIds: enums }); }
      if (signals.length) { await call('getsignaldata', { signalIds: signals }); }
    },
    contextUpdate: (m) => { viewerContext.webview = m; },
    executeCommand: (m) => {
      const handler = commandHandlers[m.commandName];
      if (handler) { handler(m.args || []); }
    },
    copyToClipboard: (m) => { toNative({ type: 'copy', text: String(m.text || '') }); },
    logOutput: (m) => { toNative({ type: 'log', message: String(m.message) }); },
    // restoreState, emitEvent, showMessage, updateConfiguration, handleDrop and
    // focus have no cmux counterpart yet.
  };

  async function fromWebview(m) {
    const handler = webviewHandlers[m.command];
    if (!handler) { return; }
    try {
      await handler(m);
    } catch (error) {
      fail(error);
    }
  }

  // ---- netlist ----
  async function getChildren(item) {
    if (item.children) { return item.children; }
    const out = [];
    const scopePath = item.scopePath.concat([item.name]);
    let start = 0;
    for (;;) {
      const r = await call('getchildren', { id: item.id, startIndex: start });
      (r.scopes || []).forEach((s) => out.push({ kind: 'scope', name: s.name, id: s.id, type: s.type, scopePath }));
      (r.vars || []).forEach((v) => out.push({ kind: 'var', ...v, encoding: String(v.encoding).split('(')[0], scopePath }));
      start += r.totalReturned;
      if (!r.totalReturned || r.remainingItems <= 0) { break; }
    }
    item.children = out;
    return out;
  }

  function addVariable(v) {
    toWebview({ command: 'add-variable', signalList: [{ signalId: v.signalId, signalWidth: v.width, signalName: v.name,
      scopePath: v.scopePath, netlistId: v.netlistId, type: v.type, encoding: v.encoding, enumType: v.enumType,
      msb: v.msb, lsb: v.lsb }], groupPath: undefined, index: undefined });
  }

  function renderTree(items, container, depth) {
    for (const it of items) {
      const row = document.createElement('div');
      row.className = 'row ' + it.kind;
      row.style.paddingLeft = 6 + depth * 12 + 'px';
      row.textContent = it.name;
      if (it.kind === 'var' && it.width > 1) {
        const range = document.createElement('span');
        range.className = 'range';
        range.textContent = ` [${it.msb}:${it.lsb}]`;
        row.appendChild(range);
      }
      container.appendChild(row);
      if (it.kind === 'scope') {
        const kids = document.createElement('div');
        container.appendChild(kids);
        row.onclick = async () => {
          try {
            if (row.classList.toggle('open')) { renderTree(await getChildren(it), kids, depth + 1); } else { kids.textContent = ''; }
          } catch (error) {
            fail(error);
          }
        };
        if (depth < 1) { row.click(); }
      } else {
        row.title = strings.addSignal || '';
        row.onclick = () => addVariable(it);
      }
    }
  }

  // ---- open ----
  async function open(config) {
    strings = config.strings || {};
    document.getElementById('netlist-title').textContent = strings.netlist || '';
    showMessage(strings.loading, '');
    doc.uri = config.url;
    startWorker();
    try {
      await call('init', { wasmUrl: 'filehandler.wasm' });
      const header = await call('loadfile', { url: config.url, size: config.size, format: config.format });
      doc.netlist = header.top.map((t) => ({ ...t, scopePath: [] }));
      renderTree(doc.netlist, treeEl, 0);
      const body = await call('readbody');
      doc.metadata = body.metadata;
      showMessage('', '');
      iframe.src = 'viewer.html';
      iframe.addEventListener('load', sendInit, { once: true });
    } catch (error) {
      fail(error);
    }
  }

  window.cmuxWaveform = { open, setTheme, applyThemeTo, fromWebview, viewerContext, commandHandlers };
  applyThemeTo(document);
  toNative({ type: 'ready' });
})();
