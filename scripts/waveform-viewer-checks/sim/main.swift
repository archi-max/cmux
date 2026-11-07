// Live simulation (run.sh sim): the sim.* path end to end on this Mac, no SSH host and no simulator.
// The real WaveformFSDBHelper starts mock-helper-sim.cjs through its own launch command (`/bin/sh` in place of
// `/usr/bin/ssh`, a scratch HOME holding the install folder); that runs the real fsdb-helper-v2/sim.js with
// fake-worker.cjs as the simulator, and windowed/mock-helper-v2.cjs for everything else.
//   relay   sim.* only when the setting adds them (WaveformSimRelay.pageCommands); sim.open's folder is the
//           panel file's own, whatever the page sends, and refused without a panel file; a poll's binary
//           comes back as the scheme handler's octet-stream; stopping the helper ends the simulation
//   page    the bundled page off-screen through the real scheme handler, the setting on (off: no controls):
//           run/stop/step/run-until; only the rows on screen are watched (a row scrolled into view is
//           watched then, x before); watched rows get the live changes; the time range grows to the
//           simulation's time and the view follows the right edge; closing live mode reloads the dump
//           and ends the simulation; so does a reload of the page
// Usage: sim <assetRoot> <v2HelperRoot> <v1HelperRoot> <proxy.cjs> <mock.cjs> <fake-worker.cjs> <fixture> <scratch>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let v2Root = URL(fileURLWithPath: args[2], isDirectory: true)
let v1Root = URL(fileURLWithPath: args[3], isDirectory: true)
let proxy = args[4]
let mock = args[5]
let fakeWorker = args[6]
let fixture = URL(fileURLWithPath: args[7], isDirectory: true)
let scratch = URL(fileURLWithPath: args[8], isDirectory: true)
// 1 ps, a 2000 ps clock, 20 ns long (10 cycles): the live run goes past its end at once.
let synth = "synth:ms=0.00002,buses=2,wide=0"
nonisolated(unsafe) var failures = 0

func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func machine() -> String {
  var u = utsname(); uname(&u)
  return withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
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
func binary(_ r: WaveformSchemeResponse) -> Data {
  guard r.headers["Content-Type"] == "application/octet-stream" else { return Data() }
  let n = r.body.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
  return r.body.subdata(in: (4 + n)..<r.body.count)
}
func result(_ r: WaveformSchemeResponse) -> [String: Any] { header(r)["result"] as? [String: Any] ?? [:] }

// ---- the folder a "dump" lives in: the fixture's run folder, with a stub its build record names
let fm = FileManager.default
let runDir = scratch.appendingPathComponent("build/run", isDirectory: true)
try? fm.removeItem(at: scratch.appendingPathComponent("build"))
try fm.createDirectory(at: runDir.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.copyItem(at: fixture.appendingPathComponent("run"), to: runDir)
let stub = scratch.appendingPathComponent("stub/libsimctl_stub.so")
let lib = scratch.appendingPathComponent("lib/libsimctl.so")
for f in [stub, lib] { try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: f) }
try Data("vcs -full64 -debug_access+all -load \(stub.path):simctl_register\n".utf8).write(to: runDir.appendingPathComponent("simv.daidir/.vcs.timestamp"))
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runDir.appendingPathComponent("simv").path)
let panelFile = runDir.appendingPathComponent("wave.fsdb").path
let workerLog = scratch.appendingPathComponent("worker.json")

