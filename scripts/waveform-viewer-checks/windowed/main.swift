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

struct InstallSpec {
  let cache: String
  let root: URL
  let files: [String]
  let launcher: String
  /// The launcher's body; nil runs the mock (v2, or as v1).
  var script: String? = nil
  var asV1 = false
}

/// A scratch HOME with the given installs in place, as build.sh would leave them; each
/// launcher runs the mock with its replies on fd 3 (or the spec's own script).
func makeHome(_ name: String, installs: [InstallSpec]) throws -> URL {
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
    let body = i.script ?? "exec node \(shellQuoted(mock)) --latency 20 --jitter 10\(i.asV1 ? " --v1" : "") \"$@\" 3>&1 1>&2"
    try Data("#!/bin/bash\n\(body)\n".utf8).write(to: dir.appendingPathComponent(i.launcher))
  }
  try fm.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

func installDir(home: URL, _ i: InstallSpec) -> URL {
  home.appendingPathComponent(".cache/cmux/\(i.cache)/\(WaveformFSDBHelper.cachedVersion(of: i.root))-\(machine())", isDirectory: true)
}
func setMode(_ url: URL, _ mode: Int) throws { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }

let v2Install = InstallSpec(cache: "fsdb-helper-v2", root: v2Root, files: ["addon/build/Release/fsdb_reader.node"], launcher: "cmux-helper-v2.sh")
let v1Install = InstallSpec(cache: "fsdb-helper", root: v1Root, files: ["fsdb_reader.node"], launcher: "fsdb-helper.sh", asV1: true)
func v2Launching(_ script: String) -> InstallSpec {
  InstallSpec(cache: "fsdb-helper-v2", root: v2Root, files: ["addon/build/Release/fsdb_reader.node"], launcher: "cmux-helper-v2.sh", script: script)
}

/// `/bin/sh -c` stands in for `ssh host`: same remote command, run here with HOME set.
func localShell(home: URL, env: String = "") -> WaveformFSDBHelper.SSHArguments {
  let h = home.path
  return { command in ["-c", "HOME=\(shellQuoted(h)); export HOME; \(env)\(command)"] }
}

/// Statuses a helper reported, for the fallback checks.
final class StatusLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [WaveformFSDBHelper.Status] = []
  func add(_ s: WaveformFSDBHelper.Status) { lock.withLock { items.append(s) } }
  var fellBack: [(detail: String, remembered: Bool)] {
    lock.withLock { items.compactMap { if case .fellBack(let d, let r) = $0 { return (d, r) }; return nil } }
  }
}

let testCommands = WaveformFSDBHelper.pageCommands.union(["sleep", "searchAll", "stats"])

func makeHelper(home: URL, loading: WaveformFSDBHelper.Loading, v2Root: URL = v2Root, hostKey: String = "local",
                allowedFile: String? = nil, readyTimeout: TimeInterval = 20, log: StatusLog? = nil, env: String = "") -> WaveformFSDBHelper {
  WaveformFSDBHelper(sshArguments: localShell(home: home, env: env),
                     installs: WaveformFSDBHelper.installs(v2Root: v2Root, v1Root: v1Root, loading: loading),
                     executable: URL(fileURLWithPath: "/bin/sh"), hostKey: hostKey, allowedCommands: testCommands,
                     allowedFile: allowedFile, readyTimeout: readyTimeout) { status in log?.add(status); print("[status]", String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)), status) }
}

