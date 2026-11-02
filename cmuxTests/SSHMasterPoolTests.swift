import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// sshd allows 10 sessions on one connection by default and refuses the rest
/// with no fallback. The one-off masters must be warm before the first run,
/// come back when they die, never be asked for an 11th session, and give way
/// to the carrier's master on a host where they can't log in.
struct SSHMasterPoolTests {
    /// A host whose sshd refuses an 11th session on a connection, as sshd does.
    /// Masters are per destination: one template path names a socket per host.
    private final class MockSSHD: SSHMasterPool.Control, @unchecked Sendable {
        let lock = NSLock()
        var starts: [String] = []
        var alive: Set<String> = []
        var sessions: [String: Int] = [:]
        var peak: [String: Int] = [:]
        var refused = 0
        var direct = 0
        var startFails = false
        /// Masters past the first never start (the pool can't grow).
        var onlyFirstMasterStarts = false
        var entered: [String] = []

        static func id(_ destination: String, _ path: String) -> String { destination + "|" + path }

        func start(_ route: SSHMasterPool.Route, path: String) async -> Bool {
            lock.withLock {
                starts.append(path)
                guard !startFails, !(onlyFirstMasterStarts && path != route.basePath) else { return false }
                alive.insert(Self.id(route.destination, path))
                return true
            }
        }

        func isAlive(_ route: SSHMasterPool.Route, path: String) async -> Bool {
            lock.withLock { alive.contains(Self.id(route.destination, path)) }
        }

        func kill(_ path: String, destination: String = SSHMasterPoolTests.destination) {
            lock.withLock { _ = alive.remove(Self.id(destination, path)) }
        }

        /// One run with `options`: on its master's connection when that master
        /// is alive (refused past 10 sessions), else a connection of its own.
        func run(_ options: [String], destination: String = SSHMasterPoolTests.destination,
                 label: String = "", nanoseconds: UInt64) async -> Bool {
            let id = Self.id(destination, SSHMasterPool.controlPath(in: options) ?? "none")
            let admitted: Bool = lock.withLock {
                entered.append(label)
                guard alive.contains(id) else { direct += 1; return true }
                let open = sessions[id, default: 0]
                guard open < 10 else { refused += 1; return false }
                sessions[id] = open + 1
                peak[id] = max(peak[id, default: 0], open + 1)
                return true
            }
            guard admitted else { return false }
            try? await Task.sleep(nanoseconds: nanoseconds)
            lock.withLock { if alive.contains(id) { sessions[id, default: 1] -= 1 } }
            return true
        }
    }

    fileprivate static let destination = "alice@example.invalid"
    private static let base = "/tmp/cmux-pool-test-ops"
    private static let carrier = "/tmp/cmux-pool-test-carrier"
    private static let options = ["BatchMode=yes", "ProxyCommand=/bin/sh -c true", "ControlPath=" + base]

    private static func route(_ destination: String = destination, options: [String] = options) throws -> SSHMasterPool.Route {
        try #require(SSHMasterPool.Route(destination: destination, port: nil, identityFile: nil, sshOptions: options))
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func session(_ pool: SSHMasterPool, destination: String = destination,
                                options: [String] = options) async throws -> [String] {
        try await pool.withSession(destination: destination, port: nil, identityFile: nil, sshOptions: options) { $0 }
    }

    private static func burst(_ pool: SSHMasterPool, sshd: MockSSHD, runs: Int, nanoseconds: UInt64 = 30_000_000) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<runs {
                group.addTask {
                    _ = try? await pool.withSession(
                        destination: destination, port: nil, identityFile: nil, sshOptions: options
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
        pool.warm(try Self.route(), carrierPath: Self.carrier)
        let ready1 = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready1)

        let used = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: used) == Self.base)
        #expect(used.contains("ProxyCommand=/bin/sh -c true"))
        #expect(sshd.lock.withLock { sshd.starts } == [Self.base])
        #expect(sshd.lock.withLock { sshd.direct } == 0)
    }

    /// 40 runs at once: no master is asked for an 11th session, none fails,
    /// and a second master takes the overflow.
    @Test
    func testABurstNeverReachesTheSessionLimit() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
        pool.warm(try Self.route(), carrierPath: Self.carrier)
        let ready2 = await Self.waitUntil { sshd.lock.withLock { !sshd.alive.isEmpty } }
        #expect(ready2)

