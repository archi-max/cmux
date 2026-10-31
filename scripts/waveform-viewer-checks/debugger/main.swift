// Waveform debugger checks (run.sh debugger): loads Resources/vaporview through the
// real WaveformViewerSchemeHandler in an off-screen WKWebView, opens a dump the way
// the panel does and drives window.cmuxWaveform.debugger as cmux would: the default
// clock, cycle stepping, play, the clock choice, Locals and highlighted rows.
// Usage: debugger <assetRoot> <dump.vcd> <out.png>   (stepping.vcd or small.vcd from make-vcd.py)
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
  var debuggerEvents: [[String: Any]] = []
  var viewerEvents: [String] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

  func marker() async -> Int? { await call("return cmuxWaveform.viewerContext.webview.markerTime ?? null") as? Int }

  func dbg(_ expression: String) async -> [String: Any]? {
    await call("return await cmuxWaveform.debugger.\(expression)") as? [String: Any]
  }

  func rows() async -> [String] {
    await call("""
      const out = [];
      const walk = (list, prefix) => (list || []).forEach((d) => {
        if (d.dataType === 'signal-group') { out.push(prefix + '[' + d.groupName + ']'); walk(d.children, prefix + d.groupName + '/'); }
        else if (d.name) { out.push(prefix + d.name); }
      });
      walk(cmuxWaveform.viewerContext.webview.displayedSignals, '');
      return out;
    """) as? [String] ?? []
  }

  func runSmallChecks() async {
    let first = await dbg("state()")
    expect(first?["stepping"] as? Bool == false, "not stepping before a step")
    let s1 = await dbg("step({ by: 1 })")
    expect((s1?["clock"] as? [String]) == ["TOP", "tb", "clock"], "default clock one level below the wrapper: \(String(describing: s1?["clock"]))")
    expect(s1?["count"] as? Int == 20 && s1?["cycle"] as? Int == 1 && s1?["edgeTime"] as? Int == 5, "20 posedges, cycle 1 at 5 (JSON chunks): \(String(describing: s1))")
    await sleep(300)
    let m = await marker()
    expect(m == 5, "marker on the first posedge: \(String(describing: m))")
    print(failures == 0 ? "DEBUGGER CHECKS PASSED" : "DEBUGGER CHECKS FAILED: \(failures)")
    snap()
  }

  func runSteppingChecks() async {
    let first = await dbg("state()")
    expect(first?["stepping"] as? Bool == false && first?["cycle"] is NSNull, "not stepping, no cycle before a step: \(String(describing: first))")
    // No marker yet: step forward lands on the first posedge.
    let s1 = await dbg("step({ by: 1 })")
    expect((s1?["clock"] as? [String]) == ["top", "clk"], "default clock top.clk")
    expect(s1?["count"] as? Int == 4000, "4000 posedges through the LZ4 path: \(String(describing: s1?["count"]))")
    expect(s1?["cycle"] as? Int == 1 && s1?["edgeTime"] as? Int == 5 && s1?["previousTime"] as? Int == 0, "cycle 1 at 5, previous 0: \(String(describing: s1))")
    await sleep(300)
    expect(await marker() == 5, "marker at 5")
    _ = await dbg("step({ by: 1 })")
    await sleep(200)
    let s2 = await dbg("state()")
    expect(await marker() == 15 && s2?["cycle"] as? Int == 2 && s2?["previousTime"] as? Int == 5, "step +1: 15, cycle 2, previous 5: \(String(describing: s2))")
    _ = await dbg("step({ by: -1 })")
    await sleep(200)
    expect(await marker() == 5, "step -1 back to 5")
    _ = await dbg("step({ by: -1 })")
    await sleep(200)
    expect(await marker() == 5, "step -1 at the first posedge stays")
    _ = await dbg("jump({ to: 'last' })")
    await sleep(200)
    let last = await dbg("state()")
    expect(await marker() == 39995 && last?["cycle"] as? Int == 4000, "jump to last: 39995, cycle 4000: \(String(describing: last))")
    _ = await dbg("step({ by: 1 })")
    await sleep(200)
    expect(await marker() == 39995, "step +1 at the last posedge stays")
    _ = await dbg("jump({ to: 'first' })")
    await sleep(200)
    expect(await marker() == 5, "jump to first")
    // Mid-cycle marker (a click): back goes to the posedge before, forward to the next.
    _ = await call("cmuxWaveform.link.setMarker(22); return null")
    await sleep(200)
    let mid = await dbg("state()")
    expect(mid?["cycle"] as? Int == 2 && mid?["edgeTime"] as? Int == 15 && mid?["previousTime"] as? Int == 5, "marker at 22 is in cycle 2: \(String(describing: mid))")
    _ = await dbg("step({ by: -1 })")
    await sleep(200)
    expect(await marker() == 15, "from 22 back to 15")
    _ = await call("cmuxWaveform.link.setMarker(22); return null")
    await sleep(200)
    _ = await dbg("step({ by: 1 })")
    await sleep(200)
    expect(await marker() == 25, "from 22 forward to 25")
    _ = await dbg("step({ by: 10 })")
    await sleep(200)
    expect(await marker() == 125, "step +10 to 125")
    let cycles = debuggerEvents.filter { $0["event"] as? String == "cycle" }.compactMap { $0["cycle"] as? Int }
    expect(cycles.contains(1) && cycles.contains(4000) && cycles.contains(13), "cmux hears each cycle: \(cycles.suffix(8))")
    let strip = await call("const el = document.getElementById('status-cycle'); return el && !el.hidden ? el.textContent : null") as? String
    expect(strip?.contains("13") == true && strip?.contains("4,000") == true, "status strip shows the cycle: \(String(describing: strip))")

    // Play: wall-clock paced, skipping cycles rather than lagging.
    _ = await dbg("jump({ to: 'first' })")
    await sleep(200)
    debuggerEvents.removeAll()
    let started = Date()
    _ = await dbg("play({ rate: 100 })")
    await sleep(1000)
    let playing = await dbg("state()")
    _ = await dbg("pause()")
    let elapsed = Date().timeIntervalSince(started)
    await sleep(200)
    let reached = await dbg("state()")
    let cycle = reached?["cycle"] as? Int ?? 0
    expect(playing?["playing"] as? Bool == true && reached?["playing"] as? Bool == false, "play then pause")
    // Each cycle the marker reached is where wall-clock time says it should be (an
    // occluded off-screen page fires timers late, so it lands on fewer cycles).
    let paced = debuggerEvents.filter { $0["event"] as? String == "cycle" }.compactMap { e -> (Int, Double)? in
      guard let c = e["cycle"] as? Int, let at = e["receivedAt"] as? Date else { return nil }
      return (c, at.timeIntervalSince(started))
    }
    let lag = paced.map { abs(Double($0.0 - 1) - 100 * $0.1) }.max() ?? .infinity
    expect(!paced.isEmpty && lag < 30 && Double(cycle) < 100 * elapsed + 20,
           "on pace at 100 cycles/s: \(paced.count) moves, worst lag \(String(format: "%.0f", lag)) cycles, cycle \(cycle) after \(String(format: "%.2f", elapsed)) s")
    let states = debuggerEvents.filter { $0["event"] as? String == "state" }.compactMap { $0["playing"] as? Bool }
    expect(states.contains(true) && states.last == false, "cmux hears play and pause: \(states)")
    let faster = await dbg("changeRate({ by: 1 })")
    expect(faster?["rate"] as? Int == 200, "faster: 100 -> 200: \(String(describing: faster?["rate"]))")
    let slower = await dbg("changeRate({ by: -1 })")
    expect(slower?["rate"] as? Int == 100, "slower: back to 100")
    let odd = await dbg("setRate({ rate: 30 })")
    let up = await dbg("changeRate({ by: 1 })")
    expect(odd?["rate"] as? Int == 30 && up?["rate"] as? Int == 50, "from 30 faster is 50: \(String(describing: up?["rate"]))")
    _ = await dbg("setRate({ rate: 10 })")
    // Play from the last posedge restarts at the first.
    _ = await dbg("jump({ to: 'last' })")
    await sleep(200)
    _ = await dbg("play({ rate: 500 })")
    await sleep(300)
    _ = await dbg("pause()")
    let restarted = await dbg("state()")
    expect((restarted?["cycle"] as? Int ?? 0) < 1000, "play at the end starts over: \(String(describing: restarted?["cycle"]))")

    // Locals: the instance's own signals in a group of their own; pinned rows stay.
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'count'])")
    await sleep(400)
    _ = await call("return await cmuxWaveform.link.selectSignal(['top', 'count'])")
    await sleep(200)
    let l1 = await call("return await cmuxWaveform.debugger.setLocals({ path: ['top', 'core'] })") as? Bool
    await sleep(400)
    let r1 = await rows()
    expect(l1 == true && r1 == ["top.count", "[Locals]", "Locals/top.core.valid", "Locals/top.core.state"], "Locals = top.core's signals, pinned count kept: \(r1)")
    let sel = await call("return cmuxWaveform.link.selectedSignal()") as? [String]
    expect(sel == ["top", "count"], "the user's selection is given back: \(String(describing: sel))")
    let l2 = await call("return await cmuxWaveform.debugger.setLocals({ path: ['top', 'core', 'alu'] })") as? Bool
    await sleep(400)
    let r2 = await rows()
    expect(l2 == true && r2 == ["top.count", "[Locals]", "Locals/top.core.alu.acc"], "caret moved to alu: \(r2)")
    // A signal in Locals is not pinned: Add to Waveform still adds its row.
    _ = await call("return await cmuxWaveform.link.addSignal(['top', 'core', 'alu', 'acc'])")
    await sleep(400)
    let r3 = await rows()
    expect(r3.filter { $0 == "top.core.alu.acc" }.count == 1 && r3.contains("Locals/top.core.alu.acc"), "add pins a Locals signal: \(r3)")
    let saved = await call("return cmuxCommands.sessionSnapshot().state.displayedSignals.map(d => d.groupName || d.name)") as? [String]
    expect(saved?.contains("Locals") == false && saved?.contains("top.count") == true, "sessions leave Locals out: \(String(describing: saved))")
    // Collapsed Locals still updates.
    _ = await call("""
      const d = document.getElementById('viewer').contentDocument;
      const g = Array.from(d.querySelectorAll('.waveform-group')).find(e => e.querySelector('p').textContent === 'Locals');
      const c = JSON.parse(g.getAttribute('data-vscode-context').replace(/%x20/g, ' '));
      document.getElementById('viewer').contentWindow.postMessage({ command: 'editSignalGroup', groupId: c.groupId, isExpanded: false }, '*');
      return null;
    """)
    await sleep(300)
    _ = await call("return await cmuxWaveform.debugger.setLocals({ path: ['top', 'core'] })")
    await sleep(400)
    let r4 = await rows()
    expect(r4.filter { $0.hasPrefix("Locals/") } == ["Locals/top.core.valid", "Locals/top.core.state"], "a collapsed Locals is refilled: \(r4)")
    let notScope = await call("return await cmuxWaveform.debugger.setLocals({ path: ['top', 'count'] })") as? Bool
    expect(notScope == false, "Locals of a signal path is refused")

    // Rows the editor highlights this cycle.
    _ = await dbg("jump({ to: 'first' })")
    await sleep(300)
    let lit = await call("return await cmuxWaveform.debugger.highlightRows({ paths: [['top', 'count'], ['top', 'core', 'state'], ['top', 'nope']] })") as? Int
    await sleep(300)
    expect(lit == 2, "count (pinned) and state (in Locals) light up, a missing path does not: \(String(describing: lit))")
    let boxes = await call("return document.getElementById('viewer').contentDocument.querySelectorAll('.cmux-debugger-transition').length") as? Int
    expect((boxes ?? 0) >= 2, "a box at the marker on each lit row: \(String(describing: boxes))")
    snapImage(suffix: "-highlight")
    await sleep(300)

    // Clock choice: the selected row's signal.
    _ = await call("return await cmuxWaveform.link.selectSignal(['top', 'core', 'valid'])")
    await sleep(300)
    let chosen = await call("return await cmuxWaveform.debugger.useSelectedAsClock()") as? [String]
    let c2 = await dbg("state()")
    expect(chosen == ["top", "core", "valid"] && c2?["count"] as? Int == 2000, "valid as the clock: 2000 posedges: \(String(describing: c2?["count"]))")
    _ = await call("return await cmuxWaveform.link.selectSignal(['top', 'count'])")
    await sleep(300)
    let wide = await call("return await cmuxWaveform.debugger.useSelectedAsClock()")
    let c3 = await dbg("state()")
    expect((wide == nil || wide is NSNull) && (c3?["clock"] as? [String]) == ["top", "core", "valid"], "an 8-bit signal is not a clock")
    let back = await call("return await cmuxWaveform.debugger.setClock({ path: null })") as? [String]
    let c4 = await dbg("state()")
    expect(back == ["top", "clk"] && c4?["count"] as? Int == 4000, "back to the default clock")

    // Stop: Locals and highlights go, pinned rows stay.
    _ = await dbg("stop()")
    await sleep(400)
    let r5 = await rows()
    let hidden = await call("return document.getElementById('status-cycle').hidden") as? Bool
    let boxes2 = await call("return document.getElementById('viewer').contentDocument.querySelectorAll('.cmux-debugger-transition').length") as? Int
    expect(!r5.contains("[Locals]") && r5.contains("top.count") && r5.contains("top.core.alu.acc"), "stop removes Locals only: \(r5)")
    expect(hidden == true && boxes2 == 0, "stop hides the counter and the boxes")
    // The page can't swap the API cmux calls.
    let tamper = await call("""
      const before = cmuxWaveform.debugger;
      try { cmuxWaveform.debugger = {}; } catch (e) {}
      try { cmuxWaveform.debugger.step = () => 0; } catch (e) {}
      return cmuxWaveform.debugger === before && Object.isFrozen(before);
    """) as? Bool
    expect(tamper == true, "debugger API is frozen and non-writable")
    let leaked = viewerEvents.filter { $0 == "signalSelect" }.count
    print("viewer signalSelect events forwarded:", leaked)
    print(failures == 0 ? "DEBUGGER CHECKS PASSED" : "DEBUGGER CHECKS FAILED: \(failures)")
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
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else {
      print("[\(m.name)]", m.body)
      return
    }
    if type == "debugger" {
      var event = body
      event["receivedAt"] = Date()
      debuggerEvents.append(event)
      return
    }
    if type == "event" { viewerEvents.append(body["eventType"] as? String ?? ""); return }
    if type == "sessionState" || type == "log" { return }
    print("[\(m.name)]", type)
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      let strings = "{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals', debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s'}"
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(strings)})")
    } else if type == "opened" {
      Task { @MainActor in
        if self.waveURL.lastPathComponent == "small.vcd" { await self.runSmallChecks() } else { await self.runSteppingChecks() }
      }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  var waveURL: URL { URL(fileURLWithPath: args[2]) }

  func snapImage(suffix: String) {
    let url = out.deletingPathExtension().appendingPathExtension("").path + suffix + ".png"
    web.takeSnapshot(with: nil) { img, _ in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: url))
        print("wrote", url)
      }
    }
  }

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
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
