import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Files panel's per-host file channel, against the real server script
/// under a local `sh` standing in for ssh: one run serves every open, names
/// that would break a shell reach the filesystem unchanged, and a dead or
/// silent channel says so instead of hanging.
@Suite(.serialized) struct SSHFileChannelTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-chan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A channel whose "ssh" is `/bin/sh -c '<prefix> <command>'` with HOME set.
    private func channel(home: URL, prefix: String = "", requestTimeout: TimeInterval = 10) -> SSHFileChannel {
        let homePath = home.path
        return SSHFileChannel(launch: { command in
            (URL(fileURLWithPath: "/bin/sh"), ["-c", "HOME='\(homePath)'; export HOME; \(prefix) \(command)"])
        }, readyTimeout: 10, requestTimeout: requestTimeout)
    }

    @Test func oneRunServesEveryOpen() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.sv")
        try Data("module a; endmodule\n".utf8).write(to: file)
        let c = channel(home: root)
        defer { c.close() }
        for _ in 0..<10 {
            let stamp = try await c.stat(file.path)
            let read = try await c.read(file.path, maxBytes: nil)
            #expect(stamp.size == 20 && read.size == 20 && read.data == Data("module a; endmodule\n".utf8))
            #expect(read.path == file.path && stamp.modificationTime == read.modificationTime)
        }
        #expect(c.launchCount == 1, "10 opens (stat + read each) take one ssh run, not 20: \(c.launchCount)")
    }

    @Test func everyLoginShellRunsTheServer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("it's here.sv")
        try Data("ok\n".utf8).write(to: file)
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        for shell in shells {
            let homePath = root.path
            let c = SSHFileChannel(launch: { command in
                (URL(fileURLWithPath: "/usr/bin/env"), ["HOME=\(homePath)", shell, "-c", command])
            })
            let r = try await c.probe(["~/it's here.sv"], maxBytes: 10)
            #expect(r.data == Data("ok\n".utf8), "\(shell): \(r.data.count) bytes")
            c.close()
        }
    }

    @Test func aWarmOpenCostsNoExec() async throws {
        // Each ssh exec here costs 0.3 s, as a new session on a real host does;
        // an open on the running channel costs none of it.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("b.txt")
        try Data(repeating: 0x61, count: 30_000).write(to: file)
        let c = channel(home: root, prefix: "sleep 0.3;")
        defer { c.close() }
        let t0 = Date()
        _ = try await c.stat(file.path)
        let cold = Date().timeIntervalSince(t0)
        var warm: [TimeInterval] = []
        for _ in 0..<20 {
            let t = Date()
            _ = try await c.stat(file.path)
            let r = try await c.read(file.path, maxBytes: nil)
            warm.append(Date().timeIntervalSince(t))
            #expect(r.data.count == 30_000)
        }
        let median = warm.sorted()[warm.count / 2]
        print("    cold \(Int(cold * 1000)) ms, warm open median \(Int(median * 1000)) ms")
        #expect(cold >= 0.3 && median < 0.2, "cold \(cold) s, warm open median \(median) s")
    }

    @Test func hostileNamesReachTheFilesystemUnchanged() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["it's.sv", "$(touch PWNED).sv", "`touch PWNED2`", "-rf", "a b\tc.sv", "semi;colon|pipe&.sv",
                     "dq\"uote.sv", "back\\slash.sv", "nl\nin.sv", "*", "~user", "ünïcödé.sv", "R 1 0 0 0 0 0 -"]
        let c = channel(home: root)
        defer { c.close() }
        for (i, name) in names.enumerated() {
            let url = root.appendingPathComponent(name)
            let body = Data("file \(i)\n".utf8)
            try body.write(to: url)
            let read = try await c.read(url.path, maxBytes: 1000)
            #expect(read.data == body && read.path == url.path, "\(name): \(read.data.count) bytes from \(read.path ?? "nil")")
            let stamp = try await c.stat(url.path)
            #expect(stamp.size == Int64(body.count), "\(name) stat")
        }
        let listing = String(decoding: try await c.list(root.path, showHidden: false), as: UTF8.self)
        #expect(listing.contains("it's.sv") && listing.contains("-rf"), "list: \(listing)")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PWNED2").path))
        #expect(!FileManager.default.fileExists(atPath: "PWNED"))
    }

    @Test func probeExpandsHomeAndTakesTheFirstFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tb"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("tb/t.sv"))
        let c = channel(home: root)
        defer { c.close() }
        let r = try await c.probe(["/nonexistent/t.sv", root.appendingPathComponent("tb").path, "~/tb/t.sv"], maxBytes: 100)
        #expect(r.index == 2 && r.path == root.appendingPathComponent("tb/t.sv").path && r.data == Data("x\n".utf8))
        await #expect(throws: SSHFileChannel.Failure.noFile) { _ = try await c.probe(["/nonexistent/a", "~/none"], maxBytes: 100) }
    }

    @Test func capsAndMissingFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.bin")
        try Data(repeating: 0, count: 5000).write(to: big)
        let c = channel(home: root)
        defer { c.close() }
        do {
            _ = try await c.read(big.path, maxBytes: 4999)
            Issue.record("a file over the cap was sent")
        } catch let SSHFileChannel.Failure.tooLarge(refused) {
            #expect(refused.size == 5000 && refused.path == big.path && refused.data.isEmpty, "\(refused)")
        }
        let exact = try await c.read(big.path, maxBytes: 5000)
        #expect(exact.data.count == 5000)
        await #expect(throws: SSHFileChannel.Failure.noFile) { _ = try await c.stat(root.appendingPathComponent("gone").path) }
        await #expect(throws: SSHFileChannel.Failure.noFile) { _ = try await c.read(root.path, maxBytes: nil) }
        #expect(c.launchCount == 1, "errors don't end the channel: \(c.launchCount) runs")
    }

    @Test func bannersAndSpoofedFramesBeforeTheReadyLineAreIgnored() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("c.txt")
        try Data("real\n".utf8).write(to: file)
        let c = channel(home: root, prefix: "echo 'Welcome to the host'; echo 'R 1 0 9 9 4 0 -'; echo FAKE;")
        defer { c.close() }
        let r = try await c.read(file.path, maxBytes: nil)
        #expect(r.data == Data("real\n".utf8))
    }

    @Test func aDeadChannelFailsFastThenRestarts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("d.txt")
        try Data("d\n".utf8).write(to: file)
        // A host where the server never starts (the login shell exits): unavailable, not a hang.
        let dead = SSHFileChannel(launch: { _ in (URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 255"]) }, readyTimeout: 2)
        let t0 = Date()
        await #expect(throws: SSHFileChannel.Failure.unavailable) { _ = try await dead.stat(file.path) }
        #expect(Date().timeIntervalSince(t0) < 3)
        // In the backoff, no new run is started.
        await #expect(throws: SSHFileChannel.Failure.unavailable) { _ = try await dead.stat(file.path) }
        #expect(dead.launchCount == 1)
        // A channel closed under a request: that request fails, the next one starts a new run.
        let c = channel(home: root)
        _ = try await c.stat(file.path)
        c.close()
        _ = try await c.stat(file.path)
        #expect(c.launchCount == 2)
        c.close()
    }

    @Test func aSilentHostTimesOut() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The server reads nothing (its stdin taken by a sleeping command): the request times out.
        let c = SSHFileChannel(launch: { _ in
            (URL(fileURLWithPath: "/bin/sh"), ["-c", "echo cmux-files-ready 1 x; sleep 30"])
        }, readyTimeout: 1, requestTimeout: 1.5)
        let t0 = Date()
        await #expect(throws: SSHFileChannel.Failure.unavailable) { _ = try await c.stat(root.path) }
        #expect(Date().timeIntervalSince(t0) < 3)
        c.close()
    }

    // MARK: Review follow-ups

    /// The real server's ready line for `command` (the nonce taken from it), then `then`.
    private static func readyThen(_ then: String) -> SSHFileChannel.Launch {
        { command in
            let b64 = command.components(separatedBy: "printf %s ")[1].components(separatedBy: " ")[0]
            let inner = String(decoding: Data(base64Encoded: b64)!, as: UTF8.self)
            let r = inner.range(of: SSHFileChannel.readyPrefix)!
            let nonce = String(inner[r.upperBound...].prefix(32))
            return (URL(fileURLWithPath: "/bin/sh"), ["-c", "echo '\(SSHFileChannel.readyPrefix)\(nonce)'; \(then)"])
        }
    }

    @Test func aZeroCapProbeNamesTheRefusedFile() async throws {
        // A ⌘-clicked dump is located with a cap-0 probe: refused, but named.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dump = root.appendingPathComponent("sim/dump.fsdb")
        try FileManager.default.createDirectory(at: dump.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: dump)
        let c = channel(home: root)
        defer { c.close() }
        do {
            _ = try await c.probe(["/nonexistent/dump.fsdb", "~/sim/dump.fsdb"], maxBytes: 0)
            Issue.record("cap 0 sent the file")
        } catch let SSHFileChannel.Failure.tooLarge(refused) {
            #expect(refused.index == 1 && refused.path == dump.path && refused.size == 4096 && refused.modificationTime > 0,
                    "\(refused)")
        }
    }

    @Test func aReplyOverItsCapOrShortOfItsSizeIsNotTakenAsTheFile() async throws {
        // A file that grew (or shrank) between its stat and its read: never a silently cut copy.
        let over = SSHFileChannel(launch: Self.readyThen("read l; printf 'R 1 0 9 3 5 0 -\\nabcde'; sleep 5"), readyTimeout: 5)
        defer { over.close() }
        do {
            let r = try await over.read("/x", maxBytes: 4)
            Issue.record("took \(r.data.count) bytes over a cap of 4")
        } catch let SSHFileChannel.Failure.tooLarge(refused) {
            #expect(refused.data.isEmpty)
        }
        let short = SSHFileChannel(launch: Self.readyThen("read l; printf 'R 1 0 9 8 5 0 -\\nabcde'; sleep 5"), readyTimeout: 5)
        defer { short.close() }
        await #expect(throws: SSHFileChannel.Failure.changed) { _ = try await short.read("/x", maxBytes: nil) }
    }

    @Test func aTrailingNewlineInANameIsKept() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("plain\n".utf8).write(to: root.appendingPathComponent("trail"))
        try Data("newline\n".utf8).write(to: root.appendingPathComponent("trail\n"))
        let c = channel(home: root)
        defer { c.close() }
        let r = try await c.read(root.appendingPathComponent("trail\n").path, maxBytes: 100)
        #expect(r.data == Data("newline\n".utf8), "got \(String(decoding: r.data, as: UTF8.self))")
        let p = try await c.probe([root.appendingPathComponent("trail\n").path], maxBytes: 100)
        #expect(p.data == Data("newline\n".utf8))
        let s = try await c.stat(root.appendingPathComponent("trail\n").path)
        #expect(s.size == 8)
    }

    @Test func tildeUserIsNeverExpanded() async throws {
        // Only `~` and `~/…` name the home folder; `~user` is a literal name, never looked up or eval'd.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = channel(home: root)
        defer { c.close() }
        await #expect(throws: SSHFileChannel.Failure.noFile) {
            _ = try await c.probe(["~root/../../etc/hosts", "~nobody/../../etc/hosts", "~$(id -un)/x"], maxBytes: 100_000)
        }
    }

    @Test func concurrentRequestsGetTheirOwnAnswers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<24 {
            try (Data("body \(i) ".utf8) + Data(repeating: UInt8(65 + i), count: i * 997)).write(to: root.appendingPathComponent("f\(i)"))
        }
        let c = channel(home: root)
        defer { c.close() }
        let bad = await withTaskGroup(of: Int.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let url = root.appendingPathComponent("f\(i)")
                    guard let r = try? await c.read(url.path, maxBytes: 1 << 20) else { return 1 }
                    return r.data == (try? Data(contentsOf: url)) && r.path == url.path ? 0 : 1
                }
            }
            var n = 0
            for await b in group { n += b }
            return n
        }
        #expect(bad == 0, "\(bad) of 24 concurrent reads got another request's answer")
        #expect(c.launchCount == 1)
    }

    @Test func aStuckServerAfterReadyTimesOutThePendingRequest() async throws {
        let c = SSHFileChannel(launch: Self.readyThen("sleep 30"), readyTimeout: 1, requestTimeout: 2)
        defer { c.close() }
        let t0 = Date()
        await #expect(throws: SSHFileChannel.Failure.unavailable) { _ = try await c.stat("/") }
        let dt = Date().timeIntervalSince(t0)
        #expect(dt > 1.5 && dt < 4, "a silent server held the request \(dt) s")
    }

    @Test func aSpoofedReadyLineWithoutTheNonceIsIgnored() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("s.txt")
        try Data("real\n".utf8).write(to: file)
        let homePath = root.path
        let c = SSHFileChannel(launch: { command in
            (URL(fileURLWithPath: "/bin/sh"),
             ["-c", "HOME='\(homePath)'; echo 'cmux-files-ready 1 deadbeef'; echo 'R 1 0 9 9 5 0 -'; echo 'fake!'; \(command)"])
        })
        defer { c.close() }
        let r = try await c.read(file.path, maxBytes: nil)
        #expect(r.data == Data("real\n".utf8), "got \(String(decoding: r.data, as: UTF8.self))")
    }

    /// A pool whose channels run the real server under a local `sh` with its own TMPDIR.
    private func pool(home: URL, tmp: URL) -> (SSHFileChannelPool, @Sendable (String) -> SSHFileChannel.Launch) {
        let homePath = home.path, tmpPath = tmp.path
        let launch: @Sendable (String) -> SSHFileChannel.Launch = { _ in
            { command in
                (URL(fileURLWithPath: "/bin/sh"), ["-c", "HOME='\(homePath)'; TMPDIR='\(tmpPath)'; export TMPDIR; \(command)"])
            }
        }
        return (SSHFileChannelPool(), launch)
    }

    @Test func aConnectedHostsFirstOpenMakesNoSpawnAndADisconnectLeavesNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("x.sv")
        try Data("x\n".utf8).write(to: file)
        let (pool, launch) = pool(home: root, tmp: tmp)
        // Connect: the channel starts before any open.
        var lease: SSHFileChannelPool.Lease? = pool.retain(key: "host-a", launch: launch("host-a"))
        let warm = pool.channel(key: "host-a", launch: launch("host-a"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(warm.launchCount == 1 && warm.isReady, "pre-warmed: \(warm.launchCount) runs, ready \(warm.isReady)")
        let t0 = Date()
        _ = try await warm.read(file.path, maxBytes: 100)
        #expect(warm.launchCount == 1, "the first open after connect spawned: \(warm.launchCount)")
        print("    first open after connect: \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).count == 1)
        // A second workspace on the same connection shares it; the channel stays until both go.
        var second: SSHFileChannelPool.Lease? = pool.retain(key: "host-a", launch: launch("host-a"))
        lease = nil
        _ = try await warm.stat(file.path)
        #expect(warm.launchCount == 1)
        second = nil
        _ = (lease, second)
        // Disconnect: the server and its temp dir are gone from the host.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        #expect(left.isEmpty, "host temp dir left after the disconnect: \(left)")
        #expect(pool.channelCount == 0)
        // A host nobody connected to starts nothing until it is asked.
        let cold = pool.channel(key: "host-b", launch: launch("host-b"))
        #expect(cold.launchCount == 0)
        cold.close()
    }
}
