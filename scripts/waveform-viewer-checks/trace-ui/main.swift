// Driver tracing's page checks (run.sh trace-ui): loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen WKWebView, opens a trace fixture dump and plays
// cmux for window.cmuxWaveform.trace: it answers the page's resolve and model requests from the
// fixture's models (trace/models, what cmux-sv-model answers) and checks the panel, fan-in
// clicks, Back/Forward, the row menu item, errors and the messages cmux hears.
// Usage: trace-ui <assetRoot> <trace dir> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let traceDir = URL(fileURLWithPath: args[2], isDirectory: true)
let out = URL(fileURLWithPath: args[3])
var failures = 0

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var events: [[String: Any]] = []
  var models: [String: Any] = [:]
  /// What the next resolve answers (nil: the dump path as the design path).
  var resolveError: String?
  var modelRequests = 0
  /// What cmux answers the page's Verdi engine requests (nil: no Verdi for this viewer).
  var engineAnswer: [String: Any]?
  var engineRequests = 0
  var checksStarted = false

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js.prefix(120), error); return nil }
  }

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

  func trace(_ expression: String) async -> [String: Any]? {
    await call("return await cmuxWaveform.trace.\(expression)") as? [String: Any]
  }

  func panelText() async -> String {
    await call("const p = document.getElementById('cmux-trace'); return p && !p.hidden ? p.innerText : ''") as? String ?? ""
  }

  func waitFor(_ what: String, _ ms: Int = 5000, _ ok: () async -> Bool) async {
    for _ in 0..<(ms / 50) { if await ok() { return }; await sleep(50) }
    print("(waited \(ms) ms for \(what))")
  }

  func steps() -> [[String: Any]] { events.filter { $0["event"] as? String == "step" }.compactMap { $0["step"] as? [String: Any] } }

  func run() async {
    let api = await call("return Object.keys(cmuxWaveform.trace).sort()") as? [String]
    expect(api == ["back", "backendChanged", "close", "driver", "driverOfDesign", "forward", "reply", "state", "status"], "trace API: \(String(describing: api))")

    // From a waveform path at a time: cmux resolves, the page traces with the fixture's models.
    let first = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let stmt = first?["stmt"] as? [String: Any]
    expect((first?["driver"] as? [String: Any])?["kind"] as? String == "proc" && (stmt?["src"] as? String)?.contains("q <= mix") == true,
           "driver of u_sink.q at 60 is its flop: \(String(describing: stmt?["src"]))")
    expect(first?["trust"] as? String == "exact" && first?["dumpPath"] as? String == "tb_c.dut.u_mid.u_sink.q", "exact, with its dump path")
    let resolves = events.filter { $0["event"] as? String == "resolve" }
    expect(resolves.count == 1 && (resolves.first?["dumpPath"] as? [String]) == ["tb_c", "dut", "u_mid", "u_sink", "q"], "one resolve, by dump segments")
    expect(modelRequests > 0, "models were asked of cmux: \(modelRequests)")
    let text = await panelText()
    expect(text.contains("tb_c.dut.u_mid.u_sink.q") && text.contains("q <= mix") && text.contains("c_struct.sv:56"),
           "panel shows the signal, statement and file:line: \(text.prefix(300))")
    expect(text.contains("exact") && text.contains("Fan-in"), "panel shows the trust badge and fan-in")
    expect(steps().count == 1, "cmux hears the step (to open the statement)")

    // A fan-in row traces one step further; Back and Forward walk the steps.
    let rowPath = "tb_c.dut.u_mid.u_sink.mix"
    let clicked = await call("const r = document.querySelector('#cmux-trace tr.fanin[data-path=\"\(rowPath)\"]'); if (!r) return false; r.click(); return true") as? Bool
    expect(clicked == true, "fan-in row for mix is there")
    await waitFor("second step") { self.steps().count >= 2 }
    let second = steps().last
    expect(second?["signal"] as? String == rowPath && (second?["driver"] as? [String: Any])?["kind"] as? String == "assign", "fan-in click traced mix: an assign")
    let st = await trace("state()")
    expect(st?["steps"] as? Int == 2 && st?["at"] as? Int == 1, "two steps, at the second: \(String(describing: st))")
    let back = await trace("back()")
    expect(back?["at"] as? Int == 0 && ((back?["step"] as? [String: Any])?["signal"] as? String) == "tb_c.dut.u_mid.u_sink.q", "Back to q")
    expect(await panelText().contains("q <= mix"), "panel shows q again")
    let fwd = await trace("forward()")
    expect(fwd?["at"] as? Int == 1, "Forward to mix")
    // A new trace from an earlier step drops the steps after it.
    _ = await trace("back()")
    _ = await trace("driver({ path: ['tb_c', 'dut', 'u_src', 'id_q'], time: 54 })")
    let branched = await trace("state()")
    expect(branched?["steps"] as? Int == 2 && branched?["at"] as? Int == 1, "tracing from step 1 replaces what followed: \(String(describing: branched))")

    // The statement link asks cmux to open it.
    let opened = await call("const a = document.querySelector('#cmux-trace .body a'); if (!a) return false; a.click(); return true") as? Bool
    await sleep(100)
    let open = events.last { $0["event"] as? String == "open" }
    expect(opened == true && ((open?["loc"] as? [String: Any])?["line"] as? Int) == 29, "file:line link posts open with the location: \(String(describing: open?["loc"]))")

    // Errors: cmux can't place the signal; no signal; no marker.
    resolveError = "Not in the design."
    _ = await trace("driver({ path: ['tb_c', 'nope'], time: 10 })")
    expect(await panelText().contains("Not in the design."), "cmux's resolve message is shown")
    resolveError = nil
    _ = await call("cmuxWaveform.link.setMarker(null); return null")
    let noSelection = await call("return await cmuxWaveform.trace.driver({ path: null, time: 5 })")
    expect(noSelection == nil || noSelection is NSNull, "no selected row: nothing traced")
    expect(await panelText().contains("Select a signal"), "says to select a signal")

    // The row menu: Trace Driver on a signal row, with the shortcut shown.
    _ = await call("return await cmuxWaveform.link.addSignal(['tb_c', 'dut', 'q'])")
    await sleep(300)
    let item = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['tb_c', 'dut', 'q'], true);
      const items = window.cmuxTraceUI.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
      const none = window.cmuxTraceUI.rowMenuItems({ webviewSection: 'scope' });
      return { label: items[0] && items[0].label, key: items[0] && items[0].keybinding, count: items.length, none: none.length };
    """) as? [String: Any]
    expect(item?["count"] as? Int == 1 && item?["label"] as? String == "Trace Driver at Marker" && item?["key"] as? String == "⌃T" && item?["none"] as? Int == 0,
           "row menu item on signal rows only: \(String(describing: item))")
    // The selected row at the marker: what Ctrl+T in the viewer does.
    _ = await call("cmuxWaveform.link.setMarker(60); return null")
    await sleep(300)
    let selected = await trace("driver({ path: null, time: null })")
    expect(selected?["signal"] as? String == "tb_c.dut.q" && selected?["time"] as? Int == 60, "selected row at the marker: \(String(describing: selected?["signal"])) @\(String(describing: selected?["time"]))")
    expect((selected?["driver"] as? [String: Any])?["kind"] as? String == "portOut", "dut.q is driven through u_mid's output port")

    // FSDB helpers: a windowed (v2) one answers "last change" and "last edge" itself, so no signal's
    // history is downloaded; a whole-signal (v1) one is read once per signal (values from those
    // changes, not a second read). Played on this VCD by giving its backend the FSDB methods.
    let kinds = await call("""
      const h = cmuxWaveform.host, b = h.currentBackend;
      const pick = (s) => s && JSON.stringify([s.signal, s.value, s.since, s.trust, s.driver && s.driver.kind, s.activation, (s.fanin || []).map((f) => [f.path, f.value, f.time])]);
      const q = () => cmuxWaveform.trace.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      const plain = pick(await q());
      const own = b.signalChanges.bind(b);
      let downloads = 0, inFake = false;
      b.signalChanges = (v, max) => { if (!inFake) { downloads++; } return own(v, max); };
      const asked = [];
      b.windowed = () => true;
      b.v2 = async (req) => {
        asked.push(req.cmd + ':' + (req.kind || ''));
        if (req.cmd !== 'edge') { return { reply: { id: req.id, error: 'not here' } }; }
        inFake = true;
        const ch = await own({ signalId: req.signalId }, 10000000);
        inFake = false;
        let t = null;
        for (let i = ch.length - 1; i >= 0; i--) {
          const at = Number(ch[i][0]), val = String(ch[i][1]);
          if (at >= req.t) { continue; }
          if (req.kind === 'any' || (req.kind === 'rise' ? val === '1' : val === '0')) { t = at; break; }
        }
        return { reply: { id: req.id, result: { t } } };
      };
      const v2 = pick(await q());
      const v2Downloads = downloads;
      delete b.windowed; delete b.v2;
      downloads = 0;
      let valuesAsked = 0, changesAsked = 0;
      b.valuesAt = async () => { valuesAsked++; return null; };
      b.changes = async () => { changesAsked++; throw new Error('not here'); };
      const whole = pick(await q());
      const reads = downloads;
      delete b.valuesAt; delete b.changes; b.signalChanges = own;
      return { plain, v2, whole, asked: [...new Set(asked)].sort(), v2Downloads, valuesAsked, changesAsked, reads };
    """) as? [String: Any]
    expect(kinds?["plain"] as? String != nil && kinds?["v2"] as? String == kinds?["plain"] as? String,
           "v2 helper: the same step: \(String(describing: kinds?["v2"])) vs \(String(describing: kinds?["plain"]))")
    expect((kinds?["asked"] as? [String])?.contains("edge:any") == true && (kinds?["asked"] as? [String])?.contains("edge:rise") == true && kinds?["v2Downloads"] as? Int == 0,
           "v2 helper: edges asked of it, no history downloaded: \(String(describing: kinds?["asked"])) downloads \(String(describing: kinds?["v2Downloads"]))")
    expect(kinds?["whole"] as? String == kinds?["plain"] as? String && kinds?["valuesAsked"] as? Int == 0 && kinds?["changesAsked"] as? Int == 0 && (kinds?["reads"] as? Int ?? 0) > 0,
           "v1 helper: the same step, each signal read once through its changes: \(String(describing: kinds))")

    // The Verdi engine (an FSDB with a KDB on the host): played on this VCD as a whole-signal
    // FSDB backend, cmux answering the page's engine requests.
    func verdiStep(_ path: String, _ t: Int) async -> [String: Any]? {
      await call("""
        const b = cmuxWaveform.host.currentBackend;
        b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
        try { return await cmuxWaveform.trace.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: \(t) }); }
        finally { delete b.valuesAt; delete b.changes; }
      """) as? [String: Any]
    }
    let asked = engineRequests
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    let agreed = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    let agreedEngine = agreed?["engine"] as? [String: Any]
    expect(engineRequests == asked + 1 && agreedEngine?["name"] as? String == "verdi" && agreed?["trust"] as? String == "exact",
           "Verdi names the same statement: answered by Verdi, still exact: \(String(describing: agreedEngine))")
    expect(await panelText().contains("Traced by Verdi"), "the panel says Verdi answered")
    // Ours is a port hop; Verdi names the flop behind the ports: our chain is followed to it.
    let hopped = await verdiStep("tb_c.dut.q", 60)
    let via = hopped?["via"] as? [[String: Any]] ?? []
    expect(hopped?["signal"] as? String == "tb_c.dut.q" && ((hopped?["stmt"] as? [String: Any])?["loc"] as? [String: Any])?["line"] as? Int == 56
             && via.count >= 1 && (hopped?["engine"] as? [String: Any])?["name"] as? String == "verdi",
           "a port hop is followed to Verdi's statement: \(via.map { $0["signal"] ?? "" }) line \(String(describing: (hopped?["stmt"] as? [String: Any])?["loc"]))")
    expect(await panelText().contains("through the ports of"), "the panel lists the port hops")
    // Verdi's last-transition answer for a value unchanged since 55: ours first, Verdi's second.
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 50]
    let differs = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    let differsEngine = differs?["engine"] as? [String: Any]
    expect(differsEngine?["name"] as? String == "cmux" && differsEngine?["verdiDiffers"] as? Bool == true
             && ((differs?["stmt"] as? [String: Any])?["loc"] as? [String: Any])?["line"] as? Int == 56
             && !((differs?["reasons"] as? [[String: Any]] ?? []).contains { $0["code"] as? String == "enginesDiffer" }),
           "an unchanged value: the statement active at t first, no penalty: \(String(describing: differsEngine))")
    expect(await panelText().contains("Verdi (driver of the last change): c_struct.sv:50"), "the panel shows Verdi's answer second")
    // Verdi not there yet, or not usable here.
    engineAnswer = ["state": "starting"]
    _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    expect(await panelText().contains("Verdi is starting on the host"), "the panel says Verdi is starting")
    engineAnswer = ["state": "unavailable", "reason": "noKDB", "message": ""]
    _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    expect(await panelText().contains("no KDB next to the FSDB"), "the panel says why Verdi is not used")
    engineAnswer = nil

    // Status while cmux builds; close.
    _ = await call("cmuxWaveform.trace.status('Building…'); return null")
    expect(!(await panelText().contains("Building")), "status does not cover a shown step")
    let closed = await trace("close()")
    expect(closed?["open"] as? Bool == false && events.contains { $0["event"] as? String == "closed" }, "close hides the panel and tells cmux")

    // The page can't swap the API cmux calls.
    let tamper = await call("""
      const before = cmuxWaveform.trace;
      try { cmuxWaveform.trace = {}; } catch (e) {}
      try { cmuxWaveform.trace.driver = () => 0; } catch (e) {}
      return cmuxWaveform.trace === before && Object.isFrozen(before);
    """) as? Bool
    expect(tamper == true, "trace API is frozen and non-writable")
    print(failures == 0 ? "TRACE UI CHECKS PASSED" : "TRACE UI CHECKS FAILED: \(failures)")
    snap()
  }

  // MARK: cmux's side

  func answer(_ id: Int, ok: Bool, result: Any? = nil, error: String? = nil, message: String? = nil) {
    var reply: [String: Any] = ["id": id, "ok": ok]
    if let result { reply["result"] = result }
    if let error { reply["error"] = error }
    if let message { reply["message"] = message }
    Task { @MainActor in
      _ = try? await web.callAsyncJavaScript("cmuxWaveform.trace.reply(argument); return null", arguments: ["argument": reply], in: nil, contentWorld: .page)
    }
  }

  func handleTrace(_ body: [String: Any]) {
    events.append(body)
    guard let id = (body["id"] as? NSNumber)?.intValue else { return }
    switch body["event"] as? String {
    case "resolve":
      if let resolveError { answer(id, ok: false, error: "resolve", message: resolveError); return }
      let path = (body["dumpPath"] as? [String] ?? []).joined(separator: ".")
      answer(id, ok: true, result: ["designPath": path, "designPrefix": "", "dumpPrefix": ""])
    case "model":
      modelRequests += 1
      let path = body["path"] as? String ?? ""
      let instances = models["instances"] as? [String: Any] ?? [:]
      if body["cmd"] as? String == "instance" {
        answer(id, ok: true, result: instances[path] ?? NSNull())
      } else if body["cmd"] as? String == "writers" {
        answer(id, ok: true, result: [String]())
      } else {
        let best = instances.keys.filter { path == $0 || path.hasPrefix($0 + ".") }.max { $0.count < $1.count }
        answer(id, ok: true, result: best.map { ["instance": $0, "name": String(path.dropFirst($0.count + 1))] } ?? NSNull())
      }
    case "engine":
      engineRequests += 1
      answer(id, ok: true, result: engineAnswer ?? ["state": "none"])
    default:
      break
    }
  }

  func start() {
    let data = try! Data(contentsOf: traceDir.appendingPathComponent("models/c.json"))
    models = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map((x) => (x && x.stack ? String(x) + ' ' + x.stack : String(x))).join(' ')); } catch(e){}; o.apply(console, a); }; }
      window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno + ':' + e.colno + ' ' + (e.error && e.error.stack)));
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
    if type == "trace" { handleTrace(body); return }
    if type == "event" || type == "sessionState" || type == "log" || type == "keyState" || type == "debugger" { return }
    print("[\(m.name)]", type)
    if type == "ready" {
      let waveURL = traceDir.appendingPathComponent("dumps/c.plain.vcd")
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      // The English page strings cmux sends (WaveformTrace.pageStrings), the ones the checks read.
      let strings: [String: String] = [
        "netlist": "Netlist", "loading": "Loading…", "openFailed": "Could not open", "addSignal": "Add",
        "traceTitle": "Trace Driver", "traceDriverMenu": "Trace Driver at Marker", "traceDriverKey": "⌃T",
        "traceNoSignal": "Select a signal in the waveform first.", "traceNoMarker": "Place the marker at the time to trace first.",
        "traceFailed": "Driver tracing failed.", "traceResolving": "Finding %@ in the design…", "traceRunning": "Tracing %1$@ at %2$@…",
        "traceStepTitle": "%1$@ = %2$@ at %3$@", "traceFanin": "Fan-in (click to trace)", "traceTrust_exact": "exact",
        "traceKindProc": "%@ block", "traceKindAssign": "Continuous assignment", "traceActivation": "%1$@ at %2$@, inputs sampled at %3$@",
        "traceEngineCmux": "Traced by cmux (slang design model)", "traceEngineVerdi": "Traced by Verdi, re-executed by cmux",
        "traceVerdiStarting": "Verdi is starting on the host", "traceVerdiLastChange": "Verdi (driver of the last change):",
        "traceThroughPorts": "through the ports of %@", "traceVerdiUnavailable": "Verdi not used: %@",
        "traceVerdiUnavailable_noKDB": "Verdi not used: no KDB next to the FSDB (compile with vcs -kdb)",
      ]
      let json = String(data: try! JSONSerialization.data(withJSONObject: strings), encoding: .utf8)!
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(json)})")
    } else if type == "opened" {
      guard !checksStarted else { return }
      checksStarted = true
      Task { @MainActor in
        await self.sleep(500)
        await self.run()
      }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
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
      exit(failures == 0 ? 0 : 1)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("timeout"); exit(1) }
app.run()