        await Self.burst(pool, sshd: sshd, runs: 40)
        let (refused, peak, starts) = sshd.lock.withLock { (sshd.refused, sshd.peak, sshd.starts) }
        #expect(refused == 0)
        #expect(peak.values.allSatisfy { $0 <= SSHMasterPool.capacity })
        #expect(starts.contains(Self.base + "2"))
        let burstRoute = try Self.route()
        #expect(pool.sessionsInUse(burstRoute, path: Self.base) == 0)
    }

    /// A master that dies is replaced by the health check before the next run.
    @Test
    func testADeadMasterComesBack() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .milliseconds(30))
        pool.warm(try Self.route(), carrierPath: Self.carrier)
        let id = MockSSHD.id(Self.destination, Self.base)
        let ready3 = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(id) } }
        #expect(ready3)
        sshd.kill(Self.base)
        let ready4 = await Self.waitUntil { sshd.lock.withLock { sshd.starts.filter { $0 == Self.base }.count == 2 && sshd.alive.contains(id) } }
        #expect(ready4)

        let usedAfter = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: usedAfter) == Self.base)
    }

    /// When no master can start and there is no carrier to use, a run still
    /// runs, on a connection of its own.
    @Test
    func testARunWithoutAMasterConnectsDirectly() async throws {
        let sshd = MockSSHD()
        sshd.startFails = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        pool.warm(try Self.route(), carrierPath: nil)
        var used: [String] = []
        let value = try await pool.withSession(
            destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options
        ) { leased in used = leased; return 7 }
        #expect(value == 7)
        #expect(SSHMasterPool.controlPath(in: used) == "none")
    }

    /// A host that takes only a password: the batch-mode master can't log in,
    /// so runs use the carrier's authenticated master, as before these masters,
    /// a few at a time, and none fails for want of a session.
    @Test
    func testRunsUseTheCarrierWhenTheMasterCantLogIn() async throws {
        let sshd = MockSSHD()
        sshd.startFails = true
        sshd.lock.withLock { _ = sshd.alive.insert(MockSSHD.id(Self.destination, Self.carrier)) }
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let failed = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        #expect(failed)
        #expect(pool.carrierPathIfMastersFail(route) == Self.carrier)

        let usedFirst = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: usedFirst) == Self.carrier)
        await Self.burst(pool, sshd: sshd, runs: 12)
        let (refused, direct, peak) = sshd.lock.withLock { (sshd.refused, sshd.direct, sshd.peak) }
        #expect(refused == 0)
        #expect(direct == 0)
        #expect((peak[MockSSHD.id(Self.destination, Self.carrier)] ?? 0) <= SSHMasterPool.carrierCapacity)

        let lease = pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options)
        #expect(SSHMasterPool.controlPath(in: lease.sshOptions) == Self.carrier)
        lease.release()
        lease.release()
        #expect(pool.sessionsInUse(route, path: Self.carrier) == 0)
    }

    /// Past the carrier's share, a run that waited still uses the carrier: a
    /// connection of its own couldn't log in.
    @Test
    func testAWaitOnTheCarrierEndsOnTheCarrier() async throws {
        let sshd = MockSSHD()
        sshd.startFails = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let failed = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        #expect(failed)
        let held = (0..<SSHMasterPool.carrierCapacity).map { _ in
            pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options)
        }
        #expect(held.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.carrier })
        let waited = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: waited) == Self.carrier)
        #expect(pool.sessionsInUse(route, path: Self.carrier) == SSHMasterPool.carrierCapacity)
        withExtendedLifetime(held) {}
    }

    /// A key that logs in: long-lived runs keep connections of their own.
    @Test
    func testLongLivedRunsKeepTheirOwnConnectionWhileTheMasterWorks() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { pool.sessionsInUse(route, path: Self.base) == 0 && sshd.lock.withLock { !sshd.alive.isEmpty } }
        #expect(ready)
        #expect(pool.carrierPathIfMastersFail(route) == nil)
    }

    /// A synchronous run takes a free session now, gives it back once, and
    /// connects directly rather than wait when none is free.
    @Test
    func testASynchronousLeaseNeverWaits() async throws {
        let sshd = MockSSHD()
        sshd.onlyFirstMasterStarts = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready)

        var leases: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.capacity {
            leases.append(pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options))
        }
        #expect(leases.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.base })
        #expect(pool.sessionsInUse(route, path: Self.base) == SSHMasterPool.capacity)
        let overflow = pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options)
        #expect(SSHMasterPool.controlPath(in: overflow.sshOptions) == "none")
        leases[0].release()
        leases[0].release()
        #expect(pool.sessionsInUse(route, path: Self.base) == SSHMasterPool.capacity - 1)
        leases.removeAll()
        #expect(pool.sessionsInUse(route, path: Self.base) == 0)
    }

    /// Waiters get freed sessions oldest first, one each: a hand-off doesn't
    /// free a second session. The held runs end 80 ms apart, so each frees
    /// one session at a time.
    @Test
    func testWaitersAreServedInOrderOneSessionEach() async throws {
        let sshd = MockSSHD()
        sshd.onlyFirstMasterStarts = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(20))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<SSHMasterPool.capacity {
                group.addTask {
                    _ = try? await pool.withSession(
                        destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options
                    ) { leased in await sshd.run(leased, label: "held\(index)", nanoseconds: 300_000_000 + UInt64(index) * 80_000_000) }
                }
            }
            _ = await Self.waitUntil { pool.sessionsInUse(route, path: Self.base) == SSHMasterPool.capacity }
            for (queued, label) in ["first", "second", "third"].enumerated() {
                group.addTask {
                    _ = try? await pool.withSession(
                        destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options
                    ) { leased in await sshd.run(leased, label: label, nanoseconds: 300_000_000) }
                }
                _ = await Self.waitUntil { pool.runsWaiting(route) == queued + 1 }
            }
            _ = await Self.waitUntil { sshd.lock.withLock { sshd.entered.contains("first") } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            #expect(pool.sessionsInUse(route, path: Self.base) <= SSHMasterPool.capacity)
        }
        let (entered, peak, refused) = sshd.lock.withLock { (sshd.entered, sshd.peak, sshd.refused) }
        #expect(entered.filter { !$0.hasPrefix("held") } == ["first", "second", "third"])
        #expect((peak[MockSSHD.id(Self.destination, Self.base)] ?? 0) <= SSHMasterPool.capacity)
        #expect(refused == 0)
        #expect(pool.sessionsInUse(route, path: Self.base) == 0)
    }

    /// A run cancelled before it queues for a session ends at once, rather
    /// than wait out ``SSHMasterPool/maxWait``.
    @Test
    func testACancelledRunDoesNotWait() async throws {
        let sshd = MockSSHD()
        sshd.onlyFirstMasterStarts = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(20))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready)
        let held = (0..<SSHMasterPool.capacity).map { _ in
            pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options)
        }

        let started = ContinuousClock.now
        let cancelledFirst = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await Self.session(pool); return false } catch { return error is CancellationError }
        }
        let firstEnded = await cancelledFirst.value
        #expect(firstEnded)
        let cancelledWhileQueued = Task { () -> Bool in
            do { _ = try await Self.session(pool); return false } catch { return error is CancellationError }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancelledWhileQueued.cancel()
        let queuedEnded = await cancelledWhileQueued.value
        #expect(queuedEnded)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(pool.sessionsInUse(route, path: Self.base) == SSHMasterPool.capacity)
        withExtendedLifetime(held) {}
    }

    /// One ControlPath template names a socket per host, so two hosts never
    /// share a master's count or its health.
    @Test
    func testHostsSharingATemplateKeepTheirOwnMasters() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        let template = ["BatchMode=yes", "ControlPath=/tmp/cmux-pool-test-%C-ops"]
        let hostA = try Self.route("a@example.invalid", options: template)
        let hostB = try Self.route("b@example.invalid", options: template)
        pool.warm(hostA, carrierPath: nil)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id("a@example.invalid", hostA.basePath)) } }
        #expect(ready)
        sshd.lock.withLock { sshd.startFails = true }
        pool.warm(hostB, carrierPath: nil)
        _ = await Self.waitUntil { sshd.lock.withLock { sshd.starts.count == 2 } }

        let usedA = try await Self.session(pool, destination: "a@example.invalid", options: template)
        let usedB = try await Self.session(pool, destination: "b@example.invalid", options: template)
        #expect(SSHMasterPool.controlPath(in: usedA) == hostA.basePath)
        #expect(SSHMasterPool.controlPath(in: usedB) == "none")
    }

    /// Options that name no warmed path pass through untouched: a user's own
    /// ControlPath never gets a master started at it.
    @Test
    func testOptionsWithoutAPoolPathPassThrough() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd)
        for options in [["BatchMode=yes"], ["ControlPath=none"], ["ControlPath none", "BatchMode=yes"],
                        ["ControlPath=/home/alice/.ssh/cm-%C"]] {
            let used = try await Self.session(pool, options: options)
            #expect(used == options)
            #expect(pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: options).sshOptions == options)
        }
        // A route at the carrier's own path is never pooled.
        pool.warm(try Self.route(options: ["ControlPath=" + Self.carrier]), carrierPath: Self.carrier)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(sshd.lock.withLock { sshd.starts }.isEmpty)
        #expect(SSHMasterPool.controlPath(in: ["BatchMode=yes", "ControlPath=/tmp/a", "ControlPath=/tmp/b"]) == "/tmp/a")
        #expect(SSHMasterPool.controlPath(in: ["ControlPath\t/tmp/a"]) == "/tmp/a")
        #expect(SSHMasterPool.replacingControlPath(in: ["ControlPath=/tmp/a", "BatchMode=yes"], with: "/tmp/a2")
            == ["BatchMode=yes", "ControlPath=/tmp/a2"])
    }

    /// A master's socket and OpenSSH's 17-byte temporary name must fit in
    /// `sun_path`; a longer one is never started.
    @Test
    func testAMasterPathMustFitASocket() {
        #expect(SSHMasterPool.ProcessControl.fitsSocketPath("/" + String(repeating: "a", count: 85)))
        #expect(!SSHMasterPool.ProcessControl.fitsSocketPath("/" + String(repeating: "a", count: 86)))
    }
}
