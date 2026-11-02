// Text breakpoint checks (run.sh text-breakpoints): loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen WKWebView, opens text-breakpoints.vcd (make-vcd.py)
// and drives window.cmuxWaveform.debugger's text breakpoints as cmux and the menus would: hits at
// every change into a matching text, the dump's first value, register names, case, plain-text
// patterns, ASCII, conditions, the list and its menu, the row menu, saving and restoring, caps,
// refusals, and the watchdog that stops a pattern that never finishes.
// Usage: text-breakpoints <assetRoot> <text-breakpoints.vcd> <out.png>
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
  var listEvents: [[[String: Any]]] = []
  var movedEvents: [[String: Any]] = []
  var openedCount = 0
  var watchEvents: [[String]] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

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

  /// Adds a text breakpoint on top.<signal>; its id (nil: refused).
  func addText(_ signal: String, _ format: String, _ pattern: String, extra: String = "") async -> Int? {
    let js = "return cmuxWaveform.debugger.addBreakpoint({ path: ['top', '\(signal)'], kind: 'text', format: '\(format)', pattern: \(Harness.js(pattern))\(extra) })"
    return (await call(js) as? [String: Any])?["id"] as? Int
  }

  static func js(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let text = String(data: data, encoding: .utf8)!
    return String(text.dropFirst().dropLast())
  }

  func only(_ id: Int?) async {
    _ = await call("""
      for (const b of cmuxWaveform.debugger.breakpoints()) {
        cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(id ?? -1) });
      }
      return null
    """)
  }

  /// From the first posedge, every landing forward until the end; then every landing back.
  func landings(_ id: Int?) async -> (forward: [Int], back: [Int]) {
    await only(id)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var forward: [Int] = []
    for _ in 0..<20 {
      let r = await dbg("continue({ dir: 1 })")
      guard let hit = r?["hit"] as? [String: Any], let landed = hit["landed"] as? Int else { break }
      forward.append(landed)
      _ = await marker(landed)
    }
    var back: [Int] = []
    for _ in 0..<20 {
      let r = await dbg("continue({ dir: -1 })")
      guard let hit = r?["hit"] as? [String: Any], let landed = hit["landed"] as? Int else { break }
      back.append(landed)
      _ = await marker(landed)
    }
    return (forward, back)
  }

  func runChecks() async {
    let worker = await call("return cmuxWaveform.debuggerText.usesWorker()") as? Bool
    expect(worker == true, "patterns are judged in a worker: \(String(describing: worker))")

    // csrw mtvec: at 0 (the first value), 15, and 52 between edges (lands on 55).
    let csrw = await addText("inst", "riscv", "csrw\\s+mtvec")
    expect(csrw != nil, "a RISC-V text breakpoint is added")
    var l = await landings(csrw)
    expect(l.forward == [15, 55], "forward from 5: 15, then 52 on 55: \(l.forward)")
    expect(l.back == [15, 5], "back: 15, then the first value (time 0) on 5: \(l.back)")
    let label = (await list()).first { $0["id"] as? Int == csrw }?["label"] as? String
    expect(label == "top.inst ~ /csrw\\s+mtvec/ (RISC-V)", "its label: \(String(describing: label))")

    // Every change into a matching text: li at 5, 35 and 75 (not 25 or 65).
    let li = await addText("inst", "riscv", "^li a0")
    l = await landings(li)
    expect(l.forward == [35, 75], "li a0: 35, 75 after the marker at 5: \(l.forward)")
    expect(l.back == [35, 5], "and back to the change at 5: \(l.back)")

    // Register names: x10 matches the ABI format by default; not when it is turned off (list menu).
    let x10 = await addText("inst", "riscv", "li x10")
    l = await landings(x10)
    expect(l.forward == [35, 75], "li x10 matches li a0: \(l.forward)")
    let menu = await call("""
      const shown = [];
      const real = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { shown.push(items); };
      const rows = Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint'));
      const row = rows.find((r) => r.querySelector('.label').textContent.includes('li x10'));
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 5, clientY: 5 }));
      window.cmuxUI.showMenu = real;
      const items = shown[0] || [];
      const names = items.find((i) => i.label.includes('Register Name'));
      if (names) { await names.run(); }
      return items.map((i) => i.label);
    """) as? [String]
    expect(menu == ["Edit Pattern…", "Match Case", "✓ Match Either Register Name (a0 or x10)", "Edit Condition…", "Remove"],
           "the list row's menu: \(String(describing: menu))")
    let x10bp = (await list()).first { $0["id"] as? Int == x10 }
    expect(x10bp?["anyRegisterNames"] as? Bool == false, "its register-name item turned it off: \(String(describing: x10bp))")
    l = await landings(x10)
    expect(l.forward.isEmpty && l.back.isEmpty, "li x10 alone no longer matches the RISC-V text: \(l)")

    // Case: insensitive unless asked.
    let upper = await addText("inst", "riscv", "LW A3")
    l = await landings(upper)
    expect(l.forward == [25], "LW A3 matches lw a3: \(l.forward)")
    _ = await call("return cmuxWaveform.debugger.setTextBreakpoint({ id: \(upper ?? -1), caseSensitive: true })")
    l = await landings(upper)
    expect(l.forward.isEmpty, "not with Match Case: \(l.forward)")

    // A pattern that is not a regex is plain text.
    let plain = await addText("inst", "riscv", "0(a1")
    l = await landings(plain)
    expect(l.forward == [25], "0(a1 as plain text: \(l.forward)")

    // Hex and ASCII formats; x values.
    let hex = await addText("inst", "hexadecimal", "^fe0")
    l = await landings(hex)
    expect(l.forward == [65], "hex ^fe0: \(l.forward)")
    let xs = await addText("inst", "hexadecimal", "^xxxx_xxxx$")
    l = await landings(xs)
    expect(l.forward == [85], "an x value's text: \(l.forward)")
    let ascii = await addText("msg", "ascii", "mu")
    l = await landings(ascii)
    expect(l.forward == [105], "ASCII 'mu' in cmux: \(l.forward)")

    // A condition, tested at the landing posedge.
    let cond = await addText("inst", "riscv", "^li a0", extra: ", condition: 'flag'")
    l = await landings(cond)
    expect(l.forward == [35] && l.back.isEmpty, "li a0 if flag: only 35: \(l)")

    // Editing the pattern (Edit Pattern… asks for it).
    let edited = await call("""
      const real = window.cmuxUI.prompt;
      window.cmuxUI.prompt = async () => 'bnez';
      const shown = [];
      const realMenu = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { shown.push(items); };
      const rows = Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint'));
      rows.find((r) => r.querySelector('.label').textContent.includes('0(a1'))
        .dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
      window.cmuxUI.showMenu = realMenu;
      await shown[0].find((i) => i.label === 'Edit Pattern…').run();
      window.cmuxUI.prompt = real;
      return cmuxWaveform.debugger.breakpoints().find((b) => b.id === \(plain ?? -1)).pattern;
    """) as? String
    expect(edited == "bnez", "Edit Pattern… changes it: \(String(describing: edited))")
    l = await landings(plain)
    expect(l.forward == [65], "and it hits on the new one: \(l.forward)")

    // The row menu: Break When Text Matches… in the row's format (hex here: the row isn't shown).
    await clearToasts()
    let rowMenu = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'msg'], true);
      const items = window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
      const real = window.cmuxUI.prompt;
      let asked = null;
      window.cmuxUI.prompt = async (o) => { asked = o.title; return '^6162'; };
      await items.find((i) => i.label === 'Break When Text Matches…').run();
      window.cmuxUI.prompt = real;
      return { labels: items.map((i) => i.label), asked };
    """) as? [String: Any]
    expect((rowMenu?["labels"] as? [String]) == ["Break When Changes", "Break When Equals…", "Break When Text Matches…", "Add Watch"],
           "the row menu: \(String(describing: rowMenu))")
    expect(rowMenu?["asked"] as? String == "Break when top.msg, shown as hex, matches", "its prompt: \(String(describing: rowMenu))")
    let fromMenu = (await list()).last
    expect(fromMenu?["format"] as? String == "hexadecimal" && fromMenu?["pattern"] as? String == "^6162", "the menu's breakpoint: \(String(describing: fromMenu))")
    l = await landings(fromMenu?["id"] as? Int)
    expect(l.forward == [205], "it hits at abcd: \(l.forward)")

    // What cmux is told (and saves), and a restore of it.
    let saved = listEvents.last?.first { $0["kind"] as? String == "text" && $0["pattern"] as? String == "csrw\\s+mtvec" }
    expect(saved?["format"] as? String == "riscv" && saved?["caseSensitive"] as? Bool == false && saved?["anyRegisterNames"] as? Bool == true,
           "cmux is told its fields: \(String(describing: saved))")
    let restored = await call("""
      return cmuxWaveform.debugger.restoreBreakpoints({ items: [
        { path: ['top', 'inst'], kind: 'text', format: 'riscv_numeric', pattern: 'li a0', enabled: true },
        { path: ['top', 'inst'], kind: 'equals', value: "32'h0005a683", enabled: false }] }).map((b) => b.label);
    """) as? [String]
    expect(restored == ["top.inst ~ /li a0/ (RISC-V, x0–x31)", "top.inst == 32'h0005a683"], "restored: \(String(describing: restored))")
    let restoredId = (await list()).first { $0["kind"] as? String == "text" }?["id"] as? Int
    l = await landings(restoredId)
    expect(l.forward == [35, 75], "the restored one hits (ABI names in a numeric format): \(l.forward)")

    // Refusals: no pattern, a format that isn't text, too many enabled.
    await clearToasts()
    let empty = await addText("inst", "riscv", "")
    let float = await addText("inst", "float", "1.5")
    expect(empty == nil && float == nil, "an empty pattern and a float format are refused")
    let said = await toasts()
    expect(said.contains("Text breakpoint top.inst ~ // (RISC-V): the pattern is empty")
           && said.contains("Text breakpoint top.inst ~ /1.5/ (float): this format cannot be searched as text"), "and say why: \(said)")
    await clearToasts()
    var added = 0
    for n in 0..<40 { if await addText("inst", "riscv", "nope\(n)") != nil { added += 1 } }
    let enabled = (await list()).filter { $0["kind"] as? String == "text" && $0["enabled"] as? Bool == true }.count
    expect(enabled == 32, "at most 32 enabled text breakpoints: \(enabled) (added \(added))")
    expect(await toasts().contains("At most 32 text breakpoints can be enabled at once."), "said: \(await toasts())")
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { if (/nope/.test(b.pattern || '')) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } } return null")

    // A pattern that never finishes: the watchdog stops it, says so, and the next search works.
    await clearToasts()
    _ = await call("cmuxWaveform.debuggerTextWatchdogMs = 300; return null")
    let slow = await addText("inst", "binary", "^(\\w+)*!$")
    let started = Date()
    l = await landings(slow)
    let took = Date().timeIntervalSince(started)
    expect(l.forward.isEmpty && took < 10, "stopped, no hit, \(String(format: "%.1f", took)) s: \(l)")
    expect(await toasts().contains { $0.contains("the pattern took too long to match") }, "and says so: \(await toasts())")
    _ = await call("cmuxWaveform.debuggerTextWatchdogMs = undefined; return null")
    let after = await addText("inst", "riscv", "csrw")
    l = await landings(after)
    expect(l.forward == [15, 55], "a new worker answers the next one: \(l.forward)")

    print(failures == 0 ? "TEXT BREAKPOINT CHECKS PASSED" : "TEXT BREAKPOINT CHECKS FAILED: \(failures)")
    snap()
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
    if type == "debugger", body["event"] as? String == "breakpoints" { listEvents.append(body["items"] as? [[String: Any]] ?? []); return }
    if type == "debugger", body["event"] as? String == "moved" { movedEvents.append(body); return }
    if type == "debugger", body["event"] as? String == "watches" { watchEvents.append(body["items"] as? [String] ?? []); return }
    if ["debugger", "event", "sessionState", "log", "keyState", "context", "signalData"].contains(type) { return }
    print("[\(m.name)]", type)
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(Harness.strings)})")
    } else if type == "opened" {
      openedCount += 1
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
   debuggerHitAfterLastEdge:'Breakpoint: %1$@ at %2$@, after the last clock edge.',
   debuggerNoEdges:'The clock never rises.', debuggerNoClock:'No clock.',
   debuggerEvaluate:'Evaluate', debuggerEvaluateTooltip:'An expression at the marker', debuggerEvalResult:'= %1$@ (width %2$@)',
   debuggerEvalTooltip:'Binary %1$@, decimal %2$@', debuggerAddWatch:'Add Watch', debuggerWatch:'Watch',
   debuggerRemoveWatch:'Remove Watch', debuggerEditWatch:'Edit Watch', debuggerExprError:'%1$@ (column %2$@)',
   debuggerExprSyntax:'Unexpected text', debuggerExprUnsupported:'Not supported here', debuggerExprEmpty:'Nothing to evaluate',
   debuggerExprTooLong:'Longer than %@ characters', debuggerExprTooManySignals:'More than %@ signals',
   debuggerExprTooWide:'Wider than %@ bits', debuggerExprBadLiteral:'Not a valid literal', debuggerExprNotConstant:'Must be a constant',
   debuggerExprBadReplication:'A replication count must be at least 1', debuggerExprUnknownName:'%@ is not in this waveform',
   debuggerExprNoValue:'%@ has no value at the marker', debuggerExprNoMarker:'Put the marker on a cycle first.',
   debuggerBreakpointIf:'%1$@ if %2$@', debuggerEditCondition:'Edit Condition…', debuggerConditionPrompt:'Break only when this is true at the clock edge',
   debuggerConditionError:'Condition of %1$@: %2$@', debuggerLinePathsCapped:'%1$@: watching the first %2$@ of %3$@ signals', debuggerLoading:'The waveform is still loading; try again in a moment.',
   debuggerLineNotPlaced:'%@: none of its signals are in the waveform (not placed in the design yet).',
   debuggerLineNothingToWatch:'%@: this line assigns no signal, so it has nothing to watch.',
   debuggerLineFileTooLarge:'%@: the file is too large to find the signals of this line.',
   debuggerBreakWhenTextMatches:'Break When Text Matches…', debuggerTextPrompt:'Break when %1$@, shown as %2$@, matches',
   debuggerTextPlaceholder:'A regular expression, for example jal ra or ^csrw mtvec', debuggerBreakpointText:'%1$@ ~ /%2$@/ (%3$@)',
   debuggerTextError:'Text breakpoint %1$@: %2$@', debuggerTextBadFormat:'this format cannot be searched as text',
   debuggerTextNoPattern:'the pattern is empty', debuggerTextPatternTooLong:'the pattern is longer than %@ characters',
   debuggerTextNoAlias:'its alias table is not loaded', debuggerTextTooSlow:'the pattern took too long to match, so the search stopped',
   debuggerTextTooManyValues:'the signal has too many different values to search here',
   debuggerTextTooMany:'At most %@ text breakpoints can be enabled at once.', debuggerEditTextPattern:'Edit Pattern…',
   debuggerTextMatchCase:'Match Case', debuggerTextAnyRegisterNames:'Match Either Register Name (a0 or x10)',
   debuggerTextFormatAlias:'alias %@', debuggerTextFormat_riscv:'RISC-V', debuggerTextFormat_riscv_numeric:'RISC-V, x0–x31',
   debuggerTextFormat_riscv_noalias:'RISC-V, no pseudo-instructions', debuggerTextFormat_riscv_numeric_noalias:'RISC-V, x0–x31, no pseudo-instructions',
   debuggerTextFormat_hexadecimal:'hex', debuggerTextFormat_binary:'binary', debuggerTextFormat_octal:'octal',
   debuggerTextFormat_decimal:'decimal', debuggerTextFormat_signed:'signed decimal', debuggerTextFormat_ascii:'ASCII'}
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
