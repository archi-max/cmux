// Windowed FSDB viewing (run.sh windowed): the protocol-v2 helper path end to end on this
// Mac, no SSH host. The real WaveformFSDBHelper starts mock-helper-v2.cjs through its own
// launch command, with `/bin/sh` in place of `/usr/bin/ssh` and a scratch HOME holding the
// install folders, then:
//   relay   protocol header, partial replies kept pending, page-id cancel (also before the
//           request arrives, and of an unknown id), v1 fallback when the v2 build fails
//   page    the bundled page in an off-screen WKWebView through the real scheme handler:
//           v2 opens windowed (set-windowing), rows draw from windows, small signals load
//           whole (hybrid), next edge, inline values and the debugger work on windowed rows;
//           loading = whole runs the v1 helper with no windowing
// Usage: windowed <assetRoot> <v2HelperRoot> <v1HelperRoot> <mock.cjs> <scratch> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let v2Root = URL(fileURLWithPath: args[2], isDirectory: true)
let v1Root = URL(fileURLWithPath: args[3], isDirectory: true)
let mock = args[4]
let scratch = URL(fileURLWithPath: args[5], isDirectory: true)
let out = URL(fileURLWithPath: args[6])
let dump = "synth:ms=1,buses=2,wide=1"
nonisolated(unsafe) var failures = 0

