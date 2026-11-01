// Enum member names in the waveform viewer (run.sh enum): loads Resources/vaporview off-screen,
// opens enum/fsm.vcd and drives window.cmuxWaveform.enums as cmux does after asking slang-server.
// Usage: enum <assetRoot> <fsm.vcd> <out.png>
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
  var asked: [[String]] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func runEnumChecks() async {
    func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
    func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    func formats() async -> [String: String] {
      let rows = await call("return (cmuxWaveform.viewerContext.webview.displayedSignals || []).map(s => [s.name, s.numberFormat])") as? [[String]] ?? []
      return Dictionary(rows.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
    }
    let define = """
      return cmuxWaveform.enums.define({ tables: [{ id: 'top|state_t|3', label: 'top.state_t', width: 3,
        members: [['IDLE', '000'], ['FETCH', '001'], ['DECODE', '100'], ['EXEC', '101'], ['DONE', '111']] }],
        signals: { 'top.state': 'top|state_t|3', 'top.other': 'top|state_t|3' } });
    """
    // The display rules, the same as SlangEnumType.display in Swift.
    let pure = await call("""
      const t = { width: 3, members: [['IDLE', '000'], ['FETCH', '001']] }; const e = cmuxWaveform.enums;
      return [e.display(t, '001'), e.display(t, '1'), e.display(t, '010'), e.display(t, 'xxx'), e.display(t, 'zzz'), e.display(t, '0x1'), e.hexLiteral('1x0101')];
    """) as? [String] ?? []
    expect(pure == ["FETCH", "FETCH", "3'h2?", "x", "z", "3'b0x1", "6'h?5"], "display rules: \(pure)")
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'state'])")
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'plain'])")
    await sleep(700)
    expect(asked.contains(["top", "state"]) && asked.contains(["top", "plain"]), "cmux is asked for the shown rows' types: \(asked)")
    let askedOnce = asked.count
    var f = await formats()
    expect(f["top.state"] == "hexadecimal", "before its type: hex (\(String(describing: f["top.state"])))")
    let defined = await call(define) as? [String: Any]
    expect((defined?["bound"] as? Int) == 1, "define binds the one added enum row: \(String(describing: defined))")
    await sleep(300)
    f = await formats()
    expect(f["top.state"] == "alias:top.state_t" && f["top.plain"] == "hexadecimal", "state gets the enum format, plain stays hex: \(f)")
    _ = await call("cmuxWaveform.link.setMarker(25); return null")
    await sleep(400)
    let shown = await call("""
      const d = document.getElementById('viewer').contentDocument;
      return Array.from(d.querySelectorAll('.value-display-item, .waveform-value, [class*=value]')).map(e => e.textContent).join('|');
    """) as? String ?? ""
    expect(shown.contains("FETCH"), "the row shows FETCH at 25: \(shown.prefix(200))")
    let values = await call("return await cmuxWaveform.link.valuesAt({ time: 35, paths: [['top', 'state'], ['top', 'plain'], ['top', 'state']], raw: [true, false] })") as? [Any] ?? []
    expect(values.count == 3 && (values[0] as? String).map { $0.hasSuffix("10") } == true && values[1] as? String == "2",
           "valuesAt raw gives bits, others their row's radix: \(values)")
    expect(values.count == 3 && values[2] as? String == "3'h2?", "a row in its enum's format gives its table's text (no member: hex and ?): \(values)")
    let helpers = await call("""
      const e = cmuxWaveform.enums;
      return [e.format(['top', 'state'], '111'), e.format('top.state', '10'), e.memberBits(['top', 'state'], 'DECODE'), String(e.memberBits(['top', 'plain'], 'IDLE')), String(e.tableFor('top.plain'))];
    """) as? [String] ?? []
    expect(helpers == ["DONE", "3'h2?", "100", "null", "null"], "format / memberBits / tableFor: \(helpers)")
    // Known type: an added row gets it in its own add (one undo step).
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'other'])")
    await sleep(600)
    f = await formats()
    expect(f["top.other"] == "alias:top.state_t", "a row added after its type is known has it at once: \(f)")
    expect(!asked.dropFirst(askedOnce).contains(["top", "state"]), "answered rows are not asked again")
    // Undo until the enum default goes (selection changes are steps of their own too).
    var otherGoneFirst = false, otherEverHex = false, undos = 0
    while undos < 8 {
      _ = await call("cmuxWaveform.runCommand({ command: 'cmux.undo' }); return null")
      await sleep(500)
      undos += 1
      f = await formats()
      if f["top.other"] == "hexadecimal" { otherEverHex = true }
      if f["top.state"] == "hexadecimal" { otherGoneFirst = f["top.other"] == nil; break }
    }
    expect(otherGoneFirst && !otherEverHex, "undo removes the later add together with its format, then takes the enum default back (\(undos) undos): \(f)")
    let again = await call(define) as? [String: Any]
    await sleep(300)
    f = await formats()
    expect((again?["bound"] as? Int) == 0 && f["top.state"] == "hexadecimal", "a row undone to hex is not set again: \(f)")
    _ = await call("cmuxWaveform.runCommand({ command: 'cmux.redo' }); return null")
    await sleep(600)
    f = await formats()
    expect(f["top.state"] == "alias:top.state_t", "redo puts the enum format back: \(f)")
    _ = await call(define)
    await sleep(300)
    f = await formats()
    expect(f["top.state"] == "alias:top.state_t" && f["top.other"] == nil, "and an answer after the redo changes nothing: \(f)")
    // The user's own choice wins over a later answer.
    _ = await call("""
      const row = (cmuxWaveform.viewerContext.webview.displayedSignals || []).find(s => s.name === 'top.state');
      cmuxWaveform.host.toWebview({ command: 'setDisplayFormat', netlistId: row.netlistId, numberFormat: 'binary' }); return null;
    """)
    await sleep(400)
    _ = await call(define)
    await sleep(300)
    f = await formats()
    expect(f["top.state"] == "binary", "a format the user picks stays: \(f)")
    // A row the user removes and adds again is a new add.
    _ = await call("""
      const row = (cmuxWaveform.viewerContext.webview.displayedSignals || []).find(s => s.name === 'top.state');
      cmuxWaveform.host.toWebview({ command: 'remove-signal', netlistId: row.netlistId, rowId: undefined, removeAllSelected: false }); return null;
    """)
    await sleep(500)
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'state'])")
    await sleep(600)
    f = await formats()
    expect(f["top.state"] == "alias:top.state_t", "re-added, the row has its enum format: \(f)")
    print(failures == 0 ? "ENUM CHECKS PASSED" : "ENUM CHECKS FAILED: \(failures)")
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
      Task { @MainActor in await self.runEnumChecks() }
    } else if type == "enumTypes" {
      asked += (body["paths"] as? [[String]]) ?? []
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
