#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Driver tracing's Verdi engine on an SSH host: which sessions cmux keeps (least recently used
/// goes first), how it retries after a failed request, what a start that did not finish says,
/// and the launcher (Resources/vaporview/verdi-trace/verdi-trace.sh) against a fake `verdi` that
/// waits in the licence queue: it says so, and it ends Verdi when cmux's ssh goes away.
@Suite struct VerdiTraceLaunchTests {
    // MARK: Sessions kept

    @Test func theLeastRecentlyUsedSessionGoesFirst() {
        var keys = VerdiTraceLaunch.SessionKeys()
        keys.use("b|/x.fsdb")
        keys.use("a|/y.fsdb")
        keys.use("b|/x.fsdb")
        // Alphabetically "a" comes first, but "b" is the more recently used one: "a" goes.
        #expect(keys.evict(keeping: 1) == ["a|/y.fsdb"])
        #expect(keys.all == ["b|/x.fsdb"])
        var fresh = VerdiTraceLaunch.SessionKeys()
        fresh.use("b"); fresh.use("a"); fresh.use("b"); fresh.use("c")
        #expect(fresh.evict(keeping: 2) == ["a"])
        #expect(fresh.all == ["b", "c"])
        fresh.remove("b")
        #expect(fresh.all == ["c"])
    }

    // MARK: Retries

    @Test func aFailedRequestIsRetriedWithBackoff() {
        #expect(VerdiTraceLaunch.retryDelay(failures: 1) == 15)
        #expect(VerdiTraceLaunch.retryDelay(failures: 2) == 30)
        #expect(VerdiTraceLaunch.retryDelay(failures: 3) == 60)
        #expect(VerdiTraceLaunch.retryDelay(failures: 9) == 300)
        #expect(VerdiTraceLaunch.retryDelay(failures: 0) == 0)
    }

    // MARK: Background prefetch

    @Test func aBackgroundPrefetchFailsSoonerAndLeavesTheSessionAlone() {
        // One Verdi session per dump: the page prefetches at most this many requests at once.
        #expect(VerdiTraceLaunch.poolSize == 1)
        // A prefetch gives up well before a click's request, and its failure (a timeout among
        // them) doesn't make the next clicks go without Verdi.
        #expect(VerdiTraceLaunch.requestTimeout(background: false) == 120)
        #expect(VerdiTraceLaunch.requestTimeout(background: true) < VerdiTraceLaunch.requestTimeout(background: false) / 4)
        #expect(VerdiTraceLaunch.failureMarksSession(background: false))
        #expect(!VerdiTraceLaunch.failureMarksSession(background: true))
    }

    // MARK: A start that did not finish

    @Test func aLicenceWaitSaysSoNotTheShellsNoise() {
        let detail = "/home/u/.bashrc: line 36: export: `x': not a valid identifier\ncmux-verdi: waiting for a Verdi licence\n"
        let failure = VerdiTraceLaunch.startFailure(detail: detail)
        #expect(failure.code == "licenceQueue")
        #expect(failure.message.isEmpty)
    }

    @Test func otherStartFailuresDropTheLoginShellsNoise() {
        let detail = "/home/u/.bashrc: line 36: export: `x': not a valid identifier\nNovas: cannot open design\n"
        let failure = VerdiTraceLaunch.startFailure(detail: detail)
        #expect(failure.code == "start")
        #expect(failure.message == "Novas: cannot open design")
    }

    // MARK: The launcher

    static let launcher = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/vaporview/verdi-trace/verdi-trace.sh")

    /// A host folder with an FSDB, a KDB next to it, and a `verdi` that records its pid, prints
    /// the licence-queue warning and waits (as Novas does for a seat).
    static func fakeHost() throws -> (dir: URL, fsdb: URL, pidFile: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verdi-launch-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin"), sim = dir.appendingPathComponent("sim")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sim.appendingPathComponent("simv.daidir/kdb.elab++"), withIntermediateDirectories: true)
        let fsdb = sim.appendingPathComponent("dump.fsdb")
        try Data("x".utf8).write(to: fsdb)
        let pidFile = dir.appendingPathComponent("verdi.pid")
        let verdi = bin.appendingPathComponent("verdi")
        try """
        #!/bin/bash
        echo $$ > "\(pidFile.path)"
        echo '*WARN* Verdi-Elite (Verdi) license is not available. Try ... Verdi-Apex'
        sleep 300 &
        wait
        """.write(to: verdi, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verdi.path)
        return (dir, fsdb, pidFile)
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// stderr as it arrives (a blocking read would wait for the fake Verdi to end).
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    @Test func theLauncherSaysItWaitsForALicenceAndEndsVerdiWhenCmuxGoes() async throws {
        let host = try Self.fakeHost()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        let scratch = host.dir.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // cmux's ssh session: a shell that runs the launcher (not exec'd, so it can go away alone).
        let session = Process()
        session.executableURL = URL(fileURLWithPath: "/bin/sh")
        session.arguments = ["-c", "bash \"$1\" \"$2\" \"$3\"; echo gone", "sh", Self.launcher.path, scratch.path, host.fsdb.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = host.dir.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        session.environment = env
        let stderr = Pipe(), stdout = Pipe()
        session.standardError = stderr
        session.standardOutput = stdout
        session.standardInput = Pipe()
        try session.run()
        var pid: Int32 = 0
        for _ in 0..<100 where pid == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            pid = Int32((try? String(contentsOf: host.pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        #expect(pid > 0, "the fake verdi started")
        // The launcher reports the licence queue on stderr (cmux shows it when it gives up).
        let heard = Heard()
        stderr.fileHandleForReading.readabilityHandler = { handle in heard.append(handle.availableData) }
        defer { stderr.fileHandleForReading.readabilityHandler = nil }
        var said = ""
        for _ in 0..<80 where !said.contains("waiting for a Verdi licence") {
            try await Task.sleep(nanoseconds: 100_000_000)
            said = heard.text
        }
        #expect(said.contains("cmux-verdi: waiting for a Verdi licence"), "stderr: \(said)")
        // cmux gives up: its ssh session ends. Verdi must not outlive it.
        session.terminate()
        var ended = false
        for _ in 0..<150 where !ended {
            try await Task.sleep(nanoseconds: 100_000_000)
            ended = pid > 0 && !Self.alive(pid)
        }
        #expect(ended, "verdi (pid \(pid)) ended within 15 s of the session")
        if pid > 0, Self.alive(pid) { kill(pid, SIGKILL) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!FileManager.default.fileExists(atPath: scratch.path), "the scratch folder is removed")
    }
}
#endif
