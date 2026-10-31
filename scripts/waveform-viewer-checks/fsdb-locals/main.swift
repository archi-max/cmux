// FSDB inline values with the debugger's Locals (run.sh fsdb-locals): the page opens an FSDB
// through a stand-in for the helper (answered here, no host), in an off-screen WKWebView.
// A signal the user pinned keeps its inline value while Locals shows the same signal and
// after Locals is refilled or removed: Locals rows share the pinned row's netlist id.
// Usage: fsdb-locals <assetRoot> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2])
nonisolated(unsafe) var failures = 0

/// The helper's replies for a tiny design: tb.dut with clk, a, cnt[3:0].
enum FakeHelper {
  static let vars: [[String: Any]] = [
    ["name": "clk", "type": "wire", "encoding": "BitVector", "netlistId": 11, "signalId": 21, "width": 1, "msb": 0, "lsb": 0],
    ["name": "a", "type": "wire", "encoding": "BitVector", "netlistId": 12, "signalId": 22, "width": 1, "msb": 0, "lsb": 0],
    ["name": "cnt", "type": "reg", "encoding": "BitVector", "netlistId": 13, "signalId": 23, "width": 4, "msb": 3, "lsb": 0],
  ]
  static func changes(_ signalId: Int) -> [[Any]] {
    switch signalId {
    case 21: return stride(from: 0, through: 100, by: 5).map { [$0, ($0 / 5) % 2 == 0 ? "0" : "1"] }
    case 22: return [[0, "0"], [10, "1"]]
    default: return [[0, "0000"], [15, "0011"]]
    }
  }
  static func reply(_ body: Data) -> WaveformSchemeResponse {
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let result: Any
    switch object["cmd"] as? String {
    case "open":
      result = ["metadata": ["timeTableLoaded": true, "scopeCount": 2, "netlistIdCount": 3, "signalIdCount": 3,
                             "timeTableCount": 0, "timeEnd": 100, "minTimeStep": 1, "timeScale": 1, "timeUnit": "ns"],
                "top": [["name": "tb", "scopeOffsetIdx": 1, "type": "module"]]]
    case "children":
      result = (object["scopeOffsetIdx"] as? Int) == 1
        ? ["scopes": [["name": "dut", "scopeOffsetIdx": 2, "type": "module"]], "vars": []] as [String: Any]
        : ["scopes": [], "vars": vars] as [String: Any]
    case "signals":
      let ids = object["signalIds"] as? [Int] ?? []
      result = ids.map { ["signalId": $0, "valueChanges": changes($0), "min": 0, "max": 0] as [String: Any] }
    default:
      return .fsdbError("unknown command")
    }
    return .fsdb(.init(header: try! JSONSerialization.data(withJSONObject: ["result": result]), binary: nil))
  }
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }
  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
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
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let relayURL = scheme.serve(fsdbRelay: { body in FakeHelper.reply(body) })
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
            debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s', debuggerTooManyEdges:'too many'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'/x.fsdb'}})
        """)
    } else if type == "opened" {
      Task { await self.run() }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      failures += 1
      finish()
    }
  }

  /// Longer than any deferred work after rows change (the viewer's context update included).
  let settleMs: UInt64 = 2500

  func value(of path: [String]) async -> String {
    let json = String(data: try! JSONSerialization.data(withJSONObject: [path]), encoding: .utf8)!
    let v = await call("return await cmuxWaveform.link.valuesAt({ time: 20, paths: \(json), unshown: false })") as? [Any] ?? []
    return (v.first as? String) ?? "-"
  }

  func values() async -> [String] {
    let v = await call("return await cmuxWaveform.link.valuesAt({ time: 20, paths: [['tb','dut','a'], ['tb','dut','cnt']], unshown: false })") as? [Any] ?? []
    return v.map { ($0 as? String) ?? "-" }
  }

  func run() async {
    await sleep(500)
    let added = await call("return [await cmuxWaveform.link.addSignal(['tb','dut','a']), await cmuxWaveform.link.addSignal(['tb','dut','cnt'])]") as? [Bool]
    expect(added == [true, true], "pinned a and cnt: \(String(describing: added))")
    await sleep(1000)
    let pinned = await values()
    expect(pinned[0] != "-" && pinned[1] != "-", "pinned rows have values at 20: \(pinned)")
    let stepped = await call("return await cmuxWaveform.debugger.step({ by: 1 })") as? [String: Any]
    expect(stepped?["cycle"] as? Int == 1, "stepping on clk: \(String(describing: stepped))")
    let l = await call("return await cmuxWaveform.debugger.setLocals({ path: ['tb','dut'] })")
    await sleep(1000)
    let locals = await call("""
      const out = [];
      (cmuxWaveform.viewerContext.webview.displayedSignals || []).forEach((d) => {
        if (d.dataType === 'signal-group') { (d.children || []).forEach((c) => out.push(d.groupName + '/' + (c.signalName || c.name))); }
      });
      return out;
    """) as? [String] ?? []
    // (Locals may leave out signals pinned outside it; clk is never pinned here.)
    expect(locals.contains("Locals/tb.dut.clk"), "Locals of tb.dut shown: \(String(describing: l)) \(locals)")
    let withLocals = await values()
    expect(withLocals == pinned, "values while Locals shows the same signals: \(withLocals)")
    // The caret moved to another scope: Locals is refilled (its rows removed, then the new scope's added).
    _ = await call("return await cmuxWaveform.debugger.setLocals({ path: ['tb'] })")
    await sleep(settleMs)
    let refilled = await values()
    expect(refilled == pinned, "pinned rows keep their values once Locals is refilled: \(refilled)")
    _ = await call("return await cmuxWaveform.debugger.setLocals({ path: ['tb','dut'] })")
    await sleep(1000)
    _ = await call("return await cmuxWaveform.debugger.setLocals({ path: null })")
    await sleep(settleMs)
    let afterLocals = await values()
    expect(afterLocals == pinned, "pinned rows keep their values once Locals is removed: \(afterLocals)")
    // A signal only Locals showed (clk), gone with it, shown again: the viewer keeps its data and
    // asks for none, so the page must still have its changes. Then pinned, the same.
    let clkBefore = await value(of: ["tb", "dut", "clk"])
    expect(clkBefore == "-", "clk, not shown, has no value (unshown off): \(clkBefore)")
    _ = await call("return await cmuxWaveform.debugger.setLocals({ path: ['tb','dut'] })")
    await sleep(settleMs)
    let clkInLocals = await value(of: ["tb", "dut", "clk"])
    expect(clkInLocals == "0", "Locals shows clk again: it has its value at 20: \(clkInLocals)")
    _ = await call("return await cmuxWaveform.link.addSignal(['tb','dut','clk'])")
    await sleep(settleMs)
    let clkPinned = await value(of: ["tb", "dut", "clk"])
    expect(clkPinned == "0", "clk pinned: it has its value at 20: \(clkPinned)")
    print(failures == 0 ? "FSDB LOCALS CHECKS PASSED" : "FSDB LOCALS CHECKS FAILED: \(failures)")
    finish()
  }

  func finish() {
    web.takeSnapshot(with: nil) { img, _ in
      if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out) }
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
