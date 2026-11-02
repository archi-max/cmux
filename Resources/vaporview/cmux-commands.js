// Adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0), package.json `contributes` (menus, keybindings, configuration), src/extension_core/commands.ts@59107c6, src/extension_core/viewer_provider.ts@59107c6, src/extension_core/document.ts@59107c6 and VaporviewStatusBar in src/extension_core/tree_view.ts@59107c6.
//
// What VS Code and VaporView's extension host do around the webview, for cmux:
// the command table (same command ids and arguments as VaporView), the
// webview and netlist context menus, the keybindings, the settings
// (vaporview.* keys), sessions (VaporView's JSON format, auto-load of
// <dump>.json, undo/redo, unsaved state), the status strip and the external
// API used by terminal links and the editor.
//
// window.cmuxCommands:
//   run(commandId, args)          a VaporView command, e.g. run('waveformViewer.setMarker', { time: 50, units: 'ns' })
//   attachFrame(frameWindow)      installs the context menu, key and drop handlers in the viewer frame
//   showNetlistMenu(item, x, y)   right-click on a netlist row
//   settings()                    current settings (vaporview.* keys without the prefix)
//   configMessage()               the webview's setConfigSettings message for those settings
//   onContextUpdate(m), restoreState(m), handleDrop(m)   webview messages
//   addSignalByName(path, msb, lsb, quiet)   -> whether it found the signal
//   sessionSaved(), applySessionFile({ text, path, error }), sessionFailed({ message })   replies from cmux
//   setSessionFile({ path, text })   <dump>.json, which cmux reads after the file opens
//   applyValueAliasFile({ text, path, error })   the file cmux read for Load Value Alias File...

