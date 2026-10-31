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
// The menus, keybindings, settings, sessions and status strip VS Code adds
// around the webview are in cmux-commands.js, the netlist panel in
// cmux-netlist.js, and the menu and dialog widgets in cmux-ui.js.
//
// cmux drives this page through window.cmuxWaveform:
//   open({ url, size, format, path, strings, settings, fsdb: { url, path } | undefined,
//          sessionFile: { path, text } | undefined, restore: { state, dirty, sessionPath } | undefined })
//   reload({ url, size })          reopen the file in place, keeping the signal list
//   fileChanged()                  the file changed on disk (reloads if Auto Reload is on)
//   setTheme({ kind, background, foreground })
//   setStatus({ title, detail })   progress while cmux prepares the FSDB helper
//   runCommand({ command, args })  a VaporView command id (cmux-commands.js)
//   sessionSaved({ path }) | sessionFailed({ message }) | applySessionFile({ text, path, error })
// and hears back on window.webkit.messageHandlers.cmuxWaveform:
//   { type: 'ready' } | { type: 'opened', top } | { type: 'error', message }
//   { type: 'copy', text } | { type: 'log', message } | { type: 'openURL', url }
//   { type: 'settings', values } | { type: 'sessionState', state, dirty, sessionPath }
//   { type: 'saveSession', text, suggestedName, path } | { type: 'loadSession' } | { type: 'reload' }
//   { type: 'event', eventType, eventData }   VaporView's API events (markerSet, signalSelect, ...)

