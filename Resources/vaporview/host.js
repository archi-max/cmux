// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), src/extension_core/document.ts@59107c6 and src/extension_core/viewer_provider.ts@59107c6.
//
// The extension-host half of VaporView for cmux: reads the waveform through a
// backend, answers the viewer frame's messages, and draws the netlist (VS Code
// shows it in a native TreeView, outside the webview).
//
// Backends: wellen (VCD/FST/GHW, the wasm parser in wellen-worker.js reading
// the served file) and fsdb (Verdi's reader in cmux's FSDB helper on the SSH
// host, reached through POST requests to the served fsdb URL).
//
// cmux drives this page through window.cmuxWaveform:
//   open({ url, size, format, strings, fsdb: { url, path } | undefined })
//   setTheme({ kind, background, foreground })
//   setStatus({ title, detail })   progress while cmux prepares the FSDB helper
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
  let backend = null;
  const doc = { uri: '', documentId: 'cmux-waveform', metadata: null, netlist: [] };
  let webviewReady = false;
  let initSent = false;
  // Per-signal load timings, newest last (read by tests and the debug inspector).
  const stats = [];

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

  function setStatus(status) {
    if (doc.metadata) { return; }
    showMessage(status.title, status.detail);
  }

  function fail(error) {
    const detail = String((error && error.message) || error);
    showMessage(strings.openFailed, detail);
    toNative({ type: 'error', message: detail });
  }

  function toWebview(msg) {
    if (iframe.contentWindow) { iframe.contentWindow.postMessage(msg, '*'); }
  }

  // The one path value changes take into the viewer (update-waveform-chunk,
  // its compressed form, update-enum-chunk). The frame is same-origin, so the
  // message event is dispatched on its window directly: postMessage would
  // structured-clone a signal's whole array of [time, value] pairs.
  function deliverValueChanges(msg) {
    const frameWindow = iframe.contentWindow;
    if (!frameWindow) { return; }
    frameWindow.dispatchEvent(new frameWindow.MessageEvent('message', { data: msg }));
  }

  // ---- wellen backend (VCD, FST, GHW) ----
  function wellenBackend(config) {
    const worker = new Worker('wellen-worker.js');
    let nextCallId = 1;
    const pending = new Map();
    worker.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'toWebview') {
        if (/^update-(waveform|enum)-chunk/.test(m.msg.command)) { deliverValueChanges(m.msg); } else { toWebview(m.msg); }
        return;
      }
      if (m.type === 'log') { toNative({ type: 'log', message: m.text }); return; }
      if (m.type === 'result') {
        const p = pending.get(m.id);
        pending.delete(m.id);
        if (!p) { return; }
        if (m.error) { p.reject(new Error(m.error)); } else { p.resolve(m.result); }
      }
    };
    worker.onerror = (e) => { fail(e.message); };
    function call(method, args) {
      const id = nextCallId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        worker.postMessage({ id, method, args });
      });
    }

    return {
      async open(showTop) {
        await call('init', { wasmUrl: 'filehandler.wasm' });
        const header = await call('loadfile', { url: config.url, size: config.size, format: config.format });
        // The netlist is usable while wellen reads the body.
        showTop(header.top);
        const body = await call('readbody');
        return body.metadata;
      },
      async children(item) {
        const out = [];
        let start = 0;
        for (;;) {
          const r = await call('getchildren', { id: item.id, startIndex: start });
          (r.scopes || []).forEach((s) => out.push({ kind: 'scope', name: s.name, id: s.id, type: s.type }));
          (r.vars || []).forEach((v) => out.push({ kind: 'var', ...v, encoding: String(v.encoding).split('(')[0] }));
          start += r.totalReturned;
          if (!r.totalReturned || r.remainingItems <= 0) { break; }
        }
        return out;
      },
      async fetch(requestList) {
        const signals = requestList.filter((r) => r.type === 'signal').map((r) => r.signalId);
        const enums = requestList.filter((r) => r.type === 'enum').map((r) => r.netlistId);
        if (enums.length) { await call('getenumdata', { netlistIds: enums }); }
        // The worker delivers the data itself (worker.onmessage above).
        if (signals.length) { await call('getsignaldata', { signalIds: signals }); }
      },
    };
  }

  // ---- fsdb backend (Verdi's reader on the SSH host) ----

  const charStrings = Array.from({ length: 256 }, (_, c) => String.fromCharCode(c));

  // A Map key for the value chars at raw[v0, v0 + width). Pure 0/1 values up
  // to 52 bits are their exact number; anything else (x, z, wider) gets a
  // negative 52-bit hash that the caller checks byte for byte.
  function valueKey(raw, v0, width) {
    if (width <= 52) {
      let key = 0, j = 0;
      for (; j < width; j++) {
        const bit = raw[v0 + j] - 48;
        if (bit !== 0 && bit !== 1) { break; }
        key = key * 2 + bit;
      }
      if (j === width) { return key; }
    }
    let h1 = 0x811c9dc5, h2 = 0x9747b28c;
    for (let j = 0; j < width; j++) {
      const c = raw[v0 + j];
      h1 = Math.imul(h1 ^ c, 0x01000193);
      h2 = Math.imul(h2 ^ c, 0x5bd1e995);
      h2 ^= h2 >>> 15;
    }
    return -1 - ((h1 >>> 0) * 1048576 + (h2 & 0xfffff));
  }

  // Inflated records [u64 LE delta time][width value chars] -> [[time, value], ...].
  // Values repeat a lot (PCs, instructions, states), so equal values share one
  // string, found by valueKey: no string is built per record.
  function decodeRecords(raw, width) {
    const rec = 8 + width;
    const count = raw.length / rec;
    const out = new Array(count);
    const dv = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
    const interned = new Map();
    let time = 0;
    for (let i = 0, k = 0; k < count; i += rec, k++) {
      time += dv.getUint32(i, true) + dv.getUint32(i + 4, true) * 4294967296;
      const v0 = i + 8;
      let value;
      if (width === 1) {
        value = charStrings[raw[v0]];
      } else {
        const key = valueKey(raw, v0, width);
        value = interned.get(key);
        let same = value !== undefined;
        if (key < 0) {
          for (let j = 0; same && j < width; j++) { same = value.charCodeAt(j) === raw[v0 + j]; }
        }
        if (!same) {
          value = String.fromCharCode.apply(null, raw.subarray(v0, v0 + width));
          interned.set(key, value);
        }
      }
      out[k] = [time, value];
    }
    return out;
  }

  async function inflateRaw(bytes) {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  function fsdbBackend(config) {
    // A reply is JSON ({result} or {error}), or for signal data
    // [u32 LE header length][header JSON][deflate-raw records].
    async function request(req) {
      const response = await fetch(config.fsdb.url, { method: 'POST', body: JSON.stringify(req) });
      const all = new Uint8Array(await response.arrayBuffer());
      let reply, bin = null;
      if ((response.headers.get('content-type') || '').startsWith('application/octet-stream')) {
        const headLength = new DataView(all.buffer).getUint32(0, true);
        reply = JSON.parse(new TextDecoder().decode(all.subarray(4, 4 + headLength)));
        bin = all.subarray(4 + headLength);
      } else {
        reply = JSON.parse(new TextDecoder().decode(all));
      }
      if (reply.error) { throw new Error(reply.error); }
      return { result: reply.result, helperMs: reply.ms || 0, bin, wireBytes: all.length };
    }

    return {
      async open(showTop) {
        const { result } = await request({ cmd: 'open', file: config.fsdb.path });
        showTop(result.top.map((t) => ({ kind: 'scope', name: t.name, id: t.scopeOffsetIdx, type: t.type })));
        return result.metadata;
      },
      async children(item) {
        const scopePath = item.scopePath.concat([item.name]).join('.');
        const { result } = await request({ cmd: 'children', scopeOffsetIdx: item.id, scopePath });
        return result.scopes.map((s) => ({ kind: 'scope', name: s.name, id: s.scopeOffsetIdx, type: s.type }))
          .concat(result.vars.map((v) => ({ kind: 'var', ...v })));
      },
      async fetch(requestList) {
        const signals = requestList.filter((r) => r.type === 'signal');
        if (!signals.length) { return; }
        const t0 = performance.now();
        const { result, bin, helperMs, wireBytes } = await request({ cmd: 'signals',
          signalIds: signals.map((r) => r.signalId), widths: signals.map((r) => r.signalWidth) });
        const fetchMs = performance.now() - t0;
        let offset = 0;
        for (const d of result) {
          const t1 = performance.now();
          let changes = d.valueChanges;
          let t2 = t1;
          if (!changes) {
            const raw = await inflateRaw(bin.subarray(offset, offset + d.bytes));
            offset += d.bytes;
            t2 = performance.now();
            changes = decodeRecords(raw, d.width);
          }
          const t3 = performance.now();
          deliverValueChanges({ command: 'update-waveform-chunk', signalId: d.signalId, transitionDataChunk: changes,
            totalChunks: 1, chunkNum: 0, min: d.min, max: d.max });
          const entry = { signalId: d.signalId, changes: changes.length, fetchMs: Math.round(fetchMs),
            helperMs: Math.round(helperMs), wireBytes, inflateMs: Math.round(t2 - t1), decodeMs: Math.round(t3 - t2),
            deliverMs: Math.round(performance.now() - t3) };
          stats.push(entry);
          toNative({ type: 'log', message: 'fsdb signal ' + JSON.stringify(entry) });
        }
      },
    };
  }

  // ---- viewer frame ----
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
    fetchDataFromFile: async (m) => { if (backend) { await backend.fetch(m.requestList); } },
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
    const scopePath = item.scopePath.concat([item.name]);
    const out = (await backend.children(item)).map((c) => ({ ...c, scopePath }));
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

  // Finds a netlist variable by its dotted path ("top.cpu.pc"), expanding scopes on the way.
  async function findVariable(path) {
    const parts = path.split('.');
    let items = doc.netlist;
    for (let i = 0; i < parts.length; i++) {
      const item = items.find((x) => x.name === parts[i]);
      if (!item) { return null; }
      if (i === parts.length - 1) { return item.kind === 'var' ? item : null; }
      if (item.kind !== 'scope') { return null; }
      items = await getChildren(item);
    }
    return null;
  }

  async function addVariableByPath(path) {
    const v = await findVariable(path);
    if (v) { addVariable(v); }
    return !!v;
  }

  // ---- open ----
  async function open(config) {
    strings = config.strings || {};
    document.getElementById('netlist-title').textContent = strings.netlist || '';
    doc.uri = config.url;
    if (config.format === 'fsdb' && !config.fsdb) {
      showMessage(strings.fsdbNeedsRemoteTitle, strings.fsdbNeedsRemoteDetail);
      return;
    }
    showMessage(strings.loading, '');
    backend = config.format === 'fsdb' ? fsdbBackend(config) : wellenBackend(config);
    try {
      const metadata = await backend.open((top) => {
        doc.netlist = top.map((t) => ({ ...t, scopePath: [] }));
        renderTree(doc.netlist, treeEl, 0);
      });
      doc.metadata = metadata;
      showMessage('', '');
      iframe.src = 'viewer.html';
      iframe.addEventListener('load', sendInit, { once: true });
    } catch (error) {
      fail(error);
    }
  }

  // ---- source link (SystemVerilog editor <-> waveform) ----
  // cmux calls these through callAsyncJavaScript. Paths are dump paths
  // ("top_tb.dut.pc"); cmux maps them to and from design paths.
  //   scopeChildren(path) -> [{ name, isScope }] | null   ('' lists the tops)
  //   hasSignal(path) -> bool
  //   addSignal(path) -> bool   adds it unless shown, then selects it
  //   selectSignal(path) -> bool
  //   setMarker(time)
  //   selectedSignal() -> path | null
  // and posts { type: 'revealInSource', path } when a signal's name is double-clicked.
  const link = (() => {
    let selectedPath = null;

    webviewHandlers.emitEvent = (m) => {
      if (m.eventType === 'signalSelect' && m.eventData && m.eventData.instancePath) {
        selectedPath = m.eventData.instancePath[0] || null;
      }
    };

    async function scopeChildren(path) {
      if (!backend) { return null; }
      let items = doc.netlist;
      for (const part of path ? path.split('.') : []) {
        const item = items.find((x) => x.name === part);
        if (!item || item.kind !== 'scope') { return null; }
        items = await getChildren(item);
      }
      return items.map((x) => ({ name: x.name, isScope: x.kind === 'scope' }));
    }

    function isShown(v) {
      const shown = (viewerContext.webview && viewerContext.webview.displayedSignals) || [];
      return shown.some((s) => s.netlistId === v.netlistId);
    }

    async function selectSignal(path) {
      const v = await findVariable(path);
      if (!v || !initSent) { return false; }
      toWebview({ command: 'setSelectedSignal', netlistId: v.netlistId });
      return true;
    }

    async function addSignal(path) {
      const v = await findVariable(path);
      if (!v || !initSent) { return false; }
      if (!isShown(v)) { addVariable(v); }
      // add-variable is handled before this message, so the new row exists.
      toWebview({ command: 'setSelectedSignal', netlistId: v.netlistId });
      return true;
    }

    // Double-click on a signal's name in the viewer's label column.
    function attachToFrame() {
      const frameDocument = iframe.contentDocument;
      if (!frameDocument) { return; }
      frameDocument.addEventListener('dblclick', (e) => {
        const label = e.target && e.target.closest && e.target.closest('.waveform-label');
        if (!label) { return; }
        let context;
        try {
          context = JSON.parse((label.getAttribute('data-vscode-context') || '').replace(/%x20/g, ' '));
        } catch (error) {
          return;
        }
        if (context.webviewSection !== 'signal' || !context.signalName) { return; }
        const path = context.scopePath ? context.scopePath + '.' + context.signalName : context.signalName;
        toNative({ type: 'revealInSource', path });
      });
    }
    iframe.addEventListener('load', attachToFrame);

    return {
      scopeChildren,
      hasSignal: async (path) => !!(await findVariable(path)),
      addSignal,
      selectSignal,
      setMarker: (time) => { toWebview({ command: 'setMarker', time: Number(time), markerType: 0 }); },
      selectedSignal: () => selectedPath,
    };
  })();

  window.cmuxWaveform = { open, setTheme, setStatus, applyThemeTo, fromWebview, viewerContext, commandHandlers,
    deliverValueChanges, addVariableByPath, stats, link };
  applyThemeTo(document);
  toNative({ type: 'ready' });
})();