func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func machine() -> String {
  var u = utsname(); uname(&u)
  return withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// A scratch HOME with the given installs in place, as build.sh would leave them; each
/// launcher runs the mock with its replies on fd 3.
func makeHome(_ name: String, installs: [(cache: String, root: URL, files: [String], launcher: String)]) throws -> URL {
  let home = scratch.appendingPathComponent(name, isDirectory: true)
  let fm = FileManager.default
  for i in installs {
    let dir = home.appendingPathComponent(".cache/cmux/\(i.cache)/\(WaveformFSDBHelper.cachedVersion(of: i.root))-\(machine())", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in i.files {
      let url = dir.appendingPathComponent(f)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url)
    }
    let script = "#!/bin/bash\nexec node \(shellQuoted(mock)) --latency 20 --jitter 10 \"$@\" 3>&1 1>&2\n"
    try Data(script.utf8).write(to: dir.appendingPathComponent(i.launcher))
  }
  try fm.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

let v2Install = (cache: "fsdb-helper-v2", root: v2Root, files: ["addon/build/Release/fsdb_reader.node"], launcher: "cmux-helper-v2.sh")
let v1Install = (cache: "fsdb-helper", root: v1Root, files: ["fsdb_reader.node"], launcher: "fsdb-helper.sh")

/// `/bin/sh -c` stands in for `ssh host`: same remote command, run here with HOME set.
func localShell(home: URL) -> WaveformFSDBHelper.SSHArguments {
  let h = home.path
  return { command in ["-c", "HOME=\(shellQuoted(h)); export HOME; \(command)"] }
}

func makeHelper(home: URL, loading: WaveformFSDBHelper.Loading, v2Root: URL = v2Root) -> WaveformFSDBHelper {
  WaveformFSDBHelper(sshArguments: localShell(home: home),
                     installs: WaveformFSDBHelper.installs(v2Root: v2Root, v1Root: v1Root, loading: loading),
                     executable: URL(fileURLWithPath: "/bin/sh")) { status in print("[status]", status) }
}

func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func header(_ r: WaveformSchemeResponse) -> [String: Any] {
  var body = r.body
  if r.headers["Content-Type"] == "application/octet-stream" {
    let n = body.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
    body = body.subdata(in: 4..<(4 + n))
  }
  return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
}

// MARK: Relay

func relayChecks() async throws {
  let home = try makeHome("relay", installs: [v2Install, v1Install])
  let helper = makeHelper(home: home, loading: .auto)
  defer { helper.stop() }
  let fail: @Sendable (Error) -> String = { "\($0)" }
  let open = await helper.response(for: json(["cmd": "open", "file": dump, "id": 1]), failureMessage: fail)
  expect(header(open)["result"] != nil, "v2 open through the relay: \(header(open).keys.sorted())")
  expect(open.headers[WaveformFSDBHelper.protocolHeader] == "2", "open reply names protocol 2: \(String(describing: open.headers[WaveformFSDBHelper.protocolHeader]))")

  // searchAll streams partial lines first; the POST resolves with the final one.
  let all = await helper.response(for: json(["cmd": "searchAll", "value": "1", "t": 0, "dir": 1, "id": 2]), failureMessage: fail)
  let h = header(all)
  expect(h["final"] as? Bool == true && h["partial"] == nil, "searchAll resolves with the final reply, not a partial: \(h)")
  let after = await helper.response(for: json(["cmd": "valueAt", "signalIds": [0], "t": 5, "id": 3]), failureMessage: fail)
  expect((header(after)["result"] as? [String: Any])?["values"] != nil, "the request after searchAll gets its own reply: \(header(after))")

  // cancel {id: page id} reaches the helper's request (whose id cmux chose).
  async let slow = helper.response(for: json(["cmd": "sleep", "ms": 4000, "id": 41]), failureMessage: fail)
  try await Task.sleep(nanoseconds: 300_000_000)
  let t0 = Date()
  let ack = await helper.response(for: json(["cmd": "cancel", "id": 41, "pageCancel": 1]), failureMessage: fail)
  let cancelled = await slow
  let ms = Int(Date().timeIntervalSince(t0) * 1000)
  expect(header(cancelled)["cancelled"] as? Bool == true && ms < 1500, "cancel by page id ends the request in \(ms) ms: \(header(cancelled)), ack \(header(ack))")

  // An unknown id: answered at once, nothing hangs.
  let t1 = Date()
  let none = await helper.response(for: json(["cmd": "cancel", "id": 999]), failureMessage: fail)
  expect(header(none)["cancelled"] as? Bool == false && Date().timeIntervalSince(t1) < 1, "cancel of an unknown page id: \(header(none))")

  // A cancel that overtakes its request (two POSTs race in the scheme handler).
  _ = await helper.response(for: json(["cmd": "cancel", "id": 55]), failureMessage: fail)
  let t2 = Date()
  let raced = await helper.response(for: json(["cmd": "sleep", "ms": 4000, "id": 55]), failureMessage: fail)
  expect(header(raced)["cancelled"] as? Bool == true && Date().timeIntervalSince(t2) < 1.5, "a request cancelled before it arrived is not run: \(header(raced))")

  // The page ids are the page's: the same id again after its reply is a new request.
  let again = await helper.response(for: json(["cmd": "sleep", "ms": 10, "id": 41]), failureMessage: fail)
  expect((header(again)["result"] as? [String: Any])?["slept"] as? Int == 10, "a reused page id after its reply runs: \(header(again))")

  // v1 fallback: the v2 install is missing and its build fails (exit 11: no Node.js).
  let broken = scratch.appendingPathComponent("broken-v2", isDirectory: true)
  try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
  try Data("#!/bin/sh\necho 'cmux-fsdb-build: Node.js 18 or later not found' >&2\nexit 11\n".utf8).write(to: broken.appendingPathComponent("build.sh"))
  let fbHome = try makeHome("fallback", installs: [v1Install])
  let fallback = makeHelper(home: fbHome, loading: .auto, v2Root: broken)
  defer { fallback.stop() }
  let fbOpen = await fallback.response(for: json(["cmd": "open", "file": dump, "id": 1]), failureMessage: fail)
  expect(header(fbOpen)["result"] != nil && fbOpen.headers[WaveformFSDBHelper.protocolHeader] == "1",
         "a failed v2 build falls back to the v1 helper: \(header(fbOpen).keys.sorted()) protocol \(String(describing: fbOpen.headers[WaveformFSDBHelper.protocolHeader]))")

  // loading = whole: the v1 helper only, even with v2 installed.
  let whole = makeHelper(home: home, loading: .whole)
  defer { whole.stop() }
  let wOpen = await whole.response(for: json(["cmd": "open", "file": dump, "id": 1]), failureMessage: fail)
  expect(wOpen.headers[WaveformFSDBHelper.protocolHeader] == "1", "loading whole runs the v1 helper: \(String(describing: wOpen.headers[WaveformFSDBHelper.protocolHeader]))")
}

// MARK: Page

@MainActor
final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  let loading: WaveformFSDBHelper.Loading
  var web: WKWebView!
  var helper: WaveformFSDBHelper!
  var opened: CheckedContinuation<Bool, Never>?

  init(loading: WaveformFSDBHelper.Loading) { self.loading = loading }

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }
  func wc(_ expr: String) async -> Any? {
    await call("const w = document.getElementById('viewer').contentWindow.__vvWindowing; return w ? (\(expr)) : null")
  }
  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }
  func waitFor(_ ms: Int, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < end { if await cond() { return true }; await sleep(50) }
    return await cond()
  }

  func open(home: URL) async -> Bool {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    cfg.userContentController.add(self, name: "cmuxWaveform")
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    // Invisible to the user: off-screen, transparent, click-through, only ever ordered back.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderBack(nil)
    helper = makeHelper(home: home, loading: loading)
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
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
            debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s', debuggerTooManyEdges:'too many'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(dump)'}})
        """)
    } else if type == "opened" {
      opened?.resume(returning: true); opened = nil
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      opened?.resume(returning: false); opened = nil
    }
  }

  func windowedChecks() async {
    let enabled = await wc("w.enabled") as? Bool
    expect(enabled == true, "protocol 2: the viewer is windowed (set-windowing before initViewport): \(String(describing: enabled))")
    for path in [["tb", "clk"], ["tb", "dut", "bus0"], ["tb", "dut", "state"], ["tb", "dut", "spike_rvfi"]] {
      let added = await call("return await cmuxWaveform.link.addSignal([\(path.map { "'\($0)'" }.joined(separator: ","))])")
      if added as? Bool != true { print("[add]", path, String(describing: added)) }
    }
    let drawn = await waitFor(15000) { (await self.wc("w.stats.firstDrawMs.length") as? Int ?? 0) >= 3 }
    let firstDraw = await wc("w.stats.firstDrawMs") ?? "none"
    if ProcessInfo.processInfo.environment["WINDOWED_DEBUG"] != nil {
      print("[debug] stats", await call("return JSON.stringify(cmuxWaveform.stats)") ?? "", await wc("JSON.stringify(w.getStats())") ?? "")
    }
    expect(drawn, "windowed rows draw from windows: firstDrawMs \(firstDraw)")
    let clkWindowed = await wc("w.isWindowed(0)") as? Bool
    expect(clkWindowed == true, "clk (1M changes) stays windowed: \(String(describing: clkWindowed))")
    let stateLocal = await waitFor(15000) { await self.wc("w.isWindowed(\(self.stateId)) === false && w.stats.promoted > 0") as? Bool == true }
    expect(stateLocal, "state (a few thousand changes) is loaded whole: promoted \(await wc("w.stats.promoted") ?? "?")")
    let relayed = await call("return cmuxWaveform.v2Stats ? cmuxWaveform.v2Stats() : null") as? [String: Any]
    expect((relayed?["relayed"] as? Int ?? 0) > 0, "viewer requests went through the page's v2 relay: \(String(describing: relayed))")

    // Next edge on the windowed clock, from the marker.
    _ = await call("cmuxWaveform.link.setMarker(500000300); return null")
    _ = await call("return await cmuxWaveform.link.selectSignal(['tb','clk'])")
    await sleep(300)
    _ = await wc("(w.goToNextTransition(0, 1, []), 1)")
    let moved = await waitFor(5000) { (await self.call("return cmuxWaveform.link.markerTime()") as? Int) == 500001000 }
    expect(moved, "next edge on a windowed row: marker \(String(describing: await call("return cmuxWaveform.link.markerTime()")))")

    // Inline values (the editor's) on windowed rows.
    let values = await call("return await cmuxWaveform.link.valuesAt({ time: 500001500, paths: [['tb','clk'], ['tb','dut','bus0']] })")
    print("[values]", String(describing: values))
    let list = values as? [Any] ?? (values as? [String: Any])?["values"] as? [Any] ?? []
    expect(list.count == 2 && "\(list)".contains("1"), "inline values of windowed signals: \(list)")

    // The debugger steps the windowed clock and reads values at its edges.
    let step = await call("return await cmuxWaveform.debugger.step({ by: 1 })") as? [String: Any]
    expect((step?["cycle"] as? Int ?? 0) > 0 && (step?["count"] as? Int ?? 0) > 1000, "debugger steps on a windowed clock: \(String(describing: step))")
    _ = await call("return await cmuxWaveform.debugger.stop()")
  }

  /// tb.dut's vars in the mock: bus0, bus1, state, spike_rvfi after clk, rst.
  var stateId: Int { 4 }

  func wholeChecks() async {
    let enabled = await wc("w.enabled") as? Bool
    expect(enabled != true, "loading whole: no windowing: \(String(describing: enabled))")
    _ = await call("return await cmuxWaveform.link.addSignal(['tb','dut','bus0'])")
    let loaded = await waitFor(15000) {
      await self.call("return cmuxWaveform.stats.some((e) => e.signalId === 2 && e.changes > 1000)") as? Bool == true
    }
    let loadStats = await call("return cmuxWaveform.stats") ?? "none"
    expect(loaded, "loading whole: bus0 arrives as whole-signal data: \(loadStats)")
  }

  func snapshot() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      web.takeSnapshot(with: nil) { img, _ in
        if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out) }
        c.resume()
      }
    }
  }

  func close() {
    helper?.stop()
    window.orderOut(nil)
  }
}

@MainActor
func run() async {
  do { try await relayChecks() } catch { expect(false, "relay checks ran: \(error)") }
  do {
    let home = try makeHome("page", installs: [v2Install, v1Install])
    let page = Page(loading: .auto)
    let ok = await page.open(home: home)
    expect(ok, "v2 page opened the synthetic dump")
    if ok { await page.windowedChecks() }
    await page.snapshot()
    page.close()
    let whole = Page(loading: .whole)
    let ok2 = await whole.open(home: home)
    expect(ok2, "loading whole page opened")
    if ok2 { await whole.wholeChecks() }
    whole.close()
  } catch { expect(false, "page checks ran: \(error)") }
  print(failures == 0 ? "WINDOWED CHECKS PASSED" : "WINDOWED CHECKS FAILED: \(failures)")
  exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("timeout"); exit(1) }
app.run()
