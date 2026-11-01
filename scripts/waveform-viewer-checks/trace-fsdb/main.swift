// Driver tracing on a remote FSDB (run.sh trace-fsdb): opens the dump over ssh through the real
// WaveformFSDBHelper (under nice on the host) in an off-screen WKWebView and traces with the page
// (cmux-trace-ui.js, cmux-trace.js), the harness answering the model requests as cmux would from a
// cmux-sv-model `--once '*'` file. Traces every signal of one instance at a time, then follows each
// step's fan-in two more steps, and prints steps by trust and driver kind, the reasons, and timings.
// Fails when a trace throws, or a signal of the design gets no driver at all.
// Usage: trace-fsdb <assetRoot> <helperRoot> <sshHost> <remote.fsdb> <model.json> <instance> <time> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let helperRoot = URL(fileURLWithPath: args[2], isDirectory: true)
let sshHost = args[3]
let remoteFile = args[4]
let modelFile = URL(fileURLWithPath: args[5])
let instance = args[6]
let time = Int(args[7]) ?? 0
let out = URL(fileURLWithPath: args[8])
nonisolated(unsafe) var failures = 0

func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var helper: WaveformFSDBHelper!
  var instances: [String: Any] = [:]

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func call(_ js: String, _ arguments: [String: Any] = [:]) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }

  func start() {
    let data = try! Data(contentsOf: modelFile)
    let all = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    instances = all["instances"] as? [String: Any] ?? [:]
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

  func answer(_ id: Int, result: Any) {
    Task { @MainActor in
      _ = await call("cmuxWaveform.trace.reply(argument); return null", ["argument": ["id": id, "ok": true, "result": result]])
    }
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "trace" {
      guard let id = (body["id"] as? NSNumber)?.intValue, body["event"] as? String == "model" else { return }
      let path = body["path"] as? String ?? ""
      if body["cmd"] as? String == "instance" {
        answer(id, result: instances[path] ?? NSNull())
      } else {
        let best = instances.keys.filter { path == $0 || path.hasPrefix($0 + ".") }.max { $0.count < $1.count }
        answer(id, result: best.map { ["instance": $0, "name": String(path.dropFirst($0.count + 1))] } ?? NSNull())
      }
    } else if type == "ready" {
      let helper = self.helper!
      let relayURL = scheme.serve(fsdbRelay: { body in await helper.response(for: body) { "\($0)" } })
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'},
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
    guard let model = instances[instance] as? [String: Any], let signals = model["signals"] as? [String: Any] else {
      expect(false, "instance \(instance) is in the model")
      finish()
      return
    }
    // Breadth first: the instance's signals, then two more levels of their fan-in.
    var queue = signals.keys.sorted().map { (instance + "." + $0, time, 0) }
    var seen = Set<String>()
    var trust: [String: Int] = [:], kinds: [String: Int] = [:], reasons: [String: Int] = [:]
    var times: [Double] = []
    var noDriver: [String] = []
    var errors = 0
    while !queue.isEmpty, times.count < 400 {
      let (path, t, depth) = queue.removeFirst()
      guard seen.insert("\(path)@\(t)").inserted else { continue }
      let t0 = Date()
      let step = await call("return await cmuxWaveform.trace.driverOfDesign(argument)",
                            ["argument": ["designPath": path, "designPrefix": "", "dumpPrefix": "", "time": t]]) as? [String: Any]
      let ms = Date().timeIntervalSince(t0) * 1000
      guard let step else { errors += 1; print("ERROR tracing \(path) @\(t)"); continue }
      times.append(ms)
      if let error = step["error"] as? String { kinds["error:" + error, default: 0] += 1; continue }
      trust[step["trust"] as? String ?? "?", default: 0] += 1
      let kind = (step["driver"] as? [String: Any])?["kind"] as? String ?? "?"
      kinds[kind, default: 0] += 1
      if kind == "none" { noDriver.append(path) }
      for r in step["reasons"] as? [[String: Any]] ?? [] { reasons[r["code"] as? String ?? "?", default: 0] += 1 }
      if times.count <= 12 || ms > 2000 {
        let src = ((step["stmt"] as? [String: Any])?["src"] as? String ?? "").prefix(70)
        print(String(format: "%7.1f ms  %@ @%d = %@  %@ [%@] %@", ms, path, t, step["value"] as? String ?? "?", kind, step["trust"] as? String ?? "?", String(src)))
      }
      if depth < 2 {
        for f in step["fanin"] as? [[String: Any]] ?? [] {
          if let p = f["path"] as? String, let ft = (f["time"] as? NSNumber)?.intValue { queue.append((p, ft, depth + 1)) }
        }
      }
    }
    let sorted = times.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    print("steps: \(times.count), trust \(trust), drivers \(kinds)")
    print("reasons: \(reasons)")
    print(String(format: "time per step: median %.1f ms, p90 %.1f ms, max %.1f ms, total %.1f s", median,
                 sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last ?? 0, times.reduce(0, +) / 1000))
    expect(errors == 0, "no trace threw (\(errors))")
    expect(noDriver.isEmpty, "every traced design signal has a driver: \(noDriver.prefix(8))")
    expect(times.count > 0, "steps were traced")
    finish()
  }

  func finish() {
    print(failures == 0 ? "TRACE FSDB CHECKS PASSED" : "TRACE FSDB CHECKS FAILED: \(failures)")
    helper.stop()
    web.takeSnapshot(with: nil) { img, _ in
      if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
      }
      exit(failures == 0 ? 0 : 1)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 840) { print("timeout"); exit(1) }
app.run()