/// A v2 source folder whose build.sh counts its runs in `counter` and exits `code`.
func failingV2Root(_ name: String, code: Int, counter: URL) throws -> URL {
  let root = scratch.appendingPathComponent(name, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("#!/bin/sh\necho run >> \(shellQuoted(counter.path))\necho 'cmux-fsdb-build: failing on purpose (\(code))' >&2\nexit \(code)\n".utf8)
    .write(to: root.appendingPathComponent("build.sh"))
  return root
}
func lines(_ url: URL) -> Int { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count }

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

  // Early cancels last as long as the request is on its way, not a fixed time.
  _ = await helper.response(for: json(["cmd": "cancel", "id": 77]), failureMessage: fail)
  try await Task.sleep(nanoseconds: 3_000_000_000)
  let late = await helper.response(for: json(["cmd": "sleep", "ms": 4000, "id": 77]), failureMessage: fail)
  expect(header(late)["cancelled"] as? Bool == true, "a cancel that overtook its request still applies 3 s later: \(header(late))")
  // ... and a cancel of a request already answered is ignored (the next request with that id runs).
  _ = await helper.response(for: json(["cmd": "cancel", "id": 3]), failureMessage: fail)
  let after3 = await helper.response(for: json(["cmd": "sleep", "ms": 10, "id": 3]), failureMessage: fail)
  expect((header(after3)["result"] as? [String: Any])?["slept"] != nil, "a cancel of an answered id doesn't cancel a later request: \(header(after3))")

  // Request and cancel POSTs racing: every request ends (cancelled or answered), none hangs.
  let raceStart = Date()
  let outcomes: [String] = await withTaskGroup(of: String?.self) { group in
    for id in 200..<260 {
      group.addTask {
        let r = await helper.response(for: json(["cmd": "sleep", "ms": 600, "id": id]), failureMessage: fail)
        let h = header(r)
        return h["cancelled"] as? Bool == true ? "cancelled" : (h["result"] != nil ? "answered" : "other \(h)")
      }
      group.addTask {
        // Half cancel at a random moment; half the moment the request is mapped (its id
        // published), where a relay that writes the request later sends the cancel first.
        if id % 2 == 0 {
          try? await Task.sleep(nanoseconds: UInt64.random(in: 0...3_000_000))
        } else {
          let end = Date().addingTimeInterval(2)
          while !helper.isMapped(pageId: id), Date() < end { await Task.yield() }
        }
        _ = await helper.response(for: json(["cmd": "cancel", "id": id]), failureMessage: fail)
        return nil
      }
    }
    var out: [String] = []
    for await o in group { if let o { out.append(o) } }
    return out
  }
  let raceMs = Int(Date().timeIntervalSince(raceStart) * 1000)
  let cancelledCount = outcomes.filter { $0 == "cancelled" }.count
  expect(outcomes.count == 60 && outcomes.allSatisfy { $0 == "cancelled" || $0 == "answered" } && cancelledCount >= 50 && raceMs < 4000,
         "60 racing request/cancel pairs: \(cancelledCount) cancelled, the rest answered, in \(raceMs) ms: \(Set(outcomes))")

  // No cancel reached the helper ahead of its request (the request is written before its
  // id is published): the mock counts requests that arrive after their own cancel.
  let order = header(await helper.response(for: json(["cmd": "stats"]), failureMessage: fail))
  expect((order["result"] as? [String: Any])?["requestsAfterCancel"] as? Int == 0,
         "no cancel overtook its request on the way to the helper: \(order)")

  // The relay passes only the page's commands, and an open only of the panel's file.
  let warm = await helper.response(for: json(["cmd": "warm", "on": true]), failureMessage: fail)
  expect((header(warm)["error"] as? String ?? "").contains("notAllowed"), "a command the page doesn't use is refused: \(header(warm))")
  let fenced = makeHelper(home: home, loading: .auto, allowedFile: dump)
  defer { fenced.stop() }
  let other = await fenced.response(for: json(["cmd": "open", "file": "synth:ms=2"]), failureMessage: fail)
  let own = await fenced.response(for: json(["cmd": "open", "file": dump]), failureMessage: fail)
  expect((header(other)["error"] as? String ?? "").contains("notAllowed") && header(own)["result"] != nil,
         "open is limited to the panel's file: other \(header(other)), own \(header(own).keys.sorted())")
}