/// A scratch HOME with the v2 install in place, as build.sh would leave it; its launcher runs the proxy.
func makeHome(_ name: String) throws -> URL {
  let home = scratch.appendingPathComponent(name, isDirectory: true)
  let dir = home.appendingPathComponent(".cache/cmux/fsdb-helper-v2/\(WaveformFSDBHelper.cachedVersion(of: v2Root))-\(machine())", isDirectory: true)
  try fm.createDirectory(at: dir.appendingPathComponent("addon/build/Release"), withIntermediateDirectories: true)
  try Data().write(to: dir.appendingPathComponent("addon/build/Release/fsdb_reader.node"))
  let env = [
    "CMUX_SIM_WORKER=\(shellQuoted(fakeWorker))", "CMUX_SIM_LIB=\(shellQuoted(lib.path))",
    "CMUX_SIM_STUB=\(shellQuoted(stub.path))", "FAKE_WORKER_LOG=\(shellQuoted(workerLog.path))",
    "SIM_SYNTH=\(shellQuoted(synth))", "CMUX_SIM_SCRATCH=\(shellQuoted(scratch.path))", "FAKE_PERIOD=2000",
  ].joined(separator: " ")
  let body = "export \(env)\nexec node \(shellQuoted(proxy)) \(shellQuoted(v2Root.appendingPathComponent("sim.js").path)) \(shellQuoted(mock)) --latency 5 \"$@\" 3>&1 1>&2"
  try Data("#!/bin/bash\n\(body)\n".utf8).write(to: dir.appendingPathComponent("cmux-helper-v2.sh"))
  return home
}
func localShell(home: URL) -> WaveformFSDBHelper.SSHArguments {
  let h = home.path
  return { command in ["-c", "HOME=\(shellQuoted(h)); export HOME; \(command)"] }
}
func makeHelper(home: URL, commands: Set<String>, allowedFile: String?) -> WaveformFSDBHelper {
  WaveformFSDBHelper(sshArguments: localShell(home: home),
                     installs: WaveformFSDBHelper.installs(v2Root: v2Root, v1Root: v1Root, loading: .auto),
                     executable: URL(fileURLWithPath: "/bin/sh"), hostKey: "local-sim", allowedCommands: commands,
                     allowedFile: allowedFile, readyTimeout: 20) { status in print("[status]", status) }
}
func workerPid() -> Int32? {
  guard let d = try? Data(contentsOf: workerLog), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
  return (o["pid"] as? NSNumber)?.int32Value
}
func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

// MARK: Relay

func relayChecks() async throws {
  let fail: @Sendable (Error) -> String = { "\($0)" }
  let home = try makeHome("relay")

  // Off (the default): the relay passes no sim.* at all.
  let off = makeHelper(home: home, commands: WaveformFSDBHelper.pageCommands, allowedFile: panelFile)
  let refused = await off.response(for: json(["cmd": "sim.open", "id": 1]), failureMessage: fail)
  expect((header(refused)["error"] as? String ?? "").contains("notAllowed"), "setting off: sim.open is refused by the relay: \(header(refused))")
  off.stop()

  expect(WaveformSimRelay.pageCommands == ["sim.open", "sim.run", "sim.until", "sim.stop", "sim.read", "sim.watch", "sim.unwatch", "sim.poll", "sim.close"],
         "the sim commands the page may send: \(WaveformSimRelay.pageCommands.sorted())")
  expect(!WaveformSimRelay.pageCommands.contains("sim.force"), "no force/deposit from the page yet")

  // No panel file: nothing to pin the folder to, so no sim.open.
  let loose = makeHelper(home: home, commands: WaveformFSDBHelper.pageCommands.union(WaveformSimRelay.pageCommands), allowedFile: nil)
  let noFile = await loose.response(for: json(["cmd": "sim.open", "dir": runDir.path, "id": 2]), failureMessage: fail)
  expect((header(noFile)["error"] as? String ?? "").contains("notAllowed"), "no panel file: sim.open refused: \(header(noFile))")
  loose.stop()

  // On: the folder is the panel file's, whatever the page asks for.
  let on = makeHelper(home: home, commands: WaveformFSDBHelper.pageCommands.union(WaveformSimRelay.pageCommands), allowedFile: panelFile)
  let open = await on.response(for: json(["cmd": "sim.open", "dir": "/etc", "id": 3]), failureMessage: fail)
  let o = result(open)
  expect((o["simv"] as? String) == runDir.appendingPathComponent("simv").path, "sim.open runs the simulator of the panel file's folder, not the page's: \(header(open))")
  expect((o["period"] as? NSNumber)?.intValue == 2000, "sim.open answers with the clock period: \(o)")

  let w = await on.response(for: json(["cmd": "sim.watch", "signals": ["tb.cnt"], "id": 4]), failureMessage: fail)
  expect(((result(w)["watch"] as? [[String: Any]])?.first?["width"] as? NSNumber)?.intValue == 8, "sim.watch through the relay: \(header(w))")
  _ = await on.response(for: json(["cmd": "sim.run", "cycles": 2, "id": 5]), failureMessage: fail)
  var records = 0, stopped = ""
  for i in 0..<40 where stopped.isEmpty {
    let p = await on.response(for: json(["cmd": "sim.poll", "waitMs": 300, "id": 6 + i]), failureMessage: fail)
    let r = result(p)
    let bin = binary(p)
    for s in r["signals"] as? [[String: Any]] ?? [] { records += (s["count"] as? NSNumber)?.intValue ?? 0 }
    let n = (r["signals"] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["count"] as? NSNumber)?.intValue ?? 0) }
    if n > 0 { expect(bin.count == n * (8 + 8), "poll binary: \(n) records of 8+8 bytes, got \(bin.count)") }
    if let stop = r["stop"] as? [String: Any] { stopped = stop["stopped"] as? String ?? "?" }
  }
  expect(stopped == "done" && records == 3, "run 2 cycles: the counter's 3 records arrive by poll, then done (\(records), \(stopped))")

  // The viewer goes away (helper stopped): the simulation goes with it.
  let pid = workerPid()
  on.stop()
  try await Task.sleep(nanoseconds: 1_500_000_000)
  expect(pid != nil && !alive(pid!), "stopping the helper ends the simulation (worker \(String(describing: pid)))")
}

