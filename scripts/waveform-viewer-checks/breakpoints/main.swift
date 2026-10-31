// Waveform debugger breakpoint checks (run.sh breakpoints): loads Resources/vaporview through
// the real WaveformViewerSchemeHandler in an off-screen WKWebView, opens breakpoints.vcd (from
// make-vcd.py) and drives window.cmuxWaveform.debugger's breakpoints as cmux would: change and
// equals breakpoints, continue and reverse continue, where a hit lands, play stopping at a hit,
// the list in the page and the waveform row's menu items.
// Usage: breakpoints <assetRoot> <breakpoints.vcd> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
var failures = 0

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var lineEvents: [[String: Any]] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

  /// The marker once the viewer reports it (a move is posted to the viewer frame first).
  func marker(_ expected: Int? = nil) async -> Int? {
    var value: Int?
    for _ in 0..<40 {
      value = await call("return cmuxWaveform.viewerContext.webview.markerTime ?? null") as? Int
      if expected == nil || value == expected { return value }
      await sleep(50)
    }
    return value
  }

  func dbg(_ expression: String) async -> [String: Any]? {
    await call("return await cmuxWaveform.debugger.\(expression)") as? [String: Any]
  }

  func list() async -> [[String: Any]] {
    await call("return cmuxWaveform.debugger.breakpoints()") as? [[String: Any]] ?? []
  }

  func toasts() async -> [String] {
    await call("return Array.from(document.querySelectorAll('.cmux-toast')).map((t) => t.textContent)") as? [String] ?? []
  }

  func clearToasts() async { _ = await call("document.querySelectorAll('.cmux-toast').forEach((t) => t.remove()); return null") }

  /// continue({ dir }) then the marker it moved to: [hit time, landed, marker].
  func go(_ dir: Int, expect landed: Int?) async -> (hit: [String: Any]?, marker: Int?) {
    let result = await dbg("continue({ dir: \(dir) })")
    let hit = result?["hit"] as? [String: Any]
    return (hit, await marker(landed))
  }

  func runChecks() async {
    // No breakpoints: F5 keeps Play/Pause; reverse continue says there are none.
    let none = await dbg("continue({ dir: 1, orTogglePlay: true })")
    expect(none?["playing"] as? Bool == true, "no breakpoints: F5 plays: \(String(describing: none))")
    _ = await dbg("pause()")
    await clearToasts()
    let noneBack = await dbg("continue({ dir: -1 })")
    expect(noneBack?["hit"] is NSNull && noneBack?["reason"] as? String == "none", "no breakpoints: reverse continue finds none: \(String(describing: noneBack))")
    expect(await toasts().contains("No breakpoints are enabled."), "and says so: \(await toasts())")
    _ = await dbg("jump({ to: 'first' })")
    expect(await marker(5) == 5, "marker on the first posedge")

    // A change breakpoint on a registered signal: each hit lands on the posedge it changed at.
    let state = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'state'], kind: 'change' })") as? [String: Any]
    let stateId = state?["id"] as? Int
    expect(stateId != nil && state?["enabled"] as? Bool == true, "change breakpoint added: \(String(describing: state))")
    var landed: [Int] = []
    for expected in [95, 195, 295, 395] {
      let (hit, at) = await go(1, expect: expected)
      landed.append(at ?? -1)
      expect(hit?["time"] as? Int == expected && hit?["landed"] as? Int == expected && hit?["id"] as? Int == stateId,
             "continue: state changes at \(expected), lands there: \(String(describing: hit)), marker \(String(describing: at))")
    }
    let end = await dbg("continue({ dir: 1 })")
    expect(end?["hit"] is NSNull && end?["reason"] as? String == "end", "no change after 395: \(String(describing: end))")
    expect(await marker(395) == 395, "the marker stays at 395")
    expect(await toasts().contains("No breakpoint hit before the end."), "and says so: \(await toasts())")
    for expected in [295, 195, 95] {
      let (hit, at) = await go(-1, expect: expected)
      expect(hit?["landed"] as? Int == expected && at == expected, "reverse continue lands on \(expected): \(String(describing: hit)), \(String(describing: at))")
    }
    let start = await dbg("continue({ dir: -1 })")
    expect(start?["hit"] is NSNull && start?["reason"] as? String == "start", "the dump's first value is not a change: \(String(describing: start))")
    expect(await toasts().contains("No breakpoint hit before the start."), "and says so: \(await toasts())")

    // A change between posedges lands on the first posedge at or after it; the message has the exact time.
    _ = await call("cmuxWaveform.debugger.setBreakpointEnabled({ id: \(stateId ?? -1), enabled: false }); return null")
    let irq = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'irq'], kind: 'change' })") as? [String: Any]
    let irqId = irq?["id"] as? Int
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    await clearToasts()
    var (hit, at) = await go(1, expect: 55)
    expect(hit?["time"] as? Int == 52 && hit?["landed"] as? Int == 55 && at == 55 && hit?["cycle"] as? Int == 6,
           "irq rises at 52: lands on 55, cycle 6: \(String(describing: hit)), \(String(describing: at))")
    let message = await toasts()
    expect(message.contains("Breakpoint: top.irq changes at 52 ns (cycle 6)"), "the hit message has the exact time: \(message)")
    (hit, at) = await go(1, expect: 705)
    expect(hit?["time"] as? Int == 702 && at == 705, "its fall at 53 lands on 55 too, so the next hit is 702 at 705: \(String(describing: hit))")
    (hit, at) = await go(-1, expect: 55)
    expect(hit?["time"] as? Int == 53 && at == 55, "reverse from 705: the fall at 53, on 55: \(String(describing: hit))")
    let before = await dbg("continue({ dir: -1 })")
    expect(before?["reason"] as? String == "start", "reverse from 55: nothing before it: \(String(describing: before))")
    _ = await call("cmuxWaveform.link.setMarker(50); return null")
    _ = await marker(50)
    (hit, at) = await go(1, expect: 55)
    expect(hit?["time"] as? Int == 52 && at == 55, "from mid-cycle 50: the rise at 52, on 55: \(String(describing: hit))")
    _ = await call("cmuxWaveform.debugger.setBreakpointEnabled({ id: \(irqId ?? -1), enabled: false }); return null")

    // Equals: hex, decimal, '?' for any bit, x; the dump's first value counts when it matches.
    func equals(_ value: String) async -> Int? {
      let bp = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: \"\(value)\" })") as? [String: Any]
      return bp?["id"] as? Int
    }
    func only(_ id: Int?) async {
      _ = await call("""
        for (const b of cmuxWaveform.debugger.breakpoints()) {
          cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(id ?? -1) });
        }
        return null
      """)
    }
    for (value, expected) in [("'h5a", 605), ("8'h5A", 605), ("165", 305), ("8'b????_0101", 305), ("'b1010_0101", 305)] {
      let id = await equals(value)
      expect(id != nil, "equals \(value) added")
      await only(id)
      _ = await dbg("jump({ to: 'first' })")
      _ = await marker(5)
      let (hit, at) = await go(1, expect: expected)
      expect(hit?["time"] as? Int == expected && at == expected, "data == \(value): first at \(expected): \(String(describing: hit)), \(String(describing: at))")
      _ = await call("cmuxWaveform.debugger.removeBreakpoint({ id: \(id ?? -1) }); return null")
    }
    let x = await equals("x")
    await only(x)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    (hit, at) = await go(1, expect: 505)
    expect(hit?["time"] as? Int == 505, "data == x after the first posedge: 505: \(String(describing: hit))")
    (hit, at) = await go(-1, expect: 5)
    expect(hit?["time"] as? Int == 0 && at == 5, "reverse: x from the start (time 0), on the first posedge: \(String(describing: hit)), \(String(describing: at))")
    _ = await call("cmuxWaveform.debugger.removeBreakpoint({ id: \(x ?? -1) }); return null")
    await clearToasts()
    let bad = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: 'zq' })")
    expect(bad is NSNull, "an unreadable value is not added: \(String(describing: bad))")
    let wide = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: \"'h1ff\" })")
    expect(wide is NSNull, "a value wider than the signal is not added: \(String(describing: wide))")
    expect(await toasts().count == 2, "both say why: \(await toasts())")
    let busy = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'busy'], kind: 'change' })") as? [String: Any]
    await only(busy?["id"] as? Int)
    let never = await dbg("continue({ dir: 1 })")
    expect(never?["reason"] as? String == "end", "a signal that never changes: no hit: \(String(describing: never))")

    // Several enabled: the nearest wins.
    _ = await call("""
      for (const b of cmuxWaveform.debugger.breakpoints()) {
        cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(stateId ?? -1) || b.id === \(irqId ?? -1) });
      }
      return null
    """)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var hits: [Int] = []
    for expected in [55, 95, 195, 295, 395, 705] {
      let (hit, _) = await go(1, expect: expected)
      hits.append(hit?["landed"] as? Int ?? -1)
    }
    expect(hits == [55, 95, 195, 295, 395, 705], "state and irq: the nearest each time: \(hits)")

    // F5 with breakpoints continues instead of playing.
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    let f5 = await dbg("continue({ dir: 1, orTogglePlay: true })")
    expect((f5?["hit"] as? [String: Any])?["landed"] as? Int == 55 && f5?["playing"] as? Bool != true,
           "F5 with breakpoints continues: \(String(describing: f5))")

    // Play stops at the first hit it crosses, even when a tick skips cycles.
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    _ = await dbg("play({ rate: 500 })")
    var playing = true
    for _ in 0..<60 where playing {
      await sleep(50)
      playing = (await dbg("state()"))?["playing"] as? Bool ?? false
    }
    let stop1 = await marker(55)
    expect(!playing && stop1 == 55, "play at 500 cycles/s stops on 55, irq's first hit: \(String(describing: stop1))")
    _ = await dbg("play({ rate: 500 })")
    playing = true
    for _ in 0..<60 where playing {
      await sleep(50)
      playing = (await dbg("state()"))?["playing"] as? Bool ?? false
    }
    let stop2 = await marker(95)
    expect(!playing && stop2 == 95, "played on from there: stops on 95 (state): \(String(describing: stop2))")

    // The list in the page: one row each, a checkbox to enable, a button to remove.
    let rows = await call("""
      const list = document.getElementById('cmux-breakpoints');
      if (!list || !list.closest('#netlist')) { return null; }
      return Array.from(list.querySelectorAll('.cmux-breakpoint')).map((r) => [r.querySelector('.label').textContent, r.querySelector('input').checked]);
    """) as? [[Any]]
    let labels = rows?.compactMap { $0.first as? String } ?? []
    expect(labels == ["top.state changes", "top.irq changes", "top.busy changes"], "the list in the netlist pane: \(String(describing: rows))")
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint input').click(); return null")
    expect((await list()).first?["enabled"] as? Bool == false, "its checkbox disables the first: \(await list())")
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint .remove').click(); return null")
    expect((await list()).map { $0["id"] as? Int } == [irqId, busy?["id"] as? Int], "its remove button removes it: \(await list())")
    let hitMark = await call("return Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint')).map((r) => r.classList.contains('hit'))") as? [Bool]
    expect(hitMark == [false, false], "the last hit (state) was removed, so none is marked: \(String(describing: hitMark))")

    // The waveform row's menu: Break When Changes and Break When Equals… for the row's signal.
    let menu = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'data'], true);
      const items = window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
      const labels = items.map((i) => i.label);
      const change = items.find((i) => i.label === 'Break When Changes');
      if (change) { await change.run(); }
      return labels;
    """) as? [String]
    expect(menu == ["Break When Changes", "Break When Equals…"], "the row menu items: \(String(describing: menu))")
    let added = (await list()).last
    expect(added?["path"] as? [String] == ["top", "data"] && added?["kind"] as? String == "change",
           "Break When Changes adds one for the row's signal: \(String(describing: added))")
    let notSignal = await call("return window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal-separator' }).length") as? Int
    expect(notSignal == 0, "no items on a separator row")

    // ... in the viewer's own context menu on a signal row.
    _ = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'state'], true);
      cmuxWaveform.host.addVariables([v]);
      return null
    """)
    var shown: [String]?
    for _ in 0..<40 {
      shown = await call("""
        const d = document.getElementById('viewer').contentDocument;
        const row = Array.from(d.querySelectorAll('[data-vscode-context]')).find((el) => /"webviewSection":"signal"/.test(el.getAttribute('data-vscode-context').replace(/%x20/g, ' ')));
        if (!row) { return null; }
        row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
        const labels = Array.from(document.querySelectorAll('.cmux-menu-item .label')).map((l) => l.textContent);
        window.cmuxUI.closeMenus();
        return labels;
      """) as? [String]
      if shown != nil { break }
      await sleep(100)
    }
    expect(shown?.contains("Break When Changes") == true && shown?.contains("Break When Equals…") == true,
           "a signal row's context menu has both: \(String(describing: shown))")

    await runLineChecks()
    print(failures == 0 ? "BREAKPOINT CHECKS PASSED" : "BREAKPOINT CHECKS FAILED: \(failures)")
    snap()
  }

  /// Line breakpoints (cmux sends them: the editor's gutter and F9): any of the line's signals changing hits.
  func runLineChecks() async {
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } return null")
    _ = await call("""
      return cmuxWaveform.debugger.setLineBreakpoints({ items: [
        { key: 'core.sv:4', label: 'core.sv:4', paths: [['top', 'state'], ['top', 'irq']], enabled: true },
        { key: 'core.sv:9', label: 'core.sv:9', paths: [], enabled: true },
      ] })
    """)
    let listed = await list()
    expect(listed.map { $0["kind"] as? String } == ["line", "line"] && listed.first?["key"] as? String == "core.sv:4"
           && listed.first?["label"] as? String == "core.sv:4", "line breakpoints listed: \(listed)")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var hits: [Int] = []
    for expected in [55, 95, 195] {
      let (hit, _) = await go(1, expect: expected)
      hits.append(hit?["landed"] as? Int ?? -1)
    }
    expect(hits == [55, 95, 195], "a line hits when any of its signals changes (irq, then state): \(hits)")
    let (back, _) = await go(-1, expect: 95)
    expect(back?["landed"] as? Int == 95, "and in reverse: \(String(describing: back))")
    let message = await toasts()
    expect(message.contains { $0.hasPrefix("Breakpoint: core.sv:4 at ") }, "the hit names the line: \(message)")
    let unplaced = await call("""
      const rows = Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint'));
      return rows.map((r) => r.querySelector('.label').title);
    """) as? [String]
    expect(unplaced?.last?.contains("not placed") == true, "a line with no signals in the waveform says so: \(String(describing: unplaced))")
    // The list's checkbox and remove button tell cmux, which owns line breakpoints.
    lineEvents.removeAll()
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint input').click(); return null")
    _ = await call("document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint .remove')[1].click(); return null")
    await sleep(100)
    let told = lineEvents.map { "\($0["key"] as? String ?? "?"):\($0["enabled"] as? Bool ?? true):\($0["removed"] as? Bool ?? false)" }
    expect(told == ["core.sv:4:false:false", "core.sv:9:true:true"], "cmux is told: \(told)")
    expect((await list()).map { $0["enabled"] as? Bool } == [false], "and the page shows it: \(await list())")
    // A new set replaces the lines, and leaves signal breakpoints alone.
    _ = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'busy'], kind: 'change' })")
    _ = await call("return cmuxWaveform.debugger.setLineBreakpoints({ items: [{ key: 'core.sv:5', label: 'core.sv:5', paths: [['top', 'data']], enabled: true }] })")
    let replaced = (await list()).map { ($0["kind"] as? String ?? "") + ":" + ($0["label"] as? String ?? "") }
    expect(replaced == ["change:top.busy changes", "line:core.sv:5"], "lines replaced, the signal breakpoint kept: \(replaced)")
  }

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map((x) => (x && x.stack ? String(x) + ' ' + x.stack : String(x))).join(' ')); } catch(e){}; o.apply(console, a); }; }
      window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno + ':' + e.colno + ' ' + (e.error && e.error.stack)));
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

  var checksStarted = false

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else {
      print("[\(m.name)]", m.body)
      return
    }
    if type == "debugger", body["event"] as? String == "lineBreakpoint" { lineEvents.append(body); return }
    if ["debugger", "event", "sessionState", "log", "keyState", "context", "signalData"].contains(type) { return }
    print("[\(m.name)]", type)
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(Harness.strings)})")
    } else if type == "opened" {
      guard !checksStarted else { return }
      checksStarted = true
      Task { @MainActor in await self.runChecks() }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  /// The English strings cmux gives the page (WaveformDebugger.pageStrings).
  static let strings = """
  {netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
   debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s',
   debuggerBreakpoints:'Breakpoints', debuggerBreakWhenChanges:'Break When Changes', debuggerBreakWhenEquals:'Break When Equals…',
   debuggerBreakEqualsPrompt:'Break when %@ equals', debuggerBreakEqualsPlaceholder:"For example 'h3f, 8'b1010_??01, 12 or x",
   debuggerBreakpointChanges:'%@ changes', debuggerBreakpointEquals:'%1$@ == %2$@', debuggerRemoveBreakpoint:'Remove',
   debuggerBreakpointHit:'Breakpoint: %1$@ at %2$@ (cycle %3$@)', debuggerNoHitForward:'No breakpoint hit before the end.',
   debuggerNoHitBack:'No breakpoint hit before the start.', debuggerNoBreakpoints:'No breakpoints are enabled.',
   debuggerBadValue:'“%1$@” is not a value for a %2$@-bit signal.', debuggerTooManyChanges:'%@ changes too often to search here.',
   debuggerBreakpointSignalGone:'%@ is not in this waveform.',
   debuggerLineNotPlaced:'%@: none of its signals are in the waveform (not placed in the design yet).'}
  """

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
        print("wrote", out.path)
      } else { print("snapshot failed", String(describing: err)) }
      exit(failures == 0 ? 0 : 1)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("timeout"); exit(1) }
app.run()