/// When v2 gives way to v1, and when it doesn't.
func fallbackChecks() async throws {
  let fail: @Sendable (Error) -> String = { "\($0)" }
  func open(_ helper: WaveformFSDBHelper) async -> WaveformSchemeResponse {
    // A small dump: these checks time the start, not the open.
    await helper.response(for: json(["cmd": "open", "file": "synth:ms=0.02", "id": 1]), failureMessage: fail)
  }
  func proto(_ r: WaveformSchemeResponse) -> String { r.headers[WaveformFSDBHelper.protocolHeader] ?? "none" }

  // The v2 build fails to compile (13): v1 runs, said with the reason, and remembered for the host.
  let counter = scratch.appendingPathComponent("builds-13.txt")
  let broken = try failingV2Root("broken-13", code: 13, counter: counter)
  let fbHome = try makeHome("fallback", installs: [v1Install])
  let log1 = StatusLog()
  let first = makeHelper(home: fbHome, loading: .auto, v2Root: broken, hostKey: "host-a", log: log1)
  let r1 = await open(first); first.stop()
  expect(header(r1)["result"] != nil && proto(r1) == "1" && log1.fellBack.count == 1 && log1.fellBack[0].remembered
         && log1.fellBack[0].detail.contains("failing on purpose"),
         "a failed v2 build falls back to v1, with the reason: protocol \(proto(r1)), \(log1.fellBack)")
  let log2 = StatusLog()
  let second = makeHelper(home: fbHome, loading: .auto, v2Root: broken, hostKey: "host-a", log: log2)
  let r2 = await open(second); second.stop()
  expect(proto(r2) == "1" && lines(counter) == 1 && log2.fellBack.first?.remembered == true,
         "the failure is remembered for the host: no second build (\(lines(counter)) runs), notice \(log2.fellBack)")
  let other = makeHelper(home: fbHome, loading: .auto, v2Root: broken, hostKey: "host-b")
  _ = await open(other); other.stop()
  expect(lines(counter) == 2, "another host builds v2 itself: \(lines(counter)) runs")
  WaveformFSDBHelper.forgetV2Failure(hostKey: "host-a")
  let retried = makeHelper(home: fbHome, loading: .auto, v2Root: broken, hostKey: "host-a")
  _ = await open(retried); retried.stop()
  expect(lines(counter) == 3, "Retry windowed (forgetV2Failure) builds v2 again: \(lines(counter)) runs")

  // Remembered per machine type: the same host name reaching another kind of machine
  // (a round-robin alias) builds there.
  let cm = scratch.appendingPathComponent("builds-13m.txt")
  let brokenM = try failingV2Root("broken-13m", code: 13, counter: cm)
  let here = makeHelper(home: fbHome, loading: .auto, v2Root: brokenM, hostKey: "host-m")
  _ = await open(here); here.stop()
  let fakeBin = scratch.appendingPathComponent("fake-uname", isDirectory: true)
  try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
  try Data("#!/bin/sh\n[ \"$1\" = -m ] && { echo riscv64; exit 0; }\nexec /usr/bin/uname \"$@\"\n".utf8).write(to: fakeBin.appendingPathComponent("uname"))
  try setMode(fakeBin.appendingPathComponent("uname"), 0o755)
  let elsewhere = makeHelper(home: fbHome, loading: .auto, v2Root: brokenM, hostKey: "host-m", env: "PATH=\(shellQuoted(fakeBin.path)):$PATH; export PATH; ")
  _ = await open(elsewhere); elsewhere.stop()
  let again = makeHelper(home: fbHome, loading: .auto, v2Root: brokenM, hostKey: "host-m")
  _ = await open(again); again.stop()
  expect(lines(cm) == 2, "a failed build is remembered per machine type: another machine builds, this one doesn't again (\(lines(cm)) builds, want 2)")

  // No Node.js (11): v1 would fail the same way: an error, not a fallback.
  let c11 = scratch.appendingPathComponent("builds-11.txt")
  let noNode = makeHelper(home: fbHome, loading: .auto, v2Root: try failingV2Root("broken-11", code: 11, counter: c11), hostKey: "host-c")
  let r11 = await open(noNode); noNode.stop()
  expect(proto(r11) == "none" && (header(r11)["error"] as? String ?? "").contains("setupFailed(code: 11"),
         "a build that can't find Node.js is an error, not a fallback: \(header(r11))")

  // The v2 launcher exits before its ready line: v1, said, not remembered.
  let exitLog = StatusLog()
  let exitHome = try makeHome("exit1", installs: [v2Launching("echo 'cmux-helper-v2: out of memory' >&2; exit 1"), v1Install])
  let exits = makeHelper(home: exitHome, loading: .auto, hostKey: "host-d", log: exitLog)
  let rx = await open(exits); exits.stop()
  expect(proto(rx) == "1" && exitLog.fellBack.first?.remembered == false && exitLog.fellBack.first?.detail.contains("out of memory") == true,
         "a v2 helper that exits before ready falls back for now, not for good: \(exitLog.fellBack)")
  // A startup error line from v2 (id 0, error): the same.
  let errLog = StatusLog()
  let errHome = try makeHome("ready-error", installs: [v2Launching("echo '{\"id\":0,\"error\":\"worker failed to open\"}'; sleep 1"), v1Install])
  let errs = makeHelper(home: errHome, loading: .auto, hostKey: "host-e", log: errLog)
  let re = await open(errs); errs.stop()
  expect(proto(re) == "1" && errLog.fellBack.first?.detail.contains("worker failed to open") == true,
         "a v2 startup error falls back to v1: \(errLog.fellBack)")

  // ... with nothing on stderr: the notice still says why.
  let quietLog = StatusLog()
  let quietHome = try makeHome("exit1-quiet", installs: [v2Launching("exit 1"), v1Install])
  let quiet = makeHelper(home: quietHome, loading: .auto, hostKey: "host-d2", log: quietLog)
  _ = await open(quiet); quiet.stop()
  expect(quietLog.fellBack.count == 1 && !(quietLog.fellBack.first?.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
         "a silent v2 exit still gives the notice a reason: \(quietLog.fellBack)")

  // An install others can write is refused before its launcher runs (a changed launcher
  // can't skip the check): group-writable launcher, then a group-writable ~/.cache/cmux.
  // v2's refusal falls back to v1, with the reason, not remembered (fixing it is enough).
  for (name, makeOpen) in [("launcher", { (dir: URL, home: URL) in try setMode(dir.appendingPathComponent("cmux-helper-v2.sh"), 0o775) }),
                           ("cache", { (dir: URL, home: URL) in try setMode(home.appendingPathComponent(".cache/cmux"), 0o775) })] {
    let ran = scratch.appendingPathComponent("tampered-\(name).txt")
    let pLog = StatusLog()
    let pHome = try makeHome("tampered-\(name)", installs: [v2Launching("echo ran >> \(shellQuoted(ran.path)); exit 0"), v1Install])
    try makeOpen(installDir(home: pHome, v2Install), pHome)
    let tampered = makeHelper(home: pHome, loading: .auto, hostKey: "host-p-\(name)", log: pLog)
    let rp = await open(tampered); tampered.stop()
    expect(lines(ran) == 0 && proto(rp) == "1" && pLog.fellBack.count == 1 && pLog.fellBack[0].remembered == false
           && pLog.fellBack[0].detail.contains("not private"),
           "a group-writable \(name) is refused before the v2 launcher runs, and v1 runs with the reason: ran \(lines(ran)), protocol \(proto(rp)), \(pLog.fellBack)")
  }

  // ssh itself can't run here: an error, not a switch to v1 (which would fail the same way).
  let runLog = StatusLog()
  let noSSH = WaveformFSDBHelper(sshArguments: localShell(home: fbHome),
                                 installs: WaveformFSDBHelper.installs(v2Root: v2Root, v1Root: v1Root, loading: .auto),
                                 executable: URL(fileURLWithPath: "/nonexistent/ssh"), hostKey: "host-run", allowedCommands: testCommands,
                                 allowedFile: nil, readyTimeout: 5) { runLog.add($0) }
  let rr = await open(noSSH); noSSH.stop()
  expect(proto(rr) == "none" && runLog.fellBack.isEmpty && (header(rr)["error"] as? String ?? "").contains("connectionFailed"),
         "ssh that can't run is an error, not a fallback: \(header(rr)), \(runLog.fellBack)")

  // ssh can't connect (255): an error, no fallback.
  let sshLog = StatusLog()
  let sshHome = try makeHome("exit255", installs: [v2Launching("echo 'ssh: connect to host: Connection refused' >&2; exit 255"), v1Install])
  let ssh = makeHelper(home: sshHome, loading: .auto, hostKey: "host-f", log: sshLog)
  let r255 = await open(ssh); ssh.stop()
  expect(proto(r255) == "none" && sshLog.fellBack.isEmpty && (header(r255)["error"] as? String ?? "").contains("connectionFailed"),
         "an unreachable host is an error, not a fallback: \(header(r255))")

  // v2's launcher refuses its install (exit 86): v1 runs, with the launcher's reason.
  let refLog = StatusLog()
  let refHome = try makeHome("exit86", installs: [v2Launching("echo 'cmux-helper-v2: refusing to run' >&2; exit 86"), v1Install])
  let refused = makeHelper(home: refHome, loading: .auto, hostKey: "host-g", log: refLog)
  let r86 = await open(refused); refused.stop()
  expect(proto(r86) == "1" && refLog.fellBack.count == 1 && refLog.fellBack[0].detail.contains("refusing to run")
         && refLog.fellBack[0].remembered == false,
         "a refused v2 install falls back to v1 with the reason: protocol \(proto(r86)), \(refLog.fellBack), \(header(r86))")
  // Remembered nothing: the next viewer of the host tries v2 again (here it runs).
  let againHome = try makeHome("exit86-fixed", installs: [v2Launching("exec node \(shellQuoted(mock)) --latency 20 --jitter 10 \"$@\" 3>&1 1>&2"), v1Install])
  let afterRefusal = makeHelper(home: againHome, loading: .auto, hostKey: "host-g", log: StatusLog())
  let rAgain = await open(afterRefusal); afterRefusal.stop()
  expect(proto(rAgain) == "2", "after a refusal the next viewer of the host tries v2: protocol \(proto(rAgain))")
  // v1 refuses too: that is the error, as without v2.
  let bothLog = StatusLog()
  let v1Refusing = InstallSpec(cache: "fsdb-helper", root: v1Root, files: ["fsdb_reader.node"], launcher: "fsdb-helper.sh",
                               script: "echo 'fsdb-helper: refusing to run' >&2; exit 86", asV1: true)
  let bothHome = try makeHome("exit86-both", installs: [v2Launching("echo 'cmux-helper-v2: refusing to run' >&2; exit 86"), v1Refusing])
  let both = makeHelper(home: bothHome, loading: .auto, hostKey: "host-g2", log: bothLog)
  let rBoth = await open(both); both.stop()
  expect(proto(rBoth) == "none" && (header(rBoth)["error"] as? String ?? "").contains("fsdb-helper: refusing") && bothLog.fellBack.count == 1,
         "v1 refusing as well is an error (v1's own): \(header(rBoth)), \(bothLog.fellBack)")

  // v2 doesn't get ready in time: v1 once, remembered for the session.
  let tLog = StatusLog()
  let tCount = scratch.appendingPathComponent("slow-launches.txt")
  let tHome = try makeHome("timeout", installs: [v2Launching("echo run >> \(shellQuoted(tCount.path)); sleep 30"), v1Install])
  WaveformFSDBHelper.timeoutMemory = 4
  defer { WaveformFSDBHelper.timeoutMemory = 600 }
  let slow = makeHelper(home: tHome, loading: .auto, hostKey: "host-h", readyTimeout: 2, log: tLog)
  let t0 = Date()
  let rt = await open(slow); slow.stop()
  expect(proto(rt) == "1" && tLog.fellBack.first?.remembered == true && Date().timeIntervalSince(t0) < 6,
         "a v2 that misses its ready timeout falls back to v1 in \(Int(Date().timeIntervalSince(t0))) s: protocol \(proto(rt)) \(header(rt).keys.sorted()), \(tLog.fellBack)")
  let slow2 = makeHelper(home: tHome, loading: .auto, hostKey: "host-h", readyTimeout: 2)
  let rt2 = await open(slow2); slow2.stop()
  expect(proto(rt2) == "1" && lines(tCount) == 1, "the next viewer of that host doesn't wait for v2 again: \(lines(tCount)) launches")
  try await Task.sleep(nanoseconds: 4_500_000_000)
  let slow3 = makeHelper(home: tHome, loading: .auto, hostKey: "host-h", readyTimeout: 1)
  _ = await open(slow3); slow3.stop()
  expect(lines(tCount) == 2, "a remembered timeout expires: v2 is tried again later (\(lines(tCount)) launches, want 2)")

  // loading = whole: the v1 helper only, even with v2 installed.
  let wHome = try makeHome("whole", installs: [v2Install, v1Install])
  let whole = makeHelper(home: wHome, loading: .whole)
  let wOpen = await open(whole); whole.stop()
  expect(proto(wOpen) == "1", "loading whole runs the v1 helper: \(proto(wOpen))")
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

  /// A VCD to open instead of the FSDB (no helper, no windowing).
  let vcd: URL?
  /// Message types the page posted to native.
  var nativeTypes: [String] = []

  /// The mock's dump to open.
  let dumpSpec: String

  init(loading: WaveformFSDBHelper.Loading, vcd: URL? = nil, dump spec: String = dump) { self.loading = loading; self.vcd = vcd; self.dumpSpec = spec }

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
    // The order of the host's messages as the viewer frame receives them.
    cfg.userContentController.addUserScript(WKUserScript(source: """
      if (location.pathname.endsWith('viewer.html')) {
        window.__msgOrder = [];
        window.__v2Replies = {};
        window.addEventListener('message', (e) => {
          const c = e.data && e.data.command;
          if (c) { window.__msgOrder.push(c); }
          if (c === 'v2-reply' && e.data.reply && e.data.reply.id >= 900000) { window.__v2Replies[e.data.reply.id] = e.data.reply; }
        }, true);
      }
      """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    // Invisible to the user: off-screen, transparent, click-through, only ever ordered back.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderBack(nil)
    helper = makeHelper(home: home, loading: loading, allowedFile: dumpSpec)
    return await withCheckedContinuation { c in
      opened = c
      web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
    }
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    nativeTypes.append(type)
    if type == "ready", let vcd {
      let fileURL = scheme.serve(fileURL: vcd)
      let size = (try? FileManager.default.attributesOfItem(atPath: vcd.path)[.size] as? Int) ?? 0
      web.evaluateJavaScript("cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add'}})")
    } else if type == "ready" {
      let helper = self.helper!
      let relayURL = scheme.serve(fsdbRelay: { body in await helper.response(for: body) { "\($0)" } })
      web.evaluateJavaScript("""
        cmuxWaveform.setTheme({kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'});
        cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb',
          strings:{netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
            debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s', debuggerTooManyEdges:'too many'},
          fsdb:{url:'\(relayURL.absoluteString)', path:'\(dumpSpec)'}})
        """)
    } else if type == "opened" {
      opened?.resume(returning: true); opened = nil
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      opened?.resume(returning: false); opened = nil
    }
  }

  func messageOrder() async -> [String] {
    await call("return document.getElementById('viewer').contentWindow.__msgOrder || []") as? [String] ?? []
  }

  /// Pixels of the snapshot's waveform area that differ from the background: drawn rows.
  func drawnPixels() async -> Int {
    let image: NSImage? = await withCheckedContinuation { c in web.takeSnapshot(with: nil) { img, _ in c.resume(returning: img) } }
    guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
    var n = 0
    let x0 = rep.pixelsWide * 3 / 10
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
      for x in stride(from: x0, to: rep.pixelsWide, by: 2) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let d = abs(c.redComponent - 0x1e / 255.0) + abs(c.greenComponent - 0x1e / 255.0) + abs(c.blueComponent - 0x2e / 255.0)
        if d > 0.25 { n += 1 }
      }
    }
    return n
  }

  func windowedChecks() async {
    let enabled = await wc("w.enabled") as? Bool
    let order = await messageOrder()
    let sw = order.firstIndex(of: "set-windowing"), iv = order.firstIndex(of: "initViewport")
    expect(enabled == true && sw != nil && iv != nil && sw! < iv!,
           "protocol 2: set-windowing reaches the viewer before initViewport: enabled \(String(describing: enabled)), order \(order.prefix(6))")
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

    let pixels = await drawnPixels()
    expect(pixels > 1500, "the windowed rows are drawn: \(pixels) drawn pixels in the waveform area")

    // The viewer's own cancels (stale windows of a viewport that moved on) go through the relay.
    let refinesBefore = await wc("w.stats.refineMs.length") as? Int ?? 0
    _ = await call("""
      const T = cmuxWaveform.host.doc.metadata.timeEnd;
      for (let k = 0; k < 12; k++) {
        const w = T / 2 ** (3 + k % 5), a = Math.floor(((k * 0.618) % 1) * (T - w));
        cmuxWaveform.host.toWebview({ command: 'setViewportRange', startTime: a, endTime: a + w });
        await new Promise((r) => setTimeout(r, 25));
      }
      return null
      """)
    let drained = await waitFor(10000) { await self.wc("w.getStats().inflight === 0") as? Bool == true }
    let cancels = (await call("return cmuxWaveform.v2Stats()") as? [String: Any])?["cancelled"] as? Int ?? 0
    let refinesAfter = await wc("w.stats.refineMs.length") as? Int ?? 0
    expect(cancels > 0 && drained && refinesAfter > refinesBefore,
           "the viewer's cancels reach the helper and nothing is left waiting: \(cancels) cancels, drained \(drained), refines \(refinesBefore)->\(refinesAfter)")

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
    let list = values as? [Any] ?? []
    let truth = try? await helper.request(json(["cmd": "valueAt", "signalIds": [0, 2], "t": 500001500]))
    let bits = truth.flatMap { (try? JSONSerialization.jsonObject(with: $0.header)) as? [String: Any] }
      .flatMap { ($0["result"] as? [String: Any])?["values"] as? [String] } ?? []
    let wantBus = bits.count == 2 ? UInt32(bits[1], radix: 2).map { String(format: "%08x", $0) } : nil
    expect(list.count == 2 && list[0] as? String == bits.first && list[1] as? String == wantBus,
           "inline values of windowed signals are the helper's: \(list) vs clk \(bits.first ?? "?"), bus0 \(wantBus ?? "?")")

    // The debugger steps the windowed clock and reads values at its edges.
    let step = await call("return await cmuxWaveform.debugger.step({ by: 1 })") as? [String: Any]
    expect((step?["cycle"] as? Int ?? 0) > 0 && (step?["count"] as? Int ?? 0) > 1000, "debugger steps on a windowed clock: \(String(describing: step))")
    _ = await call("return await cmuxWaveform.debugger.stop()")
  }

  /// Value search in a RISC-V format on a windowed row (bus0, 32 bits): the
  /// formatted-text path (window_cache.ts searchFormatted), not a bit pattern.
  func riscvSearchChecks() async {
    _ = await call("await cmuxCommands.run('vaporview.displayAsRiscvNumeric', { netlistId: 3 }); return null")
    await sleep(500)
    let windowed = await wc("w.isWindowed(2)") as? Bool
    expect(windowed == true, "bus0 is windowed: \(String(describing: windowed))")
    let cellJS = """
      const d = document.getElementById('viewer').contentDocument;
      const el = [...d.querySelectorAll('.value-display-item')].find((e) => (e.getAttribute('data-vscode-context') || '').includes('"signalName":"bus0"'));
      """
    // The value at the marker (a cell on a change shows "before->after").
    func cellText() async -> String {
      let t = await call(cellJS + "return el ? el.textContent.trim() : ''") as? String ?? ""
      return t.components(separatedBy: "->").last ?? t
    }
    func marker() async -> Int { await call("return cmuxWaveform.link.markerTime()") as? Int ?? -1 }
    // A far change's text, read at the marker (the helper's valueAt): the first
    // decodable one from 90% of the dump on (random words are often not instructions).
    let end = await call("return cmuxWaveform.host.doc.metadata.timeEnd") as? Int ?? 0
    var target = ""
    var at = end * 9 / 10
    for _ in 0..<60 {
      _ = await call("cmuxWaveform.link.setMarker(\(at)); return null")
      var text = ""
      _ = await waitFor(3000) { text = await cellText(); return !text.isEmpty }
      if text.contains(" ") { target = text; break }
      at += 2000
    }
    expect(target.contains(" "), "bus0 shows an instruction near the end: \(target) at \(at)")
    func search(_ text: String, from t0: Int) async -> Int {
      _ = await call("cmuxWaveform.link.setMarker(\(t0)); return null")
      _ = await call("return await cmuxWaveform.link.selectSignal(['tb','dut','bus0'])")
      await sleep(300)
      _ = await call("""
        const d = document.getElementById('viewer').contentDocument;
        d.getElementById('value-equals-button').click();
        const bar = d.getElementById('search-bar');
        bar.focus(); bar.value = \(jsString(text));
        bar.dispatchEvent(new KeyboardEvent('keyup', { key: 'a', bubbles: true }));
        d.getElementById('next-button').click();
        return null
        """)
      _ = await waitFor(20000) { await marker() != t0 }
      return await marker()
    }
    let escaped = NSRegularExpression.escapedPattern(for: target)
    let found = await search("^" + escaped + "$", from: 0)
    let foundText = await cellText()
    expect(found > 0 && foundText == target, "a RISC-V text search on a windowed row finds the instruction: t \(found), \(foundText) vs \(target)")
    // A search made only of 0/1/x/z characters is still text in a text format
    // (a register name, an immediate), never a bit pattern for the helper.
    for pattern in ["x1,", "x1", "0"] {
      let t = await search(pattern, from: 0)
      let text = await cellText()
      expect(t > 0 && text.lowercased().contains(pattern), "searching \(pattern) in RISC-V matches the text, not bits: t \(t), \(text)")
    }
    _ = await call("""
      const d = document.getElementById('viewer').contentDocument;
      d.getElementById('search-bar').blur();
      return null
      """)
    // Bit-pattern formats stay bit patterns: each searches the exact value of a far
    // change (outside every loaded window) and must reach the helper as a `search`
    // (a whole-value pattern), not as page-side window scans. ASCII stays text.
    func bits(_ t: Int) async -> String? {
      let r = try? await helper.request(json(["cmd": "valueAt", "signalIds": [2], "t": t]))
      return r.flatMap { (try? JSONSerialization.jsonObject(with: $0.header)) as? [String: Any] }
        .flatMap { ($0["result"] as? [String: Any])?["values"] as? [String] }?.first
    }
    var far = end * 7 / 10
    var value = ""
    for _ in 0..<50 {
      if let a = await bits(far - 1), let b = await bits(far), a != b, !b.contains("x") { value = b; break }
      far += 2000
    }
    let word = UInt32(value, radix: 2) ?? 0
    expect(!value.isEmpty, "a far change of bus0 to search for: \(far) \(value)")
    _ = await call("""
      if (!window.__relayCmds) {
        window.__relayCmds = [];
        const real = window.fetch;
        window.fetch = (u, o) => {
          try { const j = JSON.parse(o && o.body); if (j && j.cmd) { window.__relayCmds.push(j.cmd); } } catch (e) {}
          return real(u, o);
        };
      }
      return null
      """)
    let cases: [(command: String, format: String, query: String, exact: Bool)] = [
      ("displayAsHexadecimal", "hexadecimal", String(word, radix: 16), true),
      ("displayAsBinary", "binary", value, true),
      ("displayAsDecimal", "decimal", String(word), true),
      ("displayAsDecimalSigned", "signed", String(Int32(bitPattern: word)), true),
      ("displayAsFloat", "float32", "1.5", false),
    ]
    // The row's format, as cmux's context menu sets it, once the viewer reports it.
    func setFormat(_ command: String, _ format: String) async -> Bool {
      _ = await call("""
        document.getElementById('viewer').contentDocument.getElementById('search-bar').blur();
        await cmuxCommands.run('vaporview.\(command)', { netlistId: 3, width: 32 });
        return null
        """)
      return await waitFor(3000) {
        await self.call("const s = cmuxCommands.sessionSnapshot().state.displayedSignals.find((d) => d.name === 'tb.dut.bus0'); return s ? s.numberFormat : ''") as? String == format
      }
    }
    for c in cases {
      expect(await setFormat(c.command, c.format), "bus0 is shown as \(c.format)")
      _ = await call("window.__relayCmds.length = 0; return null")
      let t = await search(c.query, from: 0)
      let cmds = await call("return [...new Set(window.__relayCmds)]") as? [String] ?? []
      if c.exact { expect(t == far, "\(c.format) search for the far value \(c.query) finds it: t \(t), want \(far)") }
      expect(cmds.contains("search"), "\(c.format) search reaches the helper as a bit pattern: \(cmds)")
    }
    expect(await setFormat("displayAsAscii", "ascii"), "bus0 is shown as ascii")
    _ = await call("window.__relayCmds.length = 0; return null")
    _ = await search("a", from: 0)
    let asciiCmds = await call("return [...new Set(window.__relayCmds)]") as? [String] ?? []
    expect(!asciiCmds.contains("search"), "ASCII stays a text search (no helper search): \(asciiCmds)")
    _ = await call("await cmuxCommands.run('vaporview.displayAsHexadecimal', { netlistId: 3 }); return null")
  }

  func jsString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
  }

  /// The page side of the fallback notice, and what host.js relays.
  func hostChecks() async {
    // The notice: shown with its reason and a Retry that asks native to retry windowed.
    _ = await call("cmuxWaveform.setFallbackNotice({message: 'Using the classic viewer: build failed', detail: 'g++: error', retry: 'Retry Windowed'}); return null")
    let shown = await call("""
      const el = document.getElementById('status-fallback');
      return el && !el.hidden && el.offsetParent !== null ? el.querySelector('.text').textContent + '|' + el.querySelector('button').textContent + '|' + el.title : null
      """) as? String
    expect(shown == "Using the classic viewer: build failed|Retry Windowed|g++: error", "the fallback notice shows its reason and Retry: \(shown ?? "hidden")")
    nativeTypes.removeAll()
    _ = await call("document.querySelector('#status-fallback button').click(); return null")
    let retried = await waitFor(2000) { self.nativeTypes.contains("retryWindowed") }
    let hidden = await call("return document.getElementById('status-fallback').hidden") as? Bool
    expect(retried && hidden == true, "Retry Windowed asks native to retry and hides the notice: \(nativeTypes), hidden \(String(describing: hidden))")
    _ = await call("cmuxWaveform.setFallbackNotice({message: 'x', retry: 'r'}); cmuxWaveform.setFallbackNotice({}); return null")
    expect(await call("return document.getElementById('status-fallback').hidden") as? Bool == true, "an empty notice hides it")

    // host.js relays only the viewer's v2 commands.
    _ = await call("await cmuxWaveform.fromWebview({command: 'v2', req: {id: 900001, cmd: 'warm', on: true}}); return null")
    _ = await waitFor(3000) { await self.call("return !!document.getElementById('viewer').contentWindow.__v2Replies[900001]") as? Bool == true }
    let refused = await call("return JSON.stringify(document.getElementById('viewer').contentWindow.__v2Replies[900001] || null)") as? String ?? ""
    expect(refused.contains("not relayed: warm"), "host.js doesn't relay a command the viewer doesn't send: \(refused)")

    // An unreadable relay reply answers the viewer with an error (it never waits on it).
    _ = await call("""
      const real = window.fetch;
      window.fetch = async () => new Response(new Uint8Array([255, 255, 255, 127, 1, 2]), { headers: { 'Content-Type': 'application/octet-stream' } });
      try { await cmuxWaveform.fromWebview({command: 'v2', req: {id: 900002, cmd: 'valueAt', signalIds: [0], t: 0}}); } finally { window.fetch = real; }
      return null
      """)
    _ = await waitFor(3000) { await self.call("return !!document.getElementById('viewer').contentWindow.__v2Replies[900002]") as? Bool == true }
    let bad = await call("return JSON.stringify(document.getElementById('viewer').contentWindow.__v2Replies[900002] || null)") as? String ?? ""
    expect(bad.contains("\"error\"") && bad.contains("900002"), "an unreadable relay reply becomes an error reply for the viewer: \(bad)")
  }

  /// A VCD: no set-windowing message, and no helper.
  func vcdChecks() async {
    let order = await messageOrder()
    expect(order.contains("initViewport") && !order.contains("set-windowing"), "a VCD gets no set-windowing: \(order.prefix(6))")
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
    await sleep(500)
    let relayed = await call("return cmuxWaveform.v2Stats()") as? [String: Any]
    expect(relayed?["relayed"] as? Int == 0 && relayed?["cancelled"] as? Int == 0, "loading whole: no v2 requests at all: \(String(describing: relayed))")
    let pixels = await drawnPixels()
    expect(pixels > 500, "loading whole: bus0 is drawn: \(pixels) drawn pixels")
  }

  /// The reader's ARRAY scopes (helper-v2 replies with them inline): the netlist shows each
  /// array as a node holding its elements, nested by dimension; an element's path stays
  /// scope.name (adding by path, the link's scope listing, search, reveal).
  func arrayChecks() async {
    let r = await call("""
      const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
      const tree = document.getElementById('tree');
      const rowOf = (name) => [...tree.querySelectorAll('.row')].find((x) => x.querySelector('.name').textContent === name && x.offsetParent !== null);
      const kids = (row) => [...row.nextElementSibling.children].filter((e) => e.classList.contains('row')).map((e) => e.querySelector('.name').textContent);
      const open = async (name) => { const row = rowOf(name); if (!row) { return null; } if (!row.classList.contains('open')) { row.click(); }
        for (let i = 0; i < 60 && !row.nextElementSibling.children.length; i++) { await sleep(50); } return kids(row); };
      const R = {};
      R.tb = await open('tb');
      R.addr = await open('dfp_addr[1:0]');
      R.cube = await open('cube[1:0]');
      R.cube1 = await open('cube[1][2:0]');
      const H = window.cmuxWaveform.host, L = window.cmuxWaveform.link;
      const v = await H.findItem('tb.dfp_addr[0]', undefined, undefined, true);
      R.found = v ? [window.cmuxNetlist.instancePath(v), v.width] : null;
      R.cubeElem = (await H.findItem('tb.cube[1][2]', undefined, undefined, true) || {}).width || null;
      R.linkTb = ((await L.scopeChildren(['tb'])) || []).map((x) => x.name + (x.isScope ? '/' : ''));
      const found = await H.search('dfp_addr[0]');
      R.search = found.searchResults.map((x) => x.instancePath);
      rowOf('dfp_addr[1:0]').click(); await sleep(200);
      R.revealed = await window.cmuxNetlist.reveal(v.netlistId);
      const shown = rowOf('dfp_addr[0]');
      R.revealedShown = !!shown && shown.classList.contains('selected');
      await window.cmuxCommands.run('waveformViewer.addVariable', { instancePath: 'tb.dfp_addr[1]', quiet: true });
      const rows = () => { const st = window.cmuxCommands.sessionSnapshot().state; return ((st && st.displayedSignals) || []).map((d) => d.name); };
      for (let i = 0; i < 100 && !rows().length; i++) { await sleep(50); }
      R.rows = rows();
      return JSON.stringify(R);
      """) as? String
    let o = (r.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
    print("arrays:", o)
    let tb = o["tb"] as? [String] ?? []
    expect(tb.contains("dfp_addr[1:0]") && tb.contains("cube[1:0]") && !tb.contains("dfp_addr[1]") && !tb.contains("cube[1][2]"),
           "the scope shows each array as one node, not its elements: \(tb)")
    expect(o["addr"] as? [String] == ["dfp_addr[1]", "dfp_addr[0]"], "the array node holds its elements: \(o["addr"] ?? "nil")")
    expect(o["cube"] as? [String] == ["cube[1][2:0]", "cube[0][2:0]"] && o["cube1"] as? [String] == ["cube[1][2]", "cube[1][1]", "cube[1][0]"],
           "a 3-D array nests by dimension: \(o["cube"] ?? "nil") \(o["cube1"] ?? "nil")")
    expect((o["found"] as? [Any]).map { "\($0)" } == "[tb.dfp_addr[0], 16]" && o["cubeElem"] as? Int == 4,
           "an element's path is still scope.name: \(o["found"] ?? "nil")")
    let link = o["linkTb"] as? [String] ?? []
    expect(link.contains("dfp_addr[0]") && link.contains("cube[0][1]") && !link.contains(where: { $0.hasSuffix("/") && $0 != "dut/" }),
           "the source link's scope listing has the elements, not the array nodes: \(link)")
    expect(o["search"] as? [String] == ["tb.dfp_addr[0]"], "search finds an element once: \(o["search"] ?? "nil")")
    expect(o["revealed"] as? Bool == true && o["revealedShown"] as? Bool == true, "Show in Netlist opens the array node to the element")
    expect(o["rows"] as? [String] == ["tb.dfp_addr[1]"], "an element adds by its path: \(o["rows"] ?? "nil")")
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
  do { try await fallbackChecks() } catch { expect(false, "fallback checks ran: \(error)") }
  do {
    let home = try makeHome("page", installs: [v2Install, v1Install])
    let page = Page(loading: .auto)
    let ok = await page.open(home: home)
    expect(ok, "v2 page opened the synthetic dump")
    if ok { await page.windowedChecks(); await page.riscvSearchChecks(); await page.hostChecks() }
    await page.snapshot()
    page.close()
    let whole = Page(loading: .whole)
    let ok2 = await whole.open(home: home)
    expect(ok2, "loading whole page opened")
    if ok2 { await whole.wholeChecks() }
    whole.close()
    let arrays = Page(loading: .auto, dump: "synth:ms=1,buses=1,wide=0,arrays=1")
    let ok4 = await arrays.open(home: home)
    expect(ok4, "a page with packed arrays opened")
    if ok4 { await arrays.arrayChecks() }
    arrays.close()
    let vcdURL = scratch.appendingPathComponent("small.vcd")
    try Data("$timescale 1ns $end\n$scope module tb $end\n$var wire 1 ! clk $end\n$upscope $end\n$enddefinitions $end\n#0\n0!\n#10\n1!\n#20\n0!\n".utf8)
      .write(to: vcdURL)
    let vcdPage = Page(loading: .auto, vcd: vcdURL)
    let ok3 = await vcdPage.open(home: home)
    expect(ok3, "a VCD page opened")
    if ok3 { await vcdPage.vcdChecks() }
    vcdPage.close()
  } catch { expect(false, "page checks ran: \(error)") }
  print(failures == 0 ? "WINDOWED CHECKS PASSED" : "WINDOWED CHECKS FAILED: \(failures)")
  exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("timeout"); exit(1) }
app.run()
