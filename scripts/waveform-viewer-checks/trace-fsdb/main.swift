// Driver tracing on a remote FSDB (run.sh trace-fsdb): opens the dump over ssh through the real
// WaveformFSDBHelper (under nice on the host) in an off-screen WKWebView and traces with the page
// (cmux-trace-ui.js, cmux-trace.js), the harness answering the model requests as cmux would from a
// cmux-sv-model `--once '*'` file. Traces every signal of one instance at a time, then follows each
// step's fan-in two more steps, and prints steps by trust and driver kind, the reasons, and timings.
// Fails when a trace throws, or a signal of the design gets no driver at all.
// TRACE_FSDB_VERDI=1 also runs the Verdi engine on the host as cmux does (verdi-trace/, a warm
// `verdi -nogui` session found through the KDB next to the FSDB), answers the page's engine
// requests from it, and counts how the two engines' answers compare. TRACE_FSDB_UNDRIVEN=a,b names
// signals the design leaves undriven (no driver is the right answer for them). TRACE_FSDB_PROFILE=1 prints
// each step's whole-signal reads (count, signals, how many were read before, changes, summed time, most at once),
// and on helper v2 its windowed requests by command (count, summed time).
// TRACE_FSDB_V2=1 runs the helpers as cmux does by default (waveform.fsdbLoading auto: helper v2,
// <assetRoot>/fsdb-helper-v2, else v1); TRACE_FSDB_HOME=<dir> installs them under <dir> on the host
// instead of the user's home (so a test never replaces the helpers in use). Default: helper v1.
// Usage: trace-fsdb <assetRoot> <helperRoot> <sshHost> <remote.fsdb> <model.json> <instance> <time> <out.png>
import AppKit
import WebKit

