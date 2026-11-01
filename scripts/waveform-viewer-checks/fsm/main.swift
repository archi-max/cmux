// The state machine view (run.sh fsm): loads Resources/vaporview off-screen, opens fsm/fsm.vcd
// (tb.sv's run of dut.sv, from iverilog) and drives window.cmuxWaveform.fsm as cmux does once its
// engines (Verdi, Yosys, or the dump alone) have a model of the state register.
// Usage: fsm <assetRoot> <fsm.vcd> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
var failures = 0

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var requested: [[String]] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func runFsmChecks() async {
    func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
    func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    func marker() async -> Double? { (await call("return cmuxWaveform.link.markerTime()") as? NSNumber)?.doubleValue }
    func setMarker(_ t: Int) async { _ = await call("cmuxWaveform.link.setMarker(\(t)); return null"); await sleep(350) }
    func state() async -> [String: Any] { await call("return await cmuxWaveform.fsm.state()") as? [String: Any] ?? [:] }
    func current() async -> String? { ((await state())["current"] as? [String: Any])?["bits"] as? String }
    // A click on the pane's node or edge (shift: the one before).
    func click(_ selector: String, shift: Bool = false) async {
      _ = await call("""
        const el = document.querySelector(\(String(reflecting: selector)));
        if (!el) { return false; }
        el.dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: \(shift) })); return true;
      """)
      await sleep(400)
    }
    let ctlPath = "['tb', 'dut', 'u_ctl', 'state']"
    // Verdi's model of ctl (FsmFixtures.verdiCtl, as FsmModel.pageObject gives it).
    let ctlModel = """
      { signal: 'state', width: 3, engine: 'verdi', controls: ['go', 'stall'], reset: '000', resetSignal: 'rst',
        states: [{ bits: '000', name: 'IDLE' }, { bits: '001', name: 'FETCH' }, { bits: '100', name: 'DECODE' },
                 { bits: '101', name: 'EXEC' }, { bits: '111', name: 'DONE' }],
        transitions: [{ from: '*', to: '000' }, { from: '111', to: '000' }, { from: '101', to: '001', condition: 'go' },
                      { from: '101', to: '111', condition: '!go' }, { from: '100', to: '101', condition: '!stall' },
                      { from: '001', to: '100' }, { from: '000', to: '001', condition: 'go' }] }
    """
    let api = await call("return !!(window.cmuxWaveform.fsm && cmuxWaveform.fsm.show && cmuxWaveform.fsm.state && cmuxWaveform.fsm.hide)") as? Bool
    expect(api == true, "window.cmuxWaveform.fsm has show / state / hide")
    let hiddenFirst = await call("const p = document.getElementById('fsm'); return !p || p.hidden || getComputedStyle(p).display === 'none'") as? Bool
    expect(hiddenFirst == true, "no pane until cmux shows one")

    // Asking: the row menu's Show State Machine posts the row's dump path to cmux.
    _ = await call("return await cmuxWaveform.link.addSignal(\(ctlPath))")
    await sleep(500)
    let menu = await call("""
      const row = (cmuxWaveform.viewerContext.webview.displayedSignals || []).find(s => s.name === 'tb.dut.u_ctl.state');
      const args = { webviewSection: 'signal', netlistId: row.netlistId, scopePath: 'tb.dut.u_ctl', signalName: 'state', width: 3 };
      const ctx = cmuxCommands.menuContext(args);
      const items = cmuxUI.buildMenu(cmuxCommands.menus['webview/context'], ctx, (e) => ({ label: e.command || e.submenu, run: () => {} }));
      const bit = cmuxCommands.menuContext(Object.assign({}, args, { width: 1 }));
      const bitItems = cmuxUI.buildMenu(cmuxCommands.menus['webview/context'], bit, (e) => ({ label: e.command || e.submenu, run: () => {} }));
      cmuxCommands.run('vaporview.showStateMachine', args);
      return [JSON.stringify(items).includes('vaporview.showStateMachine'), JSON.stringify(bitItems).includes('vaporview.showStateMachine')];
    """) as? [Bool] ?? []
    await sleep(300)
    expect(menu == [true, false], "a vector row's menu has Show State Machine, a 1-bit row's not: \(menu)")
    expect(requested.last == ["tb", "dut", "u_ctl", "state"], "and it asks cmux for the row's state machine: \(requested)")

    // The real menu path, as a user takes it: a right-click on the row's label in the viewer frame
    // opens cmux's menu (cmux-commands.js contextmenu → cmux-ui.js), a click on its Show State Machine
    // item posts `fsmRequest` to cmux, and cmux answers the way FilePreviewWaveformSession.callPage does.
    func rightClickRow(scope: String, signal: String) async -> [String] {
      await call("""
        document.querySelectorAll('.cmux-menu').forEach((m) => m.remove());
        const doc = document.getElementById('viewer').contentDocument;
        const label = Array.from(doc.querySelectorAll('.waveform-label[data-vscode-context]')).find((el) => {
          try {
            const c = JSON.parse(el.getAttribute('data-vscode-context').replace(/%x20/g, ' '));
            return c.webviewSection === 'signal' && c.scopePath === \(String(reflecting: scope)) && c.signalName === \(String(reflecting: signal));
          } catch (e) { return false; }
        });
        if (!label) { return ['no row']; }
        const r = label.getBoundingClientRect();
        label.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2, clientX: r.left + 5, clientY: r.top + 5 }));
        return Array.from(document.querySelectorAll('.cmux-menu .cmux-menu-item .label')).map((l) => l.textContent);
      """) as? [String] ?? []
    }
    let showLabel = await call("return (cmuxWaveform.strings || {})['command.showStateMachine'] || 'showStateMachine'") as? String ?? "showStateMachine"
    _ = await call("return await cmuxWaveform.link.addSignal(['tb', 'dut', 'u_ctl', 'go'])")
    await sleep(500)
    let bitLabels = await rightClickRow(scope: "tb.dut.u_ctl", signal: "go")
    expect(!bitLabels.isEmpty && bitLabels != ["no row"] && !bitLabels.contains(showLabel),
           "a right-click on a 1-bit row opens a menu without \(showLabel): \(bitLabels)")
    let asked = requested.count
    let vectorLabels = await rightClickRow(scope: "tb.dut.u_ctl", signal: "state")
    expect(vectorLabels.contains(showLabel), "a right-click on the state register's row offers \(showLabel): \(vectorLabels)")
    let clicked = await call("""
      const item = Array.from(document.querySelectorAll('.cmux-menu .cmux-menu-item')).find((i) => i.querySelector('.label').textContent === \(String(reflecting: showLabel)));
      if (!item) { return false; }
      item.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      return document.querySelectorAll('.cmux-menu').length === 0;
    """) as? Bool
    await sleep(300)
    expect(clicked == true, "clicking the item runs it and closes the menu")
    expect(requested.count == asked + 1 && requested.last == ["tb", "dut", "u_ctl", "state"],
           "the click posts one fsmRequest with the row's dump path: \(requested.suffix(2))")
    // cmux's answers (WaveformFSMEngines.requested): the status, then the model, through callPage's body.
    let native = "const link = window.cmuxWaveform && window.cmuxWaveform.fsm;\nreturn link ? await link.show(argument) : null;"
    func answer(_ argument: [String: Any]) async {
      do { _ = try await web.callAsyncJavaScript(native, arguments: ["argument": argument], in: nil, contentWorld: .page) }
      catch { print("JS ERROR native show", error) }
      await sleep(400)
    }
    await answer(["path": ["tb", "dut", "u_ctl", "state"], "status": "Looking for the state machine…"])
    let nativeStatus = await call("const p = document.getElementById('fsm'); return !p.hidden && p.textContent.includes('Looking for the state machine…')") as? Bool
    expect(nativeStatus == true, "cmux's status answer opens the pane")
    let modelObject = await call("return \(ctlModel)") as? [String: Any] ?? [:]
    await answer(["path": ["tb", "dut", "u_ctl", "state"], "model": modelObject, "note": "From Verdi"])
    let nativeGraph = await call("return document.querySelectorAll('#fsm svg .fsm-node').length") as? Int
    expect(nativeGraph == 5, "cmux's model answer draws the graph: \(nativeGraph ?? -1) nodes")
    _ = await call("cmuxWaveform.fsm.hide(); return null")
    let pending = await call("""
      cmuxWaveform.fsm.show({ path: \(ctlPath), status: 'Looking for the state machine…' });
      const p = document.getElementById('fsm');
      return [!p.hidden && getComputedStyle(p).display !== 'none', p.textContent.includes('Looking for the state machine…')];
    """) as? [Bool] ?? []
    expect(pending == [true, true], "a status shows in the pane while the engines run: \(pending)")

    // The graph: a node for each state, an edge for each transition.
    _ = await call("cmuxWaveform.fsm.show({ path: \(ctlPath), model: \(ctlModel), note: 'From Verdi' }); return null")
    await sleep(600)
    let svg = await call("""
      const p = document.getElementById('fsm');
      const nodes = Array.from(p.querySelectorAll('svg .fsm-node')).map(n => n.getAttribute('data-bits')).sort();
      const edges = Array.from(p.querySelectorAll('svg .fsm-edge')).map(e => e.getAttribute('data-from') + '>' + e.getAttribute('data-to')).sort();
      const dashed = p.querySelectorAll('svg .fsm-edge.observed').length;
      return { nodes, edges, dashed, text: p.textContent };
    """) as? [String: Any] ?? [:]
    expect((svg["nodes"] as? [String]) == ["000", "001", "100", "101", "111"], "a node for each state: \(svg["nodes"] ?? "none")")
    expect((svg["edges"] as? [String]) == ["*>000", "000>001", "001>100", "100>101", "101>001", "101>111", "111>000"].sorted(),
           "an edge for each transition, the reset's too: \(svg["edges"] ?? "none")")
    expect((svg["dashed"] as? Int) == 0, "the dump takes no transition the model lacks: \(svg["dashed"] ?? "none")")
    let text = svg["text"] as? String ?? ""
    expect(["IDLE", "FETCH", "DECODE", "EXEC", "DONE", "!stall", "From Verdi", "tb.dut.u_ctl.state"].allSatisfy { text.contains($0) },
           "states are named, edges carry their conditions, and the pane says the signal and where the model came from: \(text.prefix(300))")

    // The current state at the marker.
    await setMarker(50)
    var s = await state()
    expect(await current() == "100" && ((s["current"] as? [String: Any])?["name"] as? String) == "DECODE", "at 50 the state is DECODE: \(s["current"] ?? "none")")
    let shownCurrent = await call("""
      const p = document.getElementById('fsm');
      return [Array.from(p.querySelectorAll('.fsm-node.current')).map(n => n.getAttribute('data-bits')).join(','), p.querySelector('.fsm-current').textContent];
    """) as? [String] ?? []
    expect(shownCurrent.count == 2 && shownCurrent[0] == "100" && shownCurrent[1].contains("DECODE"), "its node is marked, and the pane names it: \(shownCurrent)")
    let lastEdge = await call("return Array.from(document.querySelectorAll('#fsm .fsm-edge.last')).map(e => e.getAttribute('data-from') + '>' + e.getAttribute('data-to')).join(',')") as? String
    expect(lastEdge == "001>100", "the transition that got there is marked: \(lastEdge ?? "none")")
    await setMarker(2)
    expect(await current() == nil, "before reset (x) there is no current state")
    await setMarker(90)
    expect(await current() == "111", "it follows the marker (90: DONE)")

    // A transition click: the marker goes to its next occurrence; shift, its previous one.
    await setMarker(50)
    await click("#fsm .fsm-edge[data-from='100'][data-to='101']")
    expect(await marker() == 75, "DECODE->EXEC from 50: 75 (\(String(describing: await marker())))")
    await click("#fsm .fsm-edge[data-from='100'][data-to='101']")
    expect(await marker() == 185, "and again: 185 (\(String(describing: await marker())))")
    await click("#fsm .fsm-edge[data-from='100'][data-to='101']", shift: true)
    expect(await marker() == 75, "shift-click goes back: 75 (\(String(describing: await marker())))")
    expect(await current() == "101", "and the state there is EXEC")
    await click("#fsm .fsm-node[data-bits='111']")
    expect(await marker() == 85, "a state click: its next entry, 85 (\(String(describing: await marker())))")
    await click("#fsm .fsm-edge[data-from='*'][data-to='000']", shift: true)
    expect(await marker() == 5, "the reset edge: the reset at 5 (\(String(describing: await marker())))")
    // (The dump ends at 610; the viewer ignores a marker past the end. The last DECODE->EXEC is at 555.)
    await setMarker(580)
    await click("#fsm .fsm-edge[data-from='100'][data-to='101']")
    expect(await marker() == 580, "none later: the marker stays (\(String(describing: await marker())))")

    // Counts over the dump: entries into each state, and each transition's.
    s = await state()
    let visits = Dictionary(((s["nodes"] as? [[String: Any]]) ?? []).map { ($0["bits"] as? String ?? "", ($0["visits"] as? Int) ?? -1) }, uniquingKeysWith: { a, _ in a })
    expect(visits == ["000": 4, "001": 11, "100": 11, "101": 10, "111": 3], "entries into each state: \(visits)")
    let counts = Dictionary(((s["edges"] as? [[String: Any]]) ?? []).map { (($0["from"] as? String ?? "") + ">" + ($0["to"] as? String ?? ""), ($0["count"] as? Int) ?? -1) }, uniquingKeysWith: { a, _ in a })
    expect(counts == ["*>000": 1, "000>001": 4, "001>100": 11, "100>101": 10, "101>001": 7, "101>111": 3, "111>000": 3], "each transition's count: \(counts)")
    let countsSay = await call("return (document.querySelector('#fsm .fsm-counts-note') || {}).textContent || ''") as? String ?? ""
    expect(countsSay == "Counts are entries into a state and transitions taken, not clock cycles.", "the pane says what the counts count: \(countsSay)")
    let countText = await call("return document.querySelector(\"#fsm .fsm-edge[data-from='101'][data-to='001']\").textContent") as? String ?? ""
    expect(countText.contains("7"), "an edge shows its count: \(countText)")

    // A transition the model lacks but the dump takes is drawn dashed (observed).
    let lacking = ctlModel.replacingOccurrences(of: "{ from: '111', to: '000' }, ", with: "")
    _ = await call("cmuxWaveform.fsm.show({ path: \(ctlPath), model: \(lacking) }); return null")
    await sleep(600)
    let observed = await call("return Array.from(document.querySelectorAll('#fsm .fsm-edge.observed')).map(e => e.getAttribute('data-from') + '>' + e.getAttribute('data-to')).join(',')") as? String
    expect(observed == "111>000", "a transition only the dump has is dashed: \(observed ?? "none")")
    // The dump alone (no engine): the enum's states, the dump's transitions, all observed.
    _ = await call("""
      cmuxWaveform.fsm.show({ path: \(ctlPath), model: { signal: 'state', width: 3, engine: 'observed', controls: [],
        states: [{ bits: '000', name: 'IDLE' }, { bits: '001', name: 'FETCH' }, { bits: '010', name: 'SPARE' }, { bits: '100', name: 'DECODE' },
                 { bits: '101', name: 'EXEC' }, { bits: '111', name: 'DONE' }], transitions: [] } }); return null
    """)
    await sleep(600)
    s = await state()
    let all = ((s["edges"] as? [[String: Any]]) ?? []).map { ($0["from"] as? String ?? "") + ">" + ($0["to"] as? String ?? "") }.sorted()
    let allObserved = ((s["edges"] as? [[String: Any]]) ?? []).allSatisfy { $0["observed"] as? Bool == true }
    expect(all == ["*>000", "000>001", "001>100", "100>101", "101>001", "101>111", "111>000"].sorted() && allObserved, "observed only: the dump's transitions: \(all)")
    let spare = await call("return !!document.querySelector(\"#fsm .fsm-node[data-bits='010']\")") as? Bool
    expect(spare == true, "a state the dump never enters is still drawn")

    // A localparam FSM (Yosys's codes, named from the localparams): VCD's short values are widened.
    _ = await call("""
      cmuxWaveform.fsm.show({ path: ['tb', 'dut', 'u_lp', 'st'], model: { signal: 'st', width: 2, engine: 'yosys', controls: ['a', 'b'], reset: '00',
        states: [{ bits: '00', name: 'S_A' }, { bits: '01', name: 'S_B' }, { bits: '10', name: 'S_C' }],
        transitions: [{ from: '00', to: '00', condition: '!a' }, { from: '00', to: '01', condition: 'a' }, { from: '01', to: '00', condition: '!b' },
                      { from: '01', to: '10', condition: 'b' }, { from: '10', to: '00' }] } }); return null
    """)
    await sleep(600)
    await setMarker(70)
    s = await state()
    expect(((s["current"] as? [String: Any])?["name"] as? String) == "S_C", "the localparam FSM at 70 is S_C: \(s["current"] ?? "none")")
    let lpVisits = Dictionary(((s["nodes"] as? [[String: Any]]) ?? []).map { ($0["bits"] as? String ?? "", ($0["visits"] as? Int) ?? -1) }, uniquingKeysWith: { a, _ in a })
    expect(lpVisits == ["00": 17, "01": 17, "10": 10], "its entries: \(lpVisits)")
    let selfLoop = await call("return !!document.querySelector(\"#fsm .fsm-edge[data-from='00'][data-to='00']\")") as? Bool
    expect(selfLoop == true, "a self loop is drawn")
    await click("#fsm .fsm-edge[data-from='00'][data-to='00']")
    expect(await marker() == 70, "a self loop leaves no change to go to: the marker stays")
    await click("#fsm .fsm-edge[data-from='10'][data-to='00']")
    expect(await marker() == 75, "S_C->S_A from 70: 75 (\(String(describing: await marker())))")

    // A message instead of a model (no state machine found), then closing.
    let failed = await call("""
      cmuxWaveform.fsm.show({ path: \(ctlPath), status: 'No state machine found for this signal.' });
      const p = document.getElementById('fsm');
      return [p.querySelectorAll('svg .fsm-node').length, p.textContent.includes('No state machine found')];
    """) as? [Any] ?? []
    expect(failed.count == 2 && (failed[0] as? Int) == 0 && (failed[1] as? Bool) == true, "a status replaces the graph: \(failed)")
    _ = await call("cmuxWaveform.fsm.show({ path: \(ctlPath), model: \(ctlModel) }); return null")
    await sleep(400)
    await click("#fsm .fsm-close")
    let closed = await call("const p = document.getElementById('fsm'); return p.hidden || getComputedStyle(p).display === 'none'") as? Bool
    let openAfter = (await state())["open"] as? Bool
    expect(closed == true && openAfter == false, "the close button hides the pane")
    print(failures == 0 ? "FSM CHECKS PASSED" : "FSM CHECKS FAILED: \(failures)")
    // For the snapshot.
    _ = await call("cmuxWaveform.fsm.show({ path: \(ctlPath), model: \(ctlModel), note: 'From Verdi' }); return null")
    await setMarker(50)
    snap()
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
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    // Keep the harness invisible to the user: off-screen, transparent, click-through.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if (m.body as? [String: Any])?["type"] as? String != "log" { print("[\(m.name)]", m.body) }
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      let fmt = waveURL.pathExtension.lowercased()
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'\(fmt)', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'}})")
    } else if type == "opened" {
      Task { @MainActor in await self.runFsmChecks() }
    } else if type == "fsmRequest" {
      requested.append((body["path"] as? [String]) ?? [])
    } else if type == "error" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
        print("wrote", out.path)
      } else { print("snapshot failed", String(describing: err)) }
      exit(0)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
