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
//     Hexadecimal goes back.
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
      C.applySessionFile({ text: \(jsString(sessionText)), path: '/work/sim/riscv.json' });
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
    print(failures == 0 ? "RISCV CHECKS PASSED" : "RISCV CHECKS FAILED: \(failures)")
    snap()
  }

  // Load Value Alias File…: the page asks cmux for a file, cmux reads it and
  // answers with its text; the Alias submenu lists the file's tables.
  var aliasAnswer: (() -> Void)?

  func aliasChecks() async {
    let text = (try? String(contentsOf: aliasURL, encoding: .utf8)) ?? ""
    let ask = await call("""
      sent.length = 0;
      R.hasLoad = !!sub(menuAt('byte'), FMT, T('loadValueAliases'));
      R.noAliasMenu = !sub(menuAt('byte'), FMT, S['submenu.valueAlias']);
      R.ok = await choose('byte', FMT, T('loadValueAliases'));
      R.asked = sent.filter((m) => m.type === 'loadValueAliases').length;
      """)
    expect(ask["hasLoad"] as? Bool == true, "Format Values has Load Value Alias File…")
    expect(ask["noAliasMenu"] as? Bool == true, "no Alias submenu before a file is loaded")
    expect(ask["asked"] as? Int == 1, "choosing it asks cmux for the file once: \(ask["asked"] ?? "nil")")

    let after = await call("""
      C.applyValueAliasFile({ text: \(jsString(text)), path: '/work/sim/cpu.alias' });
      await sleep(800);
      R.toasts = [...document.querySelectorAll('.cmux-toast')].map((t) => t.textContent);
      R.alias = labels(sub(menuAt('byte'), FMT, S['submenu.valueAlias']));
      R.half = labels(sub(menuAt('half'), FMT, S['submenu.valueAlias']));
      """)
    let aliasItems = after["alias"] as? [String] ?? []
    expect(aliasItems.contains("opcode"), "the Alias submenu lists the file's tables: \(aliasItems)")
    expect((after["half"] as? [String])?.contains("opcode") == true, "for every width")

    let chosen = await call("""
      click('byte');
      await sleep(200);
      R.ok = await choose('byte', FMT, S['submenu.valueAlias'], 'opcode');
      R.byte = text('byte'); R.fmt = formatOf('byte');
      R.ok2 = await choose('byte', FMT, T('displayAsHexadecimal'));
      R.hex = text('byte'); R.fmt2 = formatOf('byte');
      await C.run('cmux.undo'); await sleep(500);
      R.undone = text('byte');
      """)
    expect(chosen["byte"] as? String == "OP_IMM" && chosen["fmt"] as? String == "alias:opcode",
           "choosing the table shows its name: \(chosen["byte"] ?? "nil") (\(chosen["fmt"] ?? "nil"))")
    expect(chosen["fmt2"] as? String == "hexadecimal" && chosen["hex"] as? String == "13",
           "Hexadecimal goes back: \(chosen["hex"] ?? "nil")")
    expect(chosen["undone"] as? String == "OP_IMM", "undo of Hexadecimal shows the alias again: \(chosen["undone"] ?? "nil")")

    let failed = await call("""
      const before = document.querySelectorAll('.cmux-toast').length;
      C.applyValueAliasFile({ path: '/work/sim/missing.alias', error: 'No such file' });
      await sleep(300);
      R.toasted = document.querySelectorAll('.cmux-toast').length > before;
      """)
    expect(failed["toasted"] as? Bool == true, "a file cmux couldn't read shows a toast")
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
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("timeout"); exit(1) }
app.run()