(function () {
  const host = () => window.cmuxWaveform.host;
  const S = () => window.cmuxWaveform.strings || {};
  const ui = () => window.cmuxUI;

  const StateChangeType = { None: 0, Restore: 1, File: 2, Undo: 3, Redo: 4, User: 5 };
  const EXTENSION_VERSION = '1.6.1-beta';

  function format(template, ...args) {
    let i = 0;
    return String(template || '').replace(/%(\d+\$)?@/g, (_, n) => String(args[n ? parseInt(n, 10) - 1 : i++] ?? ''));
  }

  // ---- menus (package.json contributes.menus, `activeCustomEditorId` terms removed) ----
  const MENUS = {
    "webview/context": [
      {submenu: "vaporview.timeUnit", group: "1_time_ruler@1"},
      {submenu: "vaporview.rulerTimeIncrement", group: "1_time_ruler@2"},
      {submenu: "vaporview.scrollMode", group: "1_time_ruler@3", when: "webviewSection == 'ruler'"},
      {command: "vaporview.showRulerLines", group: "3_general_settings@1", when: "webviewSection == 'ruler' && rulerLines == false"},
      {command: "vaporview.hideRulerLines", group: "3_general_settings@1", when: "webviewSection == 'ruler' && rulerLines == true"},
      {command: "vaporview.fillBitVector", group: "3_general_settings@2", when: "webviewSection == 'ruler' && fillBitVector == false"},
      {command: "vaporview.outlineBitVector", group: "3_general_settings@2", when: "webviewSection == 'ruler' && fillBitVector == true"},
      {command: "vaporview.enableAnimations", group: "3_general_settings@3", when: "webviewSection == 'ruler' && enableAnimations == false"},
      {command: "vaporview.disableAnimations", group: "3_general_settings@3", when: "webviewSection == 'ruler' && enableAnimations == true"},
      {command: "vaporview.viewVaporViewSettings", group: "3_general_settings@4", when: "webviewSection == 'ruler'"},
      {command: "vaporview.showReadme", group: "3_general_settings@5", when: "webviewSection == 'ruler'"},
      {submenu: "vaporview.valueFormat", group: "1_waveform_settings@2", when: "webviewSection == 'signal'"},
      {submenu: "vaporview.renderType", group: "1_waveform_settings@3", when: "webviewSection == 'signal'"},
      {submenu: "vaporview.highlightEdge", group: "1_waveform_settings@4", when: "webviewSection == 'signal'"},
      {submenu: "vaporview.valueColor", group: "1_waveform_settings@5", when: "webviewSection == 'signal'"},
      {submenu: "vaporview.rowHeight", group: "1_waveform_settings@6", when: "(webviewSection == 'signal')"},
      {submenu: "vaporview.nameType", group: "1_waveform_settings@7", when: "webviewSection == 'signal'"},
      {command: "vaporview.increaseVerticalScale", group: "1_waveform_settings@8", when: "webviewSection == 'signal' && isAnalog"},
      {command: "vaporview.decreaseVerticalScale", group: "1_waveform_settings@9", when: "webviewSection == 'signal' && isAnalog"},
      {command: "vaporview.resetVerticalScale", group: "1_waveform_settings@10", when: "webviewSection == 'signal' && isAnalog"},
      {command: "vaporview.removeSignal", group: "2_variables@1", when: "webviewSection == 'signal'"},
      {command: "vaporview.showInNetlistView", group: "2_variables@2", when: "webviewSection == 'signal'"},
      {command: "vaporview.copyName", group: "2_variables@3", when: "webviewSection == 'signal'"},
      {command: "vaporview.copyValueAtMarker", group: "2_variables@4", when: "webviewSection == 'signal'"},
      {command: "vaporview.renameSignalGroup", group: "2_variables@5", when: "(webviewSection == 'signal-group' || webviewSection == 'signal-separator')"},
      {command: "vaporview.ungroupSignals", group: "2_variables@6", when: "webviewSection == 'signal-group'"},
      {command: "vaporview.deleteGroup", group: "2_variables@7", when: "webviewSection == 'signal-group'"},
      {command: "vaporview.removeSeparator", group: "2_variables@8", when: "webviewSection == 'signal-separator'"},
      {command: "vaporview.newSignalGroup", group: "3_groups@1", when: "webviewSection != 'control-bar' && webviewSection != 'ruler' && !inputFocus"},
      {command: "vaporview.newGroupFromSelection", group: "3_groups@2", when: "webviewSection != 'control-bar' && webviewSection != 'ruler' && !inputFocus"},
      {command: "vaporview.newSeparator", group: "3_groups@6", when: "webviewSection != 'control-bar' && webviewSection != 'ruler' && !inputFocus"},
      {command: "vaporview.newSignalFromBitRange", group: "3_groups@8", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 1"},
      {submenu: "vaporview.createSignals", group: "3_groups@9", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 1"},
      {command: "vaporview.saveViewerSession", group: "4_saveLoad@1"},
      {command: "vaporview.loadViewerSession", group: "4_saveLoad@2"},
      {submenu: "vaporview.waveDrom", group: "5_waveDrom", when: "webviewSection != 'control-bar' && webviewSection != 'ruler' && !inputFocus"},
    ],
    "view/item/context": [
      {command: "vaporview.addVariable", group: "inline@2", when: "viewItem == 'netlistVar' && view == 'waveformViewerNetlistView'"},
      {command: "vaporview.showInViewer", group: "inline@1", when: "viewItem == 'netlistVar' && view == 'waveformViewerNetlistView'"},
      {command: "vaporview.searchScope", group: "1_default@0", when: "view == 'waveformViewerNetlistView' && vaporview.netlistSearchable && viewItem == 'netlistScope'"},
      {command: "vaporview.addSelected", group: "1_default@1", when: "viewItem == 'netlistVar' && view == 'waveformViewerNetlistView'"},
      {command: "vaporview.removeSelectedNetlist", group: "1_default@2", when: "viewItem == 'netlistVar' && view == 'waveformViewerNetlistView'"},
      {command: "vaporview.addAllInScopeShallow", group: "1_default@4", when: "viewItem == 'netlistScope'"},
      {command: "vaporview.addAllInScopeRecursive", group: "1_default@5", when: "viewItem == 'netlistScope'"},
      {command: "vaporview.removeAllInScope", group: "1_default@6", when: "viewItem == 'netlistScope'"},
      {command: "vaporview.showInViewer", group: "1_default@7", when: "viewItem == 'netlistVar'"},
      {command: "vaporview.copyName", group: "1_default@8", when: "view == 'waveformViewerNetlistView'"},
      {command: "vaporview.addVariableByInstancePath", group: "2_addVariable", when: "view == 'waveformViewerNetlistView'"},
      {command: "vaporview.saveViewerSession", group: "3_saveLoad@1", when: "view == 'waveformViewerNetlistView'"},
      {command: "vaporview.loadViewerSession", group: "3_saveLoad@2", when: "view == 'waveformViewerNetlistView'"},
      {command: "vaporview.reloadFile", group: "4_reload", when: "view == 'waveformViewerNetlistView'"},
    ],
    "vaporview.valueFormat": [
      {command: "vaporview.displayAsEnum", group: "0_default@1", when: "webviewSection == 'signal' && enum == true"},
      {command: "vaporview.displayAsBinary", group: "0_default@2", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsHexadecimal", group: "0_default@3", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsOctal", group: "0_default@4", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsDecimal", group: "0_default@5", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsDecimalSigned", group: "0_default@6", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsFloat", group: "0_default@7", when: "webviewSection == 'signal' && (width == '4' || width == '8' || width == '16' || width == '32' || width == '64')"},
      {command: "vaporview.displayAsBFloat", group: "0_default@8", when: "webviewSection == 'signal' && width == '16'"},
      {command: "vaporview.displayAsTFloat", group: "0_default@9", when: "webviewSection == 'signal' && width == '19'"},
      {command: "vaporview.displayAsFixedPoint", group: "0_default@10", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsFixedPointSigned", group: "0_default@11", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsAscii", group: "0_default@12", when: "webviewSection == 'signal' && width > '1'"},
      {command: "vaporview.displayAsEpochTimeNs", group: "0_default@13", when: "webviewSection == 'signal' && width >= '64'"},
      // cmux additions: the viewer's RISC-V instruction formats (extra_formats.ts,
      // 16 bits and wider; ordering in when clauses compares numbers).
      {submenu: "vaporview.riscvFormat", group: "1_instruction@1", when: "webviewSection == 'signal' && width >= '16'"},
      // Value aliases (Verdi .alias/.rc, JSON or CSV): the file's tables, by name.
      {command: "vaporview.loadValueAliases", group: "2_alias@1", when: "webviewSection == 'signal'"},
      {submenu: "vaporview.valueAlias", group: "2_alias@2", when: "webviewSection == 'signal'"},
    ],
    // Built when the menu opens, from the viewer's loaded tables (aliasMenuEntries).
    "vaporview.valueAlias": [],
    "vaporview.riscvFormat": [
      {command: "vaporview.displayAsRiscv", group: "0_default@1"},
      {command: "vaporview.displayAsRiscvNumeric", group: "0_default@2"},
      {command: "vaporview.displayAsRiscvNoAlias", group: "0_default@3"},
      {command: "vaporview.displayAsRiscvNumericNoAlias", group: "0_default@4"},
    ],
    "vaporview.valueColor": [
      {command: "vaporview.defaultColor1", group: "0_default@1", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor2", group: "0_default@2", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor3", group: "0_default@3", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor4", group: "0_default@4", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor5", group: "0_default@5", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor6", group: "0_default@6", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor7", group: "0_default@7", when: "webviewSection == 'signal'"},
      {command: "vaporview.defaultColor8", group: "0_default@8", when: "webviewSection == 'signal'"},
    ],
    "vaporview.rowHeight": [
      {command: "vaporview.rowHeight1x", group: "1_default@1", when: "(webviewSection == 'signal' || webviewSection == 'signal-separator')"},
      {command: "vaporview.rowHeight2x", group: "1_default@2", when: "(webviewSection == 'signal' || webviewSection == 'signal-separator')"},
      {command: "vaporview.rowHeight4x", group: "1_default@3", when: "(webviewSection == 'signal' || webviewSection == 'signal-separator')"},
      {command: "vaporview.rowHeight8x", group: "1_default@3", when: "(webviewSection == 'signal' || webviewSection == 'signal-separator')"},
    ],
    "vaporview.nameType": [
      {command: "vaporview.setNameTypeFullPath", group: "1_default@1", when: "webviewSection == 'signal'"},
      {command: "vaporview.setNameTypeSignalName", group: "1_default@2", when: "webviewSection == 'signal'"},
      {command: "vaporview.setNameTypeCustom", group: "1_default@3", when: "webviewSection == 'signal'"},
      {command: "vaporview.renameSignalGroup", group: "1_default@4", when: "webviewSection == 'signal'"},
    ],
    "vaporview.createSignals": [
      {command: "vaporview.createSignalsForAllBits", group: "1_default@1", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 1 && width <= 32"},
      {command: "vaporview.createSignalsForAllNibbles", group: "1_default@2", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 4 && width <= 128"},
      {command: "vaporview.createSignalsForAllBytes", group: "1_default@3", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 8 && width <= 256"},
      {command: "vaporview.createSignalsForAllWords", group: "1_default@4", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 16 && width <= 512"},
      {command: "vaporview.createSignalsForAllDoubleWords", group: "1_default@5", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 32 && width <= 1024"},
      {command: "vaporview.createSignalsForAllQuadWords", group: "1_default@6", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 64 && width <= 2048"},
      {command: "vaporview.createSignalsForAllCustomLength", group: "1_default@7", when: "(webviewSection == 'waveform-labels' || webviewSection == 'signal') && !inputFocus && width > 2 && width <= 256"},
    ],
    "vaporview.timeUnit": [
      {command: "vaporview.setTimeUnitsSeconds", group: "1_default@1", when: "s == true"},
      {command: "vaporview.setTimeUnitsMilliseconds", group: "1_default@2", when: "ms == true"},
      {command: "vaporview.setTimeUnitsMicroseconds", group: "1_default@3", when: "µs == true"},
      {command: "vaporview.setTimeUnitsNanoseconds", group: "1_default@4", when: "ns == true"},
      {command: "vaporview.setTimeUnitsPicoseconds", group: "1_default@5", when: "ps == true"},
      {command: "vaporview.setTimeUnitsFemtoseconds", group: "1_default@6", when: "fs == true"},
    ],
    "vaporview.rulerTimeIncrement": [
      {command: "vaporview.autoRulerTimeIncrement", group: "1_default@1", when: "webviewSection == 'ruler'"},
      {command: "vaporview.setRulerTimeIncrement", group: "1_default@2", when: "webviewSection == 'ruler'"},
    ],
    "vaporview.scrollMode": [
      {command: "vaporview.setMouseScrollingMode", group: "1_default@1", when: "webviewSection == 'ruler'"},
      {command: "vaporview.setTouchpadScrollingMode", group: "1_default@2", when: "webviewSection == 'ruler'"},
      {command: "vaporview.setAutoScrollingMode", group: "1_default@3", when: "webviewSection == 'ruler'"},
    ],
    "vaporview.renderType": [
      {command: "vaporview.renderMultiBit", group: "1_default@1", when: "webviewSection == 'signal' && (width > '1' || type == 'Real')"},
      {command: "vaporview.renderLinear", group: "2_analog@2", when: "webviewSection == 'signal' && (width > '1' || type == 'Real')"},
      {command: "vaporview.renderStepped", group: "2_analog@3", when: "webviewSection == 'signal' && (width > '1' || type == 'Real')"},
      {command: "vaporview.renderLinearSigned", group: "2_analog@4", when: "webviewSection == 'signal' && (width > '1')"},
      {command: "vaporview.renderSteppedSigned", group: "2_analog@5", when: "webviewSection == 'signal' && (width > '1')"},
    ],
    "vaporview.highlightEdge": [
      {command: "vaporview.annotatePosedge", group: "1_default@1", when: "webviewSection == 'signal' && width == '1'"},
      {command: "vaporview.annotateNegedge", group: "1_default@2", when: "webviewSection == 'signal' && width == '1'"},
      {command: "vaporview.annotateAllEdge", group: "1_default@3", when: "webviewSection == 'signal'"},
      {command: "vaporview.annotateNone", group: "1_default@4", when: "webviewSection == 'signal'"},
    ],
    "vaporview.waveDrom": [
      {command: "vaporview.copyWaveDrom"},
      {command: "vaporview.unsetWaveDromClock"},
      {command: "vaporview.setWaveDromClockRising"},
      {command: "vaporview.setWaveDromClockFalling"},
    ],
  };

  // Titles that are unit symbols or technical names stay as they are in every language.
  const INVARIANT_TITLES = {
    'vaporview.setTimeUnitsSeconds': 's', 'vaporview.setTimeUnitsMilliseconds': 'ms',
    'vaporview.setTimeUnitsMicroseconds': 'µs', 'vaporview.setTimeUnitsNanoseconds': 'ns',
    'vaporview.setTimeUnitsPicoseconds': 'ps', 'vaporview.setTimeUnitsFemtoseconds': 'fs',
    'vaporview.rowHeight1x': '1x', 'vaporview.rowHeight2x': '2x', 'vaporview.rowHeight4x': '4x', 'vaporview.rowHeight8x': '8x',
    'vaporview.displayAsAscii': 'ASCII', 'vaporview.displayAsBFloat': 'BFloat 16', 'vaporview.displayAsTFloat': 'TensorFloat 32',
    'vaporview.waveDrom': 'WaveDrom', 'vaporview.riscvFormat': 'RISC-V',
  };

  function title(id) {
    if (INVARIANT_TITLES[id]) { return INVARIANT_TITLES[id]; }
    const short = id.split('.').slice(1).join('.');
    return S()['command.' + short] || S()['submenu.' + short] || short;
  }

  // ---- keybindings (package.json contributes.keybindings, plus Cmd+S/Cmd+Z as VS Code's save/undo) ----
  // `viewer` bindings need the viewer frame focused (vaporview.waveformViewerFocused).
  const KEYBINDINGS = [
    { command: 'vaporview.showInNetlistView', label: '⌘R', viewer: true, match: (e) => cmd(e) && e.key.toLowerCase() === 'r' },
    { command: 'vaporview.searchNetlist', label: '⌘F', match: (e) => cmd(e) && e.key.toLowerCase() === 'f' },
    { command: 'vaporview.renameSignalGroup', label: 'F2', viewer: true, match: (e) => plain(e) && e.key === 'F2' },
    { command: 'vaporview.zoomToFit', label: '⌘0', viewer: true, match: (e) => cmd(e) && (e.key === '0' || e.code === 'Digit0') },
    { command: 'vaporview.increaseVerticalScale', label: '⌥=', viewer: true,
      match: (e) => e.altKey && !e.metaKey && !e.ctrlKey && (e.code === 'Equal' || e.code === 'NumpadAdd') },
    { command: 'vaporview.decreaseVerticalScale', label: '⌥-', viewer: true,
      match: (e) => e.altKey && !e.metaKey && !e.ctrlKey && (e.code === 'Minus' || e.code === 'NumpadSubtract') },
    { command: 'vaporview.newGroupFromSelection', label: 'G', viewer: true, match: (e) => plain(e) && e.key === 'g' },
    ...[1, 2, 3, 4, 5, 6, 7, 8].map((n) => ({ command: 'vaporview.defaultColor' + n, label: String(n), viewer: true,
      match: (e) => plain(e) && e.key === String(n) })),
    { command: 'vaporview.saveViewerSession', label: '⌘S', save: true, match: (e) => cmd(e) && e.key.toLowerCase() === 's' },
    { command: 'cmux.undo', label: '⌘Z', match: (e) => cmd(e) && e.key.toLowerCase() === 'z' },
    { command: 'cmux.redo', label: '⇧⌘Z', match: (e) => e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === 'z' },
  ];
  function cmd(e) { return e.metaKey && !e.shiftKey && !e.altKey && !e.ctrlKey; }
  function plain(e) { return !e.metaKey && !e.altKey && !e.ctrlKey && !e.shiftKey; }
  const KEY_LABELS = {};
  KEYBINDINGS.forEach((k) => { if (!KEY_LABELS[k.command]) { KEY_LABELS[k.command] = k.label; } });

  function isTextInput(target) {
    return !!(target && target.closest && target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])'));
  }

  function handleKey(e, inViewer) {
    if (e.defaultPrevented || ui().hasOpenOverlay() || isTextInput(e.target)) { return; }
    for (const binding of KEYBINDINGS) {
      if (binding.viewer && !inViewer) { continue; }
      if (!binding.match(e)) { continue; }
      e.preventDefault();
      e.stopImmediatePropagation();
      run(binding.command, undefined);
      return;
    }
  }

  // ---- settings (contributes.configuration, `vaporview.` dropped) ----
  // cmux reads FSDB through its own helper and has no WCP server, so the
  // fsdbAddonPath, fsdbReaderLibsPath and wcp.* keys do not apply.
  const COLOR_OPTIONS = [1, 2, 3, 4, 5, 6, 7, 8];
  const SETTINGS = [
    { key: 'scrollingMode', type: 'enum', options: [['Mouse', 'settingsOptionMouse'], ['Touchpad', 'settingsOptionTouchpad'], ['Auto', 'settingsOptionAuto']], value: 'Auto' },
    { key: 'touchpadPinchSensitivity', type: 'number', value: 1, step: 0.1, min: 0.1, max: 10 },
    { key: 'showRulerLines', type: 'boolean', value: true },
    { key: 'fillMultiBitValues', type: 'boolean', value: false },
    { key: 'multiBitFixedHeight', type: 'boolean', value: true },
    { key: 'enableAnimations', type: 'boolean', value: true },
    { key: 'animationDuration', type: 'number', value: 50, step: 10, min: 5, max: 500 },
    { key: 'useGlow', type: 'boolean', value: false },
    { key: 'removeGlitchTransitions', type: 'boolean', value: false },
    { key: 'defaultTimeUnit', type: 'enum', options: [['fs'], ['ps'], ['ns'], ['µs'], ['ms'], ['s'], ['none', 'settingsOptionNone']], value: 'none' },
    { key: 'defaultNameType', type: 'enum', options: [['fullPath', 'command.setNameTypeFullPath'], ['signalName', 'command.setNameTypeSignalName']], value: 'fullPath' },
    { key: 'defaultSingleBitColor', type: 'color', value: 1 },
    { key: 'defaultMultiBitColor', type: 'color', value: 1 },
    { key: 'defaultParamColor', type: 'color', value: 3 },
    { key: 'defaultStringColor', type: 'color', value: 2 },
    { key: 'defaultEnumColor', type: 'color', value: 1 },
    { key: 'defaultCustomSignalColor', type: 'color', value: 1 },
    { key: 'customColor5', type: 'string', value: '#ffa557' },
    { key: 'customColor6', type: 'string', value: '#dcdcaa' },
    { key: 'customColor7', type: 'string', value: '#d2a8ff' },
    { key: 'customColor8', type: 'string', value: '#4abfa8' },
    { key: 'sortNetlist', type: 'boolean', value: false },
    { key: 'promptLoadSettings', type: 'enum', options: [['Always', 'settingsOptionAlways'], ['Ask', 'settingsOptionAsk'], ['Never', 'settingsOptionNever']], value: 'Ask' },
    { key: 'defaultAutoReload', type: 'boolean', value: false },
    // cmux: how an FSDB on an SSH host loads. auto: windowed (big signals load what
    // is on screen, small ones whole); whole: every signal whole (the v1 helper).
    { key: 'fsdbLoading', type: 'enum', options: [['auto', 'settingsOptionFsdbAuto'], ['whole', 'settingsOptionFsdbWhole']], value: 'auto' },
    { key: 'enableInstancePathTerminalLinks', type: 'boolean', value: true },
    { key: 'overrideDevicePixelRatio', type: 'boolean', value: false },
    { key: 'userPixelRatio', type: 'number', value: 1, step: 0.25, min: 0.1, max: 10 },
    { key: 'disableAnalogRendererOptimizations', type: 'boolean', value: false },
  ];
  let settingsValues = {};

  function settings() {
    const out = {};
    SETTINGS.forEach((s) => { out[s.key] = s.key in settingsValues ? settingsValues[s.key] : s.value; });
    return out;
  }

  // A setting's value as package.json allows it (type, enum options, range), or undefined.
  function validSetting(key, value) {
    const def = SETTINGS.find((s) => s.key === key);
    if (!def) { return undefined; }
    switch (def.type) {
      case 'boolean': return typeof value === 'boolean' ? value : undefined;
      case 'number': {
        const n = Number(value);
        if (typeof value !== 'number' || !Number.isFinite(n)) { return undefined; }
        return Math.min(def.max ?? Infinity, Math.max(def.min ?? -Infinity, n));
      }
      case 'color': return COLOR_OPTIONS.includes(value) ? value : undefined;
      case 'enum': return def.options.some(([v]) => v === value) ? value : undefined;
      default: return typeof value === 'string' ? value : undefined;
    }
  }

  function loadSettings(values) {
    settingsValues = {};
    Object.entries(values || {}).forEach(([k, v]) => {
      const key = k.replace(/^vaporview\./, '');
      const value = validSetting(key, v);
      if (value !== undefined) { settingsValues[key] = value; }
    });
  }

  // Same fields as VaporviewDocument.setConfigurationSettings.
  function configMessage() {
    const c = settings();
    return {
      command: 'setConfigSettings',
      scrollingMode: c.scrollingMode,
      touchpadPinchSensitivity: c.touchpadPinchSensitivity,
      rulerLines: c.showRulerLines,
      overrideDevicePixelRatio: c.overrideDevicePixelRatio,
      userPixelRatio: c.userPixelRatio,
      fillMultiBitValues: c.fillMultiBitValues,
      multiBitFixedHeight: c.multiBitFixedHeight,
      removeGlitchTransitions: c.removeGlitchTransitions,
      defaultTimeUnit: c.defaultTimeUnit,
      enableAnimations: c.enableAnimations,
      animationDuration: c.animationDuration,
      useGlow: c.useGlow,
      disableAnalogRendererOptimizations: c.disableAnalogRendererOptimizations,
      defaultNameType: c.defaultNameType,
      defaultSingleBitColor: c.defaultSingleBitColor,
      defaultMultiBitColor: c.defaultMultiBitColor,
      defaultParamColor: c.defaultParamColor,
      defaultStringColor: c.defaultStringColor,
      defaultEnumColor: c.defaultEnumColor,
      defaultCustomSignalColor: c.defaultCustomSignalColor,
      customColorPalette: [c.customColor5, c.customColor6, c.customColor7, c.customColor8],
    };
  }

  function updateSetting(key, value) {
    const name = String(key).replace(/^vaporview\./, '');
    const valid = validSetting(name, value);
    if (valid === undefined) { return; }
    settingsValues[name] = valid;
    persistSettings();
  }

  function persistSettings() {
    host().toNative({ type: 'settings', values: Object.assign({}, settingsValues) });
    host().toWebview(configMessage());
    if (window.cmuxNetlist && host().doc.netlist.length) { window.cmuxNetlist.render(host().doc.netlist); }
  }

  function showSettings() {
    const s = S();
    return ui().modal((box, finish) => {
      box.classList.add('cmux-settings');
      const heading = document.createElement('div');
      heading.className = 'cmux-dialog-title';
      heading.textContent = s.settingsTitle || '';
      const list = document.createElement('div');
      list.className = 'cmux-settings-list';
      const current = settings();
      for (const def of SETTINGS) {
        const row = document.createElement('label');
        row.className = 'cmux-setting';
        const name = document.createElement('span');
        name.textContent = s['setting.' + def.key] || def.key;
        let input;
        if (def.type === 'boolean') {
          input = document.createElement('input');
          input.type = 'checkbox';
          input.checked = !!current[def.key];
          input.addEventListener('change', () => updateSetting(def.key, input.checked));
          row.append(input, name);
        } else if (def.type === 'enum' || def.type === 'color') {
          input = document.createElement('select');
          const options = def.type === 'color' ? COLOR_OPTIONS.map((n) => [n, null, title('vaporview.defaultColor' + n)]) : def.options;
          for (const [value, labelKey, label] of options) {
            const o = document.createElement('option');
            o.value = String(value);
            o.textContent = label || (labelKey && s[labelKey]) || String(value);
            if (String(current[def.key]) === String(value)) { o.selected = true; }
            input.appendChild(o);
          }
          input.addEventListener('change', () => updateSetting(def.key, def.type === 'color' ? Number(input.value) : input.value));
          row.append(name, input);
        } else {
          input = document.createElement('input');
          input.type = def.type === 'number' ? 'number' : 'text';
          if (def.step) { input.step = String(def.step); }
          if (def.min !== undefined) { input.min = String(def.min); }
          if (def.max !== undefined) { input.max = String(def.max); }
          input.value = String(current[def.key]);
          input.spellcheck = false;
          input.addEventListener('change', () => {
            const v = def.type === 'number' ? Number(input.value) : input.value.trim();
            if (def.type === 'number' && !Number.isFinite(v)) { input.value = String(settings()[def.key]); return; }
            updateSetting(def.key, v);
            input.value = String(settings()[def.key]);
          });
          row.append(name, input);
        }
        list.appendChild(row);
      }
      const buttons = document.createElement('div');
      buttons.className = 'cmux-dialog-buttons';
      buttons.append(
        ui().button(s.settingsReset, () => { settingsValues = {}; persistSettings(); finish(); showSettings(); }),
        ui().button(s.settingsClose, () => finish(), true),
      );
      box.append(heading, list, buttons);
    });
  }

  // ---- time helpers (src/common/functions.ts) ----
  const LOG_SCALE = { zs: -21, as: -18, fs: -15, ps: -12, ns: -9, us: -6, 'µs': -6, ms: -3, s: 0, ks: 3 };
  const logScale = (unit) => LOG_SCALE[unit] ?? 0;
  const scale = (unit) => 10 ** logScale(unit);

  function formatTime(time, unit) {
    const metadata = host().doc.metadata;
    const offset = logScale(metadata.timeUnit) - logScale(unit);
    const value = offset > 0 ? time * metadata.timeScale * (10 ** offset) : time * metadata.timeScale / (10 ** -offset);
    const parts = value.toString().split('.');
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return parts.join('.') + ' ' + unit;
  }

  function timeHz(deltaT, unit) {
    const hz = Math.abs(1 / (deltaT * scale(unit)));
    const steps = [[1e15, 'PHz'], [1e12, 'THz'], [1e9, 'GHz'], [1e6, 'MHz'], [1e3, 'kHz']];
    const [divisor, units] = steps.find(([d]) => hz >= d) || [1, 'Hz'];
    return Number((hz / divisor).toPrecision(3)) + ' ' + units;
  }

  // ---- webview context, session and undo (VaporviewDocument) ----
  let webviewContext = null;   // latest contextUpdate, as VaporviewDocument.webviewContext
  let undoStack = [];
  let redoStack = [];
  // From willReload until the reloaded viewer asks for its state (restoreState):
  // cmux holds no context, and reloadBaseline is the view from before the
  // reload, kept current by what the old viewer still sends. Its selected
  // signal is held by name, as the old netlist is gone.
  let reloading = false;
  let reloadBaseline = null;
  // During a reload, once the old viewer has handled the unload (it posts
  // ready): it is empty, and only its Auto Reload checkbox still means anything.
  let frameGone = false;
  // Whether the view kept through the reload was the viewer's live context
  // (not a restore that hadn't reached it): then it is what comes back.
  let keptIsCurrent = false;
  let dirty = false;

  // ---- value aliases ----
  // The alias files loaded into this viewer, [{ fileName, text }] (one per name,
  // the latest kept). The tables live in the viewer frame; cmux keeps the files
  // so a saved session, cmux's kept state and a restore bring them back.
  let aliasFiles = [];
  // Loads posted and not answered yet, in order: { fileName, text, user }.
  let aliasLoads = [];
  const MAX_ALIAS_FILES = 16;
  const MAX_ALIAS_TEXT = 8 * 1024 * 1024;

  function postAliasFile(fileName, text, user) {
    aliasLoads.push({ fileName, text, user });
    // A file's own signal bindings apply when the user loads it, not on a restore.
    host().toWebview({ command: 'loadValueAliases', fileName, text, apply: user });
  }

  function keepAliasFile(fileName, text) {
    aliasFiles = aliasFiles.filter((f) => f.fileName !== fileName).concat([{ fileName, text }]).slice(-MAX_ALIAS_FILES);
  }

  // cmux read the file the user picked (or couldn't).
  function applyValueAliasFile({ text, path, error } = {}) {
    const fileName = String(path || '').split('/').pop() || 'alias';
    if (error || typeof text !== 'string') {
      ui().toast(format(S().messageValueAliasLoadFailed, error || fileName), 'error');
      return;
    }
    postAliasFile(fileName, text, true);
  }

  // The viewer's answer to loadValueAliases (extra_formats.ts).
  function valueAliasesLoaded(result) {
    const r = result && typeof result === 'object' ? result : {};
    const index = aliasLoads.findIndex((l) => l.fileName === r.fileName);
    const load = index >= 0 ? aliasLoads.splice(index, 1)[0] : null;
    if (!load) { return; }
    const tables = Array.isArray(r.tables) ? r.tables : [];
    if (r.error || !tables.length) {
      if (load.user) { ui().toast(format(S().messageValueAliasLoadFailed, r.error || S().messageValueAliasNoTables), 'error'); }
      return;
    }
    keepAliasFile(load.fileName, load.text);
    const warnings = Array.isArray(r.warnings) ? r.warnings : [];
    if (load.user && warnings.length) {
      host().log('alias file ' + load.fileName + ': ' + warnings.join('; '));
      ui().toast(format(S().messageValueAliasWarnings, load.fileName, warnings[0]), 'warning');
    }
    if (load.user) { setDirty(true); }
    scheduleSessionSnapshot();
  }

  // A session's files, as saved (cmuxValueAliases): only well-formed entries.
  function sessionAliasFiles(session) {
    const list = session && Array.isArray(session.cmuxValueAliases) ? session.cmuxValueAliases : [];
    return list.filter((f) => f && typeof f.fileName === 'string' && typeof f.text === 'string' && f.text.length <= MAX_ALIAS_TEXT)
      .slice(-MAX_ALIAS_FILES);
  }

  function withAliasFiles(state) {
    return state && aliasFiles.length ? Object.assign(state, { cmuxValueAliases: aliasFiles.slice() }) : state;
  }

  // The viewer's loaded alias tables (window.vaporviewValueFormats in the frame).
  function aliasFormats() {
    try {
      const formats = document.getElementById('viewer').contentWindow.vaporviewValueFormats;
      return formats.listFormats().filter((f) => f && typeof f.id === 'string' && f.id.startsWith('alias:'));
    } catch (error) {
      return [];
    }
  }

  // The Alias submenu: one entry per table, then Remove Alias (back to hex).
  function aliasMenuEntries() {
    const tables = aliasFormats();
    if (!tables.length) { return []; }
    return tables.map((f, i) => ({ alias: f.id, label: f.id.slice('alias:'.length), group: '0_tables@' + i }))
      .concat([{ command: 'vaporview.removeValueAlias', group: '1_remove@1' }]);
  }

  function contextSession(context) {
    if (!context) { return null; }
    return {
      markerTime: context.markerTime, altMarkerTime: context.altMarkerTime, displayTimeUnit: context.displayTimeUnit,
      selectedSignal: context.selectedSignal, zoomRatio: context.zoomRatio, scrollLeft: context.scrollLeft,
      defaultPixelTime: context.defaultPixelTime, autoReload: context.autoReload,
      displayedSignals: withoutLocals(context.displayedSignals || []),
    };
  }

  // The debugger's Locals group follows the editor's caret; sessions and undo leave it out.
  function withoutLocals(list) {
    const isLocals = window.cmuxDebugger && window.cmuxDebugger.isLocals;
    return isLocals ? list.filter((d) => !isLocals(d)) : list;
  }

  function onContextUpdate(m) {
    let change = m.stateChangeType;
    if (reloading && frameGone) {
      if (reloadBaseline && m.autoReload !== undefined) { reloadBaseline.autoReload = !!m.autoReload; }
      return;
    }
    // The debugger's own edits (Locals, while it dispatches quietly) and its play ticks are not the user's:
    // no undo entries, not unsaved.
    const playing = !!(window.cmuxDebugger && window.cmuxDebugger.isPlaying());
    // While playing, a first context (none kept yet) counts as the debugger's too: nothing to compare.
    const debuggerChange = host().quietEvents > 0 || (playing && (!webviewContext || onlyMarkerMoved(webviewContext, m)));
    if (debuggerChange && change === StateChangeType.User) { change = null; }
    if (change === StateChangeType.User || change === StateChangeType.File) {
      undoStack.push(JSON.stringify(undoState()));
      if (undoStack.length > 50) { undoStack.shift(); }
      redoStack = [];
    }
    if (change === StateChangeType.User) { setDirty(true); }
    // The old viewer keeps its rows until it handles the unload, and anything
    // it sends until then (Auto Reload switched, a queued add) describes them.
    if (reloading) {
      const before = reloadBaseline || {};
      const next = contextSession(Object.assign({}, before, m));
      // A selection changed now can't be named: the old netlist is gone.
      reloadBaseline = Object.assign(next, { cmuxSelected: next.selectedSignal === before.selectedSignal ? before.cmuxSelected : null });
      return;
    }
    webviewContext = Object.assign({}, webviewContext || {}, m);
    reloadBaseline = null;
    if (applying && ANSWER_TYPES.includes(m.stateChangeType)) { applying--; }
    // The viewer answers apply-state with a Restore context (initComplete is set
    // right after it asks for its state, so the answer always comes).
    if (appliedRestoreConfig && change === StateChangeType.Restore) {
      appliedRestoreConfig.restore = null;
      appliedRestoreConfig = null;
      restorePending = false;
    }
    updateStatus(m);
    window.cmuxNetlist.setDisplayed(displayedNetlistIds(webviewContext.displayedSignals || []));
    scheduleSessionSnapshot();
    if (m.autoReload && pendingReload) {
      pendingReload = false;
      document.getElementById('status-reload').hidden = true;
      host().toNative({ type: 'reload' });
    }
    runWaitingHistory();
  }

  // Whether context update `m` changes nothing a session keeps but the marker (and the view panning to it).
  function onlyMarkerMoved(before, m) {
    const a = contextSession(before);
    const b = contextSession(Object.assign({}, before, m));
    a.markerTime = b.markerTime;
    a.scrollLeft = b.scrollLeft;
    return JSON.stringify(a) === JSON.stringify(b);
  }

  function displayedNetlistIds(list, out = []) {
    for (const item of list) {
      if (item.netlistId !== undefined) { out.push(item.netlistId); }
      if (item.children) { displayedNetlistIds(item.children, out); }
    }
    return out;
  }

  // cmux keeps the latest state so a page reload (file change, WebKit
  // crash) restores the same signals.
  let snapshotTimer = 0;
  let snapshotScheduled = false;
  function sendSessionSnapshot() {
    clearTimeout(snapshotTimer);
    snapshotScheduled = false;
    const state = plainJSON(withAliasFiles(contextSession(webviewContext)));
    if (state && !restorePending) { host().toNative({ type: 'sessionState', state, dirty }); }
  }
  function scheduleSessionSnapshot() {
    clearTimeout(snapshotTimer);
    snapshotScheduled = true;
    snapshotTimer = setTimeout(sendSessionSnapshot, 250);
  }

  // NaN and Infinity become null, so cmux can always pass the state back as JSON.
  function plainJSON(value) {
    return value === null || value === undefined ? value : JSON.parse(JSON.stringify(value));
  }

  // Whether parsed JSON is a VaporView session (VaporviewDocument.getWebviewSession).
  function isSession(data) {
    return !!data && typeof data === 'object' && !Array.isArray(data) && Array.isArray(data.displayedSignals);
  }

  function setDirty(value) {
    dirty = value;
    document.getElementById('status-unsaved').hidden = !dirty;
  }

  // VaporviewDocument.getWebviewSession: what a session file holds.
  // The selected row as a session file names it, while its netlist is open.
  function selectedSignalRef(id) {
    const selected = id !== undefined && id !== null ? host().netlistItem(id) : null;
    return selected ? { name: window.cmuxNetlist.instancePath(selected), msb: selected.msb, lsb: selected.lsb } : null;
  }

  // During a reload: the view from before it (VaporView keeps its context
  // through reload()).
  function sessionFile() {
    const w = webviewContext || reloadBaseline || {};
    return {
      extensionVersion: EXTENSION_VERSION,
      fileName: host().config.path || host().config.url,
      markerTime: w.markerTime,
      altMarkerTime: w.altMarkerTime,
      displayTimeUnit: w.displayTimeUnit,
      selectedSignal: webviewContext ? selectedSignalRef(w.selectedSignal) : (w.cmuxSelected || null),
      zoomRatio: w.zoomRatio,
      scrollLeft: w.scrollLeft,
      defaultPixelTime: w.defaultPixelTime,
      displayedSignals: withoutLocals(w.displayedSignals || []),
      // cmux addition: the value alias files the rows' alias formats need.
      ...(aliasFiles.length ? { cmuxValueAliases: aliasFiles.slice() } : {}),
    };
  }

  // VaporviewDocument.convertSignalListToSettings: resolve saved rows to the
  // netlist of the file that is open now, by instance path.
  async function convertSignalList(list, missing) {
    const out = [];
    for (const signal of Array.isArray(list) ? list : []) {
      try {
        if (signal.dataType === 'signal-group') {
          out.push(Object.assign({}, signal, { children: await convertSignalList(signal.children || [], missing) }));
        } else if (signal.dataType === 'signal-separator') {
          out.push(signal);
        } else if (signal.dataType === 'custom-variable') {
          const source = [];
          for (const s of signal.source || []) {
            const v = await host().findItem(s.name, s.msb, s.lsb, true);
            if (!v || v.kind !== 'var' || s.lsb >= v.width) {
              missing.push(s.name);
              source.push({ name: s.name, netlistId: undefined, signalId: undefined, signalWidth: s.signalWidth, msb: s.msb, lsb: Math.max(s.lsb, 0) });
            } else {
              source.push({ name: window.cmuxNetlist.instancePath(v), netlistId: v.netlistId, signalId: v.signalId,
                signalWidth: v.width, msb: Math.min(s.msb, v.width - 1), lsb: Math.max(s.lsb, 0) });
            }
          }
          out.push(Object.assign({}, signal, { encoding: 'BitVector', source }));
        } else if (signal.dataType === 'netlist-variable' || signal.dataType === undefined) {
          const v = await host().findItem(signal.name, signal.msb, signal.lsb, true);
          if (!v || v.kind !== 'var') {
            missing.push(signal.name);
            out.push(missingRow(signal));
            continue;
          }
          out.push(Object.assign({}, signal, { dataType: 'netlist-variable', netlistId: v.netlistId, signalId: v.signalId,
            signalName: v.name, scopePath: v.scopePath, signalWidth: v.width, type: v.type, encoding: v.encoding,
            enumType: v.enumType, msb: v.msb, lsb: v.lsb }));
        }
      } catch (error) {
        // A lookup that failed (the backend closed for a reload, say) keeps
        // the row too, so a save can't lose it.
        host().log('session row: ' + error);
        missing.push(signal.name);
        out.push(signal.dataType === 'netlist-variable' || signal.dataType === undefined ? missingRow(signal) : signal);
      }
    }
    return out;
  }

  // parseNetlistVariableSettings: a row whose signal isn't in the file stays, as
  // a missing signal, so a reload or a later save keeps the layout.
  function missingRow(signal) {
    const parts = String(signal.name || '').split('.');
    return Object.assign({}, signal, { dataType: 'netlist-variable', netlistId: undefined, signalId: undefined,
      signalName: parts.pop(), scopePath: parts });
  }

  // Resolves to whether the state reached the viewer: false when there was none,
  // or a reload or open overtook it.
  async function applySession(session, stateChangeType) {
    if (!session) { return false; }
    // Counted from now: a waiting Undo must not run while this resolves or
    // before the viewer answers it.
    // Only a viewer that has asked for its state answers an apply-state (before
    // its init completes it ignores one): only those are waited for.
    const epoch = applyEpoch;
    const counted = restoreAsked;
    if (counted) { applying++; }
    let posted = false;
    try {
      posted = await postSession(session, stateChangeType);
      return posted;
    } finally {
      if (counted && !posted && epoch === applyEpoch) { applying = Math.max(0, applying - 1); }
    }
  }

  // apply-state posts not answered yet (the viewer answers each with a context
  // of the same stateChangeType), counted per load: a reload or open resets.
  let applying = 0;
  let applyEpoch = 0;
  // A view still unanswered at a reload or open held the waiting presses back
  // in that load; they don't carry into the next one.
  function resetApplying() {
    if (applying) { waitingHistory = []; }
    applying = 0;
    applyEpoch++;
  }
  const ANSWER_TYPES = [StateChangeType.Restore, StateChangeType.File, StateChangeType.Undo, StateChangeType.Redo];

  async function postSession(session, stateChangeType) {
    // A reload or open that starts while this resolves rows makes it stale: its
    // rows would land in the next file's viewer, and its state would win there.
    const generation = host().loadGeneration;
    const missing = [];
    const displayedSignals = await convertSignalList(session.displayedSignals || [], missing);
    // A file holds { name, msb, lsb } (or, from older cmux, the name); the
    // viewer's own state holds the netlistId.
    let selectedSignal = session.selectedSignal;
    if (typeof selectedSignal === 'string' || (selectedSignal && typeof selectedSignal === 'object')) {
      const s = typeof selectedSignal === 'string' ? { name: selectedSignal } : selectedSignal;
      const v = s.name ? await host().findItem(s.name, s.msb, s.lsb, true).catch(() => null) : null;
      selectedSignal = v && v.kind === 'var' ? v.netlistId : undefined;
    }
    if (host().loadGeneration !== generation) { return false; }
    if (stateChangeType !== StateChangeType.Restore) { restorePending = false; }
    // The alias tables first: the viewer handles messages in order, so the
    // rows' alias formats find them.
    for (const f of sessionAliasFiles(session)) { postAliasFile(f.fileName, f.text, false); }
    host().toWebview({ command: 'apply-state', stateChangeType, state: {
      extensionVersion: session.extensionVersion, displayedSignals, markerTime: session.markerTime,
      altMarkerTime: session.altMarkerTime, displayTimeUnit: session.displayTimeUnit, selectedSignal,
      zoomRatio: session.zoomRatio, scrollLeft: session.scrollLeft, defaultPixelTime: session.defaultPixelTime,
      autoReload: session.autoReload,
    } });
    if (missing.length) {
      const text = format(S().messageMissingSignals, missing.join(', '));
      host().log(text);
      ui().toast(text, 'warning');
    }
    return true;
  }

  // The webview asks for its state after initViewport (restoreState). Its own
  // saved state (kept in the frame across an in-page reload) wins, then the
  // state cmux kept from a previous page, then <dump>.json next to the file.
  // <dump>.json is offered once per open: once the viewer has asked for its
  // state and cmux has read the file (setSessionFile), whichever comes last.
  let restoreAsked = false;
  let sessionFileOffered = false;
  // While a restore resolves, the viewer's context is empty: cmux keeps its copy.
  let restorePending = false;
  // The config whose kept restore was posted: dropped once the viewer's context
  // comes back with it (onContextUpdate), so a reload in between still has it.
  let appliedRestoreConfig = null;

  async function restoreState(m) {
    const config = host().config;
    // The frame's own saved state took whatever the emptied viewer did during
    // the gap (a marker set, Auto Reload): after an unload, cmux's kept view
    // decides.
    const afterUnload = reloading && frameGone;
    const kept = afterUnload && keptIsCurrent && reloadBaseline ? reloadBaseline : null;
    // The reloaded viewer is live: what it sends from here is its own. Views
    // posted to the old one were answered (or not) before its unload.
    reloading = false;
    frameGone = false;
    applying = 0;
    applyEpoch++;
    // A failure on the way (a handler's error) didn't stop this reload.
    failedReload = false;
    restoreAsked = true;
    restorePending = false;
    if (kept) {
      sessionFileOffered = true;
      restorePending = true;
      // The alias files too, in case the reloaded frame lost its tables.
      const state = withAliasFiles(Object.assign(contextSession(kept), { selectedSignal: kept.cmuxSelected || undefined }));
      if (await applySession(state, StateChangeType.Restore)) { appliedRestoreConfig = config; }
      return;
    }
    // cmux's kept state is cleared only once it reached the viewer: a reload
    // that overtakes the apply carries it on (host.js reload).
    if (m.state && !afterUnload) {
      sessionFileOffered = true;
      restorePending = true;
      if (await applySession(withAliasFiles(Object.assign({}, m.state)), StateChangeType.Restore)) { appliedRestoreConfig = config; }
      return;
    }
    if (config.restore && config.restore.state) {
      sessionFileOffered = true;
      restorePending = true;
      const restore = config.restore;
      if (await applySession(restore.state, StateChangeType.Restore)) {
        appliedRestoreConfig = config;
        setDirty(!!restore.dirty);
      }
      return;
    }
    await offerSessionFile();
    // Nothing to restore: an Undo pressed during the reload runs now.
    runWaitingHistory();
  }

  async function offerSessionFile() {
    const file = host().config.sessionFile;
    if (!restoreAsked || sessionFileOffered || !file || !file.text) { return; }
    sessionFileOffered = true;
    // cmux reads the file after the viewer opened (from an SSH host, seconds
    // later): once the user has changed the view, a late file must not replace it.
    if (dirty || undoStack.length) { return; }
    const mode = settings().promptLoadSettings;
    if (mode === 'Never') { return; }
    try {
      if (!isSession(JSON.parse(file.text))) { return; }
    } catch (error) {
      return;
    }
    if (mode === 'Ask') {
      const s = S();
      const answer = await ui().confirm({ message: format(s.messageRestoreSession, file.path), detail: s.messageRestoreSessionDetail,
        buttons: [{ label: s.dialogSettings, value: 'settings' }, { label: s.dialogNo, value: 'no' }, { label: s.dialogYes, value: 'yes' }] });
      if (answer === 'settings') { showSettings(); return; }
      if (answer !== 'yes') { return; }
    }
    await loadSessionText(file.text, file.path, mode === 'Ask');
  }

  // userStarted: the user picked the file or said yes, so an interrupted load is reported.
  async function loadSessionText(text, path, userStarted) {
    let data;
    try {
      data = JSON.parse(text);
    } catch (error) {
      ui().toast(format(S().messageSessionLoadFailed, String(error.message || error)), 'error');
      return;
    }
    if (!isSession(data)) {
      ui().toast(format(S().messageSessionLoadFailed, S().messageNotASession), 'error');
      return;
    }
    if (data.fileName && host().config.path && data.fileName !== host().config.path) {
      ui().toast(S().messageSessionMismatch, 'warning');
    }
    const filePath = host().config.path;
    if (await applySession(data, StateChangeType.File)) {
      setDirty(false);
    } else if (userStarted) {
      // The panel opened another file, or this one reloaded.
      ui().toast(host().config.path !== filePath ? S().messageSessionLoadInterruptedByOpen : S().messageSessionLoadInterrupted,
        'warning');
    }
  }

  // Save Vaporview Session...: cmux always asks where, as VaporView's command does.
  function saveSession() {
    const name = (host().config.path || host().config.url || 'untitled').split('/').pop().replace(/\.[^/.]+$/, '') + '.json';
    host().toNative({ type: 'saveSession', text: JSON.stringify(sessionFile(), null, 2), suggestedName: name });
  }

  // The view to go back to. During a reload's gap it is the view before the
  // reload. Before the viewer's first context, VaporView's document holds an
  // empty one (new WebviewState(), document.ts), so the first change undoes;
  // its display unit is the file's rather than a fixed "ns".
  function undoState() {
    const metadata = host().doc.metadata;
    return contextSession(webviewContext) || contextSession(reloadBaseline) || {
      markerTime: null, altMarkerTime: null, displayTimeUnit: (metadata && metadata.timeUnit) || 'ns',
      selectedSignal: null, zoomRatio: 1, scrollLeft: 0, defaultPixelTime: 1,
      autoReload: !!settings().defaultAutoReload, displayedSignals: [],
    };
  }

  // Undo/Redo pressed while a reload or its restore is pending, in order. A
  // reloading viewer has no rows to apply a view to, and its restore (until
  // the viewer answers it) would overwrite one: they run once it is back.
  let waitingHistory = [];
  // The reload in progress failed (or its viewer did): until the next reload
  // or open, nothing is shown to undo, so presses are dropped.
  let failedReload = false;
  // The path the waiting history belongs to.
  let historyPath = null;

  // Whether a view was applied (its answer then runs the next waiting one).
  function undo(stack, other, type) {
    if (failedReload) { return false; }
    if (reloading || restorePending) {
      if (waitingHistory.length < 50) { waitingHistory.push(type); }
      return false;
    }
    if (!stack.length) { return false; }
    const state = JSON.parse(stack.pop());
    other.push(JSON.stringify(undoState()));
    applySession(state, type);
    return true;
  }

  function runWaitingHistory() {
    while (waitingHistory.length && !reloading && !restorePending && !applying) {
      const type = waitingHistory.shift();
      const applied = type === StateChangeType.Undo
        ? undo(undoStack, redoStack, StateChangeType.Undo) : undo(redoStack, undoStack, StateChangeType.Redo);
      if (applied) { return; }
    }
  }

  // ---- status strip (VaporviewStatusBar) ----
  function updateStatus(event) {
    const doc = host().doc;
    if (!doc.metadata) { return; }
    const s = S();
    const w = webviewContext || {};
    const unit = event.displayTimeUnit || w.displayTimeUnit || doc.metadata.timeUnit;
    const timeEl = document.getElementById('status-time');
    const deltaEl = document.getElementById('status-delta');
    const signalEl = document.getElementById('status-signal');
    if (w.markerTime || w.markerTime === 0) {
      timeEl.textContent = format(s.statusTime, formatTime(w.markerTime, unit));
      const hasAlt = w.altMarkerTime !== null && w.altMarkerTime !== undefined;
      deltaEl.hidden = !hasAlt;
      if (hasAlt) {
        const delta = w.markerTime - w.altMarkerTime;
        deltaEl.textContent = format(s.statusDelta, formatTime(delta, unit), timeHz(delta * doc.metadata.timeScale, doc.metadata.timeUnit));
      }
    } else {
      deltaEl.hidden = true;
      timeEl.textContent = format(s.statusTimeUnits, unit);
    }
    timeEl.title = s.statusTimeUnitsTooltip || '';
    const item = w.selectedSignal !== undefined && w.selectedSignal !== null ? host().netlistItem(w.selectedSignal) : null;
    signalEl.hidden = false;
    if (item) {
      let text = format(s.statusSelectedSignal, item.name);
      if (event.transitionCount !== undefined && event.transitionCount !== null) {
        text += ' · ' + format(s.statusValueChanges, String(event.transitionCount).replace(/\B(?=(\d{3})+(?!\d))/g, ','));
      }
      signalEl.textContent = text;
    } else if (event.selectedSignalCount > 1) {
      signalEl.textContent = format(s.statusSelectedSignals, event.selectedSignalCount);
    } else {
      signalEl.hidden = true;
    }
  }

  // ---- file changes (VaporviewDocument file watcher) ----
  let pendingReload = false;

  function fileChanged() {
    // During or after a failed reload, the view from before it decides; a
    // newer reload supersedes one in progress (host.js load generations).
    const w = webviewContext || reloadBaseline;
    if (w && w.autoReload) { host().toNative({ type: 'reload' }); return; }
    pendingReload = true;
    document.getElementById('status-reload').hidden = false;
  }

  // ---- helpers used by commands ----
  function selectedNetlistVars() {
    return window.cmuxNetlist.selectedItems().filter((x) => x.kind === 'var');
  }

  async function addFiltered(vars, noWarning, mode) {
    const list = vars.filter((x) => x.kind === 'var');
    if (list.length > 48 && !noWarning) {
      const s = S();
      const answer = await ui().confirm({ message: s.messageManySignals,
        buttons: [{ label: s.dialogNo, value: false }, { label: s.dialogYes, value: true }] });
      if (!answer) { return; }
    }
    host().addVariables(list, undefined, undefined, mode);
  }

  // Add All in Scope's signals, leaving out those shown already (and repeats):
  // the warning and the cap count only what would be added.
  async function scopeVariables(scope, recursive, maxChildren) {
    const vars = [];
    const seen = new Set();
    const shown = host().alreadyShown || (() => false);
    const scopes = [scope];
    while (scopes.length && vars.length < maxChildren) {
      const children = await host().getChildren(scopes.shift());
      children.forEach((c) => {
        if (c.kind === 'var') {
          if (vars.length < maxChildren && !seen.has(c.netlistId) && !shown(c.netlistId)) { seen.add(c.netlistId); vars.push(c); }
        } else if (c.kind === 'scope' && recursive) { scopes.push(c); }
      });
    }
    return vars;
  }

  // ViewerProvider.getNetlistItemFromSignalName + addSignalByNameToDocument.
  async function addSignalByName(name, msb, lsb, quiet) {
    let path = String(name).trim().replace(/[:;]$/, '');
    const field = /\[(\d+:)?(\d+)\]$/.exec(path);
    if (field && msb === undefined) {
      msb = field[1] ? parseInt(field[1], 10) : parseInt(field[2], 10);
      lsb = parseInt(field[2], 10);
      path = path.replace(/\[(\d+:)?(\d+)\]$/, '');
    }
    const item = await host().findItem(path, msb, lsb, false);
    if (!item) {
      if (!quiet) { ui().toast(format(S().messageSignalNotFound, name), 'warning'); }
      return false;
    }
    if (item.kind === 'scope') { window.cmuxNetlist.focusSearch(item); return true; }
    // Shown already: addVariables selects its row (VaporView's reveal).
    host().addVariables([item], undefined, undefined, 'reveal');
    return true;
  }

  function setMarker(time, units, markerType) {
    const metadata = host().doc.metadata;
    if (!metadata || time === undefined || time === null || Number.isNaN(Number(time))) { return false; }
    let t = Number(time);
    if (units !== undefined && units !== null && units !== '') {
      t = Math.round(t * scale(units) / (scale(metadata.timeUnit) * metadata.timeScale));
    }
    if (t < 0 || t > metadata.timeEnd) { return false; }
    host().toWebview({ command: 'setMarker', time: t, markerType: markerType || 0 });
    return true;
  }

  function displayFormat(e, properties) {
    host().toWebview(Object.assign({ command: 'setDisplayFormat', netlistId: e ? e.netlistId : undefined,
      rowId: e ? e.rowId : undefined, index: undefined }, properties));
  }

  const keypress = (keyCommand) => (e) => host().toWebview({ command: 'handle-keypress', keyCommand, event: e || null });

  async function askNumberFormat(e, prefix) {
    const offset = await ui().prompt({ title: S().promptFixedPointOffset, value: '0' });
    if (!offset) { return; }
    displayFormat(e, { numberFormat: prefix + offset });
  }

  function copyName(e) {
    if (!e) { return; }
    let text = '';
    const scopePath = Array.isArray(e.scopePath) ? e.scopePath.join('.') : e.scopePath;
    if (scopePath) { text += scopePath + '.'; }
    if (e.name) { text += e.name; }
    if (e.signalName) { text += e.signalName; }
    host().toNative({ type: 'copy', text });
  }

  async function setTimeUnits(units) {
    const metadata = host().doc.metadata;
    if (!units) {
      const maxTime = scale(metadata.timeUnit) * metadata.timeScale * metadata.timeEnd;
      const choices = ['fs', 'ps', 'ns', 'µs', 'ms', 's'].filter((u) => scale(u) <= maxTime);
      units = await ui().quickPick({ title: S().promptTimeUnits, items: choices.map((u) => ({ label: u, value: u })) });
      if (!units) { return; }
    }
    host().toWebview({ command: 'updateRulerSettings', units });
  }

  async function setRulerIncrement() {
    const increment = await ui().prompt({ title: S().promptRulerIncrement, value: '' });
    if (increment === undefined) { return; }
    const metadata = host().doc.metadata;
    const [time, units] = increment.trim().split(/\s+/);
    const value = parseFloat(time);
    if (Number.isNaN(value)) { return; }
    const timeScale = units ? 10 ** (logScale(units) - logScale(metadata.timeUnit)) : 1;
    host().toWebview({ command: 'updateRulerSettings', pixelTime: value * timeScale });
  }

  function groupArgs(e) {
    e = e || {};
    return { groupPath: e.groupPath, parentGroupId: e.parentGroupId, eventRowId: e.rowId };
  }

  // ---- the command table (commands.ts) ----
  const COMMANDS = {
    // External API (VaporView's waveformViewer.* commands)
    'waveformViewer.setMarker': (e) => setMarker(e.time, e.units, e.markerType),
    'waveformViewer.addVariable': (e) => (e.netlistId !== undefined && host().netlistItem(e.netlistId)
      ? host().addVariables([host().netlistItem(e.netlistId)]) : addSignalByName(e.instancePath, e.msb, e.lsb, e.quiet)),
    'waveformViewer.removeVariable': async (e) => {
      const v = e.netlistId !== undefined ? host().netlistItem(e.netlistId) : await host().findItem(e.instancePath, e.msb, e.lsb, true);
      if (v) { host().toWebview({ command: 'remove-signal', netlistId: v.netlistId, rowId: undefined, removeAllSelected: false }); }
    },
    'waveformViewer.revealInNetlistView': async (e) => {
      const v = e.netlistId !== undefined ? host().netlistItem(e.netlistId) : await host().findItem(e.instancePath, e.msb, e.lsb, true);
      if (v) { window.cmuxNetlist.reveal(v.netlistId); }
    },
    'waveformViewer.getViewerState': () => sessionFile(),
    'waveformViewer.loadViewerState': (e) => applySession(e.state || e, StateChangeType.File),
    'waveformViewer.getValuesAtTime': (e) => host().valuesAtTime(e.time, e.instancePaths || []),
    'waveformViewerNetlistView.focus': () => window.cmuxNetlist.focusSearch(),

    // Netlist
    'vaporview.searchNetlist': () => window.cmuxNetlist.focusSearch(null),
    'vaporview.searchScope': (e) => window.cmuxNetlist.focusSearch(e),
    'vaporview.addVariableByInstancePath': async (e) => {
      if (e && e.instancePath) { return addSignalByName(e.instancePath); }
      const name = await ui().prompt({ title: S().promptVariableName, placeholder: 'top.mid.var' });
      if (name) { await addSignalByName(name); }
    },
    'vaporview.addVariable': (e) => addFiltered([e], true),
    'vaporview.addSelected': () => addFiltered(selectedNetlistVars(), false),
    'vaporview.removeSelectedNetlist': () => selectedNetlistVars().forEach((v) =>
      host().toWebview({ command: 'remove-signal', netlistId: v.netlistId, rowId: undefined, removeAllSelected: false })),
    'vaporview.addAllInScopeShallow': async (e) => addScope(e, false),
    'vaporview.addAllInScopeRecursive': async (e) => addScope(e, true),
    'vaporview.removeAllInScope': async (e) => {
      if (!e || e.kind !== 'scope') { return; }
      (await host().getChildren(e)).filter((c) => c.kind === 'var').forEach((v) =>
        host().toWebview({ command: 'remove-signal', netlistId: v.netlistId, rowId: undefined, removeAllSelected: false }));
    },
    'vaporview.showInNetlistView': (e) => {
      const id = e && e.netlistId !== undefined ? e.netlistId : webviewContext && webviewContext.selectedSignal;
      if (id !== undefined && id !== null) { window.cmuxNetlist.reveal(id); }
    },
    'vaporview.showInViewer': (e) => host().toWebview({ command: 'setSelectedSignal', netlistId: e.netlistId }),
    'vaporview.copyName': copyName,
    'vaporview.copyValueAtMarker': (e) => { if (e && e.rowId !== undefined) { host().toWebview({ command: 'copyValueAtMarker', rowId: e.rowId }); } },

    // Rows, groups and separators
    'vaporview.removeSignal': (e) => { if (e && e.rowId !== undefined) { host().toWebview({ command: 'remove-signal', netlistId: undefined, rowId: e.rowId, removeAllSelected: true }); } },
    'vaporview.newSignalGroup': (e) => host().toWebview(Object.assign({ command: 'newSignalGroup', groupName: e && e.name, moveSelected: false, showRenameInput: true }, groupArgs(e))),
    'vaporview.newGroupFromSelection': (e) => host().toWebview(Object.assign({ command: 'newSignalGroup', groupName: e && e.name, moveSelected: true, showRenameInput: true }, groupArgs(e))),
    'vaporview.ungroupSignals': (e) => host().toWebview({ command: 'remove-group', groupId: e && e.groupId, recursive: false }),
    'vaporview.deleteGroup': (e) => host().toWebview({ command: 'remove-group', groupId: e && e.groupId, recursive: true }),
    'vaporview.renameSignalGroup': (e) => host().toWebview({ command: 'renameSignalGroup', rowId: e && e.rowId, groupId: e && e.groupId, groupName: undefined }),
    'vaporview.newSeparator': (e) => host().toWebview(Object.assign({ command: 'add-separator', name: e && e.name }, groupArgs(e))),
    'vaporview.removeSeparator': (e) => host().toWebview({ command: 'remove-separator', rowId: e && e.rowId, removeAllSelected: true }),
    'vaporview.newSignalFromBitRange': async (e) => {
      const range = await ui().prompt({ title: S().promptBitRange, value: '0' });
      if (!range) { return; }
      if (!/^(\d+)(:(\d+))?$/.test(range)) { ui().toast(format(S().messageInvalidBitRange, range), 'warning'); return; }
      const [msb, lsb] = range.split(':').map((x) => parseInt(x, 10));
      host().toWebview(Object.assign({ command: 'add-bit-slice', name: e && e.name, msb, lsb: lsb === undefined ? msb : lsb }, groupArgs(e)));
    },
    'vaporview.createSignalsForAllCustomLength': async (e) => {
      const text = await ui().prompt({ title: S().promptCustomLength, value: '1' });
      if (!text) { return; }
      const length = parseInt(text, 10);
      if (Number.isNaN(length) || length <= 0) { ui().toast(S().messageInvalidCustomLength, 'warning'); return; }
      host().toWebview(Object.assign({ command: 'add-all-bit-slices', name: e && e.name, bitWidth: length }, groupArgs(e)));
    },

    // Value format, render type, edges, color, row height, name
    'vaporview.displayAsFloat': (e) => displayFormat(e, { numberFormat: [4, 8, 16, 32, 64].includes(e && e.width) ? 'float' + e.width : 'binary' }),
    'vaporview.displayAsFixedPoint': (e) => askNumberFormat(e, 'fixedpoint_u_'),
    'vaporview.displayAsFixedPointSigned': (e) => askNumberFormat(e, 'fixedpoint_s_'),
    'vaporview.increaseVerticalScale': keypress('increaseVerticalScale'),
    'vaporview.decreaseVerticalScale': keypress('decreaseVerticalScale'),
    'vaporview.resetVerticalScale': keypress('resetVerticalScale'),
    'vaporview.zoomToFit': keypress('zoomToFit'),

    // Time and ruler
    'vaporview.setTimeUnits': () => setTimeUnits(''),
    'vaporview.autoRulerTimeIncrement': () => host().toWebview({ command: 'updateRulerSettings', pixelTime: 0 }),
    'vaporview.setRulerTimeIncrement': setRulerIncrement,

    // Settings
    'vaporview.showRulerLines': () => updateSetting('showRulerLines', true),
    'vaporview.hideRulerLines': () => updateSetting('showRulerLines', false),
    'vaporview.fillBitVector': () => updateSetting('fillMultiBitValues', true),
    'vaporview.outlineBitVector': () => updateSetting('fillMultiBitValues', false),
    'vaporview.enableAnimations': () => updateSetting('enableAnimations', true),
    'vaporview.disableAnimations': () => updateSetting('enableAnimations', false),
    'vaporview.setMouseScrollingMode': () => updateSetting('scrollingMode', 'Mouse'),
    'vaporview.setTouchpadScrollingMode': () => updateSetting('scrollingMode', 'Touchpad'),
    'vaporview.setAutoScrollingMode': () => updateSetting('scrollingMode', 'Auto'),
    'vaporview.viewVaporViewSettings': () => showSettings(),
    'vaporview.showReadme': () => host().toNative({ type: 'openReadme' }),

    // WaveDrom
    'vaporview.copyWaveDrom': () => host().toWebview({ command: 'copyWaveDrom' }),
    'vaporview.setWaveDromClockRising': (e) => host().toWebview({ command: 'setWaveDromClock', edge: '1', netlistId: e && e.netlistId !== undefined ? e.netlistId : null }),
    'vaporview.setWaveDromClockFalling': (e) => host().toWebview({ command: 'setWaveDromClock', edge: '0', netlistId: e && e.netlistId !== undefined ? e.netlistId : null }),
    'vaporview.unsetWaveDromClock': () => host().toWebview({ command: 'setWaveDromClock', edge: '1', netlistId: null }),

    // Sessions and file
    'vaporview.saveViewerSession': () => saveSession(),
    'vaporview.loadViewerSession': () => host().toNative({ type: 'loadSession' }),
    // Value aliases: cmux picks and reads the file (on this Mac or the SSH host).
    'vaporview.loadValueAliases': () => host().toNative({ type: 'loadValueAliases' }),
    'vaporview.displayAsAlias': (e) => { if (e && e.aliasFormat) { displayFormat(e, { numberFormat: e.aliasFormat }); } },
    'vaporview.removeValueAlias': (e) => displayFormat(e, { numberFormat: 'hexadecimal' }),
    'vaporview.valueAliasesLoaded': (result) => valueAliasesLoaded(result),
    'vaporview.reloadFile': () => host().toNative({ type: 'reload' }),
    'cmux.undo': () => undo(undoStack, redoStack, StateChangeType.Undo),
    'cmux.redo': () => undo(redoStack, undoStack, StateChangeType.Redo),
  };

  const FORMATS = { displayAsBinary: 'binary', displayAsHexadecimal: 'hexadecimal', displayAsDecimal: 'decimal',
    displayAsDecimalSigned: 'signed', displayAsOctal: 'octal', displayAsBFloat: 'bfloat16', displayAsTFloat: 'tensorfloat32',
    displayAsAscii: 'ascii', displayAsEpochTimeNs: 'nsepoch', displayAsEnum: 'enum',
    // The viewer's RISC-V formats (cmux-vaporview.patch, extra_formats.ts).
    displayAsRiscv: 'riscv', displayAsRiscvNumeric: 'riscv_numeric', displayAsRiscvNoAlias: 'riscv_noalias',
    displayAsRiscvNumericNoAlias: 'riscv_numeric_noalias' };
  Object.entries(FORMATS).forEach(([k, v]) => { COMMANDS['vaporview.' + k] = (e) => displayFormat(e, { numberFormat: v }); });
  const RENDER = { renderMultiBit: 'multiBit', renderLinear: 'linear', renderStepped: 'stepped', renderLinearSigned: 'linearSigned', renderSteppedSigned: 'steppedSigned' };
  Object.entries(RENDER).forEach(([k, v]) => { COMMANDS['vaporview.' + k] = (e) => displayFormat(e, { renderType: v }); });
  const EDGES = { annotatePosedge: ['1'], annotateNegedge: ['0'], annotateAllEdge: ['0', '1'], annotateNone: [] };
  Object.entries(EDGES).forEach(([k, v]) => { COMMANDS['vaporview.' + k] = (e) => displayFormat(e, { annotateValue: v }); });
  [1, 2, 3, 4, 5, 6, 7, 8].forEach((n) => { COMMANDS['vaporview.defaultColor' + n] = (e) => displayFormat(e, { colorIndex: n - 1 }); });
  [1, 2, 4, 8].forEach((n) => { COMMANDS['vaporview.rowHeight' + n + 'x'] = (e) => displayFormat(e, { rowHeight: n }); });
  const NAME_TYPES = { setNameTypeFullPath: 'fullPath', setNameTypeSignalName: 'signalName', setNameTypeCustom: 'custom' };
  Object.entries(NAME_TYPES).forEach(([k, v]) => { COMMANDS['vaporview.' + k] = (e) => displayFormat(e, { nameType: v }); });
  const UNITS = { Seconds: 's', Milliseconds: 'ms', Microseconds: 'µs', Nanoseconds: 'ns', Picoseconds: 'ps', Femtoseconds: 'fs' };
  Object.entries(UNITS).forEach(([k, v]) => { COMMANDS['vaporview.setTimeUnits' + k] = () => setTimeUnits(v); });
  const SLICES = { Bits: 1, Nibbles: 4, Bytes: 8, Words: 16, DoubleWords: 32, QuadWords: 64 };
  Object.entries(SLICES).forEach(([k, v]) => {
    COMMANDS['vaporview.createSignalsForAll' + k] = (e) => host().toWebview(Object.assign({ command: 'add-all-bit-slices', name: e && e.name, bitWidth: v }, groupArgs(e)));
  });

  async function addScope(e, recursive) {
    if (!e || e.kind !== 'scope') { return; }
    addFiltered(await scopeVariables(e, recursive, 128), false, 'bulk');
  }

  async function run(id, args) {
    const handler = COMMANDS[id];
    if (!handler) { host().log('unknown command ' + id); return undefined; }
    try {
      return await handler(args);
    } catch (error) {
      // A reload closed the backend under it: the newer load owns the page.
      if (error && error.cmuxClosed) { return undefined; }
      host().log('command ' + id + ' failed: ' + ((error && error.stack) || error));
      ui().toast(String((error && error.message) || error), 'error');
      return undefined;
    }
  }

  // ---- context menus ----
  function resolveEntry(args) {
    return (entry) => {
      if (entry.group && entry.group.startsWith('inline')) { return null; }
      if (entry.submenu === 'vaporview.valueAlias') { return { label: title(entry.submenu), entries: aliasMenuEntries() }; }
      if (entry.submenu) { return { label: title(entry.submenu), entries: MENUS[entry.submenu] || [] }; }
      if (entry.alias) {
        return { label: entry.label, run: () => run('vaporview.displayAsAlias', Object.assign({}, args, { aliasFormat: entry.alias })) };
      }
      if (!COMMANDS[entry.command]) { return null; }
      return { label: title(entry.command), keybinding: KEY_LABELS[entry.command], run: () => run(entry.command, args) };
    };
  }

  // VS Code merges every data-vscode-context from the clicked element up to
  // the root, the closest one winning, and passes the result as the command
  // argument.
  function webviewContextAt(target) {
    const chain = [];
    for (let el = target; el && el.nodeType === 1; el = el.parentElement) {
      const raw = el.getAttribute('data-vscode-context');
      if (raw) { chain.push(raw); }
    }
    const context = {};
    for (const raw of chain.reverse()) {
      try { Object.assign(context, JSON.parse(raw.replace(/%x20/g, ' '))); } catch (error) { /* not JSON */ }
    }
    return context;
  }

  // ---- key claims (WaveformViewerShortcuts in cmux) ----
  // cmux lets VaporView's keys through to the page instead of running its own
  // shortcut only when the page will run them, so it needs to know whether the
  // viewer frame has focus (the `viewer` bindings) and whether a menu,
  // dialog or text field takes keys instead (handleKey returns early then).
  let lastKeyState = '';
  function postKeyState() {
    const frame = document.getElementById('viewer');
    const viewerFocused = document.activeElement === frame;
    let active = document.activeElement;
    if (viewerFocused) {
      try { active = frame.contentDocument.activeElement; } catch (error) { active = null; }
    }
    const state = { viewerFocused, blocked: ui().hasOpenOverlay() || isTextInput(active) };
    const key = JSON.stringify(state);
    if (key === lastKeyState) { return; }
    lastKeyState = key;
    host().toNative(Object.assign({ type: 'keyState' }, state));
  }
  const scheduleKeyState = () => setTimeout(postKeyState, 0);

  function attachFrame(frameWindow) {
    const frameDocument = frameWindow.document;
    frameDocument.addEventListener('focusin', scheduleKeyState, true);
    frameDocument.addEventListener('focusout', scheduleKeyState, true);
    frameDocument.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const args = webviewContextAt(e.target);
      const context = Object.assign({ inputFocus: isTextInput(e.target) }, host().viewerContext.keys, args);
      const items = ui().buildMenu(MENUS['webview/context'], context, resolveEntry(args));
      // cmux addition: VS Code shows Reload File in the editor title bar.
      items.push({ separator: true }, { label: title('vaporview.reloadFile'), run: () => run('vaporview.reloadFile') });
      // cmux addition: the debugger's breakpoints on a signal row (cmux-debugger.js).
      const breakItems = window.cmuxDebugger ? window.cmuxDebugger.rowMenuItems(args) : [];
      if (breakItems.length) { items.push({ separator: true }, ...breakItems); }
      const rect = document.getElementById('viewer').getBoundingClientRect();
      ui().showMenu(items, rect.left + e.clientX, rect.top + e.clientY);
    });
    frameWindow.addEventListener('keydown', (e) => handleKey(e, true), true);
    frameWindow.addEventListener('mousedown', () => ui().closeMenus(), true);
    // Netlist rows dragged in from the host page carry 'codeeditors' data.
    frameDocument.addEventListener('dragover', (e) => {
      if (e.dataTransfer && [...e.dataTransfer.types].includes('codeeditors')) { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; }
    });
  }

  function showNetlistMenu(item, x, y) {
    const context = { view: 'waveformViewerNetlistView', viewItem: item.kind === 'scope' ? 'netlistScope' : 'netlistVar',
      'vaporview.netlistSearchable': true };
    const args = Object.assign({}, item, { scopePath: item.scopePath.join('.') });
    const resolve = resolveEntry(item);
    const items = ui().buildMenu(MENUS['view/item/context'], context, (entry) => {
      const r = resolve(entry);
      // copyName reads scopePath as a dotted string, as VaporView's NetlistItem does.
      if (r && entry.command === 'vaporview.copyName') { r.run = () => run('vaporview.copyName', args); }
      return r;
    });
    ui().showMenu(items, x, y);
  }

  function handleDrop(m) {
    const ids = (m.resourceUriList || []).map((r) => r && r.cmuxNetlistId).filter((id) => id !== undefined);
    const vars = ids.map((id) => host().netlistItem(id)).filter(Boolean);
    if (vars.length) { host().addVariables(vars, m.groupPath || [], m.dropIndex); }
  }

  // ---- host page wiring ----
  let listenersInstalled = false;

  function init(config) {
    loadSettings(config.settings);
    webviewContext = null;
    undoStack = [];
    redoStack = [];
    reloading = false;
    reloadBaseline = null;
    frameGone = false;
    keptIsCurrent = false;
    waitingHistory = [];
    failedReload = false;
    historyPath = config.path || null;
    // A new viewer frame has no tables.
    aliasFiles = [];
    aliasLoads = [];
    resetApplying();
    pendingReload = false;
    setDirty(false);
    restoreAsked = false;
    sessionFileOffered = false;
    restorePending = false;
    appliedRestoreConfig = null;
    if (listenersInstalled) { return; }
    listenersInstalled = true;
    document.addEventListener('keydown', (e) => handleKey(e, false), true);
    document.addEventListener('focusin', scheduleKeyState, true);
    document.addEventListener('focusout', scheduleKeyState, true);
    document.addEventListener('cmux-overlay-change', scheduleKeyState);
    window.addEventListener('focus', scheduleKeyState);
    window.addEventListener('blur', scheduleKeyState);
    document.getElementById('status-time').addEventListener('click', () => run('vaporview.setTimeUnits'));
    const reload = document.getElementById('status-reload');
    reload.querySelector('button').addEventListener('click', () => { pendingReload = false; reload.hidden = true; host().toNative({ type: 'reload' }); });
  }

  // Before an in-page reload: the frame keeps its own state, the rest restarts.
  // host.js reload() calls this after taking its snapshot, just before the
  // viewer unloads its rows: cmux's copy of the old context is dropped with
  // them, so nothing reports or saves rows the viewer no longer has. The undo
  // history keeps that view as the one to go back to.
  function willReload() {
    pendingReload = false;
    document.getElementById('status-reload').hidden = true;
    // A change from the last 250 ms reaches cmux before the viewer unloads.
    if (snapshotScheduled) { sendSessionSnapshot(); }
    // A reload before the last one's restore came back keeps that one's view.
    // A reload while one is in its gap keeps all of that (the frame may already
    // be empty).
    if (!reloading) {
      const selected = webviewContext ? selectedSignalRef(webviewContext.selectedSignal)
        : (reloadBaseline && reloadBaseline.cmuxSelected) || null;
      reloadBaseline = Object.assign(undoState(), { cmuxSelected: selected });
      // Its kept view is still being restored (no context yet): that view stays.
      keptIsCurrent = !!webviewContext || (restorePending && keptIsCurrent);
      frameGone = false;
    }
    reloading = true;
    webviewContext = null;
    // What was posted to the old viewer is answered (if at all) before its unload.
    resetApplying();
    // An Undo queued for a reload this one overtakes doesn't carry over.
    waitingHistory = [];
    // A reload of another path: what was pressed for the old one doesn't carry.
    // Another path is another document (VaporView keeps a history per
    // document): neither the presses nor the history carry over.
    const path = host().config.path || null;
    if (path !== historyPath) { waitingHistory = []; undoStack = []; redoStack = []; historyPath = path; }
    failedReload = false;
  }

  window.cmuxCommands = {
    run, attachFrame, showNetlistMenu, settings, configMessage, onContextUpdate, restoreState, handleDrop,
    addSignalByName, fileChanged, willReload, updateSetting,
    frameUnloaded: () => { if (reloading) { frameGone = true; } },
    // The reload's file didn't open: an Undo pressed for it would apply to
    // whatever a later reload shows.
    reloadFailed: () => { if (reloading) { waitingHistory = []; failedReload = true; } },
    // A reload or restore has not come back yet (Undo/Redo wait for it).
    isRestoring: () => reloading || restorePending,
    init,
    setSessionFile: (file) => { host().config.sessionFile = file; return offerSessionFile(); },
    sessionSaved: () => { setDirty(false); scheduleSessionSnapshot(); },
    sessionFailed: ({ message }) => ui().toast(format(S().messageSessionSaveFailed, message), 'error'),
    applyValueAliasFile,
    applySessionFile: ({ text, path, error }) => (error
      ? ui().toast(format(S().messageSessionLoadFailed, error), 'error') : loadSessionText(text, path, true)),
    sessionSnapshot: () => ({ state: plainJSON(withAliasFiles(contextSession(webviewContext))), dirty }),
    undoDepth: () => undoStack.length,
    commandIds: () => Object.keys(COMMANDS),
    menus: MENUS,
  };
})();
