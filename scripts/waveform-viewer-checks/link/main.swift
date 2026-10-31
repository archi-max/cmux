// Source link checks (run.sh link): loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen WKWebView, opens link.vcd the way
// the panel does and drives window.cmuxWaveform.link as the SystemVerilog editor
// would: scopes, adds, selection, the marker, values at a time, Add All in Scope.
// Usage: link <assetRoot> <link.vcd> <out.png>
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
  var revealed: [String]?

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func runLinkChecks() async {
    func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
    let tops = await call("return await cmuxWaveform.link.scopeChildren([])") as? [[String: Any]]
    expect(tops?.compactMap { $0["name"] as? String } == ["top"], "tops = [top]: \(String(describing: tops))")
    // Concurrent lookups of a scope not listed yet share one children request.
    let shared = await call("""
      const host = cmuxWaveform.host; const top = host.doc.netlist[0];
      const wide = (await host.getChildren(top)).find((c) => c.name === 'wide');
      const a = host.getChildren(wide), b = host.getChildren(wide);
      return a === b && (await a) === (await b) && (await a).length === 60;
    """) as? Bool
    expect(shared == true, "getChildren shares an in-flight request")
    let core = await call("return await cmuxWaveform.link.scopeChildren(['top', 'core'])") as? [[String: Any]]
    expect(Set(core?.compactMap { $0["name"] as? String } ?? []) == ["valid", "state", "alu"], "top.core children")
    expect((core?.first { $0["name"] as? String == "alu" }?["isScope"] as? Bool) == true, "alu is a scope")
    let coreString = await call("return await cmuxWaveform.link.scopeChildren('top.core')") as? [[String: Any]]
    expect(coreString?.count == 3, "dotted string paths still work")
    let nope = await call("return await cmuxWaveform.link.scopeChildren(['top', 'nope'])")
    expect(nope == nil || nope is NSNull, "missing scope -> null")
    let v1 = await call("return await cmuxWaveform.link.hasSignal(['top', 'core', 'alu', 'acc'])") as? Bool
    expect(v1 == true, "hasSignal acc")
    let escaped = await call("return await cmuxWaveform.link.hasSignal(['\\\\top ', 'core', 'alu', 'acc'])") as? Bool
    expect(escaped == true, "escaped spelling of a plain name matches")
    let v2 = await call("return await cmuxWaveform.link.hasSignal(['top', 'core', 'alu'])") as? Bool
    expect(v2 == false, "scope is not a signal")
    // Two adds before the viewer reports the first back.
    let v3 = await call("return [await cmuxWaveform.link.addSignal(['top', 'core', 'state']), await cmuxWaveform.link.addSignal(['top', 'core', 'state'])]") as? [Bool]
    expect(v3 == [true, true], "addSignal state twice at once")
    try? await Task.sleep(nanoseconds: 400_000_000)
    let v4 = await call("return await cmuxWaveform.link.addSignal(['top', 'core', 'state'])") as? Bool
    expect(v4 == true, "addSignal state again")
    let v5 = await call("return await cmuxWaveform.link.addSignal(['top', 'count'])") as? Bool
    expect(v5 == true, "addSignal count")
    let v6 = await call("return await cmuxWaveform.link.addSignal(['top', 'bogus'])") as? Bool
    expect(v6 == false, "addSignal missing")
    try? await Task.sleep(nanoseconds: 600_000_000)
    let rows = await call("return (cmuxWaveform.viewerContext.webview.displayedSignals || []).map(s => s.name)") as? [String]
    expect(rows == ["top.core.state", "top.count"], "rows shown once each: \(String(describing: rows))")
    let v7 = await call("return await cmuxWaveform.link.selectSignal(['top', 'core', 'state'])") as? Bool
    expect(v7 == true, "selectSignal")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let sel = await call("return cmuxWaveform.link.selectedSignal()") as? [String]
    expect(sel == ["top", "core", "state"], "selectedSignal = \(String(describing: sel))")
    _ = await call("cmuxWaveform.link.setMarker(25); return null")
    try? await Task.sleep(nanoseconds: 300_000_000)
    let marker = await call("return cmuxWaveform.viewerContext.webview.markerTime") as? Int
    expect(marker == 25, "marker = \(String(describing: marker))")
    // Page script (main frame or the viewer frame) can't swap what cmux calls.
    let tamper = await call("""
      const before = window.cmuxWaveform.link; const outer = window.cmuxWaveform;
      try { window.cmuxWaveform = { link: { hasSignal: () => true } }; } catch (e) {}
      try { window.cmuxWaveform.link = null; } catch (e) {}
      try { window.cmuxWaveform.link.hasSignal = async () => true; } catch (e) {}
      const frame = document.getElementById('viewer').contentWindow;
      try { frame.parent.cmuxWaveform.link.scopeChildren = async () => [{ name: 'evil', isScope: true }]; } catch (e) {}
      try { Object.defineProperty(window, 'cmuxWaveform', { value: {} }); } catch (e) {}
      return window.cmuxWaveform === outer && window.cmuxWaveform.link === before && Object.isFrozen(before);
    """) as? Bool
    expect(tamper == true, "link object is frozen and non-writable")
    let stillReal = await call("return await cmuxWaveform.link.hasSignal(['top', 'bogus'])") as? Bool
    expect(stillReal == false, "hasSignal still the real one")
    _ = await call("""
      const d = document.getElementById('viewer').contentDocument;
      const labels = Array.from(d.querySelectorAll('.waveform-label'));
      const t = labels.find(l => (l.getAttribute('data-vscode-context')||'').includes('"count"'));
      (t.querySelector('*') || t).dispatchEvent(new MouseEvent('dblclick', {bubbles: true}));
      return labels.length;
    """)
    try? await Task.sleep(nanoseconds: 300_000_000)
    expect(revealed == ["top", "count"], "double-click reveals top.count: \(String(describing: revealed))")
    let values = await call("return await cmuxWaveform.link.valuesAt({ time: 25, paths: [['top', 'count'], ['top', 'core', 'state'], ['top', 'core', 'alu', 'acc'], ['top', 'nope'], ['top', 'core']] })") as? [Any]
    expect(values?.count == 5, "valuesAt answers each path: \(String(describing: values))")
    expect(values?[0] as? String == "01" && values?[2] as? String == "0003", "hex values at 25")
    expect(values?[1] as? String == "x", "a group with z and 1 in it is x: \(String(describing: values?[1]))")
    expect(values?[3] is NSNull && values?[4] is NSNull, "missing signal and scope -> null")
    let early = await call("return await cmuxWaveform.link.valuesAt({ time: 0, paths: [['top', 'core', 'state'], ['top', 'count']], unshown: false })") as? [Any]
    expect(early?[0] as? String == "x" && early?[1] as? String == "00", "values at 0 (unshown is FSDB-only): \(String(describing: early))")
    let marker2 = await call("return cmuxWaveform.link.markerTime()") as? Int
    expect(marker2 == 25, "markerTime = \(String(describing: marker2))")
    let scoped = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'core'] })") as? [String: Any]
    try? await Task.sleep(nanoseconds: 600_000_000)
    let rows2 = await call("return (cmuxWaveform.viewerContext.webview.displayedSignals || []).map(s => s.name)") as? [String] ?? []
    expect((scoped?["added"] as? Int) == 1 && (scoped?["total"] as? Int) == 1, "addScope adds only what is not shown: \(String(describing: scoped))")
    expect(rows2.contains("top.core.valid") && !rows2.contains("top.core.alu.acc") && rows2.filter { $0 == "top.core.state" }.count == 1, "addScope adds top.core's own signals: \(rows2)")
    let again = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'core'] })") as? [String: Any]
    expect((again?["added"] as? Int) == 0, "addScope again adds nothing: \(String(describing: again))")
    let wide = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'wide'] })") as? [String: Any]
    expect(wide?["needsConfirm"] as? Bool == true && (wide?["count"] as? Int) == 60, "60 signals ask first: \(String(describing: wide))")
    let rows3 = await call("return (cmuxWaveform.viewerContext.webview.displayedSignals || []).length") as? Int
    expect(rows3 == rows2.count, "nothing added before the confirm")
    let huge = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'huge'], confirmed: true })") as? [String: Any]
    expect((huge?["added"] as? Int) == 128 && (huge?["total"] as? Int) == 130, "at most 128 added, of 130: \(String(describing: huge))")
    let quick = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'huge'], confirmed: true })") as? [String: Any]
    expect((quick?["added"] as? Int) == 2, "a second add right away skips the pending ones: \(String(describing: quick))")
    let notScope = await call("return await cmuxWaveform.link.addScope({ path: ['top', 'count'] })")
    expect(notScope == nil || notScope is NSNull, "addScope on a signal -> null")
    print(failures == 0 ? "LINK CHECKS PASSED" : "LINK CHECKS FAILED: \(failures)")
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
    print("[\(m.name)]", m.body)
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      let fmt = waveURL.pathExtension.lowercased()
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'\(fmt)', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'}})")
    } else if type == "opened" {
      Task { @MainActor in await self.runLinkChecks() }
    } else if type == "revealInSource" {
      print("REVEAL", body["path"] ?? "nil")
      revealed = body["path"] as? [String]
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