// MARK: Page

@MainActor
final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var helper: WaveformFSDBHelper!
  var opened: CheckedContinuation<Bool, Never>?
  let live: Bool
  init(live: Bool) { self.live = live }

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", error); return nil }
  }
  /// In the viewer frame, with `L` = its __vvLive and `vp` = the viewport's state.
  func frame(_ expr: String) async -> Any? {
    await call("const f = document.getElementById('viewer').contentWindow; const L = f.__vvLive; return L ? (\(expr)) : null")
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
    let commands = live ? WaveformFSDBHelper.pageCommands.union(WaveformSimRelay.pageCommands) : WaveformFSDBHelper.pageCommands
    helper = makeHelper(home: home, commands: commands, allowedFile: panelFile)
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
        cmuxWaveform.open({url:'cmux-waveform://viewer/wave.fsdb', format:'fsdb', settings:{liveSimulation:\(live)},
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add',
            simLive:'Live', simRun:'Run', simStop:'Stop', simStep:'Step', simUntil:'Run Until', simUntilPlaceholder:'expression',
            simClose:'End Live', simTime:'t=%@', simOpenFailed:'Live simulation: %@'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(panelFile)'}})
        """)
    } else if type == "opened" {
      opened?.resume(returning: true); opened = nil
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      opened?.resume(returning: false); opened = nil
    }
  }

  func add(_ path: [String]) async {
    let added = await call("return await cmuxWaveform.link.addSignal([\(path.map { "'\($0)'" }.joined(separator: ","))])")
    if added as? Bool != true { print("[add]", path, String(describing: added)) }
  }
  func sim(_ js: String) async -> Any? { await call("const S = cmuxWaveform.sim; return S ? (\(js)) : 'no cmuxWaveform.sim'") }
  /// The live records of a row's signal, [[t, value]], or nil when the row is not live.
  func liveRecords(_ path: String) async -> [[Any]]? {
    await frame("(() => { const r = L.rows().find((x) => x.path === '\(path)'); if (!r || !L.isLive(r.signalId)) return null; return f.__vvDataManager.valueChangeData[r.signalId].valueChangeData.map((x) => [x[0], x[1]]); })()") as? [[Any]]
  }
  func watched() async -> [String] { (await sim("S.watched()") as? [String] ?? []).sorted() }
  func visible() async -> [String] { (await frame("L.rows().filter((r) => r.visible).map((r) => r.path)") as? [String] ?? []).sorted() }
  func timeStop() async -> Int { await frame("f.__vvLive.viewport().timeStop") as? Int ?? -1 }
  func running() async -> Bool { await sim("S.state().running") as? Bool ?? false }
  func waitIdle(_ ms: Int = 10000) async -> Bool { await waitFor(ms) { await self.sim("S.state().phase === 'ready' && !S.state().running") as? Bool == true } }

  func offChecks() async {
    let controls = await call("return !!document.getElementById('sim-controls') && !document.getElementById('sim-controls').hidden") as? Bool
    expect(controls == false, "setting off: no live simulation controls")
    let opened = await sim("S.open().then(() => 'opened', (e) => String(e.message || e))") as? String
    expect(opened != "opened", "setting off: the page can't start one either: \(String(describing: opened))")
  }

  func liveChecks() async {
    for p in [["tb", "clk"], ["tb", "dut", "state"], ["tb", "dut", "bus0"], ["tb", "rst"]] { await add(p) }
    let rows = await waitFor(10000) { (await self.frame("L.rows().length") as? Int ?? 0) == 4 }
    expect(rows, "four rows shown: \(String(describing: await frame("L.rows().map((r) => r.path)")))")
    let dumpEnd = await timeStop()
    expect(dumpEnd == 20000, "the dump ends at 20000: \(dumpEnd)")

    let controls = await call("return ['sim-run','sim-stop','sim-step','sim-until','sim-until-expr'].every((id) => !!document.getElementById(id)) && !document.getElementById('sim-controls').hidden") as? Bool
    expect(controls == true, "setting on: run, stop, step and run-until controls")

    // Only two rows fit: those are the ones watched.
    _ = await call("document.getElementById('viewer').style.height = '90px'; return null")
    await sleep(300)
    let opened = await sim("S.open().then(() => 'opened', (e) => String(e.message || e))") as? String
    expect(opened == "opened", "live simulation opens: \(String(describing: opened))")
    let period = await sim("S.state().period") as? Int
    let argv = (try? JSONSerialization.jsonObject(with: Data(contentsOf: workerLog)) as? [String: Any])?["argv"] as? [String] ?? []
    let clock = argv.firstIndex(of: "--clock").map { argv[$0 + 1] }
    expect(clock == "tb.clk", "the page names the dump's clock (the debugger's choice) to the simulation: \(String(describing: clock))")
    expect(period == 2000, "the clock period comes from the simulation: \(String(describing: period))")
    let vis = await visible()
    let w1 = await waitFor(5000) { let w = await self.watched(); return !w.isEmpty && w == vis.filter { $0 != "tb.dut.bus0" } }
    expect(w1 && vis.count < 4, "only the rows on screen are watched: watched \(await watched()), visible \(vis)")

    // Step: one cycle.
    _ = await call("document.getElementById('sim-step').click(); return null")
    expect(await waitIdle(), "step ends")
    let t1 = await sim("S.state().t") as? Int
    expect(t1 == 2000, "step runs one clock cycle: t=\(String(describing: t1))")
    let clk1 = await liveRecords("tb.clk")
    expect(clk1.map { $0.map { "\($0[0])=\($0[1])" } } == ["0=0", "1000=1", "2000=0"], "the clock row is live after a step: \(String(describing: clk1))")

    // Everything on screen again: the other rows are watched from now on (x before).
    _ = await call("document.getElementById('viewer').style.height = ''; return null")
    let w2 = await waitFor(5000) { await self.watched() == ["tb.clk", "tb.dut.state"] }
    expect(w2, "rows scrolled into view are watched (bus0 and rst are not in the simulation): \(await watched())")
    _ = await call("document.getElementById('sim-step').click(); return null")
    _ = await waitIdle()
    let state2 = await liveRecords("tb.dut.state")
    expect(state2?.first.map { "\($0[0])=\($0[1])" } == "0=xxxx" && state2?.contains { "\($0[0])=\($0[1])" == "3000=0010" } == true,
           "a row watched later is x before its watch, then live: \(String(describing: state2))")
    let bus0Live = await frame("(() => { const r = L.rows().find((x) => x.path === 'tb.dut.bus0'); return L.isLive(r.signalId); })()") as? Bool
    expect(bus0Live == false, "a row the simulation doesn't have keeps the dump's data")

    // Run past the dump's end: the range grows and the view follows the right edge.
    _ = await call("document.getElementById('viewer').contentWindow.__vvLive.viewport().setViewportRange(0, 20000); return null")
    _ = await sim("S.run(20)")
    expect(await waitIdle(), "run 20 cycles ends")
    let t3 = await sim("S.state().t") as? Int
    let stop3 = await timeStop()
    expect(t3 == 44000 && stop3 >= 44000, "the time range grows to the simulation's time: t=\(String(describing: t3)), timeStop \(stop3)")
    let right = await frame("L.viewport().timeScrollRight") as? Double ?? 0
    expect(stop3 > 20000 && right >= Double(stop3) - 1, "the view follows the right edge: right \(right), end \(stop3)")
    let state3 = await liveRecords("tb.dut.state") ?? []
    let last3 = state3.last.map { "\($0[0])=\($0[1])" }
    expect(last3 == "43000=0110", "the counter's last change is at the last rising edge, 22 mod 16 = 6: \(String(describing: last3))")
    let edges = state3.filter { ($0[0] as? Int ?? 0) > 3000 }.count
    expect(edges == 20, "one state change per cycle: \(edges)")

    // Run until.
    _ = await call("document.getElementById('sim-until-expr').value = \"tb.dut.state == 'd9\"; document.getElementById('sim-until').click(); return null")
    expect(await waitIdle(), "run-until ends")
    let st4 = await sim("S.state()") as? [String: Any]
    expect((st4?["stopped"] as? String) == "until" && (st4?["t"] as? Int) == 49000, "run-until stops where state becomes 9: \(String(describing: st4))")

    // Run, then stop.
    _ = await call("document.getElementById('sim-run').click(); return null")
    let started = await waitFor(3000) { await self.running() }
    await sleep(300)
    _ = await call("document.getElementById('sim-stop').click(); return null")
    let stopped = await waitIdle(5000)
    let st5 = await sim("S.state()") as? [String: Any]
    expect(started && stopped && (st5?["stopped"] as? String) == "stop", "run goes until stop: \(String(describing: st5))")
    let afterStop = await timeStop()
    expect(afterStop >= (st5?["t"] as? Int ?? .max), "the range covers the stopped time: \(afterStop)")

    // End live mode: the dump comes back, the simulation ends.
    let pid = workerPid()
    _ = await call("document.getElementById('sim-close').click(); return null")
    let back = await waitFor(10000) { await self.timeStop() == 20000 }
    let anyLive = await frame("L.rows().some((r) => L.isLive(r.signalId))") as? Bool
    expect(back && anyLive == false, "ending live mode reloads the dump: timeStop \(await timeStop()), live rows \(String(describing: anyLive))")
    let gone = await waitFor(5000) { pid != nil && !alive(pid!) }
    expect(gone, "ending live mode ends the simulation (worker \(String(describing: pid)))")

    // A reload of the page (or the panel) ends a simulation too.
    _ = await sim("S.open()")
    _ = await waitIdle()
    let pid2 = workerPid()
    expect(pid2 != pid && pid2.map(alive) == true, "live simulation opens again")
    _ = await call("cmuxWaveform.reload(); return null")
    let gone2 = await waitFor(8000) { pid2 != nil && !alive(pid2!) }
    expect(gone2, "a reload ends the simulation")
  }

  func close() {
    helper?.stop()
    window.orderOut(nil)
  }
}

@MainActor
func pageChecks() async throws {
  let home = try makeHome("page")
  try? fm.removeItem(at: workerLog)   // the relay checks' worker: nothing below may pass on it
  let off = Page(live: false)
  if await off.open(home: home) { await off.offChecks() } else { expect(false, "the page opened (setting off)") }
  off.close()
  let on = Page(live: true)
  if await on.open(home: home) { await on.liveChecks() } else { expect(false, "the page opened (setting on)") }
  let pid = workerPid()
  _ = await on.sim("S.open()")
  on.close()
  try await Task.sleep(nanoseconds: 1_500_000_000)
  let p = workerPid()
  expect(p != nil && p != pid && !alive(p!), "closing the viewer ends the simulation (\(String(describing: pid)) -> \(String(describing: p)))")
}

Task { @MainActor in
  do { try await relayChecks() } catch { expect(false, "relay checks threw \(error)") }
  do { try await pageChecks() } catch { expect(false, "page checks threw \(error)") }
  print(failures == 0 ? "SIM CHECKS PASSED" : "SIM CHECKS FAILED (\(failures))")
  exit(failures == 0 ? 0 : 1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 600) { print("timeout"); exit(1) }
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
