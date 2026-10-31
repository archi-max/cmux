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
//          restore: { state, dirty } | undefined })
//   reload({ url, size })          reopen the file in place, keeping the signal list
//   fileChanged()                  the file changed on disk (reloads if Auto Reload is on)
//   setTheme({ kind, background, foreground })
//   setStatus({ title, detail })   progress while cmux prepares the FSDB helper
//   runCommand({ command, args })  a VaporView command id (cmux-commands.js)
//   sessionSaved() | sessionFailed({ message }) | applySessionFile({ text, path, error })
//   setSessionFile({ path, text })   <dump>.json, offered per promptLoadSettings
// and hears back on window.webkit.messageHandlers.cmuxWaveform:
//   { type: 'ready' } | { type: 'opened', top } | { type: 'error', message }
//   { type: 'copy', text } | { type: 'log', message } | { type: 'openReadme' }
//   { type: 'settings', values } | { type: 'sessionState', state, dirty }
//   { type: 'saveSession', text, suggestedName } | { type: 'loadSession' } | { type: 'reload' }
//   { type: 'keyState', viewerFocused, blocked }   which of VaporView's keys the page will run
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

  // What a call on a backend that a reload or open closed rejects with. Nothing
  // reports it: the newer load owns the page.
  function closedError() {
    const error = new Error('closed');
    error.cmuxClosed = true;
    return error;
  }

  function fail(error) {
    if (error && error.cmuxClosed) { return; }
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
    let closed = false;
    worker.onerror = (e) => { if (!closed) { fail(e.message); } };
    function call(method, args) {
      if (closed) { return Promise.reject(closedError()); }
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
      // [[time, value], ...] of one variable, kept in the page (cmux-debugger.js).
      signalChanges(v) { return call('getsignalchanges', { signalId: v.signalId }); },
      // A 1-bit variable's rising-edge times (Float64Array), found in the worker.
      signalPosedges(v, maxEdges) { return call('getsignalposedges', { signalId: v.signalId, maxEdges }); },
      // Ends the worker and settles every call still waiting on it.
      close() {
        closed = true;
        worker.terminate();
        pending.forEach((p) => p.reject(closedError()));
        pending.clear();
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

  // signalId -> the [time, value] changes the viewer was given for it (FSDB),
  // so the source link reads shown signals' values without fetching them again.
  const drawnChanges = new Map();

  async function inflateRaw(bytes) {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  function fsdbBackend(config) {
    // Whether the helper answers valueAt (v2); unknown until the first ask.
    let pointQuery;
    // Replies to requests made before close() (a reload) are dropped, so an
    // old signal reply can't fill a row of the reloaded file.
    let closed = false;
    const aborter = new AbortController();
    // A reply is JSON ({result} or {error}), or for signal data
    // [u32 LE header length][header JSON][deflate-raw records].
    async function request(req) {
      if (closed) { throw closedError(); }
      let response, all;
      try {
        response = await fetch(config.fsdb.url, { method: 'POST', body: JSON.stringify(req), signal: aborter.signal });
        all = new Uint8Array(await response.arrayBuffer());
      } catch (error) {
        throw closed ? closedError() : error;
      }
      let reply, bin = null;
      if ((response.headers.get('content-type') || '').startsWith('application/octet-stream')) {
        const headLength = new DataView(all.buffer).getUint32(0, true);
        reply = JSON.parse(new TextDecoder().decode(all.subarray(4, 4 + headLength)));
        bin = all.subarray(4 + headLength);
      } else {
        reply = JSON.parse(new TextDecoder().decode(all));
      }
      if (closed) { throw closedError(); }
      if (reply.error) { throw new Error(reply.error); }
      return { result: reply.result, helperMs: reply.ms || 0, bin, wireBytes: all.length };
    }

    return {
      close() { closed = true; aborter.abort(); },
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
      // Values in effect at `time` per variable (helper v2's point query), or null
      // when the helper has none (v1); then the link falls back to `changes`.
      async valuesAt(vars, time) {
        if (pointQuery === false) { return null; }
        try {
          const { result } = await request({ cmd: 'valueAt', signalIds: vars.map((v) => v.signalId), t: time });
          pointQuery = true;
          return result.values;
        } catch (error) {
          if (pointQuery === undefined && /unknown command/.test(String(error.message))) { pointQuery = false; return null; }
          throw error;
        }
      },
      // [[time, value], ...] per variable, for the source link's value lookups (not
      // drawn); null for one with more than maxChanges changes, which is not decoded.
      // (Helper v1 reports the count only with the data, so it is still downloaded.)
      async changes(vars, maxChanges) {
        const { result, bin } = await request({ cmd: 'signals',
          signalIds: vars.map((v) => v.signalId), widths: vars.map((v) => v.width) });
        let offset = 0;
        const out = [];
        for (const d of result) {
          let changes = d.valueChanges || null;
          if (!changes) {
            if (!(d.count > maxChanges)) {
              changes = decodeRecords(await inflateRaw(bin.subarray(offset, offset + d.bytes)), d.width);
            }
            offset += d.bytes;
          } else if (changes.length > maxChanges) {
            changes = null;
          }
          out.push(changes);
        }
        return out;
      },
      // A 1-bit variable's rising-edge times (Float64Array) for the debugger, scanned
      // from the helper's records without a value per change; throws past maxEdges.
      async signalPosedges(v, maxEdges) {
        const drawn = drawnChanges.get(v.signalId);
        let edges = new Float64Array(1024);
        let n = 0;
        const add = (time) => {
          if (n >= maxEdges) { throw new Error('too many clock edges'); }
          if (n === edges.length) { const grown = new Float64Array(edges.length * 2); grown.set(edges); edges = grown; }
          edges[n++] = time;
        };
        if (drawn) {
          let previous = null;
          for (const [time, value] of drawn) {
            if (value === '1' && previous !== null && previous !== '1') { add(Number(time)); }
            previous = value;
          }
          return edges.slice(0, n);
        }
        const { result, bin } = await request({ cmd: 'signals', signalIds: [v.signalId], widths: [v.width] });
        const d = result[0];
        if (!d) { return new Float64Array(0); }
        if (d.valueChanges) {
          let previous = null;
          for (const [time, value] of d.valueChanges) {
            const s = String(value);
            if (s === '1' && previous !== null && previous !== '1') { add(Number(time)); }
            previous = s;
          }
          return edges.slice(0, n);
        }
        // Half the changes of a clock are rising edges: refuse before inflating.
        if (d.count > maxEdges * 2 + 2) { throw new Error('too many clock edges'); }
        const raw = await inflateRaw(bin.subarray(0, d.bytes));
        const rec = 8 + d.width;
        const dv = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
        let time = 0;
        let previous = -1;
        for (let i = 0; i + rec <= raw.length; i += rec) {
          time += dv.getUint32(i, true) + dv.getUint32(i + 4, true) * 4294967296;
          const value = d.width === 1 ? raw[i + 8] : -2;
          if (value === 0x31 && previous !== -1 && previous !== 0x31) { add(time); }
          previous = value;
        }
        return edges.slice(0, n);
      },
      // [[time, value], ...] of one variable for the page (cmux-debugger.js): what
      // the viewer was given when it draws it, else read from the helper; null past maxChanges.
      async signalChanges(v, maxChanges) {
        const drawn = drawnChanges.get(v.signalId);
        if (drawn) { return drawn; }
        return (await this.changes([v], maxChanges))[0];
      },
      async fetch(requestList) {
        const signals = requestList.filter((r) => r.type === 'signal');
        if (!signals.length) { return; }
        // The source link reads shown signals' values from drawnChanges: tell cmux they are there.
        try { await fetchSignals(signals); } finally { if (!closed) { toNative({ type: 'signalData' }); } }
      },
    };

    async function fetchSignals(signals) {
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
        if (closed) { return; }
        const t3 = performance.now();
        deliverValueChanges({ command: 'update-waveform-chunk', signalId: d.signalId, transitionDataChunk: changes,
          totalChunks: 1, chunkNum: 0, min: d.min, max: d.max });
        // The viewer keeps this same array (deliverValueChanges does not copy it), so holding it costs nothing extra.
        drawnChanges.set(d.signalId, changes);
        const entry = { signalId: d.signalId, changes: changes.length, fetchMs: Math.round(fetchMs),
          helperMs: Math.round(helperMs), wireBytes, inflateMs: Math.round(t2 - t1), decodeMs: Math.round(t3 - t2),
          deliverMs: Math.round(performance.now() - t3) };
        stats.push(entry);
        toNative({ type: 'log', message: 'fsdb signal ' + JSON.stringify(entry) });
      }
    }
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
      hostApi.contextListeners.forEach((listener) => { try { listener(m); } catch (error) { hostApi.log(error); } });
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
    const generation = loadGeneration;
    try {
      await handler(m);
    } catch (error) {
      if (generation === loadGeneration) { fail(error); }
    }
  }

  // ---- netlist (drawn by cmux-netlist.js) ----
  // Concurrent callers share one request per scope.
  function getChildren(item) {
    if (item.children) { return Promise.resolve(item.children); }
    if (!item.childrenRequest) {
      const scopePath = item.scopePath.concat([item.name]);
      item.childrenRequest = backend.children(item).then((list) => {
        const out = list.map((c) => ({ ...c, scopePath }));
        out.forEach((c) => { if (c.kind === 'var') { doc.items.set(c.netlistId, c); } });
        item.children = out;
        return out;
      }).finally(() => { delete item.childrenRequest; });
    }
    return item.childrenRequest;
  }

  function addVariables(vars, groupPath, index) {
    if (!vars.length) { return; }
    // Next to a selected row of the debugger's Locals, a new row would land in
    // Locals (and go with its next refill): it goes to the top level instead.
    if (groupPath === undefined && index === undefined && hostApi.topLevelIndexOutsideTransient) {
      index = hostApi.topLevelIndexOutsideTransient();
    }
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
  // Each open or reload is a load generation. A newer one closes the backend
  // of the one before, whose results and errors are then ignored, so two
  // quick reloads leave one worker and no false "Unable to open" error.
  let loadGeneration = 0;
  // Whether the viewer frame has loaded for the current open (reload keeps it).
  let frameLoaded = false;

  function closeBackend() {
    if (backend && backend.close) { backend.close(); }
    backend = null;
  }

  // Resolves to false when a newer load superseded this one.
  async function openBackend(generation) {
    drawnChanges.clear();
    const opening = config.format === 'fsdb' ? fsdbBackend(config) : wellenBackend(config);
    backend = opening;
    const metadata = await opening.open((top) => {
      if (generation !== loadGeneration) { return; }
      doc.netlist = top.map((t) => ({ ...t, scopePath: [] }));
      doc.netlist.forEach((t) => { if (t.kind === 'var') { doc.items.set(t.netlistId, t); } });
      window.cmuxNetlist.render(doc.netlist);
    });
    if (generation !== loadGeneration) { return false; }
    doc.metadata = metadata;
    showMessage('', '');
    return true;
  }

  async function open(next) {
    const generation = ++loadGeneration;
    // Auto Reload belongs to the file (VaporviewDocument): another file starts
    // from the setting. reload() before the frame loaded comes here too.
    if (!next || next.path !== config.path) { autoReloadState = null; }
    closeBackend();
    frameLoaded = false;
    doc.metadata = null;
    doc.netlist = [];
    doc.items.clear();
    initSent = false;
    webviewReady = false;
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
      if (!(await openBackend(generation))) { return; }
      iframe.src = 'viewer.html';
      iframe.addEventListener('load', () => {
        if (generation !== loadGeneration) { return; }
        frameLoaded = true;
        window.cmuxCommands.attachFrame(iframe.contentWindow);
        sendInit();
      }, { once: true });
    } catch (error) {
      if (generation === loadGeneration) { fail(error); }
    }
  }

  // VaporviewDocument.reload: unload the webview, read the file again and
  // re-initialize the viewport. The viewer frame stays, so its saved state
  // brings the same signals back (restoreState); cmux's copy covers the case
  // where the frame has none.
  async function reload(next) {
    if (!frameLoaded) { return open(Object.assign({}, config, next || {})); }
    const generation = ++loadGeneration;
    const snapshot = window.cmuxCommands.sessionSnapshot();
    // A restore that hasn't reached the viewer yet wins over the viewer's
    // (still empty) context; otherwise the context is the state to bring back.
    const unapplied = config.restore && config.restore.state ? config.restore : null;
    config = Object.assign({}, config, next || {}, { restore: unapplied || (snapshot.state ? snapshot : null) });
    window.cmuxCommands.willReload();
    closeBackend();
    doc.metadata = null;
    doc.netlist = [];
    doc.items.clear();
    initSent = false;
    webviewReady = false;
    toWebview({ command: 'unload' });
    window.cmuxNetlist.clear();
    showMessage(strings.loading, '');
    try {
      if (!(await openBackend(generation))) { return; }
      sendInit();
    } catch (error) {
      if (generation === loadGeneration) { fail(error); }
    }
  }

  // What cmux-commands.js and cmux-netlist.js use. Waveform data stays behind
  // the backend; these only touch the netlist and the viewer frame.
  const hostApi = {
    doc, viewerContext, toWebview, toNative, fail, getChildren, findItem, addVariables, search, valuesAtTime,
    netlistItem: (id) => doc.items.get(id) || null,
    // cmux-debugger.js: a variable's changes, VaporView events as they pass,
    // and its Locals group, which the link does not count as shown.
    signalChanges: (v, maxChanges) => (backend && backend.signalChanges ? backend.signalChanges(v, maxChanges) : Promise.resolve(null)),
    // Null when the backend has no faster way than signalChanges.
    signalPosedges: (v, maxEdges) => (backend && backend.signalPosedges ? backend.signalPosedges(v, maxEdges) : null),
    get currentBackend() { return backend; },
    viewerEventListeners: [],
    contextListeners: [],
    quietEvents: 0,
    isTransientGroup: null,
    topLevelIndexOutsideTransient: null,
    log: (message) => toNative({ type: 'log', message: String(message) }),
    get config() { return config; },
    // Bumped by every open and reload: work started for an older one is stale.
    get loadGeneration() { return loadGeneration; },
  };

  // ---- source link (SystemVerilog editor <-> waveform) ----
  // cmux calls these through callAsyncJavaScript. A path is a dump path as an
  // array of segments (["top_tb", "dut", "pc"]), so names holding dots
  // (escaped identifiers, "\a.b ") survive; cmux maps them to and from design
  // paths. Escaped names match with or without their backslash and trailing space.
  //   scopeChildren(path) -> [{ name, isScope }] | null   ([] lists the tops; at most 5000)
  //   hasSignal(path) -> bool
  //   addSignal(path) -> bool   adds it unless shown, then selects it
  //   addScope({ path, confirmed }) -> { added, total } | { needsConfirm, count, total } | null
  //                             adds the scope's own signals not shown yet
  //   selectSignal(path) -> bool
  //   setMarker(time)
  //   selectedSignal() -> path | null   (null once the selected row is gone)
  //   valuesAt({ time, paths, unshown }) -> [value | null]   formatted like the signal's row
  //   markerTime() -> time | null
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
      // Rows the debugger adds or removes for Locals select and deselect as a side effect: not the user's doing.
      if (!hostApi.quietEvents) { forwardEvent(m); }
      hostApi.viewerEventListeners.forEach((listener) => { try { listener(m); } catch (error) { hostApi.log(error); } });
      if (m.eventType === 'signalSelect') { selectedId = firstId(m.eventData); }
      if (m.eventType === 'removeVariable') {
        const removed = [].concat(m.eventData && m.eventData.netlistId != null ? m.eventData.netlistId : []);
        removed.forEach((id) => { pendingAdds.delete(id); forgetDrawn(id, removed); });
        if (removed.includes(selectedId)) { selectedId = null; }
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

    // netlistIds of the shown rows, inside groups too. pinnedOnly: not the
    // debugger's Locals group (its rows come and go with the editor's caret).
    function shownIds(pinnedOnly) {
      const out = new Set();
      const walk = (list) => (list || []).forEach((d) => {
        if (pinnedOnly && hostApi.isTransientGroup && hostApi.isTransientGroup(d)) { return; }
        if (d.netlistId !== undefined) { out.add(d.netlistId); }
        walk(d.children);
      });
      walk(viewerContext.webview && viewerContext.webview.displayedSignals);
      return out;
    }

    const isShown = (v) => shownIds(true).has(v.netlistId);

    // A removed row's changes are dropped once no other shown row (outside `removed`) draws the same signal.
    function forgetDrawn(netlistId, removed) {
      const v = doc.items.get(netlistId);
      if (!v || v.signalId === undefined) { return; }
      for (const id of shownIds()) {
        const other = doc.items.get(id);
        if (!removed.includes(id) && other && other.signalId === v.signalId) { return; }
      }
      drawnChanges.delete(v.signalId);
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

    // Like VaporView's Add All in Scope (shallow: child scopes are left out), but
    // without the signals already shown or being added. cmux asks before adding
    // more than `confirmAbove`: addScope({ path }) answers { needsConfirm, count }
    // then, and addScope({ path, confirmed: true }) adds them. At most 128 are
    // added; { added, total } says how many of how many.
    const maxScopeAdds = 128;
    const confirmAbove = 48;
    async function addScope(query) {
      const { path, confirmed } = query || {};
      const scope = await findLinkItem(path, false);
      if (!scope || scope.kind !== 'scope' || !initSent) { return null; }
      const shown = shownIds(true);
      const now = Date.now();
      const isPending = (id) => { const t = pendingAdds.get(id); return t !== undefined && now - t < 2000; };
      const all = (await getChildren(scope)).filter((c) => c.kind === 'var' && !shown.has(c.netlistId) && !isPending(c.netlistId));
      const vars = all.slice(0, maxScopeAdds);
      if (vars.length > confirmAbove && !confirmed) { return { needsConfirm: true, count: vars.length, total: all.length }; }
      vars.forEach((v) => pendingAdds.set(v.netlistId, now));
      if (vars.length) { addVariables(vars); }
      return { added: vars.length, total: all.length };
    }

    // ---- values at a time, for the editor's inline values ----
    // FSDB: shown signals are read from the changes the viewer already has
    // (drawnChanges). Others only when asked (`unshown`): through helper v2's
    // point query, else (helper v1) by fetching their changes, at most
    // maxChangesPerSignal each (longer ones get no value and are not kept),
    // kept up to maxCachedChanges in all, least recently used out.
    const maxChangesPerSignal = 1000000;
    const maxCachedChanges = 2000000;
    const changeCache = new Map();
    let cachedChanges = 0;
    let cacheBackend = null;

    function valueIn(changes, time) {
      let lo = 0, hi = changes.length - 1, at = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (changes[mid][0] <= time) { at = mid; lo = mid + 1; } else { hi = mid - 1; }
      }
      return at >= 0 ? changes[at][1] : undefined;
    }

    async function fsdbValues(time, vars, unshown) {
      // A reload opens a new backend; its ids may name other signals.
      if (cacheBackend !== backend) { changeCache.clear(); cachedChanges = 0; cacheBackend = backend; }
      const out = new Map();
      const shown = shownIds();
      const rest = [];
      for (const v of vars) {
        const drawn = shown.has(v.netlistId) ? drawnChanges.get(v.signalId) : undefined;
        if (drawn) {
          const value = valueIn(drawn, time);
          if (value !== undefined) { out.set(v.netlistId, value); }
        } else if (unshown) {
          rest.push(v);
        }
      }
      if (!rest.length) { return out; }
      const point = await backend.valuesAt(rest, time);
      if (point) {
        rest.forEach((v, k) => { if (typeof point[k] === 'string') { out.set(v.netlistId, point[k]); } });
        return out;
      }
      const missing = rest.filter((v) => !changeCache.has(v.signalId));
      for (let i = 0; i < missing.length; i += 8) {
        const batch = missing.slice(i, i + 8);
        const lists = await backend.changes(batch, maxChangesPerSignal);
        batch.forEach((v, k) => {
          // Too long to keep (null): no value rather than a cache that pins it.
          const changes = lists[k] === undefined ? [] : lists[k];
          changeCache.set(v.signalId, changes);
          if (changes) { cachedChanges += changes.length; }
        });
      }
      for (const v of rest) {
        const changes = changeCache.get(v.signalId);
        // Most recently used last.
        changeCache.delete(v.signalId);
        changeCache.set(v.signalId, changes);
        const value = changes ? valueIn(changes, time) : undefined;
        if (value !== undefined) { out.set(v.netlistId, value); }
      }
      // The values are read already, so this query's own signals may go too.
      for (const [id, changes] of changeCache) {
        if (cachedChanges <= maxCachedChanges) { break; }
        changeCache.delete(id);
        cachedChanges -= changes ? changes.length : 0;
      }
      return out;
    }

    // wellen answers a point query itself. Its path list is space-separated and
    // its answers are keyed by dotted path, so names holding a space or a dot
    // (escaped identifiers) can't be asked for and get no value.
    async function wellenValues(time, vars) {
      const out = new Map();
      if (!backend.valuesAtTime) { return out; }
      const byPath = new Map();
      for (const v of vars) {
        const parts = pathOf(v);
        if (parts.some((p) => /[\s.]/.test(p))) { continue; }
        byPath.set(parts.join('.'), v);
      }
      if (!byPath.size) { return out; }
      for (const r of await backend.valuesAtTime(time, Array.from(byPath.keys()))) {
        const v = byPath.get(r.instancePath);
        let value = r.value;
        try {
          value = JSON.parse(value);
        } catch (error) {
          // At a change with nothing before it (time 0) the list comes as `[],"0101"]`.
          const last = /"([^"]*)"\s*\]\s*$/.exec(String(value));
          if (last) { value = last[1]; }
        }
        // [before, after] at a change: the value in effect at `time` is the last.
        if (Array.isArray(value)) { value = value[value.length - 1]; }
        if (v && value != null) { out.set(v.netlistId, String(value)); }
      }
      return out;
    }

    function groupBits(bits, size, digits) {
      let out = '';
      for (let end = bits.length; end > 0; end -= size) {
        const group = bits.slice(Math.max(0, end - size), end);
        if (/^[01]+$/.test(group)) { out = digits[parseInt(group, 2)] + out; }
        else if (/^[zZ]+$/.test(group)) { out = 'z' + out; }
        else { out = 'x' + out; }
      }
      return out;
    }

    // A 4-state bit string in VaporView's number format (its default is
    // hexadecimal). Anything else (reals, strings) is returned as it is.
    function formatValue(bits, format) {
      if (!/^[01xzXZuUwWlLhH-]+$/.test(bits)) { return bits; }
      if (bits.length === 1) { return bits.toLowerCase(); }
      const known = /^[01]+$/.test(bits);
      switch (format) {
        case 'binary': return bits.toLowerCase();
        case 'octal': return groupBits(bits, 3, '01234567');
        case 'decimal': return known ? BigInt('0b' + bits).toString() : 'x';
        case 'signed': {
          if (!known) { return 'x'; }
          const n = BigInt('0b' + bits);
          return (bits[0] === '1' ? n - (1n << BigInt(bits.length)) : n).toString();
        }
        default: return groupBits(bits, 4, '0123456789abcdef');
      }
    }

    // netlistId -> numberFormat of the shown rows, inside groups too.
    function shownFormats() {
      const out = new Map();
      const walk = (list) => (list || []).forEach((d) => {
        if (d.netlistId !== undefined && !out.has(d.netlistId)) { out.set(d.netlistId, d.numberFormat); }
        walk(d.children);
      });
      walk(viewerContext.webview && viewerContext.webview.displayedSignals);
      return out;
    }

    // valuesAt({ time, paths, unshown }) -> [value | null], one per path: the
    // value in effect at `time`, in the radix of the signal's row (hexadecimal
    // if not shown). FSDB answers signals not shown only with `unshown`.
    async function valuesAt(query) {
      const { time, paths, unshown } = query || {};
      if (!backend || !initSent || !Array.isArray(paths)) { return []; }
      const list = paths.slice(0, 500);
      // One after another: siblings then find their scope's children cached.
      const vars = [];
      for (const p of list) { vars.push(await findLinkItem(p, true)); }
      const found = Array.from(new Set(vars.filter(Boolean)));
      const t = Number(time);
      const raw = backend.changes ? await fsdbValues(t, found, !!unshown) : await wellenValues(t, found);
      const formats = shownFormats();
      return vars.map((v) => {
        const bits = v ? raw.get(v.netlistId) : undefined;
        return bits === undefined ? null : formatValue(bits, formats.get(v.netlistId));
      });
    }

    function selectedSignal() {
      const v = selectedId == null ? null : doc.items.get(selectedId);
      if (!v || !shownIds(false).has(v.netlistId)) { selectedId = null; return null; }
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
    hostApi.findLinkItem = findLinkItem;
    hostApi.pathOf = pathOf;

    return Object.freeze({
      scopeChildren,
      hasSignal: async (path) => !!(await findLinkItem(path, true)),
      addSignal,
      addScope,
      selectSignal,
      setMarker: (time) => { toWebview({ command: 'setMarker', time: Number(time), markerType: 0 }); },
      selectedSignal,
      valuesAt,
      markerTime: () => (viewerContext.webview ? viewerContext.webview.markerTime ?? null : null),
    });
  })();

  window.cmuxWaveform = { open, reload, setTheme, setStatus, applyThemeTo, fromWebview, viewerContext, commandHandlers,
    deliverValueChanges, addVariableByPath, stats, strings, host: hostApi,
    fileChanged: () => window.cmuxCommands.fileChanged(),
    runCommand: ({ command, args }) => window.cmuxCommands.run(command, args),
    sessionSaved: (m) => window.cmuxCommands.sessionSaved(m),
    sessionFailed: (m) => window.cmuxCommands.sessionFailed(m),
    applySessionFile: (m) => window.cmuxCommands.applySessionFile(m),
    setSessionFile: (m) => window.cmuxCommands.setSessionFile(m) };
  // Fixed before the viewer frame loads, so a script in it can't swap the link cmux trusts.
  Object.defineProperty(window.cmuxWaveform, 'link', { value: link, writable: false, configurable: false, enumerable: true });
  Object.defineProperty(window, 'cmuxWaveform', { value: window.cmuxWaveform, writable: false, configurable: false });
  applyThemeTo(document);
  toNative({ type: 'ready' });
})();
