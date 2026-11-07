// Driver tracing's page checks (run.sh trace-ui): loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen WKWebView, opens a trace fixture dump and plays
// cmux for window.cmuxWaveform.trace: it answers the page's resolve and model requests from the
// fixture's models (trace/models, what cmux-sv-model answers) and checks the panel, fan-in
// clicks, Back/Forward, the row menu item, errors and the messages cmux hears.
// Usage: trace-ui <assetRoot> <trace dir> <out.png>
import AppKit
import WebKit

// Line-buffered, so a crash keeps what was printed.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
/// A duration for a message: a failed call's .infinity must not trap in Int(_:).
func msText(_ ms: Double) -> String { ms.isFinite ? String(Int(ms)) : "no answer" }
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
  /// What the resolves answer instead (a row only the compiled design has: cmux's compiledOnly).
  var resolveAnswer: [String: Any]?
  var modelRequests = 0
  /// The design cmux has loaded now (resolve's designId); a model request for another one is
  /// refused as cmux refuses it (nil: any).
  var currentDesign: String?
  /// Model requests are answered `noDesign` (cmux has no design for the viewer: evicted, or its build failed).
  var noDesign = false
  /// What cmux answers the page's Verdi engine requests (nil: no Verdi for this viewer).
  var engineAnswer: [String: Any]?
  /// Per traced signal (the request's dump path), ahead of `engineAnswer`.
  var engineAnswers: [String: [String: Any]] = [:]
  var engineRequests = 0
  /// How long cmux takes to answer an engine request (the Verdi session's answer time).
  var engineDelay: TimeInterval = 0
  /// cmux never answers engine requests (a hung Verdi session).
  var engineHang = false
  /// Resolve requests held unanswered (a first-time design model build under way), by id.
  var holdResolves = false
  var heldResolves: [(id: Int, path: String)] = []
  /// Model lookups answered after this long (a slow step).
  var lookupDelay: TimeInterval = 0
  /// The signals of the engine requests the page marked as background (a prefetch).
  var engineBackground: [String] = []
  /// Each engine request's signal and when it was asked and answered (seconds since start); how
  /// many were under way at once at most (a pool of Verdi sessions answers in parallel).
  var engineLog: [(signal: String, asked: Double, answered: Double?, background: Bool)] = []
  var engineInFlight = 0
  var engineMostInFlight = 0
  /// Bumped when the log is emptied: an answer to a request from before it isn't logged.
  var engineLogGen = 0
  let engineEpoch = Date()
  /// The page's 'update' posts (a step filled in after it was shown).
  var updates = 0
  var checksStarted = false

  /// Runs `js` as an async function body; past `timeout` it fails (nil) instead of hanging the run.
  func call(_ js: String, timeout: TimeInterval = 60) async -> Any? {
    let raced = """
      let timer;
      try {
        return await Promise.race([
          (async () => {
      \(js)
          })(),
          new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('harness: no answer in \(Int(timeout)) s')), \(Int(timeout * 1000))); }),
        ]);
      } finally { clearTimeout(timer); }
      """
    do { return try await web.callAsyncJavaScript(raced, arguments: [:], in: nil, contentWorld: .page) }
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
    expect(api == ["aliasHints", "back", "backendChanged", "close", "driver", "driverOfDesign", "forward", "progress", "reply", "settled", "state", "status", "xRoot"], "trace API: \(String(describing: api))")

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
      return { label: items[0] && items[0].label, key: items[0] && items[0].keybinding, count: items.length, none: none.length,
        xLabel: items[1] && items[1].label, xKey: items[1] && items[1].keybinding };
    """) as? [String: Any]
    expect(item?["count"] as? Int == 2 && item?["label"] as? String == "Trace Driver at Marker" && item?["key"] as? String == "⌃T" && item?["none"] as? Int == 0,
           "row menu items on signal rows only: \(String(describing: item))")
    expect(item?["xLabel"] as? String == "Trace X to Root" && item?["xKey"] as? String == "⌃⇧T", "the row menu has Trace X to Root, with its shortcut")
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
        try {
          await cmuxWaveform.trace.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: \(t) });
          if (cmuxWaveform.trace.settled) { await cmuxWaveform.trace.settled(); }
          return cmuxWaveform.trace.state().step;
        } finally { delete b.valuesAt; delete b.changes; }
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
    let clickedSecond = await call("""
      const a = [...document.querySelectorAll('#cmux-trace .engine a')].find((x) => x.textContent.includes('c_struct.sv:50'));
      if (!a) { return false; } a.click(); return true
      """) as? Bool
    await sleep(100)
    let openedSecond = events.last { $0["event"] as? String == "open" }?["loc"] as? [String: Any]
    expect(clickedSecond == true && openedSecond?["line"] as? Int == 50, "Verdi's second answer is clickable and opens it: \(String(describing: openedSecond))")
    // Verdi not there yet, or not usable here.
    engineAnswer = ["state": "starting"]
    _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    expect(await panelText().contains("Verdi is starting on the host"), "the panel says Verdi is starting")
    engineAnswer = ["state": "unavailable", "reason": "noKDB", "message": ""]
    _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
    expect(await panelText().contains("no KDB next to the FSDB"), "the panel says why Verdi is not used")
    // No Verdi on the host: cmux's own noVerdi string (WaveformTrace.swift, 9 locales) names the
    // variables that find it, and the launcher's hint reaches the page; without a hint, no empty
    // brackets.
    do {
      let resources = assetRoot.deletingLastPathComponent()
      let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
      let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
      var appText = ""
      if let r = traceSwift.range(of: "\"traceVerdiUnavailable_noVerdi\": String(localized: \"waveformTrace.page.verdi.noVerdi\", defaultValue: \""),
         let end = traceSwift[r.upperBound...].range(of: "\"),") {
        appText = String(traceSwift[r.upperBound..<end.lowerBound])
      }
      let locales = ((catalog["waveformTrace.page.verdi.noVerdi"] as? [String: Any])?["localizations"] as? [String: Any] ?? [:])
        .compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
      let named = { (t: String) in t.contains("VERDI_HOME") && t.contains("CMUX_VERDI_SETUP") && t.contains("%@") && !t.lowercased().contains("module") }
      expect(named(appText) && locales.count == 9 && locales.values.allSatisfy(named),
             "noVerdi names VERDI_HOME and CMUX_VERDI_SETUP and shows the launcher's hint, in 9 locales: \(appText) \(locales.filter { !named($0.value) }.keys.sorted())")
      let hint = "verdi is not on PATH, in VERDI_HOME/bin or after CMUX_VERDI_SETUP"
      let json = String(data: try! JSONSerialization.data(withJSONObject: [appText]), encoding: .utf8)!
      _ = await call("cmuxWaveform.strings.traceVerdiUnavailable_noVerdi = \(json)[0]; return null")
      engineAnswer = ["state": "unavailable", "reason": "noVerdi", "message": hint]
      _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
      let shown = await panelText()
      engineAnswer = ["state": "unavailable", "reason": "noVerdi", "message": ""]
      _ = await verdiStep("tb_c.dut.u_mid.u_sink.q", 60)
      let bare = await call("return [...document.querySelectorAll('#cmux-trace .engine')].map((e) => e.textContent).join(' | ')") as? String ?? ""
      expect(!appText.isEmpty && shown.contains(hint) && shown.contains("CMUX_VERDI_SETUP") && !shown.contains("not installed"),
             "no Verdi on the host: the launcher's hint reaches the page: \(shown.prefix(300))")
      expect(bare.contains("VERDI_HOME") && !bare.contains("()") && !bare.contains("undefined"),
             "no Verdi, no hint: the string alone, without empty brackets: \(bare)")
    }
    engineAnswer = nil

    // Timing on a whole-signal (v1) FSDB helper where each signal read takes 150 ms and Verdi
    // answers in 600 ms: a step reads its leaves concurrently, each signal once, and asks Verdi
    // while it runs, not after it (a CPU design: 20 serial whole-history reads made one step minutes long).
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    engineDelay = 0.6
    let timing = await call("""
      const b = cmuxWaveform.host.currentBackend;
      const q = () => cmuxWaveform.trace.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      await q();  // a session on the VCD itself, so the next one starts with nothing read
      const own = b.signalChanges.bind(b);
      let reads = 0, inFlight = 0, most = 0;
      const ids = [];
      b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
      b.signalChanges = async (v, max) => {
        reads++; ids.push(v.netlistId); inFlight++; most = Math.max(most, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 150));
        inFlight--;
        return own(v, max);
      };
      const t0 = performance.now();
      let step;
      let ms;
      try {
        await q(); ms = performance.now() - t0;
        if (cmuxWaveform.trace.settled) { await cmuxWaveform.trace.settled(); }
        step = cmuxWaveform.trace.state().step;
      } finally { delete b.valuesAt; delete b.changes; b.signalChanges = own; }
      return { ms, reads, most, unique: new Set(ids).size, engine: step && step.engine && step.engine.name };
    """) as? [String: Any]
    engineDelay = 0
    engineAnswer = nil
    let reads = timing?["reads"] as? Int ?? 0, ms = timing?["ms"] as? Double ?? .infinity
    let serial = Double(reads) * 150 + 600
    print(String(format: "[timing] v1 step %.0f ms, %d reads (serial would be %.0f ms), at most %d at once", ms, reads, serial, timing?["most"] as? Int ?? 0))
    expect(reads > 2 && timing?["unique"] as? Int == reads, "v1 helper: each signal read once, also when asked twice at the same time: \(String(describing: timing))")
    expect((timing?["most"] as? Int ?? 0) > 1, "v1 helper: a step's signals are read concurrently: \(String(describing: timing))")
    expect(timing?["engine"] as? String == "verdi" && ms < serial * 0.6, "v1 helper + Verdi: the step takes well under the serial time (\(msText(ms)) ms vs \(Int(serial)) ms)")

    // A step never waits on Verdi: ours is shown at once and Verdi's line filled in when it comes,
    // within a per-step budget (its port-hop following included); past it, "not checked (timed out)".
    // A Verdi answer for a step the user has moved on from (a newer trace) is dropped.
    func shown(_ path: String, settle: Bool) async -> [String: Any]? {
      await call("""
        const b = cmuxWaveform.host.currentBackend, t = cmuxWaveform.trace;
        b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
        try {
          const t0 = performance.now();
          const step = await t.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: 60 });
          const ms = performance.now() - t0;
          const panel = document.getElementById('cmux-trace')?.innerText || '';
          const t1 = performance.now();
          if (\(settle) && t.settled) { await t.settled(); }
          return { ms, step, settleMs: performance.now() - t1, after: t.state().step, panel, panelAfter: document.getElementById('cmux-trace')?.innerText || '' };
        } finally { delete b.valuesAt; delete b.changes; }
      """) as? [String: Any]
    }
    _ = await call("cmuxWaveform.traceVerdiBudgetMs = 1500; return null")
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    // A hung Verdi.
    engineHang = true
    let hung = await shown("tb_c.dut.u_mid.u_sink.q", settle: true)
    engineHang = false
    let hungMs = hung?["ms"] as? Double ?? .infinity
    let hungEngine = (hung?["step"] as? [String: Any])?["engine"] as? [String: Any]
    let hungAfter = (hung?["after"] as? [String: Any])?["engine"] as? [String: Any]
    print(String(format: "[verdi async] hung Verdi: step shown in %.0f ms, settled %.0f ms later", hungMs, hung?["settleMs"] as? Double ?? -1))
    expect(hungMs < 1000 && hungEngine?["name"] as? String == "cmux" && hungEngine?["verdi"] as? String == "checking",
           "a hung Verdi does not delay the shown step (\(msText(hungMs)) ms): \(String(describing: hungEngine))")
    expect((hung?["panel"] as? String ?? "").contains("Verdi is checking…"), "the panel says Verdi is checking")
    expect(hungAfter?["verdi"] as? String == "timedOut" && hungAfter?["name"] as? String == "cmux"
             && (hung?["after"] as? [String: Any])?["trust"] as? String == "exact",
           "past the budget: Verdi not checked (timed out), ours unchanged: \(String(describing: hungAfter))")
    expect((hung?["panelAfter"] as? String ?? "").contains("Verdi: not checked (timed out)"), "the panel says Verdi timed out")
    // A slow Verdi on a port hop: ours (the hop) at once, then Verdi's statement behind the ports.
    engineDelay = 0.8
    let updatesBefore = updates
    let stepPosts = { self.events.filter { $0["event"] as? String == "step" }.count }
    let stepsBefore = stepPosts()
    let slow = await shown("tb_c.dut.q", settle: true)
    await sleep(100)
    let stepsAfter = stepPosts()
    let slowMs = slow?["ms"] as? Double ?? .infinity
    let slowStep = slow?["step"] as? [String: Any], slowAfter = slow?["after"] as? [String: Any]
    print(String(format: "[verdi async] slow Verdi (800 ms): step shown in %.0f ms", slowMs))
    expect(slowMs < 700 && (slowStep?["engine"] as? [String: Any])?["verdi"] as? String == "checking"
             && ((slowStep?["driver"] as? [String: Any])?["kind"] as? String ?? "").hasPrefix("port"),
           "a slow Verdi does not delay the shown step (\(msText(slowMs)) ms)")
    expect(((slowAfter?["stmt"] as? [String: Any])?["loc"] as? [String: Any])?["line"] as? Int == 56
             && (slowAfter?["engine"] as? [String: Any])?["name"] as? String == "verdi" && !((slowAfter?["via"] as? [Any]) ?? []).isEmpty,
           "Verdi's answer fills the step in when it arrives (followed through the ports): \(String(describing: slowAfter?["engine"]))")
    expect(updates > updatesBefore, "the filled-in step is posted to cmux as an update")
    expect(stepsAfter - stepsBefore == 1, "the late fill-in does not move the editor (one step post, the shown one): \(stepsAfter - stepsBefore)")
    // Verdi's line, once it is there, is a link in the pane that opens it.
    let clickedVerdi = await call("""
      const a = [...document.querySelectorAll('#cmux-trace .body a')].find((x) => x.textContent.includes('c_struct.sv:56'));
      if (!a) { return false; } a.click(); return true
      """) as? Bool
    await sleep(100)
    let openedVerdi = events.last { $0["event"] as? String == "open" }?["loc"] as? [String: Any]
    expect(clickedVerdi == true && openedVerdi?["line"] as? Int == 56 && (openedVerdi?["file"] as? String ?? "").hasSuffix("c_struct.sv"),
           "the filled-in statement (Verdi's line) is clickable and opens it: \(String(describing: openedVerdi))")
    // A newer trace before Verdi answered: the newer step gets its own answer; the older one, still in
    // the history, keeps its check (a check is dropped only when its step leaves the history).
    _ = await shown("tb_c.dut.q", settle: false)
    let newer = await shown("tb_c.dut.u_mid.u_sink.q", settle: true)
    let older = await call("cmuxWaveform.trace.back(); const st = cmuxWaveform.trace.state().step; cmuxWaveform.trace.forward(); return st") as? [String: Any]
    engineDelay = 0
    engineAnswer = nil
    expect(((newer?["after"] as? [String: Any])?["engine"] as? [String: Any])?["name"] as? String == "verdi"
             && (newer?["after"] as? [String: Any])?["signal"] as? String == "tb_c.dut.u_mid.u_sink.q",
           "the newer step gets its own Verdi answer")
    // The older step is still in the history (Back reaches it): its check fills it in too.
    expect(older?["signal"] as? String == "tb_c.dut.q" && (older?["engine"] as? [String: Any])?["name"] as? String == "verdi"
             && !((older?["via"] as? [Any]) ?? []).isEmpty,
           "the step moved on from, still in the history, gets its Verdi answer: \(String(describing: older?["engine"]))")

    // Back within the budget keeps the check: trace A (a port hop), click a fan-in row (B), go Back
    // to A before Verdi answers; A is filled in, not left "checking".
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    engineDelay = 0.8
    let backA = await call("""
      const b = cmuxWaveform.host.currentBackend, t = cmuxWaveform.trace;
      b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
      try {
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        const atA = t.state().at;
        const row = document.querySelector('#cmux-trace tr.fanin');
        if (!row) { return { error: 'no fan-in row' }; }
        row.click();
        for (let i = 0; i < 300 && t.state().at !== atA + 1; i++) { await new Promise((r) => setTimeout(r, 10)); }
        const clickedOn = t.state().at === atA + 1;
        t.back();
        const backOn = t.state().at === atA;
        if (t.settled) { await t.settled(); }
        return { clickedOn, backOn, step: t.state().step, panel: document.getElementById('cmux-trace')?.innerText || '' };
      } finally { delete b.valuesAt; delete b.changes; }
      """) as? [String: Any]
    let backStep = backA?["step"] as? [String: Any]
    expect(backA?["clickedOn"] as? Bool == true && backA?["backOn"] as? Bool == true && backStep?["signal"] as? String == "tb_c.dut.q"
             && (backStep?["engine"] as? [String: Any])?["name"] as? String == "verdi",
           "Back to a step within its budget: its Verdi check still fills it in: \(String(describing: backStep?["engine"])) \(String(describing: backA?["clickedOn"])) \(String(describing: backA?["backOn"]))")
    expect(!(backA?["panel"] as? String ?? "").contains("Verdi is checking"), "the panel does not stay on \"Verdi is checking…\"")
    // close() during a check drops it: no update afterwards.
    let updatesAtClose = updates
    let closedCheck = await call("""
      const b = cmuxWaveform.host.currentBackend, t = cmuxWaveform.trace;
      b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
      try {
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        t.close();
        if (t.settled) { await t.settled(); }
        await new Promise((r) => setTimeout(r, 1000));
        return { open: t.state().open, steps: t.state().steps };
      } finally { delete b.valuesAt; delete b.changes; }
      """) as? [String: Any]
    await sleep(100)
    expect(closedCheck?["open"] as? Bool == false && updates == updatesAtClose + 0, "close() during a Verdi check drops it (no update after): \(updates - updatesAtClose)")
    engineDelay = 0

    // Our step's reads go first: on a helper that serves one read at a time (300 ms each), a
    // Verdi check's port-hop reads go one at a time and wait for the next step's own reads.
    // tb_c.dut.q: 2 reads of ours, then the hop's u_sink.q and its 4 leaves; the next step starts
    // when the hop asks for its first leaf.
    let order = await call("""
      const b = cmuxWaveform.host.currentBackend, t = cmuxWaveform.trace;
      await t.driverOfDesign({ designPath: 'tb_c.dut.u_src.id_q', designPrefix: '', dumpPrefix: '', time: 60 });  // a VCD session: nothing read on the next
      const own = b.signalChanges.bind(b);
      const names = []; let chain = Promise.resolve(), queued = 0, requests = 0, during = false, after = false, mostBg = 0, readsDuringB = 0, trigger;
      const ready = new Promise((resolve) => { trigger = resolve; });
      b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
      b.signalChanges = (v, max) => {
        queued++; requests++; names.push((during ? 'B:' : '') + (cmuxWaveform.host.pathOf ? cmuxWaveform.host.pathOf(v).join('.') : v.netlistId));
        if (requests === 4) { trigger(); }
        if (during) { readsDuringB++; } else if (after) { mostBg = Math.max(mostBg, queued); }
        const run = chain.then(() => new Promise((r) => setTimeout(r, 300))).then(() => own(v, max)).finally(() => { queued--; });
        chain = run.catch(() => {});
        return run;
      };
      try {
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        after = true;
        await Promise.race([ready, new Promise((r) => setTimeout(r, 4000))]);
        await new Promise((r) => setTimeout(r, 0));
        mostBg = Math.max(mostBg, queued);
        during = true;
        const t0 = performance.now();
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_src.id_q', designPrefix: '', dumpPrefix: '', time: 60 });
        const ms = performance.now() - t0;
        during = false;
        if (t.settled) { await t.settled(); }
        return { ms, readsDuringB, mostBg, requests, names: names.join(' ') };
      } finally { delete b.valuesAt; delete b.changes; b.signalChanges = own; }
      """) as? [String: Any]
    // B's own reads are its fan-in under u_src; a read of anything else that starts during B is
    // a Verdi check's, which must wait until B is shown.
    let duringB = (order?["names"] as? String ?? "").split(separator: " ").filter { $0.hasPrefix("B:") }
    let bReads = duringB.filter { $0.hasPrefix("B:tb_c.dut.u_src.") }.count, bgDuringB = duringB.count - bReads
    let orderMs = order?["ms"] as? Double ?? .infinity
    print(String(format: "[verdi async] serial helper: next step shown in %.0f ms with %d reads of its own, %d of Verdi's started during it; %@", orderMs, bReads, bgDuringB, String(describing: order)))
    expect(bReads > 0 && orderMs < Double(bReads + 1) * 300 + 250, "the next step waits for at most one Verdi read in flight (\(msText(orderMs)) ms, \(bReads) reads)")
    expect(bgDuringB == 0, "no Verdi read starts while the next step runs: \(duringB.joined(separator: " "))")
    expect((order?["mostBg"] as? Int ?? 99) <= 1, "Verdi's port-hop reads go one at a time: \(String(describing: order?["mostBg"]))")

    // A port hop whose reads would be too large is not followed: "Verdi: not checked (large signal)".
    _ = await call("cmuxWaveform.traceVerdiMaxBits = 1; return null")
    let large = await shown("tb_c.dut.q", settle: true)
    _ = await call("delete cmuxWaveform.traceVerdiMaxBits; return null")
    let largeEngine = (large?["after"] as? [String: Any])?["engine"] as? [String: Any]
    expect(largeEngine?["verdi"] as? String == "large" && largeEngine?["name"] as? String == "cmux",
           "a large port hop is not followed: \(String(describing: largeEngine))")
    expect((large?["panelAfter"] as? String ?? "").contains("Verdi: not checked (large signal)"), "the panel says the signal was too large")

    // Two Verdi checks that hop to different signals (q's and qd's statements in u_sink) go one
    // read at a time too: counted at every read request of the whole run, not one sample. A new
    // session (backendChanged) so nothing is cached.
    engineAnswers = ["tb_c.dut.q": ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56],
                     "tb_c.dut.qd": ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 57]]
    let two = await call("""
      const b = cmuxWaveform.host.currentBackend, t = cmuxWaveform.trace;
      cmuxWaveform.traceVerdiBudgetMs = 20000;
      t.backendChanged();
      const own = b.signalChanges.bind(b);
      const names = []; let chain = Promise.resolve(), hops = 0, mostHops = 0;
      const isHop = (name) => name.includes('.u_sink.');
      b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); };
      b.signalChanges = (v, max) => {
        const name = cmuxWaveform.host.pathOf ? cmuxWaveform.host.pathOf(v).join('.') : String(v.netlistId);
        const hop = isHop(name);
        names.push(name);
        if (hop) { hops++; mostHops = Math.max(mostHops, hops); }
        const run = chain.then(() => new Promise((r) => setTimeout(r, 300))).then(() => own(v, max)).finally(() => { if (hop) { hops--; } });
        chain = run.catch(() => {});
        return run;
      };
      try {
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        await t.driverOfDesign({ designPath: 'tb_c.dut.qd', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        return { mostHops, names: names.join(' '), steps: t.state().steps };
      } finally { delete b.valuesAt; delete b.changes; b.signalChanges = own; cmuxWaveform.traceVerdiBudgetMs = 1500; }
      """) as? [String: Any]
    let twoNames = two?["names"] as? String ?? ""
    print("[verdi async] two hopping checks: \(String(describing: two))")
    expect(twoNames.contains("u_sink.q") && twoNames.contains("u_sink.qd"), "both checks followed their port hop: \(twoNames)")
    expect((two?["mostHops"] as? Int ?? 99) <= 1, "two checks' port-hop reads go one at a time: at most \(String(describing: two?["mostHops"])) at once")
    engineAnswers = [:]

    // Helper v2 (windowed): nothing of a signal's history is downloaded, even where the page used to
    // fall back to a whole read. A mock v2 helper answers edge, search, valueAt and cancel from this
    // VCD's changes (normalized as the helper does: one value per time, no repeats, no leading all-x
    // value: the helper's stream starts from all x), at a width the
    // test may set (a 2-bit "clock" whose last bit is the edge), and can leave a signal's requests
    // unanswered until cancelled.
    _ = await call("""
      const h = cmuxWaveform.host, b = h.currentBackend;
      const own = b.signalChanges.bind(b);
      const m = window.__v2mock = { own, downloads: 0, asked: [], cancels: [], widths: new Map(), hang: new Set(), fail: new Set(), refuse: new Set(), pending: new Map(), inFake: false,
        custom: new Map(), sent: [], delay: 0, readDelay: 0, hungIds: [] };
      // A signal's history as the test sets it (m.custom), else the VCD's.
      m.read = async (v, max) => {
        if (m.readDelay && !m.inFake) { await new Promise((r) => setTimeout(r, m.readDelay)); }
        return m.custom.has(v.signalId) ? m.custom.get(v.signalId).map((c) => c.slice()) : own(v, max);
      };
      const pad = (val, w) => { const t = String(val).toLowerCase(); return t.length >= w ? t : (t[0] === 'x' || t[0] === 'z' ? t[0] : '0').repeat(w - t.length) + t; };
      m.changes = async (id) => {
        m.inFake = true;
        let ch;
        try { ch = await m.read({ signalId: id }, 10000000); } finally { m.inFake = false; }
        const w = m.widths.get(id) || 1, out = [];
        for (const [at, val] of ch || []) {
          const t = Number(at), v = pad(val, w);
          if (out.length && out[out.length - 1][0] === t) { out.pop(); }
          if (out.length && out[out.length - 1][1] === v) { continue; }
          if (!out.length && /^x+$/.test(v)) { continue; }
          out.push([t, v]);
        }
        return out;
      };
      const lastBefore = (ch, t, ok) => { for (let i = ch.length - 1; i >= 0; i--) { if (ch[i][0] < t && ok(ch[i][1])) { return ch[i][0]; } } return null; };
      const firstAfter = (ch, t, ok) => { for (const [at, v] of ch) { if (at > t && ok(v)) { return at; } } return null; };
      const matches = (v, pattern) => v.length === pattern.length && [...pattern].every((c, i) => c === '?' || c === v[i]);
      m.answer = async (req) => {
        if (req.cmd === 'edge') {
          const ch = await m.changes(req.signalId);
          // (rise/fall on a store wider than 1 bit are any change, as the helper's cacheEdge has them)
          const wideStore = (m.widths.get(req.signalId) || 1) !== 1;
          const ok = (v) => req.kind === 'any' || wideStore || v.slice(-1) === (req.kind === 'rise' ? '1' : '0');
          return { t: req.dir < 0 ? lastBefore(ch, req.t, ok) : firstAfter(ch, req.t, ok) };
        }
        if (req.cmd === 'search' && req.wildcard === '?') {
          const ch = await m.changes(req.signalId);
          const ok = (v) => matches(v, req.value);
          return { t: req.dir < 0 ? lastBefore(ch, req.t, ok) : firstAfter(ch, req.t, ok) };
        }
        if (req.cmd === 'valueAt') {
          const values = [];
          for (const id of req.signalIds) {
            const ch = await m.changes(id), w = m.widths.get(id) || 1;
            let v = 'x'.repeat(w);
            for (const [at, val] of ch) { if (at <= req.t) { v = val; } }
            values.push(v);
          }
          // helper-v2's `prev: true` (m.prev on): also the last change at or before t per signal, null with none.
          if (req.prev === true && m.prev) {
            const prev = [];
            for (const id of req.signalIds) {
              const ch = await m.changes(id);
              let at = null;
              for (const c of ch) { if (c[0] <= req.t) { at = { t: c[0], value: c[1] }; } }
              prev.push(at);
            }
            return { values, prev };
          }
          return { values };
        }
        if (req.cmd === 'count') {
          const counts = [];
          for (const id of req.signalIds) {
            // Not stored yet (the helper's "unknown" without a walk); an exact count walks it, or fails.
            if (m.uncounted && m.uncounted.has(id) && req.exact !== true) { counts.push({ signalId: id, unknown: true }); continue; }
            if (m.uncounted && m.uncounted.has(id) && m.exactFails) { counts.push({ signalId: id, error: 'signal larger than 244 MB (worker store limit)' }); continue; }
            const ch = await m.changes(id); counts.push({ signalId: id, count: ch.length, bits: m.widths.get(id) || 1 });
          }
          return { counts };
        }
        if (req.cmd === 'aliasHints') {
          // helper v2's aliasHints (m.noAliasHints: an older helper, which doesn't know it).
          if (m.noAliasHints) { throw new Error('unknown cmd aliasHints'); }
          m.aliasHints.push(req.pairs.length);
          return { accepted: req.pairs.length, refused: [] };
        }
        throw new Error('not here: ' + req.cmd);
      };
      m.install = () => {
        b.signalChanges = (v, max) => {
          if (!m.inFake) { m.downloads++; }
          // (m.normalizedDownloads: the history as the helper streams it, leading all-x dropped)
          return m.normalizedDownloads ? m.changes(v.signalId) : m.read(v, max);
        };
        b.windowed = () => true;
        b.v2 = async (req) => {
          m.asked.push(req.cmd);
          m.sent.push({ cmd: req.cmd, signalId: req.signalId, kind: req.kind, prev: req.prev === true, ids: (req.signalIds || []).length, at: performance.now() });
          if (m.delay && req.cmd !== 'cancel') { await new Promise((r) => setTimeout(r, m.delay)); }
          if (req.cmd === 'cancel') {
            m.cancels.push(req.target);
            const p = m.pending.get(req.target);
            if (p) { m.pending.delete(req.target); p({ reply: { id: req.target, cancelled: true } }); }
            return { reply: { id: req.id, result: { cancelled: !!p } } };
          }
          const ids = req.signalIds || [req.signalId];
          if (ids.some((id) => m.hang.has(id))) { m.hung = (m.hung || 0) + 1; return new Promise((resolve) => m.pending.set(req.id, resolve)); }
          // m.prevMode: how a helper answers valueAt with prev ('hang': never; 'error': an error reply;
          // 'unread': its first signal unreadable, values[0] and prev[0] null; 'hangLater': answered the
          // first time, never the second, then again; 'limit': the first batch fails as one over the store limit does).
          if (req.cmd === 'valueAt' && req.prev === true && (m.prevMode === 'hang' || m.prevMode === 'hangLater' && m.prevAnswered && !m.hungIds.length)) {
            m.hungIds.push(req.id);
            return new Promise((resolve) => m.pending.set(req.id, resolve));
          }
          if (req.cmd === 'valueAt' && req.prev === true && m.prevMode === 'limit' && !m.prevAnswered) {
            m.prevAnswered = true;
            return { reply: { id: req.id, error: 'signal larger than 244 MB (worker store limit)' } };
          }
          if (req.cmd === 'valueAt' && req.prev === true) { m.prevAnswered = true; }
          if (req.cmd === 'valueAt' && req.prev === true && m.prevMode === 'error') { return { reply: { id: req.id, error: 'unknown field prev' } }; }
          if (req.cmd === 'valueAt' && req.prev === true && m.prevMode === 'unread') {
            const r = await m.answer(req);
            if (r.prev && r.values.length) { r.values[0] = null; r.prev[0] = null; }
            return { reply: { id: req.id, result: r } };
          }
          // The helper's checkTime: a time before 0 is an error (counted: the page must not ask one).
          if (typeof req.t === 'number' && req.t < 0) { m.negative = (m.negative || 0) + 1; return { reply: { id: req.id, error: 't: out of range' } }; }
          if (req.cmd !== 'count' && ids.some((id) => m.fail.has(id))) { return { reply: { id: req.id, error: 'not answered' } }; }
          if (req.cmd !== 'valueAt' && ids.some((id) => m.refuse.has(id))) { return { reply: { id: req.id, error: 'signal larger than 244 MB (worker store limit)' } }; }
          try { return { reply: { id: req.id, result: await m.answer(req) } }; }
          catch (error) { return { reply: { id: req.id, error: String(error.message) } }; }
        };
      };
      // The plain (whole-signal) page on the same histories, to compare with.
      m.plain = () => { b.signalChanges = (v, max) => m.read(v, max); };
      m.remove = () => { m.custom.clear(); m.sent = []; m.aliasHints = []; m.noAliasHints = false; m.delay = 0; m.readDelay = 0; m.prev = false; m.prevMode = undefined; m.normalizedDownloads = false; m.fail.clear(); b.signalChanges = own; delete b.windowed; delete b.v2; delete b.valuesAt; delete b.changes; };
      m.pick = (s) => s && JSON.stringify([s.signal, s.value, s.since, s.trust, s.driver && s.driver.kind, s.activation, (s.fanin || []).map((f) => [f.path, f.value, f.time])]);
      return null
      """)

    // A wide clock (its last bit is the edge): the edge is found with the helper's search, not by
    // downloading the clock's history.
    let wide = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
      const width = clk.width;
      clk.width = 2;
      m.widths.set(clk.signalId, 2);
      const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      try {
        t.backendChanged();
        const plain = m.pick(await q());
        m.install(); m.downloads = 0; m.asked = []; m.negative = 0;
        t.backendChanged();
        const v2 = m.pick(await q());
        return { plain, v2, downloads: m.downloads, asked: [...new Set(m.asked)].sort(), negative: m.negative };
      } finally { m.remove(); clk.width = width; m.widths.clear(); t.backendChanged(); }
      """) as? [String: Any]
    expect(wide?["plain"] as? String != nil && wide?["v2"] as? String == wide?["plain"] as? String,
           "v2 helper, a 2-bit clock: the same step: \(String(describing: wide?["v2"])) vs \(String(describing: wide?["plain"]))")
    expect(wide?["downloads"] as? Int == 0 && (wide?["asked"] as? [String])?.contains("search") == true,
           "v2 helper, a 2-bit clock: its edge is searched for, no history downloaded: \(String(describing: wide?["asked"])) downloads \(String(describing: wide?["downloads"]))")
    expect(wide?["negative"] as? Int == 0,
           "v2 helper, a 2-bit clock in a dump from 0: no request for a time before 0 (the helper rejects it): \(String(describing: wide?["negative"]))")

    // Values the helper's batch can't give (a signal it fails, which fails the batch): each is
    // asked again on its own, not downloaded.
    let miss = await call("""
      const h = cmuxWaveform.host, b = h.currentBackend, t = cmuxWaveform.trace, m = window.__v2mock;
      const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      try {
        t.backendChanged();
        const plain = m.pick(await q());
        m.install(); m.downloads = 0; m.asked = [];
        b.changes = async () => { throw new Error('not here'); };
        b.valuesAt = async () => { throw new Error('reader reports 0 bits (alias?)'); };
        t.backendChanged();
        const v2 = m.pick(await q());
        return { plain, v2, downloads: m.downloads, asked: [...new Set(m.asked)].sort() };
      } finally { m.remove(); t.backendChanged(); }
      """) as? [String: Any]
    expect(miss?["plain"] as? String != nil && miss?["v2"] as? String == miss?["plain"] as? String,
           "v2 helper, a failed value batch: the same step: \(String(describing: miss?["v2"])) vs \(String(describing: miss?["plain"]))")
    expect(miss?["downloads"] as? Int == 0 && (miss?["asked"] as? [String])?.contains("valueAt") == true,
           "v2 helper, a failed value batch: values asked again of the helper, none downloaded: \(String(describing: miss?["asked"])) downloads \(String(describing: miss?["downloads"]))")

    // valueAt with prev (helper-v2's point read for trace-X): a step's values and each one's last change come
    // from one batched read per time, with no edge search for a last change (a clock's edge walk is
    // counted apart: SystemVerilog edges need rise, fall and the change before); a helper without prev is
    // searched as before. Trace Driver and Trace X to Root give the same steps either way.
    func pointReads(prev: Bool) async -> [String: Any]? {
      await call("""
        const h = cmuxWaveform.host, b = h.currentBackend, t = cmuxWaveform.trace, m = window.__v2mock;
        const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        const x = () => t.xRoot({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 });
        const chain = (c) => JSON.stringify(((c && c.steps) || []).map((e) => [e.signal, e.time, e.value, e.since]).concat([c && c.end && c.end.code]));
        try {
          t.backendChanged();
          const plain = m.pick(await q()), plainChain = chain(await x());
          m.install(); m.prev = \(prev); m.downloads = 0; m.sent = []; window.cmuxTraceChecks.walkQueries = 0;
          b.changes = async () => { throw new Error('not here'); };
          b.valuesAt = async () => { throw new Error('not here'); };
          t.backendChanged();
          const v2 = m.pick(await q()), v2Chain = chain(await x());
          const sent = m.sent.filter((r) => r.cmd !== 'cancel');
          return { plain, v2, plainChain, v2Chain, downloads: m.downloads,
            // (every last-change search, the clocks' too: a clock walk's own queries for the change
            // before one are counted by the page, by purpose)
            anyEdges: sent.filter((r) => r.cmd === 'edge' && r.kind === 'any').length - (window.cmuxTraceChecks.walkQueries || 0),
            clockEdges: sent.filter((r) => r.cmd === 'edge' && r.kind !== 'any').length + (window.cmuxTraceChecks.walkQueries || 0),
            prevReads: sent.filter((r) => r.cmd === 'valueAt' && r.prev).length, requests: sent.length,
            byCmd: Object.entries(sent.reduce((a, r) => { const k = r.cmd + (r.prev ? '+prev' : '') + (r.kind ? ':' + r.kind : '') + (r.ids > 1 ? ' batch' : ''); a[k] = (a[k] || 0) + 1; return a; }, {})).sort().map(([k, n]) => k + ' ' + n).join(', ') };
        } finally { m.remove(); t.backendChanged(); }
        """) as? [String: Any]
    }
    for prev in [true, false] {
      let r = await pointReads(prev: prev)
      print("[v2 point reads] prev \(prev): \(String(describing: r?["requests"])) requests, \(String(describing: r?["anyEdges"])) last-change searches, \(String(describing: r?["clockEdges"])) clock edge queries, \(String(describing: r?["prevReads"])) prev reads; \(r?["byCmd"] as? String ?? "")")
      expect(r?["plain"] as? String != nil && r?["v2"] as? String == r?["plain"] as? String && r?["v2Chain"] as? String == r?["plainChain"] as? String,
             "v2 helper, valueAt prev \(prev): the same step and chain: \(String(describing: r?["v2"])) vs \(String(describing: r?["plain"])); \(String(describing: r?["v2Chain"])) vs \(String(describing: r?["plainChain"]))")
      expect(r?["downloads"] as? Int == 0, "v2 helper, valueAt prev \(prev): no history downloaded (\(String(describing: r?["downloads"])))")
      if prev {
        expect(r?["anyEdges"] as? Int == 0 && (r?["prevReads"] as? Int ?? 0) > 0,
               "v2 helper, valueAt prev: last changes come with the values, no edge search: \(String(describing: r?["anyEdges"])) searches, \(String(describing: r?["prevReads"])) prev reads")
      }
    }

    // A helper whose valueAt with prev never answers, or answers with an error: the step does not wait
    // past twice its budget, is the same as without the helper's prev, and prev is not asked again this
    // session. A signal it can't read (values[i] null) is read as before, not taken as unchanged since 0.
    // After prev answered once, a timeout fails that read only (prev is asked again); a first batch
    // that fails as one over the store limit does (one signal's error) doesn't turn prev off either.
    // A read that timed out is cancelled at the helper.
    for mode in ["hang", "error", "unread", "hangLater", "limit"] {
      let r = await call("""
        const h = cmuxWaveform.host, b = h.currentBackend, t = cmuxWaveform.trace, m = window.__v2mock;
        const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        const x = () => t.xRoot({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 });
        const chain = (c) => JSON.stringify(((c && c.steps) || []).map((e) => [e.signal, e.time, e.value, e.since]).concat([c && c.end && c.end.code]));
        cmuxWaveform.traceVerdiBudgetMs = 800;
        try {
          t.backendChanged();
          const plain = m.pick(await q()), plainChain = chain(await x());
          m.install(); m.prev = true; m.prevMode = '\(mode)'; m.downloads = 0; m.sent = []; m.cancels = []; m.hungIds = []; m.prevAnswered = false;
          b.changes = async () => { throw new Error('not here'); };
          b.valuesAt = async () => { throw new Error('not here'); };
          t.backendChanged();
          const t0 = performance.now();
          const v2 = await Promise.race([q().then(m.pick), new Promise((r) => setTimeout(() => r('hung'), 6000))]);
          const ms = performance.now() - t0;
          const v2Chain = v2 === 'hung' ? 'hung' : chain(await x());
          const prevReads = m.sent.filter((r) => r.cmd === 'valueAt' && r.prev).length;
          const hungIds = m.hungIds.slice();
          const cancelled = hungIds.filter((id) => m.cancels.filter((c) => c === id).length === 1).length;
          return { plain, v2, plainChain, v2Chain, ms, prevReads, downloads: m.downloads, hung: hungIds.length, cancelled };
        } finally { for (const p of m.pending.values()) { p({ reply: { cancelled: true } }); } m.pending.clear(); m.remove(); cmuxWaveform.traceVerdiBudgetMs = 1500; t.backendChanged(); }
        """) as? [String: Any]
      print("[v2 point reads] \(mode): \(String(describing: r?["ms"])) ms, \(String(describing: r?["prevReads"])) prev reads")
      expect(r?["plain"] as? String != nil && r?["v2"] as? String == r?["plain"] as? String && r?["v2Chain"] as? String == r?["plainChain"] as? String,
             "v2 helper, valueAt prev \(mode): the same step and chain as without prev: \(String(describing: r?["v2"])) vs \(String(describing: r?["plain"])); \(String(describing: r?["v2Chain"])) vs \(String(describing: r?["plainChain"]))")
      expect((r?["ms"] as? Double ?? 1e9) < 2 * 800 + 1500, "v2 helper, valueAt prev \(mode): the step waits at most twice its budget (\(String(describing: r?["ms"])) ms)")
      if mode == "hang" || mode == "error" {
        expect(r?["prevReads"] as? Int == 1, "v2 helper, valueAt prev \(mode): prev asked once, then not again (\(String(describing: r?["prevReads"])))")
      }
      if mode == "hangLater" || mode == "limit" {
        expect(r?["prevReads"] as? Int ?? 0 >= 3, "v2 helper, valueAt prev \(mode): prev still asked after that read failed (\(String(describing: r?["prevReads"])) prev reads)")
      }
      if mode == "hang" || mode == "hangLater" {
        expect(r?["hung"] as? Int ?? 0 >= 1 && r?["cancelled"] as? Int == r?["hung"] as? Int,
               "v2 helper, valueAt prev \(mode): each read that timed out is cancelled once (\(String(describing: r?["cancelled"])) of \(String(describing: r?["hung"])))")
      }
      expect(r?["downloads"] as? Int == 0, "v2 helper, valueAt prev \(mode): no history downloaded (\(String(describing: r?["downloads"])))")
    }

    // The dump's port aliases (from the KDB model, cmux's aliasHints call): sent to helper v2 in
    // chunks of 4096 pairs; nothing to a page without helper v2; an older helper that doesn't know
    // aliasHints is not asked again for the rest.
    let aliases = await call("""
      const t = cmuxWaveform.trace, m = window.__v2mock;
      const pairs = (n) => Array.from({ length: n }, (_, i) => ['tb.u.p' + i, 'tb.n' + i]);
      try {
        t.backendChanged();
        const plain = await t.aliasHints({ pairs: pairs(10) });
        m.install(); m.aliasHints = []; m.sent = [];
        t.backendChanged();
        const sent = await t.aliasHints({ pairs: pairs(5000) });
        const chunks = m.aliasHints.slice();
        m.aliasHints = []; m.noAliasHints = true; m.sent = [];
        const old = await t.aliasHints({ pairs: pairs(9000) });
        const oldAsked = m.sent.filter((r) => r.cmd === 'aliasHints').length;
        return { plain, sent, chunks, old, oldAsked };
      } finally { m.remove(); t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] aliasHints: \(String(describing: aliases))")
    expect(aliases?["plain"] as? Int == 0, "aliasHints: nothing sent without helper v2 (\(String(describing: aliases?["plain"])))")
    expect(aliases?["chunks"] as? [Int] == [4096, 904] && aliases?["sent"] as? Int == 5000,
           "aliasHints: 5000 pairs go to helper v2 as 4096 + 904 (\(String(describing: aliases?["chunks"])), \(String(describing: aliases?["sent"])) sent)")
    expect(aliases?["oldAsked"] as? Int == 1 && aliases?["old"] as? Int == 0,
           "aliasHints: an older helper is asked once, not for every chunk (\(String(describing: aliases?["oldAsked"])) asked, \(String(describing: aliases?["old"])) sent)")

    // A 1-bit clock's edges are SystemVerilog's, through helper v2 (whose rise/fall test the new
    // bit only) as through the whole history (the VCD provider): posedge 0->1, 0->x, 0->z, x->1,
    // z->1; negedge 1->0, 1->x, 1->z, x->0, z->0; x<->z is no edge. Every pair of 0/1/x/z, there
    // and back, at the transition, just before and after it, and from the dump's start.
    let svEdges = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock, ui = (window.cmuxTraceChecks || {}).prevEdge ? window.cmuxTraceChecks : window.cmuxTraceUI;
      const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
      const width = clk.width;
      const pos = new Set(['01', '0x', '0z', 'x1', 'z1']), neg = new Set(['10', '1x', '1z', 'x0', 'z0']);
      const sv = (a, b, edge) => edge === 'PosEdge' ? pos.has(a + b) : edge === 'NegEdge' ? neg.has(a + b) : pos.has(a + b) || neg.has(a + b);
      const expected = (hist, time, edge) => {
        let at = null;
        for (let i = 1; i < hist.length; i++) { if (hist[i][0] <= time && hist[i][1] !== hist[i - 1][1] && sv(hist[i - 1][1], hist[i][1], edge)) { at = hist[i][0]; } }
        return at;
      };
      const cases = [];
      for (const a of '01xz') { for (const b of '01xz') {
        for (const time of [9, 10, 11]) { cases.push({ name: a + '->' + b + ' @' + time, hist: [[0, a], [10, b]], time }); }
        cases.push({ name: a + '->' + b + '->' + a + ' @25', hist: [[0, a], [10, b], [20, a]], time: 25 });
        cases.push({ name: a + '->' + b + '->' + a + ' @19', hist: [[0, a], [10, b], [20, a]], time: 19 });
      } cases.push({ name: 'start ' + a, hist: [[0, a]], time: 5 }); }
      const wrong = [], ok = { v2: 0, plain: 0, v2history: 0, v2wide: 0 };
      // The same matrix with the dump starting at 100 (every time +100): with the start known (the
      // open's timeStart) it must give the same answers; with it unknown (dumpStart 0), the only
      // misses allowed are an edge at the dump's first time where SystemVerilog has none (the
      // stream's first change read as from x: the known limit until the helper reports timeStart).
      const shifted = { known: {}, unknown: {} }, shiftWrong = [], phantom = [];
      const dumpStart = h.dumpStart;
      const run = async (kind, shift, start) => {
        h.dumpStart = () => start;
        const into = shift === 0 ? ok : shifted[start === shift ? 'known' : 'unknown'];
        into[kind] = into[kind] || 0;
        for (const c0 of cases) {
          const c = { name: c0.name, hist: c0.hist.map(([at, v]) => [at + shift, v]), time: c0.time + shift };
          m.custom.set(clk.signalId, c.hist);
          t.backendChanged();
          await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 + shift });
          for (const edge of ['PosEdge', 'NegEdge', 'BothEdges']) {
            const got = await ui.prevEdge('tb_c.dut.u_mid.u_sink.clk', c.time, edge);
            const want = expected(c.hist, c.time, edge);
            const g = got === undefined ? null : got;
            if (g === want) { into[kind]++; continue; }
            const line = kind + ' +' + shift + ' start ' + start + ' ' + edge + ' ' + c.name + ': ' + got + ', not ' + want;
            if (shift && start !== shift && want === null && g === shift) { phantom.push(line); continue; }
            const list = shift ? shiftWrong : wrong;
            if (list.length < 12) { list.push(line); }
          }
        }
      };
      try {
        for (const [shift, start] of [[0, 0], [100, 100], [100, 0]]) {
          m.plain(); await run('plain', shift, start);
          m.install(); await run('v2', shift, start);
          // The helper's edge queries fail: the page reads the history as the helper streams it.
          m.fail.add(clk.signalId); m.normalizedDownloads = true; await run('v2history', shift, start);
          m.fail.clear(); m.normalizedDownloads = false;
          // A 2-bit clock (its last bit the edge), through the helper's search.
          clk.width = 2; m.widths.set(clk.signalId, 2); await run('v2wide', shift, start);
          clk.width = width; m.widths.clear();
        }
        return { wrong, ok, cases: cases.length * 3, shifted, shiftWrong, phantom: phantom.length, phantomFirst: phantom.slice(0, 3) };
      } finally { h.dumpStart = dumpStart; m.remove(); clk.width = width; m.widths.clear(); t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] SV clock edges: \(String(describing: svEdges?["ok"])) of \(String(describing: svEdges?["cases"])) each")
    expect((svEdges?["wrong"] as? [String])?.isEmpty == true && (svEdges?["cases"] as? Int ?? 0) >= 240,
           "a 1-bit clock's edges are SystemVerilog's on helper v2 (narrow, history, 2-bit) and the whole history, every 0/1/x/z pair: \(String(describing: svEdges?["wrong"]))")
    print("[v2] SV clock edges, dump from 100: start known \(String(describing: svEdges?["shifted"])); \(String(describing: svEdges?["phantom"])) phantom first-time edges with the start unknown, e.g. \(String(describing: svEdges?["phantomFirst"]))")
    let cases3 = svEdges?["cases"] as? Int ?? 0
    let known = (svEdges?["shifted"] as? [String: Any])?["known"] as? [String: Int] ?? [:]
    expect((svEdges?["shiftWrong"] as? [String])?.isEmpty == true && known.count == 4 && known.values.allSatisfy { $0 == cases3 },
           "a dump from 100 with its start known gives the same edges as one from 0 (every path), and with it unknown misses only a phantom edge at 100: \(String(describing: svEdges?["shiftWrong"])); known \(known)")

    // The check hooks are not in the shipped page: only with the checks' window.cmuxTraceChecks.
    let hooks = await call("return { shipped: 'prevEdge' in (window.cmuxTraceUI || {}), checks: typeof (window.cmuxTraceChecks || {}).prevEdge }") as? [String: Any]
    expect(hooks?["shipped"] as? Bool == false && hooks?["checks"] as? String == "function",
           "the prevEdge hook is the checks' only: \(String(describing: hooks))")

    // A clean 0/1 clock's edge costs 1-2 round trips to helper v2 (each answer m.delay late), and a
    // clock of unknown width (no netlist width; the helper stores 2 bits, whose rise/fall are any
    // change) is not taken for a 1-bit one.
    let cost = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock, ui = (window.cmuxTraceChecks || {}).prevEdge ? window.cmuxTraceChecks : window.cmuxTraceUI;
      const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
      const width = clk.width;
      const out = {};
      try {
        m.install();
        for (const [name, time, edge] of [['rise', 35, 'PosEdge'], ['fall', 25, 'PosEdge'], ['both', 25, 'BothEdges'], ['neg', 35, 'NegEdge']]) {
          m.custom.set(clk.signalId, [[0, '0'], [10, '1'], [20, '0'], [30, '1']]);
          t.backendChanged();
          await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
          m.delay = 80; m.sent = [];
          const t0 = performance.now();
          const at = await ui.prevEdge('tb_c.dut.u_mid.u_sink.clk', time, edge);
          const ms = performance.now() - t0;
          m.delay = 0;
          // Every request counts, the valueAt+prev point read too.
          out[name] = { at, requests: m.sent.filter((r) => r.cmd === 'edge' || r.cmd === 'search' || r.cmd === 'valueAt').length, others: m.sent.filter((r) => !['edge', 'search', 'valueAt', 'cancel'].includes(r.cmd)).map((r) => r.cmd), trips: Math.round(ms / 80) };
        }
        delete clk.width; m.widths.set(clk.signalId, 2);
        m.custom.set(clk.signalId, [[0, '1'], [10, '0']]);
        t.backendChanged();
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        out.unknownWidth = await ui.prevEdge('tb_c.dut.u_mid.u_sink.clk', 11, 'PosEdge');
        return out;
      } finally { m.remove(); clk.width = width; m.widths.clear(); t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] clean clock edge cost: \(String(describing: cost))")
    let wants: [String: Int] = ["rise": 30, "fall": 10, "both": 20, "neg": 20]
    for (name, want) in wants.sorted(by: { $0.key < $1.key }) {
      let c = cost?[name] as? [String: Any]
      expect(c?["at"] as? Int == want && (c?["trips"] as? Int ?? 9) <= 2 && (c?["requests"] as? Int ?? 9) <= 4 && (c?["others"] as? [String])?.isEmpty == true,
             "v2 helper, a clean clock's \(name) edge: \(want) in at most 2 round trips and 4 requests: \(String(describing: c))")
    }
    expect(cost?.keys.contains("unknownWidth") == true && cost?["unknownWidth"] is NSNull,
           "v2 helper, a clock of unknown width is not read as 1-bit: \(String(describing: cost?["unknownWidth"]))")

    // A signal the helper refuses to index (over its store limit) is not downloaded instead: the
    // whole read is capped too and only costs time; its last change is unknown.
    let refused = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      try {
        m.install(); m.downloads = 0; m.asked = [];
        t.backendChanged();
        const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], true);
        m.refuse.add(v.signalId);
        const step = await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        return { shown: !!step, value: step && step.value, downloads: m.downloads, asked: [...new Set(m.asked)].sort() };
      } finally { m.refuse.clear(); m.remove(); t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] refused signal: \(String(describing: refused))")
    expect(refused?["shown"] as? Bool == true && refused?["downloads"] as? Int == 0,
           "v2 helper: a signal over the helper's store limit is not downloaded instead: \(String(describing: refused))")

    // A wide clock's last bit through x/z runs, with its other bit changing inside runs: the
    // helper's search gives the same step as the whole history (here q's last change at 55 is a
    // rise of the last bit from x). Few non-edge runs back to the edge: still no download; more
    // than the search's cap: the history is read once.
    _ = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      m.clkCase = async (hist, at) => {
        const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
        const width = clk.width;
        clk.width = 2;
        m.widths.set(clk.signalId, 2);
        m.custom.set(clk.signalId, hist);
        const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: at || 60 });
        try {
          m.plain(); t.backendChanged();
          const plain = m.pick(await q());
          m.install(); m.custom.set(clk.signalId, hist); m.downloads = 0; m.asked = [];
          t.backendChanged();
          const step = await q();
          return { plain, v2: m.pick(step), activation: step && step.activation && step.activation.time, downloads: m.downloads, asked: [...new Set(m.asked)].sort() };
        } finally { m.remove(); clk.width = width; m.widths.clear(); t.backendChanged(); }
      };
      return null
      """)
    let xzRuns = await call("""
      return await window.__v2mock.clkCase([[0, '00'], [5, '01'], [10, '00'], [20, '01'], [30, '00'], [40, '10'], [50, '00'],
        [52, '0x'], [53, '1x'], [55, '11'], [57, '01'], [58, '0z'], [59, '00']])
      """) as? [String: Any]
    expect(xzRuns?["plain"] as? String != nil && xzRuns?["v2"] as? String == xzRuns?["plain"] as? String && xzRuns?["activation"] as? Int == 55,
           "v2 helper, a wide clock through x/z runs: the same step: \(String(describing: xzRuns))")
    let fewRuns = await call("""
      return await window.__v2mock.clkCase([[0, '00'], [40, '01'], [44, '0x'], [46, '1z'], [48, '0x'], [50, '1z'], [52, '0x'], [55, '1z']])
      """) as? [String: Any]
    expect(fewRuns?["v2"] as? String == fewRuns?["plain"] as? String && fewRuns?["downloads"] as? Int == 0,
           "v2 helper, a wide clock 6 non-edge runs past its edge: the same step, nothing downloaded: \(String(describing: fewRuns))")
    let manyRuns = await call("""
      const hist = [[0, '00'], [10, '01']];
      for (let k = 0; k < 40; k++) { hist.push([12 + k, k % 2 ? '0z' : '0x']); }
      return await window.__v2mock.clkCase(hist)
      """) as? [String: Any]
    expect(manyRuns?["v2"] as? String == manyRuns?["plain"] as? String && manyRuns?["downloads"] as? Int == 1,
           "v2 helper, a wide clock 40 non-edge runs past its edge: the same step, its history read once: \(String(describing: manyRuns))")
    // A wide clock the helper gives fewer bits than the netlist says: read whole, not "no edge".
    let narrow = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
      const width = clk.width;
      const q = () => t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      try {
        clk.width = 2;
        t.backendChanged();
        const plain = m.pick(await q());
        m.install(); m.downloads = 0;
        t.backendChanged();
        const v2 = m.pick(await q());
        return { plain, v2, downloads: m.downloads };
      } finally { m.remove(); clk.width = width; t.backendChanged(); }
      """) as? [String: Any]
    expect(narrow?["v2"] as? String == narrow?["plain"] as? String && narrow?["downloads"] as? Int == 1,
           "v2 helper, a clock narrower than its netlist width: its history is read: \(String(describing: narrow))")

    // A Verdi check stopped while its wide-edge search is under way (each reply lands before the
    // cancel could reach it) sends nothing more once it has settled.
    engineAnswers = ["tb_c.dut.q": ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]]
    let stoppedQueries = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      const clk = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'clk'], true);
      const width = clk.width;
      cmuxWaveform.traceVerdiBudgetMs = 800;
      try {
        m.install(); m.downloads = 0;
        clk.width = 2; m.widths.set(clk.signalId, 2);
        const hist = [[0, '00'], [10, '01']];
        for (let k = 0; k < 40; k++) { hist.push([12 + k, k % 2 ? '0z' : '0x']); }
        m.custom.set(clk.signalId, hist);
        t.backendChanged();
        m.delay = 60;
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        const at = performance.now();
        await new Promise((r) => setTimeout(r, 1500));
        const after = m.sent.filter((x) => x.at > at && x.cmd !== 'cancel').map((x) => x.cmd);
        return { verdi: t.state().step && t.state().step.engine && t.state().step.engine.verdi, after: after.length, kinds: [...new Set(after)], downloads: m.downloads };
      } finally { m.remove(); clk.width = width; m.widths.clear(); cmuxWaveform.traceVerdiBudgetMs = 1500; t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] stopped check: \(String(describing: stoppedQueries))")
    expect(stoppedQueries?["verdi"] as? String == "timedOut" && stoppedQueries?["after"] as? Int == 0 && stoppedQueries?["downloads"] as? Int == 0,
           "v2 helper: a stopped Verdi check sends no more queries and downloads nothing: \(String(describing: stoppedQueries))")

    // A check's query that was cancelled is not remembered as "no change": our step on the same
    // signal and time asks the helper again (q last changed at 55).
    let notPoisoned = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      cmuxWaveform.traceVerdiBudgetMs = 800;
      try {
        m.install();
        t.backendChanged();
        const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], true);
        m.hang.add(v.signalId);
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        const verdi = t.state().step && t.state().step.engine && t.state().step.engine.verdi;
        m.hang.clear();
        const before = m.sent.filter((x) => x.cmd === 'edge' && x.signalId === v.signalId).length;
        const step = await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        const asked = m.sent.filter((x) => x.cmd === 'edge' && x.signalId === v.signalId).length - before;
        return { verdi, since: step && step.since, asked };
      } finally { m.hang.clear(); m.pending.clear(); m.remove(); cmuxWaveform.traceVerdiBudgetMs = 1500; t.backendChanged(); }
      """) as? [String: Any]
    expect(notPoisoned?["verdi"] as? String == "timedOut" && notPoisoned?["since"] as? Int == 55 && (notPoisoned?["asked"] as? Int ?? 0) > 0,
           "v2 helper: a cancelled check query is asked again by our step, not answered as no change: \(String(describing: notPoisoned))")

    // A Verdi check's whole read that ends after the check stopped is not kept (a later read of
    // that signal reads it again); one over the v2 memory ceiling is not made ("large").
    let lateRead = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      cmuxWaveform.traceVerdiBudgetMs = 800;
      try {
        m.install(); m.downloads = 0;
        t.backendChanged();
        const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], true);
        m.fail.add(v.signalId);
        m.readDelay = 1500;
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        await new Promise((r) => setTimeout(r, 1800));
        const first = m.downloads;
        m.readDelay = 0;
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        return { first, downloads: m.downloads };
      } finally { m.fail.clear(); m.remove(); cmuxWaveform.traceVerdiBudgetMs = 1500; t.backendChanged(); }
      """) as? [String: Any]
    expect(lateRead?["first"] as? Int == 1 && lateRead?["downloads"] as? Int == 2,
           "v2 helper: a check's whole read that ends after the check is not kept: \(String(describing: lateRead))")
    let ceiling = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      cmuxWaveform.traceVerdiV2MaxBits = 1;
      try {
        m.install(); m.downloads = 0;
        t.backendChanged();
        for (const name of ['q', 'qd', 'in', 'mix']) {
          const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', name], true);
          if (v) { m.fail.add(v.signalId); }
        }
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        const e = t.state().step && t.state().step.engine;
        return { verdi: e && e.verdi, downloads: m.downloads, counted: m.asked.includes('count') };
      } finally { m.fail.clear(); m.remove(); delete cmuxWaveform.traceVerdiV2MaxBits; t.backendChanged(); }
      """) as? [String: Any]
    expect(ceiling?["verdi"] as? String == "large" && ceiling?["downloads"] as? Int == 0 && ceiling?["counted"] as? Bool == true,
           "v2 helper: a check's read over the v2 memory ceiling is not made: \(String(describing: ceiling))")
    // The changes kept across signals are bounded by their bits (a wide signal's changes cost its
    // width each), not by their number: with a 1-bit bound only the newest read is kept.
    var cacheRuns: [[String: Any]] = []
    for limit in ["undefined", "1"] {
      let r = await call("""
        const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
        if (\(limit) !== undefined) { cmuxWaveform.traceCacheBits = \(limit); }
        try {
          m.install(); m.downloads = 0;
          t.backendChanged();
          for (const path of [['u_mid', 'u_sink', 'q'], ['u_mid', 'u_sink', 'qd'], ['u_mid', 'u_sink', 'in'], ['u_mid', 'u_sink', 'mix'], ['u_src', 'data_q'], ['u_src', 'd']]) {
            const v = await h.findLinkItem(['tb_c', 'dut', ...path], true);
            if (v) { m.fail.add(v.signalId); }
          }
          await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
          if (t.settled) { await t.settled(); }
          await t.driverOfDesign({ designPath: 'tb_c.dut.u_src.data_q', designPrefix: '', dumpPrefix: '', time: 74 });
          if (t.settled) { await t.settled(); }
          return { downloads: m.downloads, cache: t.state().cache || null };
        } finally { m.fail.clear(); m.remove(); delete cmuxWaveform.traceCacheBits; t.backendChanged(); }
        """) as? [String: Any] ?? [:]
      cacheRuns.append(r)
    }
    let whole = cacheRuns[0]["cache"] as? [String: Any], tight = cacheRuns[1]["cache"] as? [String: Any]
    expect((cacheRuns[0]["downloads"] as? Int ?? 0) >= 2 && whole?["signals"] as? Int == cacheRuns[0]["downloads"] as? Int
             && (whole?["bits"] as? Int ?? 0) > 0 && tight?["signals"] as? Int == 1 && (tight?["bits"] as? Int ?? 0) > 1,
           "the changes kept are bounded by bits: \(cacheRuns)")
    // The helper doesn't know the count without a walk: an exact count is asked for, and a read
    // whose exact count fails too isn't made either (unknown is not "under").
    for exactFails in [false, true] {
      let unknownCount = await call("""
        const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
        cmuxWaveform.traceVerdiV2MaxBits = 1;
        try {
          m.install(); m.downloads = 0; m.asked = []; m.uncounted = new Set(); m.exactFails = \(exactFails);
          t.backendChanged();
          for (const name of ['q', 'qd', 'in', 'mix']) {
            const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', name], true);
            if (v) { m.fail.add(v.signalId); m.uncounted.add(v.signalId); }
          }
          await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
          if (t.settled) { await t.settled(); }
          const e = t.state().step && t.state().step.engine;
          return { verdi: e && e.verdi, downloads: m.downloads, counts: m.asked.filter((c) => c === 'count').length };
        } finally { m.fail.clear(); m.uncounted = null; m.exactFails = false; m.remove(); delete cmuxWaveform.traceVerdiV2MaxBits; t.backendChanged(); }
        """) as? [String: Any]
      expect(unknownCount?["verdi"] as? String == "large" && unknownCount?["downloads"] as? Int == 0 && (unknownCount?["counts"] as? Int ?? 0) >= 2,
             "v2 helper: a check's read with an unknown count (exact count \(exactFails ? "fails" : "over")) is not made: \(String(describing: unknownCount))")
    }

    // A dumped signal the helper refused (its last change unknown) is approximate, with a reason,
    // and isn't asked about again.
    let unknownSince = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      try {
        m.install();
        t.backendChanged();
        const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], true);
        m.refuse.add(v.signalId);
        const step = await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 40 });
        const before = m.sent.filter((x) => x.signalId === v.signalId && x.cmd !== 'valueAt').length;
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 45 });
        const again = m.sent.filter((x) => x.signalId === v.signalId && x.cmd !== 'valueAt').length - before;
        return { value: step && step.value, since: step && step.since, trust: step && step.trust, reasons: (step && step.reasons || []).map((r) => r.code), again };
      } finally { m.refuse.clear(); m.remove(); t.backendChanged(); }
      """) as? [String: Any]
    expect(unknownSince?["trust"] as? String == "approximate" && (unknownSince?["reasons"] as? [String])?.contains("sinceUnknown") == true,
           "v2 helper: a dumped value whose last change is unknown is approximate: \(String(describing: unknownSince))")
    expect(unknownSince?["again"] as? Int == 0, "v2 helper: a refused signal is not asked about again: \(String(describing: unknownSince?["again"]))")

    // A Verdi check that runs out of budget while its port-hop queries are still with the helper
    // cancels them (they would keep a worker busy), and downloads nothing in their place.
    engineAnswers = ["tb_c.dut.q": ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]]
    // 20 times: the budget's boundary (the cancelled queries fall back in the same millisecond)
    // must not start a download.
    var cancelled: [String: Any]?
    var roundsHung = 0
    for round in 0..<20 {
    cancelled = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      cmuxWaveform.traceVerdiBudgetMs = 800;
      try {
        m.install(); m.downloads = 0; m.asked = []; m.cancels = []; m.hung = 0;
        t.backendChanged();
        for (const name of ['q', 'qd', 'clk', 'rst_n', 'in', 'mix']) {
          const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', name], true);
          if (v) { m.hang.add(v.signalId); }
        }
        const step = await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        const hung = m.pending.size;
        if (t.settled) { await t.settled(); }
        await new Promise((r) => setTimeout(r, 100));
        return { shown: !!step, verdi: t.state().step && t.state().step.engine && t.state().step.engine.verdi,
                 hungAtShown: hung, hung: m.hung, cancels: m.cancels.length, left: m.pending.size, downloads: m.downloads };
      } finally { m.hang.clear(); m.pending.clear(); m.remove(); cmuxWaveform.traceVerdiBudgetMs = 1500; t.backendChanged(); }
      """) as? [String: Any]
    if round == 0 { print("[v2] cancel on budget: \(String(describing: cancelled))") }
    // Every query left hanging is cancelled (a round whose check stopped before asking any has
    // none; most rounds must have some).
    if (cancelled?["hung"] as? Int ?? 0) > 0 { roundsHung += 1 }
    let okCancel = cancelled?["verdi"] as? String == "timedOut" && cancelled?["cancels"] as? Int == cancelled?["hung"] as? Int && cancelled?["left"] as? Int == 0
      && (round < 19 || roundsHung >= 10)
    let okNoDownload = cancelled?["downloads"] as? Int == 0
    if !okCancel || !okNoDownload || round == 19 {
      expect(okCancel, "v2 helper: a Verdi check past its budget cancels its queries still with the helper (round \(round + 1) of 20, \(roundsHung) with queries hanging): \(String(describing: cancelled))")
      expect(okNoDownload, "v2 helper: a timed-out Verdi check downloads nothing (round \(round + 1) of 20): \(String(describing: cancelled?["downloads"]))")
      break
    }
    }

    // On v2 a large signal is not skipped: a port hop the helper can't answer by query is read
    // whole and followed, whatever its size (only v1 refuses: "not checked (large signal)").
    let bigV2 = await call("""
      const h = cmuxWaveform.host, t = cmuxWaveform.trace, m = window.__v2mock;
      cmuxWaveform.traceVerdiMaxBits = 1;
      const widened = [];
      try {
        m.install(); m.downloads = 0;
        t.backendChanged();
        // Wider than 64 bits with no history read yet: what v1 refuses unread.
        for (const name of ['q', 'qd', 'in', 'mix']) {
          const v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', name], true);
          if (v) { m.fail.add(v.signalId); widened.push([v, v.width]); v.width = 65; }
        }
        await t.driverOfDesign({ designPath: 'tb_c.dut.q', designPrefix: '', dumpPrefix: '', time: 60 });
        if (t.settled) { await t.settled(); }
        const e = t.state().step && t.state().step.engine;
        return { verdi: e && e.verdi, name: e && e.name, downloads: m.downloads };
      } finally { for (const [v, w] of widened) { v.width = w; } m.fail.clear(); m.remove(); delete cmuxWaveform.traceVerdiMaxBits; t.backendChanged(); }
      """) as? [String: Any]
    print("[v2] large signal: \(String(describing: bigV2))")
    expect(bigV2 != nil && bigV2?["verdi"] as? String != "large" && bigV2?["verdi"] as? String != "timedOut" && (bigV2?["downloads"] as? Int ?? 0) > 0,
           "v2 helper: a large port hop is followed, not skipped: \(String(describing: bigV2))")
    engineAnswers = [:]

    engineAnswer = nil
    _ = await call("delete cmuxWaveform.traceVerdiBudgetMs; return null")

    // ---- Verdi prefetch (status/tracex-verdi-pool.md) ----
    // Once a step's check has settled, Verdi is asked about the step's fan-in leaves; a click on
    // one uses that answer (no new request). One session: nothing is prefetched while a check of
    // ours asks; N sessions: up to N at once. No answer survives another dump, a closed panel, or
    // a Verdi that wasn't ready.
    func engineAsks(_ signal: String, since k: Int = 0) -> Int { engineLog[k...].filter { $0.signal == signal }.count }
    func prefetchRun(sessions: Int, delay: TimeInterval) async -> (leaves: [[String: Any]], step: [String: Any]?) {
      // A request still in flight from the run before (an old session's last prefetch) would count
      // as one at once with this run's: wait for it first.
      for _ in 0..<100 where engineInFlight > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
      engineLog = []; engineLogGen += 1; engineMostInFlight = 0; engineDelay = delay
      let r = await call("""
        const t = cmuxWaveform.trace;
        cmuxWaveform.traceVerdiPrefetch = 4; cmuxWaveform.traceVerdiSessions = \(sessions);
        t.backendChanged();
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        await t.settled();
        await new Promise((r) => setTimeout(r, \(Int(delay * 1000) * 5 + 300)));
        const st = t.state();
        return { leaves: (st.step.fanin || []).filter((f) => f.path).map((f) => ({ path: f.path, time: f.time, role: f.role })), prefetch: st.prefetch };
        """) as? [String: Any]
      return (r?["leaves"] as? [[String: Any]] ?? [], r)
    }
    // A helper-backed dump (the page doesn't ask Verdi about a file it reads itself).
    _ = await call("const b = cmuxWaveform.host.currentBackend; b.valuesAt = async () => null; b.changes = async () => { throw new Error('not here'); }; return null")
    engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    engineBackground = []
    let one = await prefetchRun(sessions: 1, delay: 0.25)
    let firstSignal = engineLog.first?.signal ?? ""
    expect(engineBackground.count == engineLog.count - 1 && !engineBackground.isEmpty,
           "prefetch: the leaves are asked as background requests, the step's own check isn't: \(engineBackground.count) of \(engineLog.count) (first \(firstSignal))")
    let firstAnswered = engineLog.first?.answered ?? 0
    let prefetched = engineLog.dropFirst().map(\.signal)
    let leafPaths = one.leaves.compactMap { $0["path"] as? String }
    expect(!leafPaths.isEmpty && Set(prefetched) == Set(leafPaths.prefix(4)),
           "prefetch: the shown step's fan-in leaves are asked of Verdi: \(prefetched) vs \(leafPaths)")
    expect(engineLog.dropFirst().allSatisfy { $0.asked >= firstAnswered - 0.01 } && engineMostInFlight == 1,
           "prefetch, one session: nothing is prefetched while our check asks, one at a time (at most \(engineMostInFlight))")
    if let leaf = one.leaves.first, let path = leaf["path"] as? String, let time = leaf["time"] as? Int {
      let k = engineLog.count
      let used = await call("""
        const t = cmuxWaveform.trace;
        await t.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: \(time) });
        await t.settled();
        return t.state().prefetch
        """) as? [String: Any]
      expect(engineAsks(path, since: k) == 0 && used?["used"] as? Int == 1,
             "prefetch: a click on a prefetched leaf uses Verdi's answer, no new request: \(engineAsks(path, since: k)) asked, \(String(describing: used))")
      // Another dump (backendChanged): the answer isn't used.
      _ = await prefetchRun(sessions: 1, delay: 0)
      let k2 = engineLog.count
      _ = await call("""
        const t = cmuxWaveform.trace;
        t.backendChanged();
        await t.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: \(time) });
        await t.settled();
        return null
        """)
      expect(engineAsks(path, since: k2) >= 1, "prefetch: after another dump, a leaf is asked again, not answered from before")
      // A Verdi that wasn't ready (a seat refused): nothing kept.
      engineAnswer = ["state": "unavailable", "reason": "licence", "message": "no seat"]
      _ = await prefetchRun(sessions: 1, delay: 0)
      let k3 = engineLog.count
      _ = await call("""
        const t = cmuxWaveform.trace;
        await t.driverOfDesign({ designPath: '\(path)', designPrefix: '', dumpPrefix: '', time: \(time) });
        await t.settled();
        return null
        """)
      expect(engineAsks(path, since: k3) == 1, "prefetch: an answer from a Verdi that wasn't ready is not kept (\(engineAsks(path, since: k3)) asked again)")
      engineAnswer = ["state": "ready", "scope": "tb_c.dut.u_mid.u_sink", "file": "/host/rtl/c_struct.sv", "line": 56]
    } else {
      expect(false, "prefetch: the step has fan-in leaves: \(one.leaves)")
    }
    // Two sessions asked for while cmux has one Verdi per dump (it says `pool: 1`, or nothing):
    // one request at a time. Two only when cmux says it has two.
    _ = await prefetchRun(sessions: 2, delay: 0.3)
    expect(engineMostInFlight == 1, "prefetch, two sessions asked, one in cmux's pool: one request at a time (at most \(engineMostInFlight))")
    engineAnswer?["pool"] = 1
    _ = await prefetchRun(sessions: 2, delay: 0.3)
    expect(engineMostInFlight == 1, "prefetch, two sessions asked, cmux says pool 1: one request at a time (at most \(engineMostInFlight))")
    engineAnswer?["pool"] = 2
    _ = await prefetchRun(sessions: 2, delay: 0.3)
    expect(engineMostInFlight == 2, "prefetch, two sessions, cmux says pool 2: two requests at once (at most \(engineMostInFlight))")
    engineAnswer?["pool"] = nil
    // Prefetched answers kept are capped (traceVerdiAnswers for tests), oldest out.
    engineDelay = 0
    let capped = await call("""
      const t = cmuxWaveform.trace;
      cmuxWaveform.traceVerdiPrefetch = 4; cmuxWaveform.traceVerdiSessions = 1; cmuxWaveform.traceVerdiAnswers = 2;
      try {
        t.backendChanged();
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        await t.settled();
        await new Promise((r) => setTimeout(r, 400));
        return t.state().prefetch;
      } finally { delete cmuxWaveform.traceVerdiAnswers; }
      """) as? [String: Any]
    expect((capped?["asked"] as? Int ?? 0) >= 3 && capped?["kept"] as? Int == 2,
           "prefetch: the answers kept are capped, oldest out: \(String(describing: capped))")
    // Prefetches queued behind ones in flight, then a click on a leaf still waiting, whose step is
    // slow (500 ms): with one session nothing is prefetched between the step and its check's
    // Verdi request; with two (cmux says pool 2) the clicked leaf is asked once, by the click, not
    // prefetched as well.
    func queuedClick(sessions: Int) async -> (asks: [String], last: String?, ok: Bool, info: Any?, clickAt: Double) {
      engineLog = []; engineLogGen += 1; engineDelay = 0.3
      engineAnswer?["pool"] = sessions
      defer { engineDelay = 0; engineAnswer?["pool"] = nil }
      let r = await call("""
        const t = cmuxWaveform.trace, h = cmuxWaveform.host, b = h.currentBackend;
        cmuxWaveform.traceVerdiPrefetch = 6; cmuxWaveform.traceVerdiSessions = \(sessions);
        t.backendChanged();
        await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
        await t.settled();
        const leaves = (t.state().step.fanin || []).filter((f) => f.path).map((f) => ({ path: f.path, time: f.time }));
        await new Promise((r) => setTimeout(r, \(sessions == 1 ? 450 : 150)));
        const queuedNow = t.state().prefetch.queued || [];
        const lastPath = queuedNow.length ? queuedNow[queuedNow.length - 1] : null;
        const last = leaves.find((l) => l.path === lastPath);
        if (!last) { return { leaves: leaves.map((l) => l.path), queuedNow }; }
        const slowChanges = b.signalChanges, slowRaw = h.rawValuesAt;
        const pause = () => new Promise((r) => setTimeout(r, 500));
        if (slowChanges) { b.signalChanges = async (...a) => { await pause(); return slowChanges.apply(b, a); }; }
        h.rawValuesAt = async (...a) => { await pause(); return slowRaw.apply(h, a); };
        const clickAt = Date.now();
        try {
          await t.driverOfDesign({ designPath: last.path, designPrefix: '', dumpPrefix: '', time: last.time });
          await t.settled();
        } finally { if (slowChanges) { b.signalChanges = slowChanges; } h.rawValuesAt = slowRaw; }
        await new Promise((r) => setTimeout(r, 2500));
        return { leaves: leaves.map((l) => l.path), queuedNow, last: last.path, clickAt };
        """) as? [String: Any]
      let last = r?["last"] as? String
      // The page's wall clock (ms) on the log's clock (seconds since engineEpoch).
      let clickAt = ((r?["clickAt"] as? Double) ?? 0) / 1000 - engineEpoch.timeIntervalSince1970
      return (engineLog.map(\.signal), last, last != nil, r, clickAt)
    }
    let qOne = await queuedClick(sessions: 1)
    if qOne.ok, let last = qOne.last {
      // Asked first: the first step's check, then the prefetch in flight and the one after it
      // (450 ms in at 300 ms each); the click's check is next, before any further prefetch.
      let clickIndex = qOne.asks.firstIndex(of: last) ?? -1
      expect(clickIndex >= 1 && clickIndex <= 3,
             "prefetch, one session: no prefetch starts between a click's step and its check's request: \(qOne.asks) (clicked \(last))")
      // Nor while the click's step is under way (its reads are slow here, so Verdi would sit idle
      // in between): the click's step replaces the old step's queued leaves, so none of them is
      // prefetched after the click.
      let leftovers = Set((qOne.info as? [String: Any])?["queuedNow"] as? [String] ?? []).subtracting([last])
      let late = engineLog.filter { $0.background && $0.asked >= qOne.clickAt - 0.005 && leftovers.contains($0.signal) }.map(\.signal)
      let ms = { (t: Double) in Int(((t - qOne.clickAt) * 1000).rounded()) }
      expect(!leftovers.isEmpty && late.isEmpty,
             "prefetch, one session: none of the old step's queued leaves is prefetched after a click: \(late) of \(leftovers.sorted()) in \(engineLog.map { "\($0.signal.split(separator: ".").last ?? "") \($0.background ? "bg" : "fg") \(ms($0.asked))-\($0.answered.map(ms).map(String.init) ?? "?") ms" })")
    } else {
      expect(false, "prefetch: a leaf is still queued when clicked (one session): \(String(describing: qOne.info))")
    }
    let qTwo = await queuedClick(sessions: 2)
    if qTwo.ok, let last = qTwo.last {
      let lastAsks = qTwo.asks.filter { $0 == last }.count
      expect(lastAsks == 1, "prefetch, two sessions: a clicked leaf still in the queue is asked once, not prefetched too: \(lastAsks) in \(qTwo.asks)")
    } else {
      expect(false, "prefetch: a leaf is still queued when clicked (two sessions): \(String(describing: qTwo.info))")
    }
    // Closing the panel stops prefetching.
    engineLog = []; engineLogGen += 1; engineDelay = 0.3
    _ = await call("""
      const t = cmuxWaveform.trace;
      cmuxWaveform.traceVerdiPrefetch = 4; cmuxWaveform.traceVerdiSessions = 1;
      t.backendChanged();
      await t.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60 });
      await t.settled();
      await new Promise((r) => setTimeout(r, 50));
      t.close();
      return null
      """)
    let closedAt = Date().timeIntervalSince(engineEpoch)
    _ = await call("await new Promise((r) => setTimeout(r, 1500)); return null")
    expect(engineLog.filter { $0.asked > closedAt + 0.05 }.isEmpty, "prefetch: nothing is asked after the panel closes: \(engineLog.map { ($0.signal, $0.asked) })")
    engineDelay = 0
    _ = await call("const b = cmuxWaveform.host.currentBackend; delete b.valuesAt; delete b.changes; delete cmuxWaveform.traceVerdiPrefetch; delete cmuxWaveform.traceVerdiSessions; cmuxWaveform.trace.backendChanged(); return null")
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
    // The "when it last changed is unknown" reason fits every step it is on: an edge procedure's
    // (the last clock edge) and a combinational or latch one's (the values at the time asked), in
    // English and as the app's default.
    let resources = assetRoot.deletingLastPathComponent()
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let sinceEntry = ((catalog?["strings"] as? [String: Any])?["waveformTrace.reason.sinceUnknown"] as? [String: Any])?["localizations"] as? [String: Any]
    let sinceEn = ((sinceEntry?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
    let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
    expect(sinceEn.contains("clock edge") && sinceEn.contains("combinational") && sinceEn.contains("latch")
             && traceSwift.contains("defaultValue: \"\(sinceEn)\"") && (sinceEntry?.count ?? 0) == 9,
           "the sinceUnknown reason fits edge, combinational and latch steps, in 9 locales: \(sinceEn)")
    await compiledOnlyChecks()
    await designChecks()
    await kdbDiffersChecks()
    await kdbPendingChecks()
    await kdbCheckedChecks()
    await xRootChecks()
    await buildChecks()
    print(failures == 0 ? "TRACE UI CHECKS PASSED" : "TRACE UI CHECKS FAILED: \(failures)")
    snap()
  }

  /// The first-time design model build (cmux's progress calls while a trace's resolve waits): the
  /// panel shows its stages, the compile's percent, the host and the time so far; another click
  /// asks nothing new and points at the panel; "What is being built?" asks cmux for its doc; a
  /// failure shows the log's last lines and Retry.
  func buildChecks() async {
    _ = await trace("close()")
    await reopen("c")
    let q = "{ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 }"
    func resolves() -> Int { events.filter { $0["event"] as? String == "resolve" }.count }
    func progress(_ p: String) async { _ = await call("cmuxWaveform.trace.progress(\(p)); return null") }
    holdResolves = true
    defer { holdResolves = false }
    let before = resolves()
    _ = await call("window.__drv = cmuxWaveform.trace.driver(\(q)); return null")
    await waitFor("the resolve") { resolves() == before + 1 }
    let started = Date().timeIntervalSince1970 * 1000 - 65_000
    await progress("{ stage: 'upload', host: 'build-host', startedAt: \(started), sourceBytes: 92160 }")
    await progress("{ stage: 'fetch', host: 'build-host', startedAt: \(started) }")
    await progress("{ stage: 'configure', host: 'build-host', startedAt: \(started) }")
    await progress("{ stage: 'compile', percent: 42, host: 'build-host', startedAt: \(started) }")
    var text = await panelText()
    expect(text.contains("Building the design model on build-host") && text.contains("42%") && !text.contains("Finding"),
           "build: the panel shows the build on its host and the compile's percent, not Finding: \(text.prefix(400))")
    expect(text.contains("Upload") && text.contains("90 KB") && text.contains("Configur") && text.contains("Install") && text.contains("Load"),
           "build: the panel lists the stages (upload with its size, configure, compile, install, load): \(text.prefix(400))")
    let marks = await call("""
      return [...document.querySelectorAll('#cmux-trace li.stage')].map((li) => li.dataset.stage + ':' + li.dataset.state).join(' ')
      """) as? String ?? ""
    expect(marks.hasPrefix("upload:done fetch:done configure:done compile:current install:pending load:pending"),
           "build: stages before the compile are done, the compile is current, the rest wait: \(marks)")
    // The time so far (m:ss) in seconds; a slow run may be a few seconds on, so it is a range.
    func elapsed() async -> Int? {
      let t = await call("const e = document.querySelector('#cmux-trace .build-elapsed'); return e ? e.textContent : ''") as? String ?? ""
      guard let m = t.range(of: #"\d+:\d\d"#, options: .regularExpression) else { return nil }
      let parts = t[m].split(separator: ":").compactMap { Int($0) }
      return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
    let shownAt = await elapsed()
    expect(shownAt.map { (65...75).contains($0) } == true, "build: the elapsed time is shown as m:ss: \(String(describing: shownAt))")
    await sleep(2100)
    let laterAt = await elapsed()
    expect(shownAt != nil && laterAt.map { $0 >= shownAt! + 1 } == true, "build: the elapsed time goes on while it builds: \(String(describing: shownAt)) then \(String(describing: laterAt))")
    // The "Finding…" bug: another click while it builds starts nothing and keeps the build shown.
    _ = await call("const r = cmuxWaveform.trace.driver(\(q)); window.__again = r; return null")
    await sleep(200)
    let pulsed = await call("return document.getElementById('cmux-trace').classList.contains('pulse')") as? Bool
    text = await panelText()
    expect(resolves() == before + 1 && heldResolves.count == 1, "build: another Trace Driver while it builds asks nothing new (\(resolves() - before) resolves)")
    expect(pulsed == true && text.contains("Building the design model") && !text.contains("Finding"),
           "build: and points at the build's panel (highlighted), not Finding: \(String(describing: pulsed)) \(text.prefix(200))")
    _ = await call("cmuxWaveform.trace.xRoot(\(q)); return null")
    await sleep(100)
    expect(resolves() == before + 1, "build: Trace X to Root while it builds asks nothing new either")
    // A row menu's Trace Driver goes the same way.
    let rowAsked = await call("""
      const h = cmuxWaveform.host, v = await h.findLinkItem(['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], true);
      const items = window.cmuxTraceUI.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
      items[0].run(); return true
      """) as? Bool
    await sleep(100)
    expect(rowAsked == true && resolves() == before + 1, "build: the row menu's Trace Driver while it builds asks nothing new")
    // What is being built? asks cmux for the doc.
    let infos = events.filter { $0["event"] as? String == "buildInfo" }.count
    _ = await call("const a = document.querySelector('#cmux-trace .buildinfo'); if (a) a.click(); return null")
    await sleep(100)
    expect(events.filter { $0["event"] as? String == "buildInfo" }.count == infos + 1, "build: What is being built? asks cmux to open its doc")
    // Install, load, then done: the trace goes on to its step.
    await progress("{ stage: 'install', host: 'build-host', startedAt: \(started) }")
    await progress("{ stage: 'load', host: 'build-host', startedAt: \(started) }")
    text = await panelText()
    expect(text.contains("Loading the design"), "build: loading the design is shown: \(text.prefix(300))")
    await progress("{ stage: 'done', host: 'build-host', startedAt: \(started) }")
    // A progress call that arrives after done (sent before it) doesn't bring the build back.
    await progress("{ stage: 'compile', percent: 99, host: 'build-host', startedAt: \(started) }")
    for held in heldResolves { answer(held.id, ok: true, result: ["designPath": held.path, "designPrefix": "", "dumpPrefix": ""]) }
    heldResolves = []
    _ = await call("await window.__drv; return null")
    text = await panelText()
    expect(text.contains("q <= mix") && !text.contains("Building"), "build: when it is done the step is shown: \(text.prefix(200))")
    // A failed build: the message, the log's last lines and Retry, which asks again.
    let before2 = resolves()
    _ = await call("window.__drv = cmuxWaveform.trace.driver(\(q)); return null")
    await waitFor("the second resolve") { resolves() == before2 + 1 }
    await progress("{ stage: 'upload', host: 'build-host', startedAt: \(Date().timeIntervalSince1970 * 1000), sourceBytes: 92160 }")
    await progress("{ stage: 'failed', host: 'build-host', message: 'The design model could not be compiled on build-host.', log: 'error: one\\nerror: two\\nmake: *** [all] Error 2' }")
    for held in heldResolves { answer(held.id, ok: false, error: "resolve", message: "The design model could not be compiled on build-host.") }
    heldResolves = []
    _ = await call("await window.__drv; return null")
    text = await panelText()
    let retry = await call("return !!document.querySelector('#cmux-trace button.retry')") as? Bool
    expect(text.contains("could not be compiled") && text.contains("error: two") && text.contains("Error 2") && retry == true,
           "build: a failure shows the message, the log's last lines and Retry: \(text.prefix(400))")
    holdResolves = false
    _ = await call("document.querySelector('#cmux-trace button.retry').click(); return null")
    await waitFor("Retry's resolve") { resolves() == before2 + 2 }
    _ = await call("await cmuxWaveform.trace.settled(); return null")
    await sleep(300)
    text = await panelText()
    expect(resolves() == before2 + 2 && text.contains("q <= mix"), "build: Retry traces again (asking cmux anew): \(resolves() - before2) \(text.prefix(200))")
    // A second viewer of the same design (progress review M1): cmux's done or failed went to the
    // other viewer, and this one's resolve fails. The panel shows why, and the next trace asks anew.
    let before3 = resolves()
    holdResolves = true
    _ = await call("window.__drv = cmuxWaveform.trace.driver(\(q)); return null")
    await waitFor("the third resolve") { resolves() == before3 + 1 }
    await progress("{ stage: 'compile', percent: 10, host: 'build-host', startedAt: \(Date().timeIntervalSince1970 * 1000) }")
    for held in heldResolves { answer(held.id, ok: false, error: "resolve", message: "The design model could not be compiled on build-host.") }
    heldResolves = []
    _ = await call("await window.__drv; return null")
    text = await panelText()
    expect(text.contains("could not be compiled") && !text.contains("Building"),
           "build: a resolve failing while the page shows a build ends the build and shows the error: \(text.prefix(300))")
    holdResolves = false
    _ = await call("await cmuxWaveform.trace.driver(\(q)); return null")
    expect(resolves() == before3 + 2, "build: and the next trace asks cmux anew (\(resolves() - before3) resolves)")
    // A trace from the editor while the design model builds (progress review M2): cmux sends the
    // build's state with focus, and the panel points at it; a failure's Retry traces the editor's
    // signal (its dump path), not the page's last trace.
    _ = await trace("close()")
    await sleep(1300)
    let calm = await call("return document.getElementById('cmux-trace').classList.contains('pulse')") as? Bool
    let now = Date().timeIntervalSince1970 * 1000
    await progress("{ stage: 'configure', host: 'build-host', startedAt: \(now), focus: true, entry: { dumpPath: ['tb_c', 'dut', 'u_mid', 'u_sink', 'd'], time: 60 } }")
    let focused = await call("return document.getElementById('cmux-trace').classList.contains('pulse')") as? Bool
    // The panel takes the focus without joining the tab order.
    let focusable = await call("const p = document.getElementById('cmux-trace'); return p.tabIndex === -1 && document.activeElement === p") as? Bool
    expect(focusable == true, "build: the build's panel takes the focus, out of the tab order: \(String(describing: focusable))")
    text = await panelText()
    expect(calm == false && focused == true && text.contains("Building the design model on build-host"),
           "build: a trace from the editor while it builds shows the build and points at it: \(String(describing: calm)) \(String(describing: focused)) \(text.prefix(200))")
    await progress("{ stage: 'failed', host: 'build-host', startedAt: \(now), message: 'The design model could not be compiled on build-host.', log: 'error: one' }")
    let before4 = events.count
    _ = await call("const b = document.querySelector('#cmux-trace button.retry'); if (b) b.click(); return !!b")
    await waitFor("the editor entry's resolve") { events.dropFirst(before4).contains { $0["event"] as? String == "resolve" } }
    let asked = events.dropFirst(before4).first { $0["event"] as? String == "resolve" }?["dumpPath"] as? [String]
    expect(asked == ["tb_c", "dut", "u_mid", "u_sink", "d"], "build: Retry after an editor-started build traces the editor's signal: \(String(describing: asked))")
    _ = await call("await cmuxWaveform.trace.settled(); return null")
    // cmux traces from the editor once the design is built, and the build's done may come after
    // the trace (it is queued behind the design's other progress calls): the trace is shown.
    // Another design's build (one page, two designs) is not over for it: it stays shown.
    let other = Date().timeIntervalSince1970 * 1000 + 1
    await progress("{ stage: 'compile', percent: 30, host: 'build-host', startedAt: \(other), design: 'design-b' }")
    let held = await call("""
      const s = await cmuxWaveform.trace.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60, design: 'design-a' });
      return !!s
      """) as? Bool
    text = await panelText()
    expect(held == false && text.contains("Building the design model on build-host"),
           "build: an editor trace of another design keeps this build shown: \(String(describing: held)) \(text.prefix(200))")
    await progress("{ stage: 'done', host: 'build-host', startedAt: \(other), design: 'design-b' }")
    let built = Date().timeIntervalSince1970 * 1000 + 2
    await progress("{ stage: 'compile', percent: 80, host: 'build-host', startedAt: \(built), design: 'design-a' }")
    let traced = await call("""
      const s = await cmuxWaveform.trace.driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60, design: 'design-a' });
      return !!s
      """) as? Bool
    await progress("{ stage: 'done', host: 'build-host', startedAt: \(built), design: 'design-a' }")
    text = await panelText()
    expect(traced == true && text.contains("q <= mix") && !text.contains("Building"),
           "build: an editor trace that comes before its build's done is traced and shown: \(String(describing: traced)) \(text.prefix(200))")
    // Every page string of the build panel is sent by cmux and localized.
    let resources = assetRoot.deletingLastPathComponent()
    let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    let keys = Harness.pageStrings.keys.filter { $0.hasPrefix("traceBuild") }.sorted()
    let missing = keys.filter { key in
      guard let r = traceSwift.range(of: "\"\(key)\": String(localized: \""),
            let id = traceSwift[r.upperBound...].split(separator: "\"").first,
            let entry = (catalog[String(id)] as? [String: Any])?["localizations"] as? [String: Any] else { return true }
      return entry.count != 9
    }
    expect(keys.count >= 12 && missing.isEmpty, "build: the panel's \(keys.count) strings come from cmux in 9 locales (missing: \(missing))")
  }

  /// A row only the compiled design has (cmux resolved it with the dump's KDB model: slang's design
  /// lacks its instance, or has another module there): one step, approximate, that says its drivers
  /// come from the compiled design and its value isn't evaluated, with the KDB's write lines to
  /// jump to and the dumped value; slang's models are not asked.
  func compiledOnlyChecks() async {
    _ = await trace("close()")
    let row = "tb_c.dut.u_mid.u_sink.q"
    resolveAnswer = ["compiledOnly": true, "dumpPath": row, "reason": "notInSlang",
                     "writes": [["file": "/work/rtl/soc.sv", "line": 40, "kind": "nb"], ["file": "/work/rtl/soc.sv", "line": 52, "kind": "b"]]]
    let models = modelRequests
    let step = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let compiled = step?["compiledOnly"] as? [String: Any]
    expect(step?["trust"] as? String == "approximate" && compiled?["reason"] as? String == "notInSlang"
             && (compiled?["writes"] as? [Any])?.count == 2 && step?["signal"] as? String == row,
           "compiled only: one approximate step with the KDB's writes: \(String(describing: step))")
    expect(step?["value"] is String, "compiled only: the dumped value is read: \(String(describing: step?["value"]))")
    expect(modelRequests == models, "compiled only: slang's models are not asked (\(modelRequests - models))")
    var text = await panelText()
    expect(text.contains("Drivers come from the compiled design (KDB)") && text.contains("values aren't evaluated")
             && text.contains("doesn't have this instance") && text.contains("soc.sv:40") && text.contains("soc.sv:52") && text.contains("approximate"),
           "compiled only: the panel says where the drivers come from, why, and the write lines: \(text.prefix(400))")
    let clicked = await call("const a = [...document.querySelectorAll('#cmux-trace .body a')].find((x) => x.textContent === 'soc.sv:52'); if (!a) return false; a.click(); return true") as? Bool
    await sleep(100)
    let open = events.last { $0["event"] as? String == "open" }?["loc"] as? [String: Any]
    expect(clicked == true && open?["file"] as? String == "/work/rtl/soc.sv" && open?["line"] as? Int == 52,
           "compiled only: a write line opens it: \(String(describing: open))")
    // Another module at the instance; Trace X to Root from such a row is the same one step.
    resolveAnswer = ["compiledOnly": true, "dumpPath": row, "reason": "otherModule", "writes": [[String: Any]]()]
    let x = await trace("xRoot({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    text = await panelText()
    expect((x?["compiledOnly"] as? [String: Any])?["reason"] as? String == "otherModule" && text.contains("another module")
             && text.contains("no statement writing it"),
           "compiled only: Trace X to Root shows the step; another module, no writes: \(text.prefix(300))")
    resolveAnswer = nil
    _ = await trace("close()")
    // Its strings come from cmux, in 9 locales.
    let resources = assetRoot.deletingLastPathComponent()
    let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    let keys = Harness.pageStrings.keys.filter { $0.hasPrefix("traceCompiled") }.sorted()
    let missing = keys.filter { key in
      guard let r = traceSwift.range(of: "\"\(key)\": String(localized: \""),
            let id = traceSwift[r.upperBound...].split(separator: "\"").first,
            let entry = (catalog[String(id)] as? [String: Any])?["localizations"] as? [String: Any] else { return true }
      return entry.count != 9
    }
    expect(keys.count == 5 && missing.isEmpty, "compiled only: the panel's \(keys.count) strings come from cmux in 9 locales (missing: \(missing))")
  }

  /// Issue #8: the page's answers belong to the design cmux resolved them in (its designId): a
  /// trace in another design starts a new session and asks its models anew, every model request
  /// says which design it is for, and one cmux refuses (the design changed) is shown, not mixed.
  func designChecks() async {
    _ = await trace("close()")
    let path = "['tb_c', 'dut', 'u_mid', 'u_sink', 'q']"
    func answerIn(_ design: String, _ signal: String = "q") {
      resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink." + signal, "designPrefix": "", "dumpPrefix": "", "designId": design]
      currentDesign = design
    }
    func asked(since k: Int) -> [[String: Any]] { Array(events[k...]).filter { $0["event"] as? String == "model" } }
    answerIn("d#1")
    var k = events.count
    let first = await trace("driver({ path: \(path), time: 60 })")
    var models = asked(since: k)
    expect(first?["signal"] as? String == "tb_c.dut.u_mid.u_sink.q" && !models.isEmpty && models.allSatisfy { $0["design"] as? String == "d#1" },
           "design: the step's model requests say their design: \(models.map { $0["design"] ?? "none" })")
    k = events.count
    _ = await trace("driver({ path: \(path), time: 60 })")
    let again = asked(since: k).count
    expect(again == 0, "design: the same design's models are kept (\(again) asked again: \(asked(since: k).map { "\($0["cmd"] ?? ""):\($0["path"] ?? "")" }))")
    answerIn("d#2")
    k = events.count
    let second = await trace("driver({ path: \(path), time: 60 })")
    models = asked(since: k)
    expect(second?["signal"] as? String == "tb_c.dut.u_mid.u_sink.q" && !models.isEmpty && models.allSatisfy { $0["design"] as? String == "d#2" },
           "design: another design asks its models anew: \(models.count) \(models.map { $0["design"] ?? "none" })")
    // cmux loaded the design again (an edit, a restart) while the page still traces in d#2.
    answerIn("d#2", "d")
    currentDesign = "d#3"
    _ = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'd'], time: 60 })")
    let text = await panelText()
    expect(text.contains("The design changed since this trace began"), "design: a refused model answer is shown: \(text.prefix(200))")
    answerIn("d#3", "d")
    let third = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'd'], time: 60 })")
    expect(third?["signal"] as? String == "tb_c.dut.u_mid.u_sink.d", "design: the next trace works in the new design: \(String(describing: third?["signal"]))")
    // From the editor: cmux's query names the design too.
    currentDesign = "d#4"
    k = events.count
    _ = await trace("driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60, designId: 'd#4' })")
    models = asked(since: k)
    expect(!models.isEmpty && models.allSatisfy { $0["design"] as? String == "d#4" }, "design: the editor's trace asks in its design: \(models.map { $0["design"] ?? "none" })")
    // cmux dropped the viewer's design (evicted, Refs #8 F1): the page's session ends there too,
    // so a design cmux makes again is asked anew, never answered from the old one's kept models.
    currentDesign = nil
    answerIn("e#1")
    _ = await trace("driver({ path: \(path), time: 60 })")
    noDesign = true
    answerIn("e#1", "d")
    k = events.count
    _ = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'd'], time: 60 })")
    expect(!asked(since: k).isEmpty, "design: the noDesign trace asked a model (\(asked(since: k).count))")
    noDesign = false
    answerIn("e#1")
    k = events.count
    let anew = await trace("driver({ path: \(path), time: 60 })")
    expect(anew?["signal"] as? String == "tb_c.dut.u_mid.u_sink.q" && !asked(since: k).isEmpty,
           "design: after noDesign the session's kept models are dropped (\(asked(since: k).count) asked)")
    resolveAnswer = nil
    currentDesign = nil
    _ = await trace("close()")
  }

  /// Issue #9: a row the KDB mapped where the compiled design and slang's differ (another
  /// parameter, width, write line, or a source newer than the compile; cmux's kdbDiffers says what)
  /// is evaluated with slang's statements all the same, so its steps are approximate and say why.
  func kdbDiffersChecks() async {
    _ = await trace("close()")
    let differs = "parameter DEPTH of tb_c.dut.u_mid.u_sink: 16 compiled, 8 in slang"
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "k#1", "kdbDiffers": differs]
    let step = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let codes = (step?["reasons"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
    let text = await panelText()
    expect(step?["trust"] as? String == "approximate" && codes.contains("kdbDiffers"),
           "kdb differs: the step is approximate and says why: \(String(describing: step?["trust"])) \(codes)")
    expect(text.contains("differs from the compiled design (KDB)") && text.contains(differs), "kdb differs: the panel says what differs: \(text.prefix(400))")
    // The same design, agreeing: no such reason.
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "k#2"]
    let agreed = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let agreedCodes = (agreed?["reasons"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
    expect(agreed != nil && !agreedCodes.contains("kdbDiffers"), "kdb agrees: no kdbDiffers reason: \(agreedCodes)")
    resolveAnswer = nil
    // Its string comes from cmux, in 9 locales.
    let resources = assetRoot.deletingLastPathComponent()
    let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    let id = traceSwift.range(of: "\"traceReason_kdbDiffers\": String(localized: \"").flatMap { traceSwift[$0.upperBound...].split(separator: "\"").first }
    let locales = id.flatMap { (catalog[String($0)] as? [String: Any])?["localizations"] as? [String: Any] }?.count ?? 0
    expect(locales == 9, "kdb differs: the reason's string comes from cmux in 9 locales (\(locales))")
    _ = await trace("close()")
  }

  /// Issue #9 F3: with a KDB model, cmux compared only the traced row's instance chain (resolve's
  /// kdbChecked: the levels whose parameters and ports agree, and `level.signal` for each signal
  /// whose shape and writes agree); a step in another instance, or of a signal not in it, is
  /// approximate and says it was not checked. No
  /// kdbChecked (no KDB model): no such reason. An empty one (the editor's trace, not resolved
  /// with the KDB): every step.
  func kdbCheckedChecks() async {
    _ = await trace("close()")
    func codes(_ step: [String: Any]?) -> [String] { (step?["reasons"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String } }
    let row = "driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })"
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "c#1",
                     "kdbChecked": ["tb_c", "tb_c.dut", "tb_c.dut.u_mid", "tb_c.dut.u_mid.u_sink", "tb_c.dut.u_mid.u_sink.q"]]
    let inside = await trace(row)
    expect(inside != nil && !codes(inside).contains("kdbNotChecked"), "kdb checked: the row's own instance and signal are checked: \(codes(inside))")
    // The instance agreed, but not this signal (another signal's writes were compared, not q's).
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "c#1b",
                     "kdbChecked": ["tb_c", "tb_c.dut", "tb_c.dut.u_mid", "tb_c.dut.u_mid.u_sink", "tb_c.dut.u_mid.u_sink.d"]]
    let signalOutside = await trace(row)
    expect(signalOutside?["trust"] as? String == "approximate" && codes(signalOutside).contains("kdbNotChecked"),
           "kdb checked: a signal not compared is approximate though its instance agreed: \(String(describing: signalOutside?["trust"])) \(codes(signalOutside))")
    // An input port's step (the engine's own portIn step: the driver's instance is the row's): its
    // connection is evaluated in the parent, so the parent must be checked too.
    let portRow = "driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'in'], time: 54 })"
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.in", "designPrefix": "", "dumpPrefix": "", "designId": "c#1c",
                     "kdbChecked": ["tb_c", "tb_c.dut", "tb_c.dut.u_mid.u_sink", "tb_c.dut.u_mid.u_sink.in"]]
    let parentOutside = await trace(portRow)
    expect(((parentOutside?["driver"] as? [String: Any])?["kind"] as? String) == "portIn"
           && parentOutside?["trust"] as? String == "approximate" && codes(parentOutside).contains("kdbNotChecked"),
           "kdb checked: an input port whose parent was not checked is approximate: \(String(describing: parentOutside?["trust"])) \(codes(parentOutside))")
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.in", "designPrefix": "", "dumpPrefix": "", "designId": "c#1d",
                     "kdbChecked": ["tb_c", "tb_c.dut", "tb_c.dut.u_mid", "tb_c.dut.u_mid.u_sink", "tb_c.dut.u_mid.u_sink.in"]]
    let parentInside = await trace(portRow)
    expect(parentInside != nil && !codes(parentInside).contains("kdbNotChecked"), "kdb checked: with its parent checked, the input port is: \(codes(parentInside))")
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "c#2", "kdbChecked": ["tb_c"]]
    let outside = await trace(row)
    let text = await panelText()
    expect(outside?["trust"] as? String == "approximate" && codes(outside).contains("kdbNotChecked"),
           "kdb checked: a step in an instance not checked is approximate: \(String(describing: outside?["trust"])) \(codes(outside))")
    expect(text.contains("not checked against the compiled design (KDB)"), "kdb checked: the panel says so: \(text.prefix(300))")
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "c#3"]
    let none = await trace(row)
    expect(none != nil && !codes(none).contains("kdbNotChecked"), "kdb checked: without a KDB model no such reason: \(codes(none))")
    resolveAnswer = nil
    _ = await trace("driverOfDesign({ designPath: 'tb_c.dut.u_mid.u_sink.q', designPrefix: '', dumpPrefix: '', time: 60, designId: 'c#4', kdbChecked: [] })")
    let editorText = await panelText()
    expect(editorText.contains("not checked against the compiled design (KDB)"), "kdb checked: the editor's trace with a KDB model is not checked: \(editorText.prefix(300))")
    let resources = assetRoot.deletingLastPathComponent()
    let traceSwift = (try? String(contentsOf: resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels/WaveformTrace.swift"), encoding: .utf8)) ?? ""
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    let id = traceSwift.range(of: "\"traceReason_kdbNotChecked\": String(localized: \"").flatMap { traceSwift[$0.upperBound...].split(separator: "\"").first }
    let locales = id.flatMap { (catalog[String($0)] as? [String: Any])?["localizations"] as? [String: Any] }?.count ?? 0
    expect(locales == 9, "kdb checked: the reason's string comes from cmux in 9 locales (\(locales))")
    expect(traceSwift.contains("argument[\"kdbChecked\"]"), "kdb checked: the editor's trace says when a KDB model went unused")
    _ = await trace("close()")
  }

  /// Issue #8 F3: while the dump's KDB export runs (a viewer just opened or reloaded it), cmux
  /// traces with slang's design and says so: resolve's kdbPending marks each step (its trust is
  /// slang's own), and a row slang lacks says the compiled design is still loading, not that the
  /// row is not in the design. A reload's helper gets slang's aliases again (L1).
  func kdbPendingChecks() async {
    _ = await trace("close()")
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "p#1", "kdbPending": true]
    let step = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let codes = (step?["reasons"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
    let text = await panelText()
    expect(step != nil && codes.contains("kdbPending"), "kdb pending: the step says slang's design was used: \(codes)")
    expect(text.contains("still loading, so this was traced with slang"), "kdb pending: the panel says so: \(text.prefix(300))")
    resolveAnswer = ["designPath": "tb_c.dut.u_mid.u_sink.q", "designPrefix": "", "dumpPrefix": "", "designId": "p#1"]
    let later = await trace("driver({ path: ['tb_c', 'dut', 'u_mid', 'u_sink', 'q'], time: 60 })")
    let laterCodes = (later?["reasons"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
    expect(later != nil && !laterCodes.contains("kdbPending"), "kdb pending: gone once the export answered: \(laterCodes)")
    resolveAnswer = nil
    // cmux's side: the reason's string in 9 locales; a row slang lacks while the export runs.
    let resources = assetRoot.deletingLastPathComponent()
    let sources = resources.deletingLastPathComponent().appendingPathComponent("Sources/Panels")
    let traceSwift = (try? String(contentsOf: sources.appendingPathComponent("WaveformTrace.swift"), encoding: .utf8)) ?? ""
    let linkSwift = (try? String(contentsOf: sources.appendingPathComponent("WaveformSourceLink.swift"), encoding: .utf8)) ?? ""
    let catalog = (try? Data(contentsOf: resources.appendingPathComponent("Localizable.xcstrings")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["strings"] as? [String: Any] ?? [:]
    func locales(_ key: String) -> Int { ((catalog[key] as? [String: Any])?["localizations"] as? [String: Any])?.count ?? 0 }
    let id = traceSwift.range(of: "\"traceReason_kdbPending\": String(localized: \"").flatMap { traceSwift[$0.upperBound...].split(separator: "\"").first }
    expect(id.map { locales(String($0)) } == 9, "kdb pending: the reason's string comes from cmux in 9 locales")
    expect(traceSwift.contains("WaveformTraceKDB.pending(for: waveform)") && locales("waveformTrace.kdbStillLoading") == 9,
           "kdb pending: a row slang lacks while the export runs says the compiled design is still loading (9 locales: \(locales("waveformTrace.kdbStillLoading")))")
    func body(_ text: String, after marker: String) -> String {
      guard let start = text.range(of: marker), let end = text[start.upperBound...].range(of: "\n    }\n") else { return "" }
      return String(text[start.lowerBound..<end.upperBound])
    }
    expect(body(linkSwift, after: "static func waveformReloading(").contains("WaveformTrace.waveformReloading(")
             && body(traceSwift, after: "static func waveformReloading(").contains("aliasRules.removeObject"),
           "L1: a reload clears the viewer's alias rule, so its new helper gets slang's aliases again")
    _ = await trace("close()")
  }

  /// Trace X to Root: from a value with x bits, the fan-in that brought the x, step by step, to
  /// where it was made (designs J and K, the engine's own fixtures).
  func xRootChecks() async {
    _ = await trace("close()")
    await reopen("j")
    func chain(_ q: String) async -> [String: Any]? { await trace("xRoot(\(q))") }
    func signals(_ c: [String: Any]?) -> [String] { (c?["steps"] as? [[String: Any]] ?? []).compactMap { $0["signal"] as? String } }
    func end(_ c: [String: Any]?) -> String { (c?["end"] as? [String: Any])?["code"] as? String ?? "?" }
    func why(_ c: [String: Any]?, _ i: Int) -> String {
      let st = c?["steps"] as? [[String: Any]] ?? []
      return i < st.count ? (st[i]["why"] as? [String: Any])?["code"] as? String ?? "?" : "-"
    }
    // q <= tmp, tmp = go ? a : b in the same block: the x came in on a (the blocking temp is gone
    // through, go and b have none), through dut's input port, from the testbench.
    let q = await chain("{ designPath: 'tb_j.dut.q', designPrefix: '', dumpPrefix: '', time: 20000 }")
    expect(signals(q) == ["tb_j.dut.q", "tb_j.dut.a", "tb_j.a"] && end(q) == "testbench",
           "J: q's x goes back through the temp to a, then the testbench: \(signals(q)) \(end(q))")
    expect(why(q, 0) == "start" && why(q, 1) == "only" && why(q, 2) == "only" && q?["root"] as? Int == 2,
           "J: each step says why it follows, the testbench step is the root: \(why(q, 1)) \(why(q, 2)) root \(String(describing: q?["root"]))")
    expect(q?["approximate"] as? Bool == true, "J: a chain with an approximate step (the testbench's) is approximate")
    let rows = await call("""
      const rs = [...document.querySelectorAll('#cmux-trace tr.xstep')];
      return { n: rs.length, root: rs.findIndex((r) => r.classList.contains('root')), text: document.getElementById('cmux-trace').innerText };
    """) as? [String: Any]
    let rowText = rows?["text"] as? String ?? ""
    expect(rows?["n"] as? Int == 3 && rows?["root"] as? Int == 2, "J: the panel lists the 3 steps, the root highlighted: \(String(describing: rows?["n"])) root \(String(describing: rows?["root"]))")
    expect(rowText.contains("X chain from tb_j.dut.q at 20,000") && rowText.contains("the only input with x or z") && rowText.contains("Root: the testbench sets the value.")
             && rowText.contains("approximate") && rowText.contains("j_temps.sv:20"),
           "J: the panel shows the title, why, the root's reason, trust and file:line: \(rowText.prefix(400))")
    // A step's row opens its statement and shows its signal at its time in the waveform.
    let opens = events.filter { $0["event"] as? String == "open" }.count
    let stepTime = ((q?["steps"] as? [[String: Any]])?[1]["time"] as? NSNumber)?.intValue
    _ = await call("const r = document.querySelectorAll('#cmux-trace tr.xstep')[1]; r.click(); return null")
    await waitFor("the step's signal selected at its time") {
      let sel = await self.call("return (cmuxWaveform.link.selectedSignal() || []).join('.')") as? String
      let at = await self.call("return cmuxWaveform.link.markerTime()") as? NSNumber
      return sel == "tb_j.dut.a" && at?.intValue == stepTime
    }
    let opened = events.filter { $0["event"] as? String == "open" }
    let selected = await call("return (cmuxWaveform.link.selectedSignal() || []).join('.')") as? String
    let marker = await call("return cmuxWaveform.link.markerTime()") as? NSNumber
    expect(opened.count == opens + 1 && ((opened.last?["loc"] as? [String: Any])?["line"] as? Int) != nil, "J: a step's row opens its statement")
    expect(selected == "tb_j.dut.a" && marker?.intValue == stepTime, "J: and selects its signal at its time in the waveform: \(String(describing: selected)) @\(String(describing: marker)) vs \(String(describing: stepTime))")
    // Add Chain Signals to Waveform: every step's signal gets a row.
    _ = await call("const b = document.querySelector('#cmux-trace button.xadd'); if (b) b.click(); return null")
    await sleep(600)
    let shown = await call("""
      const v = await cmuxWaveform.link.valuesAt({ time: 20000, paths: [['tb_j', 'dut', 'q'], ['tb_j', 'dut', 'a'], ['tb_j', 'a']] });
      return v.map((x) => x !== null && x !== undefined);
    """) as? [Bool]
    expect(shown == [true, true, true], "J: Add Chain Signals to Waveform shows each step's signal: \(String(describing: shown))")
    // zq <= a2 with zsel 2: a2 was never written (its only write needs zsel 3): uninitialised.
    let zq = await chain("{ designPath: 'tb_j.dut.zq', designPrefix: '', dumpPrefix: '', time: 40000 }")
    expect(signals(zq) == ["tb_j.dut.zq", "tb_j.dut.a2"] && end(zq) == "uninit" && zq?["root"] as? Int == 1,
           "J: zq's x comes from a2, never written: \(signals(zq)) \(end(zq))")
    // A value without x or z: nothing to follow.
    let go = await chain("{ designPath: 'tb_j.dut.go', designPrefix: '', dumpPrefix: '', time: 20000 }")
    let noXText = await panelText()
    expect(end(go) == "noX" && noXText.contains("has no x or z bits"), "J: a value without x: says so: \(end(go))")
    // The step budget: the chain stops there, without a root.
    _ = await call("cmuxWaveform.traceXChainSteps = 2; return null")
    let short = await chain("{ designPath: 'tb_j.dut.q', designPrefix: '', dumpPrefix: '', time: 20000 }")
    _ = await call("delete cmuxWaveform.traceXChainSteps; return null")
    expect(signals(short) == ["tb_j.dut.q", "tb_j.dut.a"] && end(short) == "budget" && (short?["root"] as? Int ?? 0) < 0,
           "J: a step budget of 2 stops after 2 steps, no root: \(signals(short)) \(end(short)) root \(String(describing: short?["root"]))")
    expect(await panelText().contains("Stopped after 2 steps"), "J: the panel says the budget stopped it")

    // K: steps show as they are found, and Cancel stops the chain.
    _ = await trace("close()")
    await reopen("k")
    lookupDelay = 0.4
    defer { lookupDelay = 0 }
    _ = await call("window.__xr = cmuxWaveform.trace.xRoot({ designPath: 'tb_k.dut.fr', designPrefix: '', dumpPrefix: '', time: 40000 }); return null")
    await waitFor("a first chain step", 15000) {
      ((await self.call("return document.querySelectorAll('#cmux-trace tr.xstep').length") as? Int) ?? 0) >= 1
    }
    let mid = await trace("state()")
    let midChain = mid?["chain"] as? [String: Any]
    expect(midChain?["running"] as? Bool == true && (midChain?["steps"] as? Int ?? 0) >= 1, "K: steps are listed while the chain runs: \(String(describing: midChain))")
    let cancelled = await call("""
      const b = document.querySelector('#cmux-trace button.xcancel');
      if (!b) return { button: false };
      b.click();
      const c = await window.__xr;
      return { button: true, end: c && c.end && c.end.code, n: c && c.steps.length };
    """) as? [String: Any]
    expect(cancelled?["button"] as? Bool == true && cancelled?["end"] as? String == "cancelled" && (cancelled?["n"] as? Int ?? 9) < 3,
           "K: Cancel stops the chain where it is: \(String(describing: cancelled))")
    expect(await panelText().contains("Cancelled."), "K: the panel says it was cancelled")
    lookupDelay = 0
    // fr went x at 15 from xa (the force at 22 kept it x): the testbench's xa.
    let fr = await chain("{ designPath: 'tb_k.dut.fr', designPrefix: '', dumpPrefix: '', time: 40000 }")
    expect(signals(fr) == ["tb_k.dut.fr", "tb_k.dut.xa", "tb_k.xa"] && end(fr) == "testbench",
           "K: fr's x comes from the testbench's xa: \(signals(fr)) \(end(fr))")
    // The chain is the same code the trace-fsdb benchmark runs (its xchain mode calls xRoot).
    let bench = (try? String(contentsOf: assetRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/waveform-viewer-checks/trace-fsdb/main.swift"), encoding: .utf8)) ?? ""
    expect(bench.contains("cmuxWaveform.trace.xRoot("), "trace-fsdb's X chain calls the page's xRoot")
    _ = await trace("close()")
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
    if body["event"] as? String == "update" { updates += 1; return }
    guard let id = (body["id"] as? NSNumber)?.intValue else { return }
    switch body["event"] as? String {
    case "resolve":
      if let resolveError { answer(id, ok: false, error: "resolve", message: resolveError); return }
      let path = (body["dumpPath"] as? [String] ?? []).joined(separator: ".")
      if holdResolves { heldResolves.append((id, path)); return }
      if let resolveAnswer { answer(id, ok: true, result: resolveAnswer); return }
      answer(id, ok: true, result: ["designPath": path, "designPrefix": "", "dumpPrefix": ""])
    case "model":
      modelRequests += 1
      if noDesign {
        answer(id, ok: false, error: "noDesign", message: "Open a design first.")
        return
      }
      if let currentDesign, body["design"] as? String != currentDesign {
        answer(id, ok: false, error: "designChanged", message: "The design changed since this trace began. Trace again.")
        return
      }
      let path = body["path"] as? String ?? ""
      let instances = models["instances"] as? [String: Any] ?? [:]
      if body["cmd"] as? String == "instance" {
        answer(id, ok: true, result: instances[path] ?? NSNull())
      } else if body["cmd"] as? String == "writers" {
        answer(id, ok: true, result: [String]())
      } else {
        let best = instances.keys.filter { path == $0 || path.hasPrefix($0 + ".") }.max { $0.count < $1.count }
        let result: Any = best.map { ["instance": $0, "name": String(path.dropFirst($0.count + 1))] } ?? NSNull()
        if lookupDelay > 0 {
          DispatchQueue.main.asyncAfter(deadline: .now() + lookupDelay) { [self] in answer(id, ok: true, result: result) }
        } else {
          answer(id, ok: true, result: result)
        }
      }
    case "engine":
      engineRequests += 1
      let k = engineLog.count, gen = engineLogGen
      engineLog.append((body["signal"] as? String ?? "", Date().timeIntervalSince(engineEpoch), nil, body["background"] as? Bool == true))
      if body["background"] as? Bool == true { engineBackground.append(body["signal"] as? String ?? "") }
      if engineHang { return }
      engineInFlight += 1
      engineMostInFlight = max(engineMostInFlight, engineInFlight)
      let result: [String: Any] = (body["signal"] as? String).flatMap { engineAnswers[$0] } ?? engineAnswer ?? ["state": "none"]
      let done = { [self] in
        engineInFlight -= 1
        if gen == engineLogGen, k < engineLog.count { engineLog[k].answered = Date().timeIntervalSince(engineEpoch) }
        answer(id, ok: true, result: result)
      }
      if engineDelay > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + engineDelay) { done() }
      } else {
        done()
      }
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
    window.cmuxTraceChecks = {};
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
      openDump("c.plain.vcd")
    } else if type == "opened" {
      opened += 1
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

  /// The English page strings cmux sends (WaveformTrace.pageStrings), the ones the checks read.
  static let pageStrings: [String: String] = [
    "netlist": "Netlist", "loading": "Loading…", "openFailed": "Could not open", "addSignal": "Add",
    "traceTitle": "Trace Driver", "traceDriverMenu": "Trace Driver at Marker", "traceDriverKey": "⌃T",
    "traceNoSignal": "Select a signal in the waveform first.", "traceNoMarker": "Place the marker at the time to trace first.",
    "traceFailed": "Driver tracing failed.", "traceResolving": "Finding %@ in the design…", "traceRunning": "Tracing %1$@ at %2$@…",
    "traceStepTitle": "%1$@ = %2$@ at %3$@", "traceFanin": "Fan-in (click to trace)", "traceTrust_exact": "exact",
    "traceKindProc": "%@ block", "traceKindAssign": "Continuous assignment", "traceActivation": "%1$@ at %2$@, inputs sampled at %3$@",
    "traceEngineCmux": "Traced by cmux (slang design model)", "traceEngineVerdi": "Traced by Verdi, re-executed by cmux",
    "traceVerdiStarting": "Verdi is starting on the host", "traceVerdiChecking": "Verdi is checking…",
    "traceVerdiTimedOut": "Verdi: not checked (timed out)", "traceVerdiLarge": "Verdi: not checked (large signal)", "traceVerdiLastChange": "Verdi (driver of the last change):",
    "traceThroughPorts": "through the ports of %@", "traceVerdiUnavailable": "Verdi not used: %@",
    "traceVerdiUnavailable_noKDB": "Verdi not used: no KDB next to the FSDB (compile with vcs -kdb)",
    "traceXRootMenu": "Trace X to Root", "traceXRootKey": "⌃⇧T", "traceXTitle": "X chain from %1$@ at %2$@",
    "traceXRunning": "Following the x back… (%@ steps)", "traceXCancel": "Cancel", "traceXAdd": "Add Chain Signals to Waveform",
    "traceXRootBadge": "root", "traceXWhy_start": "the value traced", "traceXWhy_only": "the only input with x or z",
    "traceXWhy_earliest": "the earliest x or z of %@ inputs", "traceXEnd_noXInput": "Root: this statement makes the x (no input has x or z).",
    "traceXEnd_uninit": "Root: never written since the start (uninitialised storage or a declaration).",
    "traceXEnd_testbench": "Root: the testbench sets the value.", "traceXEnd_input": "Root: an input of the top level.",
    "traceXEnd_force": "Root: a force or deposit from outside the instance.", "traceXEnd_loop": "Stopped: the x goes round a loop through %@.",
    "traceXEnd_budget": "Stopped after %@ steps (the step limit).", "traceXEnd_failed": "Stopped: a step could not be traced.",
    "traceXEnd_cancelled": "Cancelled.", "traceXEnd_noX": "%@ has no x or z bits at this time.",
    "traceTrust_approximate": "approximate", "traceTrust_computed": "computed",
    "traceBuildTitle": "Building the design model on %@", "traceBuildTitleLocal": "Building the design model on this Mac",
    "traceBuildStage_upload": "Upload the model's sources (%@)", "traceBuildStage_fetch": "Download slang and its libraries",
    "traceBuildStage_configure": "Configure (CMake)", "traceBuildStage_compile": "Compile", "traceBuildStage_install": "Install",
    "traceBuildStage_load": "Loading the design", "traceBuildElapsed": "%@ so far", "traceBuildOnce": "Built once per host and cmux version.",
    "traceBuildWhat": "What is being built?", "traceBuildFailedTitle": "The design model could not be built on %@",
    "traceBuildFailedTitleLocal": "The design model could not be built on this Mac", "traceBuildLog": "Last lines of the build log:",
    "traceBuildRetry": "Retry",
    "traceCompiledOnly": "Drivers come from the compiled design (KDB); values aren't evaluated.",
    "traceCompiledOnly_notInSlang": "Slang's design model doesn't have this instance (its module may be in a file it didn't read).",
    "traceCompiledOnly_otherModule": "Slang's design model has another module at this instance, so its statements aren't used.",
    "traceCompiledWrites": "Written at:",
    "traceCompiledNoWrites": "The compiled design has no statement writing it here (it is driven through a port, or is an input).",
    "traceReason_kdbDiffers": "slang’s design differs from the compiled design (KDB) here, so its statements may not be what ran: %@.",
    "traceReason_kdbPending": "The compiled design (KDB) is still loading, so this was traced with slang’s design.",
    "traceReason_kdbNotChecked": "This instance was not checked against the compiled design (KDB), so slang’s statements may not be what ran.",
  ]

  /// How many times the page said a dump opened.
  var opened = 0
  /// Opens `dump` (in trace/dumps) as cmux does, with the page strings.
  func openDump(_ dump: String) {
    let waveURL = traceDir.appendingPathComponent("dumps/\(dump)")
    let fileURL = scheme.serve(fileURL: waveURL)
    let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
    let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
    let json = String(data: try! JSONSerialization.data(withJSONObject: Harness.pageStrings), encoding: .utf8)!
    web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(json)})")
  }
  /// Another design: its models answer, its Icarus dump is opened (the checks wait for it).
  func reopen(_ design: String) async {
    let data = try! Data(contentsOf: traceDir.appendingPathComponent("models/\(design).json"))
    models = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let before = opened
    openDump("\(design).icarus.vcd")
    await waitFor("\(design) opened", 10000) { self.opened > before }
    await sleep(500)
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
DispatchQueue.main.asyncAfter(deadline: .now() + 150) { print("timeout"); exit(1) }
app.run()