(function () {
  const nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmuxWaveform;
  const toNative = (msg) => { if (nativeHandler) { nativeHandler.postMessage(msg); } };

  const iframe = document.getElementById('viewer');
  const messageEl = document.getElementById('message');

  let theme = { kind: 'dark', background: null, foreground: null };
  let strings = {};
  let backend = null;
  let config = {};
  // items: every netlist variable loaded so far, by netlistId.
  const doc = { uri: '', documentId: 'cmux-waveform', metadata: null, netlist: [], items: new Map() };
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
      search(query, scope) { return call('searchnetlist', { query, scopeId: scope ? scope.id : 0xFFFFFFFF }); },
      valuesAtTime(time, paths) { return call('getvaluesattime', { time, paths: paths.join(' ') }); },
      close() { worker.terminate(); },
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
    toWebview(window.cmuxCommands.configMessage());
    const autoReload = autoReloadState !== null ? autoReloadState : !!window.cmuxCommands.settings().defaultAutoReload;
    toWebview({ command: 'initViewport', metadata: doc.metadata, documentId: doc.documentId, uri: doc.uri,
      colorPalette: [], errorColorPalette: ['#C00000'], themeValid: false, autoReload });
  }

  // What VS Code would hold for its menus and keybindings: the context keys the
  // webview sets (setContext) and its latest webview context (contextUpdate:
  // selected rows, markers, the right-clicked item). An in-page context menu
  // and keyboard layer can read these later.
  const viewerContext = { keys: {}, webview: null };

  // VS Code commands the webview executes (executeCommand): setContext here,
  // VaporView's own commands through cmux-commands.js.
  const commandHandlers = {
    setContext: ([key, value]) => { viewerContext.keys[key] = value; },
  };

  // The Auto Reload checkbox survives an in-page reload.
  let autoReloadState = null;

  const webviewHandlers = {
    ready: () => { webviewReady = true; sendInit(); },
    initialized: () => { toNative({ type: 'opened', top: doc.netlist.map((t) => t.name) }); },
    fetchDataFromFile: async (m) => { if (backend) { await backend.fetch(m.requestList); } },
    contextUpdate: (m) => {
      viewerContext.webview = m;
      if (m.autoReload !== undefined) { autoReloadState = !!m.autoReload; }
      window.cmuxCommands.onContextUpdate(m);
    },
    restoreState: (m) => window.cmuxCommands.restoreState(m),
    executeCommand: (m) => {
      const handler = commandHandlers[m.commandName];
      if (handler) { handler(m.args || []); } else { window.cmuxCommands.run(m.commandName, (m.args || [])[0]); }
    },
    updateConfiguration: (m) => { window.cmuxCommands.updateSetting(m.property, m.value); },
    showMessage: (m) => { window.cmuxUI.toast(String(m.message || ''), m.messageType); },
    handleDrop: (m) => { window.cmuxCommands.handleDrop(m); },
    emitEvent: (m) => { toNative({ type: 'event', eventType: m.eventType, eventData: m.eventData }); },
    copyToClipboard: (m) => { toNative({ type: 'copy', text: String(m.text || '') }); },
    logOutput: (m) => { toNative({ type: 'log', message: String(m.message) }); },
    // focus (reveal the editor tab) has no cmux counterpart: the panel is already visible.
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

  // ---- netlist (drawn by cmux-netlist.js) ----
  async function getChildren(item) {
    if (item.children) { return item.children; }
    const scopePath = item.scopePath.concat([item.name]);
    const out = (await backend.children(item)).map((c) => ({ ...c, scopePath }));
    out.forEach((c) => { if (c.kind === 'var') { doc.items.set(c.netlistId, c); } });
    item.children = out;
    return out;
  }

  function addVariables(vars, groupPath, index) {
    if (!vars.length) { return; }
    toWebview({ command: 'add-variable', signalList: vars.map((v) => ({ signalId: v.signalId, signalWidth: v.width,
      signalName: v.name, scopePath: v.scopePath, netlistId: v.netlistId, type: v.type, encoding: v.encoding,
      enumType: v.enumType, msb: v.msb, lsb: v.lsb })), groupPath, index });
  }

  function addVariable(v) { addVariables([v]); }

  // Finds a netlist item by its dotted path ("top.cpu.pc"), expanding scopes
  // on the way. Of several variables with the same name (bit-blasted vectors),
  // the one with the given msb/lsb wins. varOnly: scopes do not match.
  async function findItem(path, msb, lsb, varOnly) {
    if (!path) { return null; }
    const parts = String(path).split('.');
    let items = doc.netlist;
    for (let i = 0; i < parts.length; i++) {
      const last = i === parts.length - 1;
      const named = items.filter((x) => x.name === parts[i]);
      if (last) {
        const vars = named.filter((x) => x.kind === 'var');
        const exact = msb === undefined ? null : vars.find((v) => v.msb === msb && v.lsb === (lsb === undefined ? msb : lsb));
        if (exact || vars[0]) { return exact || vars[0]; }
        return varOnly ? null : named.find((x) => x.kind === 'scope') || null;
      }
      const scope = named.find((x) => x.kind === 'scope');
      if (!scope) { return null; }
      items = await getChildren(scope);
    }
    return null;
  }

  async function findVariable(path) { return findItem(path, undefined, undefined, true); }

  async function addVariableByPath(path) {
    const v = await findVariable(path);
    if (v) { addVariable(v); }
    return !!v;
  }

  // VaporView's netlist search: wellen searches the hierarchy itself; other
  // backends walk the tree here (breadth first, bounded).
  async function search(query, scope) {
    if (backend.search) { return backend.search(query, scope); }
    const needle = query.toLowerCase();
    const results = [];
    let total = 0, visited = 0;
    const queue = scope ? [scope] : [{ kind: 'scope', name: '', scopePath: [], children: doc.netlist }];
    while (queue.length && visited < 20000) {
      const s = queue.shift();
      for (const c of await getChildren(s)) {
        visited++;
        const instancePath = c.scopePath.concat([c.name]).join('.');
        if (instancePath.toLowerCase().includes(needle)) {
          total++;
          if (results.length < 100) {
            results.push({ instancePath, isVar: c.kind === 'var', type: c.type || '', msb: c.kind === 'var' ? c.msb : -1, lsb: c.kind === 'var' ? c.lsb : -1 });
          }
        }
        if (c.kind === 'scope') { queue.push(c); }
      }
    }
    return { totalResults: total, searchResults: results };
  }

  async function valuesAtTime(time, paths) {
    if (backend.valuesAtTime) { return backend.valuesAtTime(time, paths); }
    return [];
  }

  // ---- open ----
  async function openBackend() {
    backend = config.format === 'fsdb' ? fsdbBackend(config) : wellenBackend(config);
    const metadata = await backend.open((top) => {
      doc.netlist = top.map((t) => ({ ...t, scopePath: [] }));
      doc.netlist.forEach((t) => { if (t.kind === 'var') { doc.items.set(t.netlistId, t); } });
      window.cmuxNetlist.render(doc.netlist);
    });
    doc.metadata = metadata;
    showMessage('', '');
  }

  async function open(next) {
    config = Object.assign({}, next);
    strings = config.strings || {};
    window.cmuxWaveform.strings = strings;
    document.getElementById('netlist-title').textContent = strings.netlist || '';
    document.getElementById('status-unsaved').title = strings.statusUnsaved || '';
    document.querySelector('#status-reload .text').textContent = strings.messageFileChanged || '';
    document.querySelector('#status-reload button').textContent = strings['command.reloadFile'] || '';
    window.cmuxCommands.init(config);
    doc.uri = config.url;
    if (config.format === 'fsdb' && !config.fsdb) {
      showMessage(strings.fsdbNeedsRemoteTitle, strings.fsdbNeedsRemoteDetail);
      return;
    }
    showMessage(strings.loading, '');
    try {
      await openBackend();
      iframe.src = 'viewer.html';
      iframe.addEventListener('load', () => {
        window.cmuxCommands.attachFrame(iframe.contentWindow);
        sendInit();
      }, { once: true });
    } catch (error) {
      fail(error);
    }
  }

  // VaporviewDocument.reload: unload the webview, read the file again and
  // re-initialize the viewport. The viewer frame stays, so its saved state
  // brings the same signals back (restoreState); cmux's copy covers the case
  // where the frame has none.
  async function reload(next) {
    if (!doc.metadata || !webviewReady) { return open(Object.assign({}, config, next || {})); }
    const snapshot = window.cmuxCommands.sessionSnapshot();
    config = Object.assign({}, config, next || {}, { restore: snapshot.state ? snapshot : null });
    window.cmuxCommands.willReload();
    if (backend && backend.close) { backend.close(); }
    backend = null;
    doc.metadata = null;
    doc.netlist = [];
    doc.items.clear();
    initSent = false;
    webviewReady = false;
    toWebview({ command: 'unload' });
    window.cmuxNetlist.clear();
    showMessage(strings.loading, '');
    try {
      await openBackend();
      sendInit();
    } catch (error) {
      fail(error);
    }
  }

  // What cmux-commands.js and cmux-netlist.js use. Waveform data stays behind
  // the backend; these only touch the netlist and the viewer frame.
  const hostApi = {
    doc, viewerContext, toWebview, toNative, fail, getChildren, findItem, addVariables, search, valuesAtTime,
    netlistItem: (id) => doc.items.get(id) || null,
    log: (message) => toNative({ type: 'log', message: String(message) }),
    get config() { return config; },
  };

  // ---- source link (SystemVerilog editor <-> waveform) ----
  // cmux calls these through callAsyncJavaScript. A path is a dump path as an
  // array of segments (["top_tb", "dut", "pc"]), so names holding dots
  // (escaped identifiers, "\a.b ") survive; cmux maps them to and from design
  // paths. Escaped names match with or without their backslash and trailing space.
  //   scopeChildren(path) -> [{ name, isScope }] | null   ([] lists the tops; at most 5000)
  //   hasSignal(path) -> bool
  //   addSignal(path) -> bool   adds it unless shown, then selects it
  //   selectSignal(path) -> bool
  //   setMarker(time)
  //   selectedSignal() -> path | null   (null once the selected row is gone)
  // and posts { type: 'revealInSource', path } when a signal's name is double-clicked.
  const link = (() => {
    const maxChildren = 5000;
    let selectedId = null;
    // netlistId -> time of an add the viewer has not reported back yet.
    const pendingAdds = new Map();

    // eventData.netlistId is an array of the rows' ids.
    const firstId = (data) => [].concat(data && data.netlistId != null ? data.netlistId : [])[0] ?? null;
    const forwardEvent = webviewHandlers.emitEvent;
    webviewHandlers.emitEvent = (m) => {
      forwardEvent(m);
      if (m.eventType === 'signalSelect') { selectedId = firstId(m.eventData); }
      if (m.eventType === 'removeVariable') {
        const removed = firstId(m.eventData);
        pendingAdds.delete(removed);
        if (removed === selectedId) { selectedId = null; }
      }
    };

    const plainName = (name) => {
      const s = String(name);
      return s.startsWith('\\') ? s.slice(1).trimEnd() : s;
    };

    function segments(path) {
      if (Array.isArray(path)) { return path.map(String); }
      return path ? String(path).split('.') : [];
    }

    // Like findItem, over segments; an exact name wins over an escaped spelling of it.
    async function findLinkItem(path, varOnly) {
      const parts = segments(path);
      let items = doc.netlist;
      for (let i = 0; i < parts.length; i++) {
        const last = i === parts.length - 1;
        let named = items.filter((x) => x.name === parts[i]);
        if (!named.length) { named = items.filter((x) => plainName(x.name) === plainName(parts[i])); }
        if (last) {
          return named.find((x) => x.kind === 'var') || (varOnly ? null : named.find((x) => x.kind === 'scope') || null);
        }
        const scope = named.find((x) => x.kind === 'scope');
        if (!scope) { return null; }
        items = await getChildren(scope);
      }
      return null;
    }

    async function scopeChildren(path) {
      if (!backend) { return null; }
      let items = doc.netlist;
      if (segments(path).length) {
        const scope = await findLinkItem(path, false);
        if (!scope || scope.kind !== 'scope') { return null; }
        items = await getChildren(scope);
      }
      return items.slice(0, maxChildren).map((x) => ({ name: x.name, isScope: x.kind === 'scope' }));
    }

    function isShown(v) {
      const shown = (viewerContext.webview && viewerContext.webview.displayedSignals) || [];
      return shown.some((s) => s.netlistId === v.netlistId);
    }

    async function selectSignal(path) {
      const v = await findLinkItem(path, true);
      if (!v || !initSent) { return false; }
      toWebview({ command: 'setSelectedSignal', netlistId: v.netlistId });
      return true;
    }

    async function addSignal(path) {
      const v = await findLinkItem(path, true);
      if (!v || !initSent) { return false; }
      // displayedSignals arrives with the next contextUpdate; a second add before it would duplicate the row.
      const pending = pendingAdds.get(v.netlistId);
      if (!isShown(v) && !(pending && Date.now() - pending < 2000)) {
        pendingAdds.set(v.netlistId, Date.now());
        addVariable(v);
      }
      // add-variable is handled before this message, so the new row exists.
      toWebview({ command: 'setSelectedSignal', netlistId: v.netlistId });
      return true;
    }

    const pathOf = (v) => (v.scopePath || []).concat([v.name]);

    function selectedSignal() {
      const v = selectedId == null ? null : doc.items.get(selectedId);
      if (!v || !isShown(v)) { selectedId = null; return null; }
      return pathOf(v);
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
        const v = doc.items.get(context.netlistId);
        const path = v ? pathOf(v) : segments(context.scopePath).concat([String(context.signalName)]);
        toNative({ type: 'revealInSource', path });
      });
    }
    iframe.addEventListener('load', attachToFrame);

    return Object.freeze({
      scopeChildren,
      hasSignal: async (path) => !!(await findLinkItem(path, true)),
      addSignal,
      selectSignal,
      setMarker: (time) => { toWebview({ command: 'setMarker', time: Number(time), markerType: 0 }); },
      selectedSignal,
    });
  })();

  window.cmuxWaveform = { open, reload, setTheme, setStatus, applyThemeTo, fromWebview, viewerContext, commandHandlers,
    deliverValueChanges, addVariableByPath, stats, strings, host: hostApi,
    fileChanged: () => window.cmuxCommands.fileChanged(),
    runCommand: ({ command, args }) => window.cmuxCommands.run(command, args),
    sessionSaved: (m) => window.cmuxCommands.sessionSaved(m),
    sessionFailed: (m) => window.cmuxCommands.sessionFailed(m),
    applySessionFile: (m) => window.cmuxCommands.applySessionFile(m) };
  // Fixed before the viewer frame loads, so a script in it can't swap the link cmux trusts.
  Object.defineProperty(window.cmuxWaveform, 'link', { value: link, writable: false, configurable: false, enumerable: true });
  Object.defineProperty(window, 'cmuxWaveform', { value: window.cmuxWaveform, writable: false, configurable: false });
  applyThemeTo(document);
  toNative({ type: 'ready' });
})();
