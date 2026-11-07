// Live simulation (run.sh sim): the sim.* path end to end on this Mac, no SSH host and no simulator.
// The real WaveformFSDBHelper starts mock-helper-sim.cjs through its own launch command (`/bin/sh` in place of
// `/usr/bin/ssh`, a scratch HOME holding the install folder); that runs the real fsdb-helper-v2/sim.js with
// fake-worker.cjs as the simulator, and windowed/mock-helper-v2.cjs for everything else.
//   relay   sim.* only when the setting adds them (WaveformSimRelay.pageCommands); sim.open's folder is the
//           panel file's own, whatever the page sends, and refused without a panel file; a poll's binary
//           comes back as the scheme handler's octet-stream; stopping the helper ends the simulation
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
let synth = "synth:ms=1,buses=2,wide=1,insn=1"
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
    "SIM_SYNTH=\(shellQuoted(synth))", "CMUX_SIM_SCRATCH=\(shellQuoted(scratch.path))",
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
  expect((o["period"] as? NSNumber)?.intValue == 10, "sim.open answers with the clock period: \(o)")

  let w = await on.response(for: json(["cmd": "sim.watch", "signals": ["tb.cnt"], "id": 4]), failureMessage: fail)
  expect(((result(w)["watch"] as? [[String: Any]])?.first?["width"] as? NSNumber)?.intValue == 8, "sim.watch through the relay: \(header(w))")
  _ = await on.response(for: json(["cmd": "sim.run", "cycles": 2, "id": 5]), failureMessage: fail)
  var records = 0, stopped = ""
  for i in 0..<40 where stopped.isEmpty {
    let p = await on.response(for: json(["cmd": "sim.poll", "waitMs": 300, "id": 6 + i]), failureMessage: fail)
    let r = result(p)
    let bin = binary(p)
    for s in r["signals"] as? [[String: Any]] ?? [] { records += (s["count"] as? NSNumber)?.intValue ?? 0 }
    if records > 0 { expect(bin.count == records * (8 + 8), "poll binary: \(records) records of 8+8 bytes, got \(bin.count)") }
    if let stop = r["stop"] as? [String: Any] { stopped = stop["stopped"] as? String ?? "?" }
  }
  expect(stopped == "done" && records == 3, "run 2 cycles: the counter's 3 records arrive by poll, then done (\(records), \(stopped))")

  // The viewer goes away (helper stopped): the simulation goes with it.
  let pid = workerPid()
  on.stop()
  try await Task.sleep(nanoseconds: 1_500_000_000)
  expect(pid != nil && !alive(pid!), "stopping the helper ends the simulation (worker \(String(describing: pid)))")
}

Task { @MainActor in
  do { try await relayChecks() } catch { expect(false, "relay checks threw \(error)") }
  print(failures == 0 ? "SIM CHECKS PASSED" : "SIM CHECKS FAILED (\(failures))")
  exit(failures == 0 ? 0 : 1)
}
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
