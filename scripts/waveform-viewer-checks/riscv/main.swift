// RISC-V and value-alias format checks (run.sh riscv): loads Resources/vaporview
// through the real WaveformViewerSchemeHandler in an off-screen, transparent,
// click-through WKWebView (never shown, never activated), opens riscv.vcd with
// the app's page strings (WaveformViewerStrings) and drives the viewer's own
// context menu (a contextmenu event on a value cell, cmux's menu items run as
// a click would):
//   - Format Values has a RISC-V submenu only for signals 16 bits or wider
//     (8 no, 16, 32 and 128 yes), with its four formats;
//   - each format changes the shown value to the decoded instruction;
//   - a format chosen on one row of a selection applies to the whole selection;
//   - undo takes back the last format and on to hexadecimal, redo comes back;
//   - Save Viewer Session keeps the format, and loading that session, a reload
//     and a restore (a new panel) show the instruction again;
//   - Load Value Alias File… hands the file cmux reads to the viewer, the Alias
//     submenu lists its tables, choosing one shows alias names, and
//     Hexadecimal goes back;
//   - alias files are kept by full path (two cpu.alias from different folders
//     both come back), sessions embed at most 256 KiB of alias text and name
//     the rest by key and SHA-256, which cmux re-reads on restore
//     (WaveformValueAliasFiles, the app's code, over a stand-in file system);
//     a missing or changed file is a toast and the rest still load;
//   - the restore asks by key only: cmux reads only files its own registry
//     recorded (picked, or named by a session file cmux read), so an unknown
//     key gets nothing, and a path or hash the page or kept state supplies is
//     ignored.
// Prints RISCV CHECKS PASSED, or the failures and RISCV CHECKS FAILED: n.
// Usage: riscv <assetRoot> <riscv.vcd> <aliases.alias> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let aliasURL = URL(fileURLWithPath: args[3])
let out = URL(fileURLWithPath: args[4])
var failures = 0

