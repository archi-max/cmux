// Loads Resources/vaporview through the real WaveformViewerSchemeHandler and
// WaveformFSDBHelper in an off-screen WKWebView, opens a remote FSDB over ssh
// (installing the helper there on first use), adds signals by path, and
// reports per-signal timings and WebContent RSS. Also unit-checks
// FrameParser, the fsdb route and the reply framing. Run through ./run.sh.
// Usage: fsdb-harness <assetRoot> <helperRoot> <sshHost> <remoteFsdb> <out.png> <signal> [<signal>...]
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let helperRoot = URL(fileURLWithPath: args[2], isDirectory: true)
let sshHost = args[3]
let remoteFile = args[4]
let out = URL(fileURLWithPath: args[5])
let signalPaths = Array(args.dropFirst(6))

// Unit checks for the frame parser and the route.
func check(_ c: Bool, _ m: String) { if !c { print("CHECK FAILED:", m); exit(2) } }
do {
  var p = FrameParser()
  func frame(_ e: FrameParser.Event?) -> FrameParser.Frame? { if case .frame(let f)? = e { return f }; return nil }
  // Shell noise, a title escape glued to the ready line, a frame split across chunks.
  p.append(Data("bashrc noise\n\u{1b}]0;title\u{07}{\"id\":0,\"ready\":true}\n{\"id\":3,\"result\":1,\"binLength\":4}\nab".utf8))
  if case .unreadableLine? = p.next() {} else { check(false, "noise line") }
  let f0 = frame(p.next()); check(f0?.id == 0 && f0?.isReady == true, "ready frame after title escape")
  check(p.next() == nil, "waits for binary")
  p.append(Data("cd{\"id\":4,\"error\":\"x\"}\n{\"id\":5,".utf8))
  let f3 = frame(p.next()); check(f3?.id == 3 && f3?.binary == Data("abcd".utf8), "binary frame")
  let f4 = frame(p.next()); check(f4?.id == 4 && f4?.binary == nil, "error frame")
  check(p.next() == nil, "partial line waits")
  p.append(Data("\"result\":2}\n{\"id\":6,\"binLength\":99999999999}\n".utf8))
  let f5 = frame(p.next()); check(f5?.id == 5, "line split across chunks")
  if case .tooLarge? = p.next() {} else { check(false, "binLength cap") }
  // Many small frames through compaction.
  var q = FrameParser(); var got = 0
  for i in 1...5000 { q.append(Data("{\"id\":\(i),\"binLength\":3}\nxyz".utf8)); while let e = q.next() { if case .frame(let f) = e, f.binary == Data("xyz".utf8), f.id == got + 1 { got += 1 } } }
  check(got == 5000, "5000 frames in order (got \(got))")
  let relay = WaveformFSDBRelay(token: "tok") { _ in .status(200) }
  func r(_ s: String) -> WaveformViewerSchemeHandler.Route? {
    WaveformViewerSchemeHandler.route(for: URL(string: s)!, assetRoot: assetRoot.standardizedFileURL.resolvingSymlinksInPath(), source: nil, fsdbRelay: relay)
  }
  if case .fsdb = r("cmux-waveform://viewer/fsdb/tok") {} else { check(false, "fsdb token") }
  check(r("cmux-waveform://viewer/fsdb/nope") == nil, "fsdb wrong token")
  if case .asset = r("cmux-waveform://viewer/fsdb-helper/build.sh") {} else { check(false, "helper asset") }
  let resp = WaveformSchemeResponse.fsdb(.init(header: Data("{}".utf8), binary: Data([1, 2])))
  check(resp.body == Data([2, 0, 0, 0, 0x7b, 0x7d, 1, 2]), "binary framing")
  print("checks passed; helper version", WaveformFSDBHelper.cachedVersion(of: helperRoot))
}

func rssMB(_ pid: Int32) -> Int {
  let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "rss=", "-p", String(pid)]
  let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
  return (Int(String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var helper: WaveformFSDBHelper!
  var t0 = Date()

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
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    // Keep the harness invisible to the user: off-screen, transparent, click-through.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    helper = WaveformFSDBHelper(sshArguments: { cmd in ["-o", "BatchMode=yes", "-T", "--", sshHost, cmd] },
                                resourceRoot: helperRoot) { status in print("[status]", status) }
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  var pid: Int32 { (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0 }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "console" { print("[console]", m.body); return }
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "log" { print("[log]", body["message"] ?? ""); return }
    print("[\(type)]", body["message"] ?? "", String(format: "t=%.2fs", Date().timeIntervalSince(t0)))
    if type == "ready" {
      t0 = Date()
      let helper = self.helper!
      let relayURL = scheme.serve(fsdbRelay: { body in
        await helper.response(for: body) { "\($0)" }
      })
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(remoteFile)'}})
        """)
    } else if type == "opened" {
      Task { await self.addSignals() }
    } else if type == "error" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  func js(_ s: String) async -> Any? { try? await web.evaluateJavaScript(s) }

  func addSignals() async {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    print("RSS idle after open: \(rssMB(pid)) MB (pid \(pid))")
    for (i, path) in signalPaths.enumerated() {
      let before = rssMB(pid)
      let tAdd = Date()
      let found = await js("cmuxWaveform.addVariableByPath('\(path)').then(x => String(x))")
      // addVariableByPath resolves after the add; poll for the stats entry.
      _ = found
      var entry: Any? = nil
      for _ in 0..<600 {
        entry = await js("cmuxWaveform.stats.length > \(i) ? JSON.stringify(cmuxWaveform.stats[\(i)]) : null")
        if let e = entry as? String, !e.isEmpty { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      // A probe posted to the viewer frame after the data is handled after it
      // (same source, ordered), so it marks when the viewer has processed the signal.
      _ = await js("new Promise(r => { const w = document.getElementById('viewer').contentWindow; w.addEventListener('message', function h(e) { if (e.data && e.data.__probe) { w.removeEventListener('message', h); r(1); } }); w.postMessage({__probe: 1}, '*'); })")
      let total = Date().timeIntervalSince(tAdd)
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      let after = rssMB(pid)
      print("SIGNAL \(path): \(entry ?? "none") addToProcessed=\(Int(total * 1000))ms rss \(before) -> \(after) MB (+\(after - before))")
    }
    snap()
  }

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out); print("wrote", out.path)
      } else { print("snapshot failed", String(describing: err)) }
      self.helper.stop()
      exit(0)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("timeout"); exit(1) }
app.run()
