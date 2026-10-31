// Loads Resources/vaporview through the real WaveformViewerSchemeHandler in an
// off-screen WKWebView, opens a waveform the way the panel does, adds every
// signal, and snapshots it. With xss-signal-names.vcd it also checks that
// markup in signal names stays inert: exits 3 if any injected element or
// handler ran. Run through ./run.sh.
// Usage: harness <assetRoot> <waveFile> <out.png> [light]
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
let light = args.count > 4 && args[4] == "light"

// Unit checks for the pure helpers.
func check(_ c: Bool, _ m: String) { if !c { print("CHECK FAILED:", m); exit(2) } }
check(WaveformByteRange.parse("bytes=0-9", size: 100) == 0...9, "range a-b")
check(WaveformByteRange.parse("bytes=90-", size: 100) == 90...99, "range a-")
check(WaveformByteRange.parse("bytes=-10", size: 100) == 90...99, "suffix")
check(WaveformByteRange.parse("bytes=95-200", size: 100) == 95...99, "clamp")
check(WaveformByteRange.parse("bytes=100-", size: 100) == nil, "past end")
check(WaveformByteRange.parse("bytes=5-1", size: 100) == nil, "reversed")
check(WaveformByteRange.parse("bytes=0-1,4-5", size: 100) == nil, "multi")
check(WaveformByteRange.parse("items=0-1", size: 100) == nil, "unit")
let src = WaveformFileSource(fileURL: waveURL, token: "tok")
let base = "cmux-waveform://viewer/"
func r(_ s: String) -> WaveformViewerSchemeHandler.Route? {
  WaveformViewerSchemeHandler.route(for: URL(string: s)!, assetRoot: assetRoot.standardizedFileURL.resolvingSymlinksInPath(), source: src)
}
if case .asset = r(base + "index.html") {} else { check(false, "index") }
if case .asset = r(base + "codicons/codicon.css") {} else { check(false, "subdir") }
if case .file = r(base + "file/tok") {} else { check(false, "file token") }
check(r(base + "file/other") == nil, "wrong token")
check(r(base + "file/tok/x") == nil, "token extra")
check(r(base + "../LICENSE") == nil, "dotdot")
check(r(base + "codicons/../../x") == nil, "dotdot2")
check(r(base + "codicons/%2e%2e/%2e%2e/etc/passwd") == nil, "encoded dotdot")
check(r(base + "codicons") == nil, "directory")
check(r("cmux-waveform://other/index.html") == nil, "host")
check(r("https://viewer/index.html") == nil, "scheme")
check(r(base + "nope.js") == nil, "missing")
print("helper checks passed")

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!

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
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    print("[\(m.name)]", m.body)
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = light ? "{kind:'light', background:'#fafafa', foreground:'#222222'}" : "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      let fmt = waveURL.pathExtension.lowercased()
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'\(fmt)', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'}})")
    } else if type == "opened" {
      // Add the first two variables in the tree, like a user click.
      web.evaluateJavaScript("Array.from(document.querySelectorAll('#tree .var')).forEach(e=>e.click()); document.querySelectorAll('#tree .var').length") { n, e in
        print("vars in tree:", n ?? "nil", e ?? "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          // Dispatch a drag-start style render too: the labels and value display re-render on marker moves.
          self.web.evaluateJavaScript("(() => { const d = document.getElementById('viewer').contentDocument; return JSON.stringify({html: Array.from(d.querySelectorAll('img, [onload], [onerror]')).map(i => i.outerHTML).join(' | '), frameTitle: d.title, topTitle: document.title, labels: Array.from(d.querySelectorAll('.waveform-label')).map(e => e.getAttribute('data-vscode-context') ? 'ctx-ok' : 'ctx-missing')}); })()") { r, e in
            print("XSS-CHECK", r ?? "nil", e ?? "")
            if let json = (r as? String)?.data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
              let injected = (result["html"] as? String).map { !$0.isEmpty } ?? true
              let ran = result["frameTitle"] as? String != "VaporView - Waveform Viewer" || result["topTitle"] as? String != "Waveform"
              if injected || ran { print("XSS CHECK FAILED"); exit(3) }
              print("xss check passed")
            }
            self.snap()
          }
        }
      }
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
