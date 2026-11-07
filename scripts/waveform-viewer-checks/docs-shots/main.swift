// Screenshot harness for docs/vaporview (make-shots.sh): loads Resources/vaporview through the app's own
// WaveformViewerSchemeHandler in an off-screen, transparent, click-through WKWebView (like
// run.sh's page harnesses), opens one dump and runs a steps file. Nothing is shown on screen.
// Usage: shot <assetRoot> <dump> <strings.json> <steps.js> <outDir> [width height]
// steps.js: sections that start with `//// <name> [x y w h] [wait=ms]`; each section's body is the
// body of an async JS function run in the page. A name other than `-` takes a snapshot after the wait.
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let strings = try! String(contentsOf: URL(fileURLWithPath: args[3]), encoding: .utf8)
let stepsText = try! String(contentsOf: URL(fileURLWithPath: args[4]), encoding: .utf8)
let outDir = URL(fileURLWithPath: args[5], isDirectory: true)
let width = args.count > 6 ? Double(args[6])! : 1200
let height = args.count > 7 ? Double(args[7])! : 640

struct Step { var name: String; var rect: CGRect?; var wait: Double; var js: String }
func parseSteps() -> [Step] {
  var steps: [Step] = []
  for line in stepsText.components(separatedBy: "\n") {
    if line.hasPrefix("//// ") {
      var parts = line.dropFirst(5).split(separator: " ").map(String.init)
      var wait = 400.0
      if let w = parts.last, w.hasPrefix("wait=") { wait = Double(w.dropFirst(5))!; parts.removeLast() }
      let name = parts.first ?? "-"
      var rect: CGRect?
      if parts.count >= 5 { let n = parts[1...4].map { Double($0)! }; rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
      steps.append(Step(name: name, rect: rect, wait: wait, js: ""))
    } else if !steps.isEmpty {
      steps[steps.count - 1].js += line + "\n"
    }
  }
  return steps
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var started = false

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
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else {
      print("[\(m.name)]", m.body); return
    }
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let fmt = waveURL.pathExtension.lowercased()
      let theme = "{kind:'dark', background:'#1e1e1e', foreground:'#cccccc'}"
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'\(fmt)', path:'/work/sim/\(waveURL.lastPathComponent)', strings:\(strings), settings:{defaultNameType:'signalName'}})")
    } else if type == "opened", !started {
      started = true
      Task { @MainActor in await self.run() }
    } else if type != "debugger" {
      print("[msg]", type)
    }
  }

  func run() async {
    try? await Task.sleep(nanoseconds: 800_000_000)
    for step in parseSteps() {
      do {
        let r = try await web.callAsyncJavaScript(step.js, arguments: [:], in: nil, contentWorld: .page)
        if let r = r, !(r is NSNull) { print("[\(step.name)] ->", r) }
      } catch { print("[\(step.name)] JS ERROR", error) }
      try? await Task.sleep(nanoseconds: UInt64(step.wait * 1_000_000))
      if step.name != "-" { await snap(step) }
    }
    exit(0)
  }

  func snap(_ step: Step) async {
    let config = WKSnapshotConfiguration()
    if let r = step.rect { config.rect = r }
    let out = outDir.appendingPathComponent(step.name + ".png")
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
      web.takeSnapshot(with: config) { img, err in
        if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
          try? png.write(to: out)
          print("wrote", out.path, rep.pixelsWide, "x", rep.pixelsHigh)
        } else { print("snapshot failed", String(describing: err)) }
        k.resume()
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("timeout"); exit(1) }
app.run()
