// Waveform debugger on a remote FSDB (run.sh debugger-fsdb): opens the dump over
// ssh through the real WaveformFSDBHelper (run under nice on the host) in an
// off-screen WKWebView, then steps its clock: default clock, posedge count and
// the time the first step takes, step / jump / cycleAt, Locals of a scope.
// Usage: debugger-fsdb <assetRoot> <helperRoot> <sshHost> <remote.fsdb> <locals.scope.path> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let helperRoot = URL(fileURLWithPath: args[2], isDirectory: true)
let sshHost = args[3]
let remoteFile = args[4]
let localsScope = args[5].split(separator: ".").map(String.init)
let out = URL(fileURLWithPath: args[6])
nonisolated(unsafe) var failures = 0

func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var helper: WaveformFSDBHelper!

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }

  func dbg(_ e: String) async -> [String: Any]? { await call("return await cmuxWaveform.debugger.\(e)") as? [String: Any] }
  func marker() async -> Int? { await call("return cmuxWaveform.viewerContext.webview.markerTime ?? null") as? Int }
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
    helper = WaveformFSDBHelper(sshArguments: { cmd in
      ["-o", "BatchMode=yes", "-T", "--", sshHost, "exec nice -n 10 bash -c " + shellQuoted(cmd)]
    }, resourceRoot: helperRoot) { status in print("[status]", status) }
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let helper = self.helper!
      let relayURL = scheme.serve(fsdbRelay: { body in await helper.response(for: body) { "\($0)" } })
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
            debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s', debuggerTooManyEdges:'too many'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(remoteFile)'}})
        """)
    } else if type == "opened" {
      print("[opened] top:", body["top"] ?? "")
      Task { await self.run() }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      failures += 1
      finish()
    }
  }

  func run() async {
    let t0 = Date()
    let s1 = await dbg("step({ by: 1 })")
    let firstStep = Date().timeIntervalSince(t0)
    let count = s1?["count"] as? Int ?? 0
    print("clock \(String(describing: s1?["clock"])) posedges \(count) first step \(String(format: "%.2f", firstStep)) s")
    expect(s1?["cycle"] as? Int == 1 && count > 1, "default clock found and stepped to cycle 1: \(String(describing: s1))")
    await sleep(400)
    let m1 = await marker()
    expect(m1 != nil && m1 == s1?["edgeTime"] as? Int, "marker on the first posedge: \(String(describing: m1))")
    let t1 = Date()
    _ = await dbg("step({ by: 10 })")
    await sleep(400)
    let s11 = await dbg("state()")
    print(String(format: "step +10 (edges cached) %.2f s", Date().timeIntervalSince(t1)))
    expect(s11?["cycle"] as? Int == 11, "step +10: cycle 11: \(String(describing: s11?["cycle"]))")
    if let t = s11?["time"] as? Int {
      let at = await dbg("cycleAt({ time: \(t) })")
      expect(at?["cycle"] as? Int == 11 && at?["previousTime"] as? Int != nil, "cycleAt the marker: \(String(describing: at))")
    }
    _ = await dbg("jump({ to: 'last' })")
    await sleep(400)
    let last = await dbg("state()")
    expect(last?["cycle"] as? Int == count, "jump to the last cycle: \(String(describing: last?["cycle"])) of \(count)")
    let pathJSON = "[" + localsScope.map { "'\($0)'" }.joined(separator: ",") + "]"
    let t2 = Date()
    let l = await call("return await cmuxWaveform.debugger.setLocals({ path: \(pathJSON) })") as? Bool
    await sleep(800)
    let rows = await call("""
      const out = [];
      (cmuxWaveform.viewerContext.webview.displayedSignals || []).forEach((d) => {
        if (d.dataType === 'signal-group') { (d.children || []).forEach((c) => out.push(d.groupName + '/' + c.name)); }
      });
      return out;
    """) as? [String] ?? []
    print(String(format: "Locals of %@: %d rows in %.2f s", args[5], rows.count, Date().timeIntervalSince(t2)))
    expect(l == true && !rows.isEmpty && rows.allSatisfy { $0.hasPrefix("Locals/") }, "Locals of \(args[5]): \(rows.prefix(6))")
    _ = await dbg("stop()")
    await sleep(300)
    print(failures == 0 ? "DEBUGGER FSDB CHECKS PASSED" : "DEBUGGER FSDB CHECKS FAILED: \(failures)")
    finish()
  }

  func finish() {
    web.takeSnapshot(with: nil) { img, _ in
      if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out) }
      self.helper.stop()
      exit(failures == 0 ? 0 : 1)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("timeout"); exit(1) }
app.run()
