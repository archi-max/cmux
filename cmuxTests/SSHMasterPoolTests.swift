import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// sshd allows 10 sessions on one connection by default and refuses the rest
/// with no fallback. The one-off masters must be warm before the first run,
/// come back when they die, and never be asked for an 11th session.
struct SSHMasterPoolTests {
    /// A host whose sshd refuses an 11th session on a connection, as sshd does.
    private final class MockSSHD: SSHMasterPool.Control, @unchecked Sendable {
        let lock = NSLock()
        var starts: [String] = []
        var alive: Set<String> = []
        var sessions: [String: Int] = [:]
        var peak: [String: Int] = [:]
        var refused = 0
        var direct = 0
        var startFails = false
        var startDelayNanoseconds: UInt64 = 0

        func start(_ route: SSHMasterPool.Route, path: String) async -> Bool {
            if startDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: startDelayNanoseconds) }
            return lock.withLock {
                starts.append(path)
                guard !startFails else { return false }
                alive.insert(path)
                return true
            }
        }

        func isAlive(_ route: SSHMasterPool.Route, path: String) async -> Bool {
            lock.withLock { alive.contains(path) }
        }

        func kill(_ path: String) { lock.withLock { _ = alive.remove(path) } }

        /// One run with `options`: on its master's connection when that master
        /// is alive (refused past 10 sessions), else a connection of its own.
        func run(_ options: [String], nanoseconds: UInt64) async -> Bool {
            let path = SSHMasterPool.controlPath(in: options) ?? "none"
            let admitted: Bool = lock.withLock {
                guard alive.contains(path) else { direct += 1; return true }
                let open = sessions[path, default: 0]
                guard open < 10 else { refused += 1; return false }
                sessions[path] = open + 1
                peak[path] = max(peak[path, default: 0], open + 1)
                return true
            }
            guard admitted else { return false }
            try? await Task.sleep(nanoseconds: nanoseconds)
            lock.withLock { if alive.contains(path) { sessions[path, default: 1] -= 1 } }
            return true
        }
    }

    private static let options = ["BatchMode=yes", "ProxyCommand=/bin/sh -c true", "ControlPath=/tmp/cmux-pool-test-ops"]

    private static func route() throws -> SSHMasterPool.Route {
        try #require(SSHMasterPool.Route(destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: options))
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func burst(_ pool: SSHMasterPool, sshd: MockSSHD, runs: Int, nanoseconds: UInt64 = 30_000_000) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<runs {
                group.addTask {
                    _ = try? await pool.withSession(
                        destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: options
                    ) { leased in await sshd.run(leased, nanoseconds: nanoseconds) }
                }
            }
        }
    }

    /// The first one-off run after the carrier connects uses the master the
    /// connect opened: no handshake of its own, no second start.
    @Test
    func testTheFirstRunReusesTheWarmMaster() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        pool.warm(try Self.route())
        let ready1 = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains("/tmp/cmux-pool-test-ops") } }
        #expect(ready1)

        var used: [String] = []
        _ = try await pool.withSession(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: Self.options
        ) { leased in used = leased; return 0 }
        #expect(SSHMasterPool.controlPath(in: used) == "/tmp/cmux-pool-test-ops")
        #expect(used.contains("ProxyCommand=/bin/sh -c true"))
        #expect(sshd.lock.withLock { sshd.starts } == ["/tmp/cmux-pool-test-ops"])
        #expect(sshd.lock.withLock { sshd.direct } == 0)
    }

    /// 40 runs at once: no master is asked for an 11th session, none fails,
    /// and a second master takes the overflow.
    @Test
    func testABurstNeverReachesTheSessionLimit() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
        pool.warm(try Self.route())
        let ready2 = await Self.waitUntil { sshd.lock.withLock { !sshd.alive.isEmpty } }
        #expect(ready2)

        await Self.burst(pool, sshd: sshd, runs: 40)
        let (refused, peak, starts) = sshd.lock.withLock { (sshd.refused, sshd.peak, sshd.starts) }
        #expect(refused == 0)
        #expect(peak.values.allSatisfy { $0 <= SSHMasterPool.capacity })
        #expect(starts.contains("/tmp/cmux-pool-test-ops2"))
        let route = try Self.route()
        #expect(pool.sessionsInUse(route, path: "/tmp/cmux-pool-test-ops") == 0)
    }

    /// A master that dies is replaced by the health check before the next run.
    @Test
    func testADeadMasterComesBack() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .milliseconds(30))
        let path = "/tmp/cmux-pool-test-ops"
        pool.warm(try Self.route())
        let ready3 = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(path) } }
        #expect(ready3)
        sshd.kill(path)
        let ready4 = await Self.waitUntil { sshd.lock.withLock { sshd.starts.filter { $0 == path }.count == 2 && sshd.alive.contains(path) } }
        #expect(ready4)

        var used: [String] = []
        _ = try await pool.withSession(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: Self.options
        ) { leased in used = leased; return 0 }
        #expect(SSHMasterPool.controlPath(in: used) == path)
    }

    /// When no master can start, a run still runs, on a connection of its own.
    @Test
    func testARunWithoutAMasterConnectsDirectly() async throws {
        let sshd = MockSSHD()
        sshd.startFails = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        var used: [String] = []
        let value = try await pool.withSession(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: Self.options
        ) { leased in used = leased; return 7 }
        #expect(value == 7)
        #expect(SSHMasterPool.controlPath(in: used) == "none")
    }

    /// Options that name no pool master pass through untouched.
    @Test
    func testOptionsWithoutAPoolPathPassThrough() async throws {
        let pool = SSHMasterPool(control: MockSSHD())
        for options in [["BatchMode=yes"], ["ControlPath=none"], ["ControlPath none", "BatchMode=yes"]] {
            let used = try await pool.withSession(
                destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: options
            ) { $0 }
            #expect(used == options)
        }
        #expect(SSHMasterPool.controlPath(in: ["BatchMode=yes", "ControlPath=/tmp/a", "ControlPath=/tmp/b"]) == "/tmp/a")
        #expect(SSHMasterPool.replacingControlPath(in: ["ControlPath=/tmp/a", "BatchMode=yes"], with: "/tmp/a2")
            == ["BatchMode=yes", "ControlPath=/tmp/a2"])
    }
}