func expect(_ ok: Bool, _ what: String) {
  print(ok ? "ok  " : "FAIL", what)
  if !ok { failures += 1 }
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1400, height: 600),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var opened = 0
  var onOpened: (() -> Void)?
  var native: [[String: Any]] = []
  let strings = WaveformViewerStrings.all()
  /// The stand-in file system cmux re-reads alias files from on restore.
  var fakeFiles: [String: String] = [:]
  var readRequests = 0
  /// What native code recorded: alias files cmux read and session files it loaded.
  let registry = WaveformValueAliasFiles.Registry()
  /// Paths the stand-in file system was asked to read, and the answers by request id.
  var reads: [String] = []
  var answersByID: [Int: [[String: String]]] = [:]

  // Page helpers every check uses.
  static let prelude = """
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const C = window.cmuxCommands, H = window.cmuxWaveform.host, S = window.cmuxWaveform.strings;
    const frameDoc = () => document.getElementById('viewer').contentDocument;
    const rows = () => (H.viewerContext.webview && H.viewerContext.webview.displayedSignals) || [];
    const snapshotRows = () => { const st = C.sessionSnapshot().state; return st ? st.displayedSignals : []; };
    const formatOf = (name) => { const s = snapshotRows().find((x) => x.name === 'top.' + name); return s ? s.numberFormat : null; };
    // The value cell (#value-<rowId>) of top.<name>, found by its context.
    const cell = (name) => [...frameDoc().querySelectorAll('.value-display-item')].find((el) => {
      try { return JSON.parse((el.getAttribute('data-vscode-context') || '').replace(/%x20/g, ' ')).signalName === name; } catch (e) { return false; }
    });
    const text = (name) => { const el = cell(name); return el ? el.textContent.trim() : null; };
    const click = (name, opts) => cell(name).dispatchEvent(new MouseEvent('click', Object.assign({ bubbles: true }, opts || {})));
    // Right-clicks the value cell; returns cmux's menu items (what showMenu got).
    const menuAt = (name) => {
      let got = null;
      const show = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { got = items; };
      try {
        const el = cell(name);
        const r = el.getBoundingClientRect();
        el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 }));
      } finally { window.cmuxUI.showMenu = show; }
      return got || [];
    };
    const find = (items, label) => (items || []).find((i) => i && i.label === label);
    const sub = (items, ...path) => { let it = { items }; for (const l of path) { it = find(it.items, l); if (!it) { return null; } } return it; };
    const labels = (item) => (item && item.items ? item.items.filter((i) => !i.separator).map((i) => i.label) : null);
    const choose = async (name, ...path) => {
      const item = sub(menuAt(name), ...path);
      if (!item || !item.run) { return false; }
      await item.run();
      await sleep(400);
      return true;
    };
    const reloaded = async () => { const t = Date.now(); const busy = () => !C.sessionSnapshot().state || (C.isRestoring && C.isRestoring()); while (busy() && Date.now() - t < 30000) { await sleep(50); } await sleep(400); };
    const sent = window.__sent || (window.__sent = []);
    if (!window.__sentHooked) { window.__sentHooked = true; const toNative = H.toNative; H.toNative = (m) => { sent.push(m); return toNative(m); }; }
    const FMT = S['submenu.valueFormat'], RV = 'RISC-V';
    const T = (k) => S['command.' + k];
    """

  func call(_ body: String) async -> [String: Any] {
    let js = Self.prelude + "\nconst R = {};\n" + body + "\nreturn JSON.stringify(R);"
    do {
      let value = try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
      let object = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
      print("js:", (object ?? [:]).filter { $0.key != "state" && $0.key != "text" })
      return object ?? [:]
    } catch {
      print("JS ERROR", error)
      failures += 1
      return [:]
    }
  }

  func open(restore: [String: Any]? = nil) async {
    let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
    var argument: [String: Any] = [
      "url": scheme.serve(fileURL: waveURL).absoluteString, "size": size, "format": "vcd",
      "path": "/work/sim/riscv.vcd", "strings": strings, "settings": [String: Any](),
    ]
    argument["restore"] = restore
    let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      onOpened = { done.resume() }
      web.evaluateJavaScript("cmuxWaveform.open(\(json))")
    }
    try? await Task.sleep(nanoseconds: 800_000_000)
  }

  func addAll() async {
    _ = await call("""
      for (const n of ['instr', 'instr2', 'half', 'byte', 'wide']) { await C.run('waveformViewer.addVariable', { instancePath: 'top.' + n, quiet: true }); await sleep(150); }
      await sleep(600);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
      await sleep(400);
      R.rows = rows().length;
      """)
  }

  func runChecks() async {
    await open()
    await addAll()
    let decoded = ["instr": "sw ra,8(sp)", "instr2": "ret"]

    // The menu: RISC-V for 16 bits and wider, not for 8.
    let menu = await call("""
      R.hex = { instr: text('instr'), instr2: text('instr2') };
      for (const n of ['byte', 'half', 'instr', 'wide']) {
        const fmt = sub(menuAt(n), FMT);
        R[n] = { fmt: labels(fmt), rv: labels(sub(menuAt(n), FMT, RV)) };
      }
      R.want = [T('displayAsRiscv'), T('displayAsRiscvNumeric'), T('displayAsRiscvNoAlias'), T('displayAsRiscvNumericNoAlias')];
      """)
    let want = menu["want"] as? [String] ?? []
    expect(want == ["ABI Names", "x-Registers", "ABI Names, No Pseudo-instructions", "x-Registers, No Pseudo-instructions"],
           "the four RISC-V labels come from the app's strings: \(want)")
    func rv(_ n: String) -> [String]? { (menu[n] as? [String: Any])?["rv"] as? [String] }
    func fmt(_ n: String) -> [String]? { (menu[n] as? [String: Any])?["fmt"] as? [String] }
    expect(fmt("byte")?.contains("Hexadecimal") == true, "8-bit row has Format Values: \(fmt("byte") ?? [])")
    expect(rv("byte") == nil && fmt("byte")?.contains("RISC-V") == false, "no RISC-V for an 8-bit row")
    for n in ["half", "instr", "wide"] {
      expect(rv(n) == want, "RISC-V for \(n) (16/32/128 bits) has the four formats: \(String(describing: rv(n)))")
    }
    let hex = menu["hex"] as? [String: String] ?? [:]
    expect(hex["instr"] != nil && hex["instr"] != decoded["instr"] && hex["instr2"] != nil, "rows start in hex: \(hex)")

    // One row, then a selection of two.
    let single = await call("""
      click('instr');
      await sleep(200);
      R.ok = await choose('instr', FMT, RV, T('displayAsRiscv'));
      R.instr = text('instr'); R.instr2 = text('instr2');
      R.fmt = [formatOf('instr'), formatOf('instr2')];
      """)
    expect(single["ok"] as? Bool == true, "ABI Names runs from the menu")
    expect(single["instr"] as? String == decoded["instr"], "instr shows the instruction: \(single["instr"] ?? "nil")")
    expect(single["instr2"] as? String == hex["instr2"], "an unselected row keeps hex: \(single["instr2"] ?? "nil")")
    expect(single["fmt"] as? [String] == ["riscv", "hexadecimal"], "formats: \(single["fmt"] ?? "nil")")

    let multi = await call("""
      click('instr');
      await sleep(150);
      click('instr2', { shiftKey: true });
      await sleep(300);
      R.selected = H.viewerContext.webview.selectedSignalCount;
      R.ok = await choose('instr2', FMT, RV, T('displayAsRiscvNumeric'));
      R.instr = text('instr'); R.instr2 = text('instr2');
      R.fmt = [formatOf('instr'), formatOf('instr2')];
      """)
    expect(multi["selected"] as? Int == 2, "two rows selected")
    expect(multi["instr"] as? String == "sw x1,8(x2)" && multi["instr2"] as? String == "ret",
           "x-Registers applies to both selected rows: \(multi["instr"] ?? "nil") / \(multi["instr2"] ?? "nil")")
    expect(multi["fmt"] as? [String] == ["riscv_numeric", "riscv_numeric"], "formats: \(multi["fmt"] ?? "nil")")

    let noAlias = await call("""
      click('instr2');
      await sleep(200);
      R.ok1 = await choose('instr2', FMT, RV, T('displayAsRiscvNoAlias'));
      R.a = text('instr2');
      R.ok2 = await choose('instr2', FMT, RV, T('displayAsRiscvNumericNoAlias'));
      R.b = text('instr2');
      R.instr = text('instr');
      R.depth = C.undoDepth();
      """)
    expect(noAlias["a"] as? String == "jalr zero,0(ra)", "No Pseudo-instructions: \(noAlias["a"] ?? "nil")")
    expect(noAlias["b"] as? String == "jalr x0,0(x1)", "x-Registers, No Pseudo-instructions: \(noAlias["b"] ?? "nil")")
    expect(noAlias["instr"] as? String == "sw x1,8(x2)", "the other row is left alone")

    // Undo: the last change first, then back to hex; redo forward again.
    let undo = await call("""
      await C.run('cmux.undo'); await sleep(500);
      R.first = text('instr2');
      const hexAgain = () => formatOf('instr') === 'hexadecimal' && formatOf('instr2') === 'hexadecimal';
      for (let i = 0; i < 20 && !hexAgain(); i++) { await C.run('cmux.undo'); await sleep(400); }
      R.instr = text('instr'); R.instr2 = text('instr2');
      R.fmt = [formatOf('instr'), formatOf('instr2')];
      for (let i = 0; i < 20 && formatOf('instr2') !== 'riscv_numeric_noalias'; i++) { await C.run('cmux.redo'); await sleep(400); }
      R.rinstr = text('instr'); R.rinstr2 = text('instr2');
      """)
    expect(undo["first"] as? String == "jalr zero,0(ra)", "one undo takes back the last format: \(undo["first"] ?? "nil")")
    expect(undo["instr"] as? String == hex["instr"] && undo["instr2"] as? String == hex["instr2"],
           "undo restores hex: \(undo["instr"] ?? "nil") / \(undo["instr2"] ?? "nil")")
    expect(undo["fmt"] as? [String] == ["hexadecimal", "hexadecimal"], "formats after undo: \(undo["fmt"] ?? "nil")")
    expect(undo["rinstr"] as? String == "sw x1,8(x2)" && undo["rinstr2"] as? String == "jalr x0,0(x1)",
           "redo brings the formats back: \(undo["rinstr"] ?? "nil") / \(undo["rinstr2"] ?? "nil")")

    // Save the session, then load it into a fresh viewer.
    let saved = await call("""
      await C.run('vaporview.saveViewerSession');
      const save = sent.filter((m) => m.type === 'saveSession').pop();
      R.text = save ? save.text : null;
      R.state = C.sessionSnapshot().state;
      """)
    let sessionText = saved["text"] as? String ?? ""
    let file = (try? JSONSerialization.jsonObject(with: Data(sessionText.utf8))) as? [String: Any]
    let savedFormats = (file?["displayedSignals"] as? [[String: Any]] ?? []).reduce(into: [String: String]()) {
      $0[$1["name"] as? String ?? ""] = $1["numberFormat"] as? String
    }
    expect(savedFormats["top.instr"] == "riscv_numeric" && savedFormats["top.instr2"] == "riscv_numeric_noalias",
           "the saved session holds the formats: \(savedFormats)")

    await open()
    let loaded = await call("""
      \(sessionFileJS(sessionText));
      await sleep(1500);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
      await sleep(400);
      R.instr = text('instr'); R.instr2 = text('instr2');
      """)
    expect(loaded["instr"] as? String == "sw x1,8(x2)" && loaded["instr2"] as? String == "jalr x0,0(x1)",
           "a loaded session shows the instructions: \(loaded["instr"] ?? "nil") / \(loaded["instr2"] ?? "nil")")

    let reloaded = await call("""
      window.cmuxWaveform.reload({});
      await reloaded();
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
      await sleep(400);
      R.instr = text('instr'); R.instr2 = text('instr2');
      R.state = C.sessionSnapshot().state;
      """)
    expect(reloaded["instr"] as? String == "sw x1,8(x2)" && reloaded["instr2"] as? String == "jalr x0,0(x1)",
           "a reload keeps them: \(reloaded["instr"] ?? "nil") / \(reloaded["instr2"] ?? "nil")")

    if let state = reloaded["state"] as? [String: Any] {
      await open(restore: ["state": state, "dirty": false])
      try? await Task.sleep(nanoseconds: 800_000_000)
      let restored = await call("""
        await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
        await sleep(400);
        R.instr = text('instr'); R.instr2 = text('instr2');
        """)
      expect(restored["instr"] as? String == "sw x1,8(x2)" && restored["instr2"] as? String == "jalr x0,0(x1)",
             "a restore (new panel) keeps them: \(restored["instr"] ?? "nil") / \(restored["instr2"] ?? "nil")")
    } else {
      expect(false, "a state to restore")
    }

    await aliasChecks()
    await aliasFileChecks()
    print(failures == 0 ? "RISCV CHECKS PASSED" : "RISCV CHECKS FAILED: \(failures)")
    snap()
  }

  // Load Value Alias File…: the page asks cmux for a file, cmux reads it (on
  // this Mac or the SSH host) and hands its text to applyValueAliasFile; the
  // Alias submenu lists the file's tables. The tables go with the session.
  func aliasChecks() async {
    let text = (try? String(contentsOf: aliasURL, encoding: .utf8)) ?? ""
    let ALIAS = "S['submenu.valueAlias']"
    let ask = await call("""
      sent.length = 0;
      R.hasLoad = !!sub(menuAt('byte'), FMT, T('loadValueAliases'));
      R.noAliasMenu = !sub(menuAt('byte'), FMT, \(ALIAS));
      R.ok = await choose('byte', FMT, T('loadValueAliases'));
      R.asked = sent.filter((m) => m.type === 'loadValueAliases').length;
      """)
    expect(ask["hasLoad"] as? Bool == true, "Format Values has Load Value Alias File…")
    expect(ask["noAliasMenu"] as? Bool == true, "no Alias submenu before a file is loaded")
    expect(ask["asked"] as? Int == 1, "choosing it asks cmux for the file once: \(ask["asked"] ?? "nil")")

    let after = await call("""
      const before = document.querySelectorAll('.cmux-toast').length;
      \(aliasFileJS("/work/sim/cpu.alias", text));
      await sleep(800);
      R.toasted = document.querySelectorAll('.cmux-toast').length > before;
      R.alias = labels(sub(menuAt('byte'), FMT, \(ALIAS)));
      R.half = labels(sub(menuAt('half'), FMT, \(ALIAS)));
      R.remove = T('removeValueAlias');
      """)
    let aliasItems = after["alias"] as? [String] ?? []
    let remove = after["remove"] as? String ?? "?"
    expect(after["toasted"] as? Bool == false, "a clean file loads without a toast")
    expect(aliasItems == ["opcode", remove], "the Alias submenu lists the file's table and Remove Alias: \(aliasItems)")
    expect((after["half"] as? [String])?.contains("opcode") == true, "for every width")

    let chosen = await call("""
      click('byte');
      await sleep(200);
      R.ok = await choose('byte', FMT, \(ALIAS), 'opcode');
      R.byte = text('byte'); R.fmt = formatOf('byte');
      R.ok2 = await choose('byte', FMT, T('displayAsHexadecimal'));
      R.hex = text('byte'); R.fmt2 = formatOf('byte');
      await C.run('cmux.undo'); await sleep(500);
      R.undone = text('byte');
      R.ok3 = await choose('byte', FMT, \(ALIAS), T('removeValueAlias'));
      R.removed = text('byte'); R.fmt3 = formatOf('byte');
      await C.run('cmux.undo'); await sleep(500);
      R.back = text('byte');
      """)
    expect(chosen["byte"] as? String == "OP_IMM" && chosen["fmt"] as? String == "alias:opcode",
           "choosing the table shows its name: \(chosen["byte"] ?? "nil") (\(chosen["fmt"] ?? "nil"))")
    expect(chosen["fmt2"] as? String == "hexadecimal" && chosen["hex"] as? String == "13",
           "Hexadecimal goes back: \(chosen["hex"] ?? "nil")")
    expect(chosen["undone"] as? String == "OP_IMM", "undo of Hexadecimal shows the alias again: \(chosen["undone"] ?? "nil")")
    expect(chosen["fmt3"] as? String == "hexadecimal" && chosen["removed"] as? String == "13",
           "Remove Alias goes back to hex: \(chosen["removed"] ?? "nil")")
    expect(chosen["back"] as? String == "OP_IMM", "and undoes: \(chosen["back"] ?? "nil")")

    // The tables go with the session: a saved file, a fresh viewer loading it,
    // a reload, and a restore in a new panel.
    let saved = await call("""
      await C.run('vaporview.saveViewerSession');
      const save = sent.filter((m) => m.type === 'saveSession').pop();
      R.text = save ? save.text : null;
      const file = save ? JSON.parse(save.text) : {};
      R.tables = (file.cmuxValueAliases || []).map((a) => a.fileName);
      """)
    expect(saved["tables"] as? [String] == ["cpu.alias"], "the saved session holds the alias file: \(saved["tables"] ?? "nil")")
    let sessionText = saved["text"] as? String ?? "{}"
    await open()
    let loaded = await call("""
      \(sessionFileJS(sessionText));
      await sleep(1500);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
      await sleep(400);
      R.byte = text('byte'); R.instr = text('instr');
      R.alias = labels(sub(menuAt('byte'), FMT, \(ALIAS)));
      """)
    expect(loaded["byte"] as? String == "OP_IMM" && loaded["instr"] as? String == "sw x1,8(x2)",
           "a loaded session shows the alias and the instruction: \(loaded["byte"] ?? "nil") / \(loaded["instr"] ?? "nil")")
    expect((loaded["alias"] as? [String])?.contains("opcode") == true, "and its Alias submenu: \(loaded["alias"] ?? "nil")")
    let reloaded = await call("""
      window.cmuxWaveform.reload({});
      await reloaded();
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
      await sleep(400);
      R.byte = text('byte');
      await sleep(400);
      R.state = C.sessionSnapshot().state;
      R.snapshotTables = ((R.state && R.state.cmuxValueAliases) || []).map((a) => a.fileName);
      """)
    expect(reloaded["byte"] as? String == "OP_IMM", "a reload keeps the alias: \(reloaded["byte"] ?? "nil")")
    expect(reloaded["snapshotTables"] as? [String] == ["cpu.alias"], "cmux's kept state holds the file: \(reloaded["snapshotTables"] ?? "nil")")
    if let state = reloaded["state"] as? [String: Any] {
      await open(restore: ["state": state, "dirty": false])
      try? await Task.sleep(nanoseconds: 800_000_000)
      let restored = await call("""
        await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 });
        await sleep(400);
        R.byte = text('byte');
        """)
      expect(restored["byte"] as? String == "OP_IMM", "a restore (new panel) keeps the alias: \(restored["byte"] ?? "nil")")
    }

    let failed = await call("""
      const before = document.querySelectorAll('.cmux-toast').length;
      window.cmuxWaveform.applyValueAliasFile({ path: '/work/sim/missing.alias', error: 'No such file' });
      await sleep(300);
      window.cmuxWaveform.applyValueAliasFile({ text: 'alias broken\\n  A 8\\'h01\\n', path: '/work/sim/broken.alias' });
      await sleep(600);
      R.toasts = [...document.querySelectorAll('.cmux-toast')].slice(before).map((t) => t.textContent);
      """)
    let toasts = failed["toasts"] as? [String] ?? []
    expect(toasts.count == 2, "a file cmux couldn't read, and one the viewer can't parse, each show a toast: \(toasts)")
  }

  /// What cmux hands the page after reading the file at `path` on this Mac
  /// (and records, as FilePreviewWaveformSession.chooseLocalValueAliasFile does).
  func aliasFileJS(_ path: String, _ text: String) -> String {
    registry.noteLoaded(key: path, location: .local(path), text: text)
    let argument: [String: Any] = ["text": text, "path": path, "key": path, "sha256": WaveformValueAliasFiles.sha256(text)]
    return "window.cmuxWaveform.applyValueAliasFile(" + String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)! + ")"
  }

  func aliasFileChecks() async {
    let ALIAS = "S['submenu.valueAlias']"
    let a = "alias ta\n  BYTE_A 8'h13\nendalias\n"
    let b = "alias tb\n  HALF_B 16'h4501\nendalias\n"
    // A table past the embedding budget: about 300 KiB of entries.
    var big = "alias tbig\n  BIG_13 32'h00112423\n"
    var n = 0
    while big.utf8.count < 300 * 1024 { big += "  FILL_\(n) 32'h\(String(format: "%08x", 0x1000_0000 + n))\n"; n += 1 }
    big += "endalias\n"
    fakeFiles = ["/a/cpu.alias": a, "/b/cpu.alias": b, "/big/big.alias": big]

    // A1: two files named cpu.alias, from different folders.
    await open()
    await addAll()
    let both = await call("""
      \(aliasFileJS("/a/cpu.alias", a));
      \(aliasFileJS("/b/cpu.alias", b));
      await sleep(800);
      R.tables = labels(sub(menuAt('byte'), FMT, \(ALIAS)));
      click('byte'); await sleep(200);
      await choose('byte', FMT, \(ALIAS), 'ta');
      click('half'); await sleep(200);
      await choose('half', FMT, \(ALIAS), 'tb');
      R.byte = text('byte'); R.half = text('half');
      await C.run('vaporview.saveViewerSession');
      const save = sent.filter((m) => m.type === 'saveSession').pop();
      R.text = save ? save.text : null;
      const file = save ? JSON.parse(save.text) : {};
      R.keys = (file.cmuxValueAliases || []).map((f) => f.key);
      await sleep(400);
      R.state = C.sessionSnapshot().state;
      R.stateKeys = ((R.state && R.state.cmuxValueAliases) || []).map((f) => f.key);
      """)
    expect((both["tables"] as? [String])?.contains("ta") == true && (both["tables"] as? [String])?.contains("tb") == true,
           "both cpu.alias tables load: \(both["tables"] ?? "nil")")
    expect(both["byte"] as? String == "BYTE_A" && both["half"] as? String == "HALF_B", "both show: \(both["byte"] ?? "nil") / \(both["half"] ?? "nil")")
    expect(both["keys"] as? [String] == ["/a/cpu.alias", "/b/cpu.alias"], "the saved session keeps both files by path: \(both["keys"] ?? "nil")")
    expect(both["stateKeys"] as? [String] == ["/a/cpu.alias", "/b/cpu.alias"], "and cmux's kept state: \(both["stateKeys"] ?? "nil")")
    let bothText = both["text"] as? String ?? "{}"
    await open()
    let loaded = await call("""
      \(sessionFileJS(bothText));
      await sleep(1500);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
      R.byte = text('byte'); R.half = text('half');
      """)
    expect(loaded["byte"] as? String == "BYTE_A" && loaded["half"] as? String == "HALF_B",
           "loading the session brings both back: \(loaded["byte"] ?? "nil") / \(loaded["half"] ?? "nil")")
    if let state = both["state"] as? [String: Any] {
      await open(restore: ["state": state, "dirty": false])
      let restored = await call("""
        await sleep(800);
        await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
        R.byte = text('byte'); R.half = text('half');
        """)
      expect(restored["byte"] as? String == "BYTE_A" && restored["half"] as? String == "HALF_B",
             "a restore brings both back: \(restored["byte"] ?? "nil") / \(restored["half"] ?? "nil")")
    }

    // A2: at most 256 KiB of alias text in a session; the rest by path and hash.
    await open()
    await addAll()
    let capped = await call("""
      \(aliasFileJS("/a/cpu.alias", a));
      \(aliasFileJS("/big/big.alias", big));
      await sleep(1500);
      click('instr'); await sleep(200);
      await choose('instr', FMT, \(ALIAS), 'tbig');
      click('byte'); await sleep(200);
      await choose('byte', FMT, \(ALIAS), 'ta');
      R.instr = text('instr');
      await sleep(400);
      const states = sent.filter((m) => m.type === 'sessionState').slice(-3);
      R.stateSizes = states.map((m) => JSON.stringify(m.state).length);
      await C.run('vaporview.saveViewerSession');
      const save = sent.filter((m) => m.type === 'saveSession').pop();
      R.text = save ? save.text : null;
      R.size = R.text ? R.text.length : -1;
      const file = save ? JSON.parse(save.text) : {};
      R.entries = (file.cmuxValueAliases || []).map((f) => [f.key, typeof f.text === 'string', /^[0-9a-f]{64}$/.test(f.sha256 || '')]);
      R.state = C.sessionSnapshot().state;
      """)
    expect(capped["instr"] as? String == "BIG_13", "the big table shows: \(capped["instr"] ?? "nil")")
    let entries = capped["entries"] as? [[Any]] ?? []
    expect(entries.count == 2 && entries[0][0] as? String == "/a/cpu.alias" && entries[0][1] as? Bool == true
           && entries[1][0] as? String == "/big/big.alias" && entries[1][1] as? Bool == false
           && entries.allSatisfy { $0[2] as? Bool == true },
           "the small file is embedded, the big one named by path and SHA-256: \(entries)")
    let size = capped["size"] as? Int ?? -1
    expect(size > 0 && size < 256 * 1024 + 16 * 1024, "the saved session stays small: \(size) bytes")
    let stateSizes = capped["stateSizes"] as? [Int] ?? []
    expect(!stateSizes.isEmpty && stateSizes.allSatisfy { $0 < 256 * 1024 + 16 * 1024 }, "so does cmux's kept state: \(stateSizes)")

    let cappedText = capped["text"] as? String ?? "{}"
    readRequests = 0
    await open()
    let reread = await call("""
      \(sessionFileJS(cappedText));
      await sleep(2000);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
      R.instr = text('instr'); R.byte = text('byte');
      """)
    expect(readRequests == 1, "cmux is asked to re-read the big file: \(readRequests) requests")
    expect(reread["instr"] as? String == "BIG_13" && reread["byte"] as? String == "BYTE_A",
           "loading the session re-reads it: \(reread["instr"] ?? "nil") / \(reread["byte"] ?? "nil")")
    if let state = capped["state"] as? [String: Any] {
      await open(restore: ["state": state, "dirty": false])
      let restored = await call("""
        await sleep(1500);
        await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
        R.instr = text('instr');
        """)
      expect(restored["instr"] as? String == "BIG_13", "a restore re-reads it too: \(restored["instr"] ?? "nil")")
    }

    // Missing, then changed: a toast each, and the embedded file still loads.
    for (label, change) in [("missing", { (h: Harness) in h.fakeFiles["/big/big.alias"] = nil }),
                            ("changed", { (h: Harness) in h.fakeFiles["/big/big.alias"] = big + "alias tother\n  O 8'h01\nendalias\n" })] {
      change(self)
      await open()
      let r = await call("""
        // Toasts already shown (an earlier one may leave while this waits) aren't this load's.
        document.querySelectorAll('.cmux-toast').forEach((t) => { t.dataset.seen = '1'; });
        \(sessionFileJS(cappedText));
        await sleep(2000);
        await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
        R.toasts = [...document.querySelectorAll('.cmux-toast:not([data-seen])')].map((t) => t.textContent);
        R.instr = text('instr'); R.byte = text('byte');
        R.tables = labels(sub(menuAt('byte'), FMT, \(ALIAS)));
        R.keys = ((C.sessionSnapshot().state || {}).cmuxValueAliases || []).map((f) => f.key);
        """)
      let toasts = r["toasts"] as? [String] ?? []
      expect(toasts.count == 1 && toasts[0].contains("big.alias"), "a \(label) file shows one toast naming it: \(toasts)")
      expect(r["byte"] as? String == "BYTE_A" && r["instr"] as? String != "BIG_13", "the rest still loads (\(label)): \(r["byte"] ?? "nil") / \(r["instr"] ?? "nil")")
      expect((r["tables"] as? [String])?.contains("tother") == false, "a changed file's tables are not loaded (\(label)): \(r["tables"] ?? "nil")")
      expect(r["keys"] as? [String] == ["/a/cpu.alias"], "and it is no longer kept (\(label)): \(r["keys"] ?? "nil")")
    }

    await keyOnlyChecks(big: big, capped: capped)
    boundedReadChecks()
    remotePathChecks()
  }

  // Key-only restore: cmux reads only what its registry recorded.
  func keyOnlyChecks(big: String, capped: [String: Any]) async {
    let ALIAS = "S['submenu.valueAlias']"
    let secret = "alias tsecret\n  SECRET 8'h13\nendalias\n"
    let secretSHA = WaveformValueAliasFiles.sha256(secret)
    fakeFiles["/big/big.alias"] = big
    fakeFiles["/secret/key.alias"] = secret

    // The registry itself (the app's code, no page).
    let r = WaveformValueAliasFiles.Registry()
    let h = String(repeating: "a", count: 64)
    let sessionJSON: [String: Any] = ["displayedSignals": [], "cmuxValueAliases": [
      ["key": "/m/local.alias", "path": "/elsewhere/x.alias", "sha256": h],
      ["key": "ssh://ews-01:22/r/remote.alias", "path": "/r/remote.alias", "sha256": h],
      ["key": "ssh://other-host/r/other.alias", "sha256": h],
      ["key": "relative.alias", "sha256": h],
      ["key": "/m/nohash.alias", "text": "alias t\nendalias\n"],
      ["key": "/m/badhash.alias", "sha256": "ABC"],
    ]]
    // A real Files identity: destination, port, identity file, ssh options (\u{1f}-joined).
    let identity = "ssh:ews-01|22|/Users/u/.ssh/id_ed25519|ProxyJump=bastion:2222\u{1f}ServerAliveInterval=30"
    r.noteSession(text: String(data: try! JSONSerialization.data(withJSONObject: sessionJSON), encoding: .utf8)!, remoteIdentity: identity)
    expect(r.record(for: "/m/local.alias") == .init(location: .local("/m/local.alias"), sha256: h),
           "a session's local entry is read from its key, not its path field: \(String(describing: r.record(for: "/m/local.alias")))")
    expect(r.record(for: "ssh://ews-01:22/r/remote.alias")?.location == .remote("/r/remote.alias"), "the open file's host: remote")
    expect(r.record(for: "ssh://other-host/r/other.alias")?.location == .otherHost("/r/other.alias"), "another host's file: other host")
    // Remote keys: destination and port only, never the identity file or ssh options.
    let remote = WaveformValueAliasFiles.remoteKey(identity: identity, path: "/r/a.alias")
    expect(remote == "ssh://ews-01:22/r/a.alias", "a remote key is ssh://<dest>:<port><path>: \(remote)")
    expect(!remote.contains(".ssh") && !remote.contains("ProxyJump") && !remote.contains("|"), "and carries no identity file or ssh options")
    let otherKey = "ssh:ews-01|22|/Users/u/.ssh/other_key|"
    expect(WaveformValueAliasFiles.location(ofKey: remote, remoteIdentity: otherKey) == .remote("/r/a.alias"),
           "the same host with another identity file or options is the same host")
    expect(WaveformValueAliasFiles.location(ofKey: remote, remoteIdentity: "ssh:ews-02|22||") == .otherHost("/r/a.alias")
           && WaveformValueAliasFiles.location(ofKey: remote, remoteIdentity: "ssh:ews-01|2222||") == .otherHost("/r/a.alias"),
           "another destination or port is another host")
    expect(WaveformValueAliasFiles.location(ofKey: remote, remoteIdentity: nil) == .otherHost("/r/a.alias"),
           "an SSH key in a viewer on this Mac is another host")
    expect(WaveformValueAliasFiles.remoteKey(identity: "ssh:ews-01||||", path: "/r/a.alias") == "ssh://ews-01/r/a.alias",
           "no port: ssh://<dest><path>")
    let vm = WaveformValueAliasFiles.remoteKey(identity: "vm:abc|/secret/thing", path: "/p")
    expect(vm.hasPrefix("ssh://id-") && !vm.contains("secret") && WaveformValueAliasFiles.location(ofKey: vm, remoteIdentity: "vm:abc|/secret/thing") == .remote("/p"),
           "another kind of identity is named by its hash: \(vm)")
    expect(WaveformValueAliasFiles.location(ofKey: "ssh:ews-01|22|/k|:/r/a.alias", remoteIdentity: identity) == nil
           && WaveformValueAliasFiles.location(ofKey: "ssh:///r/a.alias", remoteIdentity: identity) == nil,
           "a key in another shape is not recorded")
    expect(r.record(for: "relative.alias") == nil && r.record(for: "/m/nohash.alias") == nil && r.record(for: "/m/badhash.alias") == nil,
           "entries without a path key or a well-formed hash are not recorded")
    expect(r.count == 3, "three recorded: \(r.count)")
    let keys = WaveformValueAliasFiles.keys(from: ["/a", ["key": "/b", "path": "/etc/hosts"], "/a", 7, ""] + (0..<20).map { "/k\($0)" })
    expect(keys.first == "/a" && !keys.contains("/b") && keys.count == 16 && Set(keys).count == 16,
           "request keys: strings only, no repeats, at most 16: \(keys.prefix(3))… \(keys.count)")
    let other = await WaveformValueAliasFiles.answer(["ssh://other-host/r/other.alias"], registry: r) { _ in "read" }
    expect(other.count == 1 && other[0]["text"] == nil && other[0]["error"] != nil, "another host's file is an error, not a read: \(other)")

    // A page that posts readValueAliases itself: an unknown key with a real path
    // and hash gets nothing, and nothing is read.
    await open()
    reads = []
    answersByID = [:]
    _ = await call("""
      H.toNative({ type: 'readValueAliases', id: 9001, keys: ['/secret/key.alias'],
        files: [{ key: '/secret/key.alias', path: '/secret/key.alias', sha256: '\(secretSHA)' }], path: '/secret/key.alias' });
      H.toNative({ type: 'readValueAliases', id: 9002, files: [{ key: '/big/big.alias', path: '/secret/key.alias', sha256: '\(secretSHA)' }] });
      H.toNative({ type: 'readValueAliases', id: 9003, keys: ['/big/big.alias'],
        files: [{ key: '/big/big.alias', path: '/secret/key.alias', sha256: '\(secretSHA)' }], path: '/secret/key.alias', sha256: '\(secretSHA)' });
      await sleep(600);
      """)
    expect(answersByID[9001].map { $0.isEmpty } == true, "a forged key gets no answer: \(String(describing: answersByID[9001]))")
    expect(answersByID[9002].map { $0.isEmpty } == true, "a path and hash without keys get no answer: \(String(describing: answersByID[9002]))")
    let known = answersByID[9003] ?? []
    expect(known.count == 1 && known[0]["key"] == "/big/big.alias" && known[0]["path"] == "/big/big.alias"
           && known[0]["text"].map(WaveformValueAliasFiles.sha256) == WaveformValueAliasFiles.sha256(big),
           "a known key with a forged path and hash reads cmux's own file: \(known.map { [$0["key"] ?? "", $0["path"] ?? "", $0["error"] ?? "", String($0["text"]?.count ?? -1)] })")
    expect(!reads.contains("/secret/key.alias") && reads == ["/big/big.alias"], "only the recorded file is read: \(reads)")

    // Kept state is the page's: a restore whose entries name an unknown key,
    // or a known key with another path and hash, reads only cmux's record.
    guard var state = capped["state"] as? [String: Any], var entries = state["cmuxValueAliases"] as? [[String: Any]] else {
      expect(false, "the capped state has alias entries")
      return
    }
    entries = entries.map { e in
      var e = e
      if e["key"] as? String == "/big/big.alias" { e["path"] = "/secret/key.alias"; e["sha256"] = secretSHA }
      return e
    }
    entries.append(["key": "/secret/key.alias", "path": "/secret/key.alias", "fileName": "key.alias", "sha256": secretSHA])
    state["cmuxValueAliases"] = entries
    reads = []
    // The restore starts as the file opens: earlier toasts are marked first.
    _ = await call("document.querySelectorAll('.cmux-toast').forEach((t) => { t.dataset.seen = '1'; }); sent.length = 0;")
    await open(restore: ["state": state, "dirty": false])
    let forged = await call("""
      await sleep(1500);
      await C.run('waveformViewer.setMarker', { time: 0, markerType: 0 }); await sleep(400);
      R.toasts = [...document.querySelectorAll('.cmux-toast:not([data-seen])')].map((t) => t.textContent);
      R.instr = text('instr'); R.byte = text('byte');
      R.tables = labels(sub(menuAt('byte'), FMT, \(ALIAS)));
      R.asked = sent.filter((m) => m.type === 'readValueAliases').slice(-1).map((m) => [Object.keys(m).sort().join(','), m.keys]);
      """)
    let tables = forged["tables"] as? [String] ?? []
    expect(forged["instr"] as? String == "BIG_13" && forged["byte"] as? String == "BYTE_A",
           "the known files load from cmux's record: \(forged["instr"] ?? "nil") / \(forged["byte"] ?? "nil")")
    expect(!tables.contains("tsecret") && tables.contains("tbig"), "the forged entry's table is not loaded: \(tables)")
    expect(!reads.contains("/secret/key.alias"), "the forged path is never read: \(reads)")
    let asked = forged["asked"] as? [[Any]] ?? []
    expect(asked.count == 1 && asked[0][0] as? String == "id,keys,type"
           && (asked[0][1] as? [String]).map(Set.init) == Set(["/big/big.alias", "/secret/key.alias"]),
           "the page asks with keys only: \(asked)")
    let toasts = forged["toasts"] as? [String] ?? []
    let notRecorded = strings["messageValueAliasNotRecorded"] as? String ?? "?"
    expect(toasts.count == 1 && toasts[0].contains("key.alias") && toasts[0].contains(notRecorded),
           "the unknown key is one toast saying cmux has no record of it: \(toasts)")

    // A session file cmux read naming another host's file: recorded as such,
    // and its own toast (not read).
    guard var otherSession = (try? JSONSerialization.jsonObject(with: Data((capped["text"] as? String ?? "{}").utf8))) as? [String: Any] else {
      expect(false, "the capped session parses")
      return
    }
    otherSession["cmuxValueAliases"] = (otherSession["cmuxValueAliases"] as? [[String: Any]] ?? [])
      + [["key": "ssh://other-host:22/r/x.alias", "path": "/r/x.alias", "fileName": "x.alias", "sha256": String(repeating: "b", count: 64)]]
    let otherText = String(data: try! JSONSerialization.data(withJSONObject: otherSession), encoding: .utf8)!
    reads = []
    await open()
    let otherHost = await call("""
      document.querySelectorAll('.cmux-toast').forEach((t) => { t.dataset.seen = '1'; });
      \(sessionFileJS(otherText));
      await sleep(2000);
      R.toasts = [...document.querySelectorAll('.cmux-toast:not([data-seen])')].map((t) => t.textContent);
      R.instr = text('instr');
      """)
    let otherToasts = otherHost["toasts"] as? [String] ?? []
    let otherHostText = String(localized: "filePreview.waveform.valueAlias.otherHost", defaultValue: "The file is on another host.")
    expect(otherToasts.count == 1 && otherToasts[0].contains("x.alias") && otherToasts[0].contains(otherHostText),
           "another host's file is one toast saying so: \(otherToasts)")
    expect(!reads.contains("/r/x.alias") && otherHost["instr"] as? String == "BIG_13", "it is not read, and the rest loads: \(reads)")
  }

  // Reads are bounded on the file a symlink points to; FIFOs are refused.
  func boundedReadChecks() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("riscv-bounded-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let max = 8 * 1024 * 1024
    let huge = dir.appendingPathComponent("huge.alias"), hugeLink = dir.appendingPathComponent("link.alias")
    let small = dir.appendingPathComponent("small.alias"), smallLink = dir.appendingPathComponent("small-link.alias")
    let exact = dir.appendingPathComponent("exact.alias"), fifo = dir.appendingPathComponent("fifo.alias")
    FileManager.default.createFile(atPath: huge.path, contents: Data(repeating: 0x41, count: 20 * 1024 * 1024))
    FileManager.default.createFile(atPath: exact.path, contents: Data(repeating: 0x41, count: max))
    try? "alias t\nendalias\n".write(to: small, atomically: true, encoding: .utf8)
    try? FileManager.default.createSymbolicLink(at: hugeLink, withDestinationURL: huge)
    try? FileManager.default.createSymbolicLink(at: smallLink, withDestinationURL: small)
    mkfifo(fifo.path, 0o600)
    func refused(_ url: URL) -> String? {
      do { _ = try WaveformValueAliasFiles.readText(at: url, maxBytes: max); return nil } catch { return "\(error)" }
    }
    expect(refused(hugeLink) != nil, "a symlink to a 20 MiB file is refused: \(refused(hugeLink) ?? "read")")
    expect(refused(huge) != nil, "so is the 20 MiB file itself")
    expect((try? WaveformValueAliasFiles.readText(at: smallLink, maxBytes: max)) == "alias t\nendalias\n", "a symlink to a small file is read")
    expect((try? WaveformValueAliasFiles.readText(at: exact, maxBytes: max))?.utf8.count == max, "a file of exactly the limit is read")
    expect(refused(fifo) != nil, "a FIFO is refused without blocking")
    expect(refused(dir) != nil, "so is a folder")
    fifoRaceChecks(dir: dir, max: max)
  }

  // A FIFO at the path read never blocks: not one a symlink points to, and not
  // one swapped in between a check and the open (the read checks the file it
  // opened, opened without blocking).
  func fifoRaceChecks(dir: URL, max: Int) {
    let fifoSrc = dir.appendingPathComponent("race-fifo"), regSrc = dir.appendingPathComponent("race-reg")
    let race = dir.appendingPathComponent("race.alias"), tmp = dir.appendingPathComponent("race-tmp")
    let fifoLink = dir.appendingPathComponent("fifo-link.alias")
    mkfifo(fifoSrc.path, 0o600)
    try? "alias t\nendalias\n".write(to: regSrc, atomically: true, encoding: .utf8)
    try? FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifoSrc)
    link(regSrc.path, race.path)
    // Unblocks a reader stuck opening the FIFO, so a failing run still ends.
    func unblock() {
      let fd = Darwin.open(fifoSrc.path, O_WRONLY | O_NONBLOCK)
      if fd >= 0 { Darwin.close(fd) }
    }
    final class State: @unchecked Sendable {
      let lock = NSLock()
      var stop = false, read = 0, refused = 0
      var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }
    }
    let state = State()
    func timed(_ seconds: Double, _ body: @escaping @Sendable () -> Void) -> Bool {
      let done = DispatchSemaphore(value: 0)
      Thread { body(); done.signal() }.start()
      if done.wait(timeout: .now() + seconds) == .success { return true }
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline { unblock(); if done.wait(timeout: .now() + 0.05) == .success { break } }
      return false
    }
    let linkFinished = timed(5) { _ = try? WaveformValueAliasFiles.readText(at: fifoLink, maxBytes: max) }
    expect(linkFinished, "a symlink to a FIFO is refused without blocking")
    // The swap: the path is the regular file, then the FIFO, over and over.
    let swapper = Thread {
      while !state.stopped {
        link(fifoSrc.path, tmp.path); rename(tmp.path, race.path)
        link(regSrc.path, tmp.path); rename(tmp.path, race.path)
      }
    }
    swapper.start()
    let raceFinished = timed(15) {
      for _ in 0..<20_000 {
        let ok = (try? WaveformValueAliasFiles.readText(at: race, maxBytes: max)) != nil
        state.lock.lock(); if ok { state.read += 1 } else { state.refused += 1 }; state.lock.unlock()
      }
    }
    state.lock.lock(); state.stop = true; let counts = (state.read, state.refused); state.lock.unlock()
    expect(raceFinished, "a FIFO swapped in during the reads never blocks one (20000 reads within 15 s; read \(counts.0), refused \(counts.1))")
  }

  // Load from Host takes only a path from the root of the host: "~/x.alias" or
  // "dir/x.alias" would make a key that names another host after a reload.
  func remotePathChecks() {
    func message(_ path: String) -> String? {
      do { try WaveformValueAliasFiles.checkRemotePath(path); return nil } catch { return error.localizedDescription }
    }
    for path in ["~/x.alias", "dir/x.alias", "x.alias", "./x.alias", ""] {
      expect(message(path) == "The path must be an absolute path on the SSH host", "Load from Host refuses \"\(path)\": \(message(path) ?? "accepted")")
    }
    expect(message("/r/x.alias") == nil, "Load from Host takes \"/r/x.alias\"")
    let identity = "ssh:ews-01|22||"
    let key = WaveformValueAliasFiles.remoteKey(identity: identity, path: "/r/x.alias")
    expect(WaveformValueAliasFiles.location(ofKey: key, remoteIdentity: identity) == .remote("/r/x.alias"), "its key comes back as the same host's file: \(key)")
  }

  /// cmux read the session file `text` (loadSession): it records the file's
  /// alias entries, then hands the text to the page.
  func sessionFileJS(_ text: String) -> String {
    registry.noteSession(text: text, remoteIdentity: nil)
    return "C.applySessionFile({ text: \(jsString(text)), path: '/work/sim/riscv.json' })"
  }

  func jsString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
  }

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map(String).join(' ')); } catch(e){}; o.apply(console, a); }; }
      window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno));
    })();
    """
    cfg.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    cfg.userContentController.add(self, name: "console")
    cfg.userContentController.add(self, name: "cmuxWaveform")
    // Never visible: off-screen, transparent, click-through, never ordered front.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "console" { print("[console]", m.body); return }
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    native.append(body)
    switch type {
    case "ready":
      guard opened == 0, native.filter({ $0["type"] as? String == "ready" }).count == 1 else { return }
      Task { @MainActor in await self.runChecks() }
    case "opened":
      opened += 1
      let next = onOpened
      onOpened = nil
      next?()
    case "readValueAliases":
      readRequests += 1
      // As FilePreviewWaveformSession.readValueAliasFiles: keys only.
      let keys = WaveformValueAliasFiles.keys(from: body["keys"])
      let id = body["id"] ?? 0
      Task { @MainActor in
        let answers = await WaveformValueAliasFiles.answer(keys, registry: self.registry) { location in
          self.reads.append(location.path)
          guard case .local(let path) = location, let text = self.fakeFiles[path] else {
            throw CocoaError(.fileReadNoSuchFile)
          }
          return text
        }
        self.answersByID[(id as? NSNumber)?.intValue ?? 0] = answers
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["id": id, "files": answers]), encoding: .utf8)!
        _ = try? await self.web.evaluateJavaScript("cmuxWaveform.valueAliasFilesRead(\(json))")
      }
    case "error":
      print("[error]", body["message"] ?? "")
    default:
      break
    }
  }

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
      } else { print("snapshot failed", String(describing: err)) }
      exit(failures == 0 ? 0 : 2)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
// The whole run's limit, scaled by the machine's load (the checks sleep in
// real time and a loaded Mac runs them slower): 240 s, plus 4 s per point of
// one-minute load average, at most 840 s (run.sh callers wrap it in 900 s).
var loads = [Double](repeating: 0, count: 3)
let load = getloadavg(&loads, 3) > 0 ? loads[0] : 0
let limit = min(840.0, 240.0 + 4.0 * load)
print("timeout limit \(Int(limit)) s at load \(Int(load))")
DispatchQueue.main.asyncAfter(deadline: .now() + limit) { print("timeout after \(Int(limit)) s"); exit(1) }
app.run()
