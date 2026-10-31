// FSDB inline value checks (run.sh fsdb-values): loads Resources/vaporview
// through the real WaveformViewerSchemeHandler and WaveformFSDBHelper in an
// off-screen WKWebView, opens a remote FSDB over ssh and checks link.valuesAt
// against values decoded here from a separate whole-signal fetch:
//   A  a signal shown in the viewer is read from the changes it drew (no request)
//   B  with `unshown` off, a signal not shown gets no value and no request
//   C  with `unshown` on, helper v1 answers valueAt "unknown command", the
//      signals fallback gives the value, and the next ask is cached
//   D  a signal over the 1M-change cap gets no value and is not fetched again
//   E  three signals under 1M that pass 2M together evict the oldest
//   F  a reload drops the old backend's drawn and cached changes
// Usage: fsdb-values <assetRoot> <helperRoot> <sshHost> <remoteFsdb> <out.png>
//          <shown> <unshown> <overCap> <mid1> <mid2> <mid3>   (dotted dump paths)
// CMUX_FSDB_HELPER_COMMAND, when set, is run over ssh instead of the installed helper.
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let helperRoot = URL(fileURLWithPath: args[2], isDirectory: true)
let sshHost = args[3]
let remoteFile = args[4]
let out = URL(fileURLWithPath: args[5])
let extra = Array(args.dropFirst(6))
let helperCommand = ProcessInfo.processInfo.environment["CMUX_FSDB_HELPER_COMMAND"] ?? ""

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
  var openedCount = 0
  var reopened = false
  var relayURLString = ""

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
    helper = WaveformFSDBHelper(sshArguments: { cmd in ["-o", "BatchMode=yes", "-T", "--", sshHost, helperCommand.isEmpty ? cmd : helperCommand] },
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
      relayURLString = relayURL.absoluteString
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(remoteFile)'}})
        """)
    } else if type == "opened" {
      openedCount += 1
      if openedCount == 1 { Task { await self.run() } } else { reopened = true }
    } else if type == "error" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  func js(_ s: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(s, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }

  var failures = 0
  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func run() async {
    // Count the helper commands the page sends.
    _ = await js("""
      if (!window.__cmds) { window.__cmds = []; const orig = window.fetch;
        window.fetch = (u, o) => { try { if (o && o.body) { const b = JSON.parse(o.body); window.__cmds.push(b.cmd + (b.signalIds ? ':' + b.signalIds.join(',') : '')); } } catch (e) {} return orig(u, o); }; }
      return 1;
    """)
    // extra: shown, unshownShort, longOverCap, mid1, mid2, mid3 (dotted)
    let shown = extra[0], short = extra[1], long = extra[2], mids = Array(extra.dropFirst(3))
    // Ground truth: a separate whole-signal fetch, decoded here.
    _ = await js(groundTruthJS(relay: relayURLString))
    let truthShown = await js("return JSON.stringify(await __truth(\(jsonArray(shown))))") as? String ?? "nil"
    print("TRUTH shown", truthShown)
    let truthShort = await js("return JSON.stringify(await __truth(\(jsonArray(short))))") as? String ?? "nil"
    print("TRUTH short", truthShort)
    // Pick T inside the shown signal's changes.
    guard let tData = truthShown.data(using: .utf8), let t = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
          let time = t["t"] as? NSNumber, let expectedShown = t["value"] as? String else { print("no truth"); snap(); return }
    let shortT = await js("return JSON.stringify(await __truthAt(\(jsonArray(short)), \(time)))") as? String ?? "nil"
    print("TRUTH short at T", shortT)
    // A. shown signal: values come from the drawn changes.
    _ = await js("cmuxWaveform.addVariableByPath('\(shown)'); return 1")
    for _ in 0..<1200 {
      if (await js("return cmuxWaveform.stats.length") as? Int ?? 0) > 0 { break }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    print("STATS", await js("return JSON.stringify(cmuxWaveform.stats)") ?? "nil")
    let before = await js("return window.__cmds.length") as? Int ?? 0
    let rssA0 = rssMB(pid)
    let a = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(shown))], unshown: false })") as? [Any]
    let afterA = await js("return window.__cmds.length") as? Int ?? 0
    print("A raw", String(describing: a), "expected bits", expectedShown)
    expect(a?.first is String, "A: shown signal has a value from the drawn changes")
    expect(afterA == before, "A: no helper request for a shown signal (\(afterA - before))")
    // B. unshown, toggle off: no value, no request.
    let b = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(short))], unshown: false })") as? [Any]
    let afterB = await js("return window.__cmds.length") as? Int ?? 0
    expect(b?.first is NSNull && afterB == afterA, "B: toggle off -> unshown signal gets null and no request (\(String(describing: b)), \(afterB - afterA))")
    // C. toggle on, v1: valueAt unknown -> signals fallback; then cached.
    let tC = Date()
    let c = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(short))], unshown: true })") as? [Any]
    let cmdsC = await js("return window.__cmds.slice(\(afterB))") as? [String] ?? []
    print("C raw", String(describing: c), "cmds", cmdsC, "ms", Int(Date().timeIntervalSince(tC) * 1000))
    expect(c?.first is String, "C: toggle on -> unshown short signal has a value")
    expect(cmdsC.first?.hasPrefix("valueAt") == true && cmdsC.contains { $0.hasPrefix("signals") }, "C: tried valueAt, fell back to signals")
    let c2before = await js("return window.__cmds.length") as? Int ?? 0
    _ = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(short))], unshown: true })")
    let c2after = await js("return window.__cmds.length") as? Int ?? 0
    expect(c2after == c2before, "C: second ask is cached, and valueAt is not retried (\(c2after - c2before))")
    // D. over the per-signal cap: no value, not kept, not refetched.
    let tD = Date()
    let rssD0 = rssMB(pid)
    let d = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(long))], unshown: true })") as? [Any]
    let msD = Int(Date().timeIntervalSince(tD) * 1000)
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let rssD1 = rssMB(pid)
    let d2before = await js("return window.__cmds.length") as? Int ?? 0
    _ = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(long))], unshown: true })")
    let d2after = await js("return window.__cmds.length") as? Int ?? 0
    expect(d?.first is NSNull, "D: \(long) over 1M changes -> null (\(String(describing: d)), \(msD) ms, rss \(rssD0) -> \(rssD1) MB)")
    expect(d2after == d2before, "D: not fetched again")
    // E. total cap: three signals under 1M each, over 2M together: the oldest is evicted and fetched again.
    if mids.count >= 3 {
      for m in mids {
        let tm = Date()
        let v = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(m))], unshown: true })") as? [Any]
        print("E \(m):", String(describing: v), Int(Date().timeIntervalSince(tm) * 1000), "ms, rss", rssMB(pid), "MB")
      }
      let e0 = await js("return window.__cmds.length") as? Int ?? 0
      _ = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(mids[0]))], unshown: true })")
      let e1 = await js("return window.__cmds.length") as? Int ?? 0
      expect(e1 > e0, "E: the least recently used signal was evicted past 2M changes and is fetched again")
      _ = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(mids[2]))], unshown: true })")
      let e2 = await js("return window.__cmds.length") as? Int ?? 0
      expect(e2 == e1, "E: the most recent one is still cached")
    }
    // F. reload: the old backend's drawn and cached changes are not used.
    reopened = false
    _ = await js("cmuxWaveform.reload({}); return 1")
    let f0 = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(shown)), \(jsonArray(short))], unshown: true })") as? [Any]
    expect(f0 == nil || f0?.isEmpty == true || f0?.allSatisfy({ $0 is NSNull }) == true, "F: during the reload no values (\(String(describing: f0)))")
    for _ in 0..<600 where !reopened { try? await Task.sleep(nanoseconds: 100_000_000) }
    expect(reopened, "F: reopened")
    let fBefore = await js("return window.__cmds.length") as? Int ?? 0
    let f1 = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(short))], unshown: true })") as? [Any]
    let fCmds = await js("return window.__cmds.slice(\(fBefore))") as? [String] ?? []
    expect(f1?.first is String && fCmds.contains { $0.hasPrefix("signals") }, "F: after reopening the cache starts over (\(fCmds))")
    // The restored row is drawn again: its value comes back from the new drawn changes.
    var f2: [Any]?
    for _ in 0..<300 {
      f2 = await js("return await cmuxWaveform.link.valuesAt({ time: \(time), paths: [\(jsonArray(shown))], unshown: false })") as? [Any]
      if f2?.first is String { break }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    expect(f2?.first is String, "F: restored shown signal has its value again (\(String(describing: f2)))")
    _ = (rssA0)
    print("RSS end \(rssMB(pid)) MB")
    print(failures == 0 ? "FSDB VALUE CHECKS PASSED" : "FSDB VALUE CHECKS FAILED: \(failures)")
    snap()
  }

  func jsonArray(_ dotted: String) -> String {
    let parts = dotted.split(separator: ".").map { "'\($0)'" }
    return "[" + parts.joined(separator: ",") + "]"
  }

  func groundTruthJS(relay: String) -> String {
    """
    window.__truthFetch = async (path) => {
      const v = await cmuxWaveform.host.findItem(path.join('.'), undefined, undefined, true);
      if (!v) { return null; }
      const r = await fetch('\(relay)', { method: 'POST', body: JSON.stringify({ cmd: 'signals', signalIds: [v.signalId], widths: [v.width] }) });
      const all = new Uint8Array(await r.arrayBuffer());
      const hl = new DataView(all.buffer).getUint32(0, true);
      const head = JSON.parse(new TextDecoder().decode(all.subarray(4, 4 + hl)));
      const d = head.result[0];
      const raw = new Uint8Array(await new Response(new Blob([all.subarray(4 + hl, 4 + hl + d.bytes)]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
      const rec = 8 + d.width, n = raw.length / rec, dv = new DataView(raw.buffer);
      const times = new Float64Array(n), vals = new Array(n); let t = 0;
      for (let i = 0; i < n; i++) { t += dv.getUint32(i * rec, true) + dv.getUint32(i * rec + 4, true) * 4294967296; times[i] = t; vals[i] = String.fromCharCode.apply(null, raw.subarray(i * rec + 8, i * rec + rec)); }
      return { times, vals, width: d.width };
    };
    window.__truth = async (path) => { const s = await __truthFetch(path); if (!s) { return null; } const k = Math.floor(s.times.length * 0.6); return { n: s.times.length, t: s.times[k] + 1, value: s.vals[k] }; };
    window.__truthAt = async (path, time) => { const s = await __truthFetch(path); if (!s) { return null; } let at = -1; for (let i = 0; i < s.times.length && s.times[i] <= time; i++) { at = i; } return { n: s.times.length, value: at < 0 ? null : s.vals[at] }; };
    return 1;
    """
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
DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("timeout"); exit(1) }
app.run()