// Line-buffered: a run cut short keeps what it printed.
setvbuf(stdout, nil, _IOLBF, 0)
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
  var verdi: SVModelSidecar?
  var verdiReady = false

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
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map((x) => (x && x.stack ? String(x) + ' ' + x.stack : String(x))).join(' ')); } catch(e){}; o.apply(console, a); }; }
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
    let env = ProcessInfo.processInfo.environment
    let home = env["TRACE_FSDB_HOME"].map { "HOME=" + shellQuoted($0) + " " } ?? ""
    let installs = env["TRACE_FSDB_V2"] == "1"
      ? WaveformFSDBHelper.installs(v2Root: assetRoot.appendingPathComponent("fsdb-helper-v2", isDirectory: true), v1Root: helperRoot, loading: .auto)
      : [WaveformFSDBHelper.Install(protocolVersion: 1, resourceRoot: helperRoot)]
    print("[helper] \(installs.map { "v\($0.protocolVersion)" }.joined(separator: ", then "))\(home.isEmpty ? "" : ", own install folder")")
    helper = WaveformFSDBHelper(sshArguments: { cmd in
      ["-o", "BatchMode=yes", "-T", "--", sshHost, home + "exec nice -n 10 bash -c " + shellQuoted(cmd)]
    }, installs: installs) { status in print("[status]", status) }
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  /// What cmux answers the page's engine requests (WaveformTraceVerdi.answer).
  func answerEngine(_ id: Int, _ body: [String: Any]) {
    guard let verdi, verdiReady, let signal = body["signal"] as? String, let t = (body["time"] as? NSNumber)?.int64Value else {
      answer(id, result: ["state": "none"])
      return
    }
    Task { @MainActor in
      do {
        let r = try await verdi.request(["cmd": "active", "signal": signal, "time": t], timeout: 120)
        self.answer(id, result: ["state": "ready", "scope": r["scope"] ?? "", "file": r["file"] ?? "", "line": r["line"] ?? 0])
      } catch SVModelSidecar.Failure.request(code: "notFound", message: let message) {
        self.answer(id, result: ["state": "ready", "notFound": true, "message": message])
      } catch {
        self.answer(id, result: ["state": "unavailable", "reason": "failed", "message": "\(error)"])
      }
    }
  }

  /// Starts the Verdi session and waits for it, as cmux does in the background.
  func startVerdi() async {
    guard ProcessInfo.processInfo.environment["TRACE_FSDB_VERDI"] == "1",
          let scripts = VerdiTraceLaunch.scripts(in: assetRoot.appendingPathComponent("verdi-trace", isDirectory: true)) else { return }
    let host = sshHost
    let session = SVModelSidecar(
      runner: { command in .init(executable: "/usr/bin/ssh", arguments: ["-o", "BatchMode=yes", "-T", "--", host, "sh -c '\(command)'"]) },
      launchCommand: VerdiTraceLaunch.command(launcher: scripts.launcher, serve: scripts.serve, fsdbPath: remoteFile),
      installCommand: nil
    )
    verdi = session
    let t0 = Date()
    do {
      let info = try await session.request(["cmd": "info"], timeout: 300)
      verdiReady = VerdiTraceLaunch.unitsMatch(info)
      print(String(format: "[verdi] ready in %.1f s, units %@ / %@", Date().timeIntervalSince(t0), "\(info["fileUnit"] ?? "")", "\(info["windowUnit"] ?? "")"))
      expect(verdiReady, "Verdi's window unit is the FSDB's")
    } catch {
      print("[verdi] unavailable:", error)
      expect(false, "the Verdi engine starts")
    }
  }

  func answer(_ id: Int, result: Any) {
    Task { @MainActor in
      _ = await call("cmuxWaveform.trace.reply(argument); return null", ["argument": ["id": id, "ok": true, "result": result]])
    }
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else { print("[\(m.name)]", m.body); return }
    if type != "trace" && type != "log" && type != "event" { print("[page]", type, (body["message"] as? String ?? "").prefix(200)) }
    if type == "trace", body["event"] as? String == "engine", let id = (body["id"] as? NSNumber)?.intValue {
      answerEngine(id, body)
    } else if type == "trace" {
      guard let id = (body["id"] as? NSNumber)?.intValue, body["event"] as? String == "model" else { return }
      let path = body["path"] as? String ?? ""
      if body["cmd"] as? String == "instance" {
        answer(id, result: instances[path] ?? NSNull())
      } else if body["cmd"] as? String == "writers" {
        answer(id, result: Self.writers(of: path, in: instances))
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
      Task { await self.startVerdi(); await self.run() }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      failures += 1
      finish()
    }
  }

  /// What cmux-sv-model's `writers` answers: the other instances with $abs: lvalues into `path`.
  static func writers(of path: String, in instances: [String: Any]) -> [String] {
    instances.compactMap { key, model -> String? in
      guard key != path, let data = try? JSONSerialization.data(withJSONObject: model),
            String(decoding: data, as: UTF8.self).contains("\"name\":\"$abs:\(path).") else { return nil }
      return key
    }.sorted()
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
    var verdiTimes: [Double] = []
    var noDriver: [String] = []
    // Signals the design itself leaves undriven (TRACE_FSDB_UNDRIVEN, comma-separated): "none" is right for them.
    let undriven = Set((ProcessInfo.processInfo.environment["TRACE_FSDB_UNDRIVEN"] ?? "").split(separator: ",").map(String.init))
    var knownUndriven: [String] = []
    var engines: [String: Int] = [:]
    var errors = 0
    // TRACE_FSDB_PROFILE=1: per step, the whole-signal reads it made (count, signals, changes, time).
    let profile = ProcessInfo.processInfo.environment["TRACE_FSDB_PROFILE"] == "1"
    while !queue.isEmpty, times.count < (Int(ProcessInfo.processInfo.environment["TRACE_FSDB_MAX_STEPS"] ?? "") ?? 400) {
      let (path, t, depth) = queue.removeFirst()
      guard seen.insert("\(path)@\(t)").inserted else { continue }
      if profile {
        // Wrap the backend's whole-signal reads (and the engine requests) once: count, time, changes.
        _ = await call("""
          const b = cmuxWaveform.host.currentBackend;
          if (!b.__prof) {
            const p = b.__prof = { calls: 0, signals: 0, changes: 0, ms: 0, most: 0, now: 0, again: 0, againChanges: 0, seen: new Set() };
            window.__traceProf = p;
            const own = b.changes.bind(b);
            b.changes = async (vars, max) => {
              const t = performance.now(); p.calls++; p.signals += vars.length; p.now++; p.most = Math.max(p.most, p.now);
              try {
                const r = await own(vars, max);
                r.forEach((c, k) => {
                  p.changes += c ? c.length : 0;
                  if (p.seen.has(vars[k].signalId)) { p.again++; p.againChanges += c ? c.length : 0; } else { p.seen.add(vars[k].signalId); }
                });
                return r;
              }
              finally { p.now--; p.ms += performance.now() - t; }
            };
            if (b.v2) {
              const v2 = b.v2.bind(b);
              b.v2 = async (req) => {
                const t = performance.now();
                try { return await v2(req); }
                finally { const c = p.v2[req.cmd] = p.v2[req.cmd] || { n: 0, ms: 0 }; c.n++; c.ms += performance.now() - t; }
              };
            }
          }
          Object.assign(window.__traceProf, { calls: 0, signals: 0, changes: 0, ms: 0, most: 0, again: 0, againChanges: 0, v2: {} });
          return null
          """)
      }
      let t0 = Date()
      let shown = await call("return await cmuxWaveform.trace.driverOfDesign(argument)",
                             ["argument": ["designPath": path, "designPrefix": "", "dumpPrefix": "", "time": t]]) as? [String: Any]
      let ms = Date().timeIntervalSince(t0) * 1000
      // The step as shown is what is timed; Verdi's fill-in (after it) is waited for, timed apart.
      var step = shown
      if shown != nil, let settled = await call("const t = cmuxWaveform.trace; if (!t.settled) { return null; } const t0 = performance.now(); const st = (await t.settled()).step; return { st, ms: performance.now() - t0 }") as? [String: Any] {
        step = settled["st"] as? [String: Any] ?? shown
        verdiTimes.append(settled["ms"] as? Double ?? 0)
      }
      guard let step else { errors += 1; print("ERROR tracing \(path) @\(t)"); continue }
      times.append(ms)
      if let error = step["error"] as? String { kinds["error:" + error, default: 0] += 1; continue }
      trust[step["trust"] as? String ?? "?", default: 0] += 1
      let kind = (step["driver"] as? [String: Any])?["kind"] as? String ?? "?"
      kinds[kind, default: 0] += 1
      if kind == "none" { if undriven.contains(path) { knownUndriven.append(path) } else { noDriver.append(path) } }
      for r in step["reasons"] as? [[String: Any]] ?? [] { reasons[r["code"] as? String ?? "?", default: 0] += 1 }
      if let e = step["engine"] as? [String: Any] {
        let name = e["name"] as? String ?? "?"
        let how = e["verdiNotFound"] as? Bool == true ? "notFound" : e["verdiDiffers"] as? Bool == true ? "differs"
          : (step["via"] as? [Any])?.isEmpty == false ? "throughPorts" : name == "verdi" ? "agrees" : (e["verdi"] as? String ?? "none")
        engines[how, default: 0] += 1
        if how == "differs", engines[how, default: 0] <= 12 {
          let ours = (step["stmt"] as? [String: Any])?["loc"] as? [String: Any]
          let theirs = e["verdiLoc"] as? [String: Any]
          print("[verdi differs] \(path) @\(t): cmux \((ours?["file"] as? String ?? "").split(separator: "/").last ?? ""):\(ours?["line"] ?? "") verdi \((theirs?["file"] as? String ?? "").split(separator: "/").last ?? ""):\(theirs?["line"] ?? "") since \(step["since"] ?? "")")
        }
      }
      if profile, let p = await call("const p = window.__traceProf; return p ? { calls: p.calls, signals: p.signals, changes: p.changes, ms: p.ms, most: p.most, again: p.again, againChanges: p.againChanges, v2: Object.entries(p.v2 || {}).map(([k, c]) => `${k} ${c.n} (${Math.round(c.ms)} ms)`).join(', ') } : null") as? [String: Any] {
        if let v2 = p["v2"] as? String, !v2.isEmpty { print("[profile] \(path): v2 \(v2)") }
        print(String(format: "[profile] %@: %d reads, %d signals (%d read before, %d changes), %d changes, %.0f ms in reads (summed), at most %d at once",
                     path, p["calls"] as? Int ?? 0, p["signals"] as? Int ?? 0, p["again"] as? Int ?? 0, p["againChanges"] as? Int ?? 0,
                     p["changes"] as? Int ?? 0, p["ms"] as? Double ?? 0, p["most"] as? Int ?? 0))
      }
      if times.count <= 12 || ms > 2000 {
        let src = ((step["stmt"] as? [String: Any])?["src"] as? String ?? "").prefix(70)
        print(String(format: "%7.1f ms  %@ @%d = %@  %@ [%@] %@", ms, path, t, step["value"] as? String ?? "?", kind, step["trust"] as? String ?? "?", String(src)))
      }
      if depth < 2 {
        // The shown step's fan-in (ours), so Verdi on and off trace the same signals.
        for f in (shown?["fanin"] ?? step["fanin"]) as? [[String: Any]] ?? [] {
          if let p = f["path"] as? String, let ft = (f["time"] as? NSNumber)?.intValue { queue.append((p, ft, depth + 1)) }
        }
      }
    }
    let sorted = times.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    print("steps: \(times.count), trust \(trust), drivers \(kinds)")
    print("reasons: \(reasons)")
    print("engines: \(engines)")
    print(String(format: "time per step: median %.1f ms, p90 %.1f ms, max %.1f ms, total %.1f s", median,
                 sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last ?? 0, times.reduce(0, +) / 1000))
    if !verdiTimes.isEmpty, verdiTimes.contains(where: { $0 > 0 }) {
      let v = verdiTimes.sorted()
      print(String(format: "Verdi fill-in after the shown step: median %.1f ms, max %.1f ms", v[v.count / 2], v.last ?? 0))
    }
    expect(errors == 0, "no trace threw (\(errors))")
    if !knownUndriven.isEmpty { print("undriven in the design (TRACE_FSDB_UNDRIVEN):", knownUndriven) }
    expect(noDriver.isEmpty, "every traced design signal has a driver: \(noDriver.prefix(8))")
    expect(times.count > 0, "steps were traced")
    finish()
  }

  func finish() {
    print(failures == 0 ? "TRACE FSDB CHECKS PASSED" : "TRACE FSDB CHECKS FAILED: \(failures)")
    helper.stop()
    verdi?.stop()
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
DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["TRACE_FSDB_TIMEOUT"] ?? "") ?? 840)) { print("timeout"); exit(1) }
app.run()
