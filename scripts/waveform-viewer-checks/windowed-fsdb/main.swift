// Ship gate for windowed FSDB viewing (run.sh windowed-fsdb): cmux's own page and helper
// relay on a real dump over ssh, windowed (fsdbLoading auto: helper v2) against whole
// (fsdbLoading whole: helper v1), side by side, with bench.js's measurements and the
// WebContent process's peak RSS. The helpers install under <remoteHome> on the host
// (node-local, not the NFS home) and run under nice. Off-screen, never shown.
// Usage: windowed-fsdb <assetRoot> <v2Root> <v1Root> <bench.js> <sshHost> <remoteHome> <remote.fsdb>
//          <scope,scope,...> <signal,signal,...> <runs> <out.json>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let v2Root = URL(fileURLWithPath: args[2], isDirectory: true)
let v1Root = URL(fileURLWithPath: args[3], isDirectory: true)
let benchJS = try! String(contentsOfFile: args[4], encoding: .utf8)
let sshHost = args[5]
let remoteHome = args[6]
let remoteFile = args[7]
let scopes = args[8].split(separator: ",").map(String.init)
let signals = args[9].split(separator: ",").map(String.init)
let runs = Int(args[10]) ?? 1
let out = URL(fileURLWithPath: args[11])

func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func jsString(_ s: String) -> String {
  String(data: try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]), encoding: .utf8)!
    .dropFirst().dropLast().description
}

func rssMB(_ pid: pid_t) -> Int? {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/ps")
  p.arguments = ["-o", "rss=", "-p", String(pid)]
  let pipe = Pipe(); p.standardOutput = pipe
  try? p.run(); p.waitUntilExit()
  let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return Int(s).map { $0 / 1024 }
}

@MainActor
final class Run: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  let loading: WaveformFSDBHelper.Loading
  var web: WKWebView!
  var helper: WaveformFSDBHelper!
  var opened: CheckedContinuation<String?, Never>?
  var openSent = Date()

  init(loading: WaveformFSDBHelper.Loading) { self.loading = loading }

  func open() async -> String? {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    cfg.userContentController.add(self, name: "cmuxWaveform")
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderBack(nil)
    let home = remoteHome
    helper = WaveformFSDBHelper(sshArguments: { cmd in
      ["-o", "BatchMode=yes", "-T", "--", sshHost, "HOME=\(shellQuoted(home)) exec nice -n 10 bash -c " + shellQuoted(cmd)]
    }, installs: WaveformFSDBHelper.installs(v2Root: v2Root, v1Root: v1Root, loading: loading)) { status in print("[status]", status) }
    return await withCheckedContinuation { c in
      opened = c
      web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
    }
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let helper = self.helper!
      let relayURL = scheme.serve(fsdbRelay: { body in await helper.response(for: body) { "\($0)" } })
      openSent = Date()
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'},
          fsdb:{url:'\(relayURL.absoluteString)', path:\(jsString(remoteFile))}})
        """)
    } else if type == "opened" {
      opened?.resume(returning: nil); opened = nil
    } else if type == "error" {
      opened?.resume(returning: body["message"] as? String ?? "error"); opened = nil
    }
  }

  func bench() async -> [String: Any] {
    var result: [String: Any] = ["loading": loading.rawValue, "openMs": Int(Date().timeIntervalSince(openSent) * 1000)]
    _ = try? await web.evaluateJavaScript(benchJS)
    let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    var peak = 0
    let sampler = Task { @MainActor in
      while !Task.isCancelled { if let mb = rssMB(pid) { peak = max(peak, mb) }; try? await Task.sleep(nanoseconds: 250_000_000) }
    }
    let opts = try! JSONSerialization.data(withJSONObject: ["scopes": scopes, "signals": signals])
    do {
      let r = try await web.callAsyncJavaScript("return await window.__cmuxBench(\(String(decoding: opts, as: UTF8.self)))",
                                                 arguments: [:], in: nil, contentWorld: .page)
      if let r = r as? [String: Any] { result.merge(r) { a, _ in a } }
    } catch { result["error"] = "\(error)" }
    sampler.cancel()
    result["rssPeakMB"] = peak
    result["rssEndMB"] = rssMB(pid) ?? 0
    return result
  }

  func close() {
    helper?.stop()
    window.orderOut(nil)
  }
}

@MainActor
func main() async {
  var all: [[String: Any]] = []
  for run in 1...runs {
    // GATE_LOADINGS=auto (or whole) runs one side only.
    let only = ProcessInfo.processInfo.environment["GATE_LOADINGS"]
    for loading in [WaveformFSDBHelper.Loading.auto, .whole] where only == nil || only == loading.rawValue {
      let r = Run(loading: loading)
      if let error = await r.open() {
        print("run \(run) \(loading.rawValue): open failed: \(error)")
        all.append(["run": run, "loading": loading.rawValue, "error": error])
      } else {
        var res = await r.bench()
        res["run"] = run
        print("run \(run) \(loading.rawValue):", String(decoding: try! JSONSerialization.data(withJSONObject: res, options: [.sortedKeys]), as: UTF8.self))
        all.append(res)
      }
      r.close()
      try? await Task.sleep(nanoseconds: 2_000_000_000)
    }
  }
  try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: out)
  print("WINDOWED FSDB GATE DONE")
  exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await main() }
DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { print("timeout"); exit(1) }
app.run()
