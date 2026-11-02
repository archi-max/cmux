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
        await #expect(throws: SSHFileChannel.Failure.tooLarge) { _ = try await c.read(big.path, maxBytes: 4999) }
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
}
