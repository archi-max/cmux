import Foundation
import Testing
#if canImport(CmuxFoundation)
import CmuxFoundation
#endif

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
        /// Starts fail as a network error would.
        var startFails = false
        /// Starts are refused as a host that takes only a password refuses a batch login.
        var loginRefused = false
        var startDelayNanoseconds: UInt64 = 0
        /// Masters past the first never start (the pool can't grow).
        var onlyFirstMasterStarts = false
        var entered: [String] = []

        /// A socket per route: `%C` hashes the destination and port.
        static func id(_ destination: String, _ path: String, port: Int? = nil) -> String {
            destination + "|" + (port.map(String.init) ?? "") + "|" + path
        }

        func start(_ route: SSHMasterPool.Route, path: String) async -> SSHMasterPool.StartOutcome {
            if startDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: startDelayNanoseconds) }
            return lock.withLock {
                starts.append(path)
                if loginRefused { return .unavailable }
                guard !startFails, !(onlyFirstMasterStarts && path != route.basePath) else { return .failed }
                alive.insert(Self.id(route.destination, path, port: route.port))
                return .started
            }
        }

        func check(_ route: SSHMasterPool.Route, path: String) async -> SSHMasterPool.Liveness {
            lock.withLock { alive.contains(Self.id(route.destination, path, port: route.port)) ? .alive : .dead }
        }

        /// Sockets routes resolve to, where two routes name one (else per route).
        var sockets: [String: String] = [:]

        func socketPath(_ route: SSHMasterPool.Route, path: String) async -> String? {
            lock.withLock { sockets[route.key] ?? route.key }
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

    private static func route(_ destination: String = destination, port: Int? = nil, identityFile: String? = nil,
                              options: [String] = options) throws -> SSHMasterPool.Route {
        try #require(SSHMasterPool.Route(destination: destination, port: port, identityFile: identityFile, sshOptions: options))
    }

    private static func lease(_ pool: SSHMasterPool) async throws -> SSHMasterPool.Lease {
        try await pool.lease(destination: destination, port: nil, identityFile: nil, sshOptions: options)
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
        #expect(starts.contains(Self.base + "-2"))
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

    /// When no master can start (the network, say), a run doesn't wait for one
    /// but runs at once on a connection of its own, even with a carrier there.
    @Test
    func testARunWithoutAMasterConnectsDirectlyAtOnce() async throws {
        for carrier in [nil, Self.carrier] {
            let sshd = MockSSHD()
            sshd.startFails = true
            let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
            pool.warm(try Self.route(), carrierPath: carrier)
            _ = await Self.waitUntil { sshd.lock.withLock { !sshd.starts.isEmpty } }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let began = ContinuousClock.now
            var used: [String] = []
            let value = try await pool.withSession(
                destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options
            ) { leased in used = leased; return 7 }
            #expect(value == 7)
            #expect(SSHMasterPool.controlPath(in: used) == "none")
            #expect(ContinuousClock.now - began < .seconds(2))
        }
    }

    /// A run that queued while the only master was starting, which then fails,
    /// goes direct when the start ends, not after the whole wait.
    @Test
    func testAFailedStartSendsItsQueueDirect() async throws {
        let sshd = MockSSHD()
        sshd.startFails = true
        sshd.startDelayNanoseconds = 100_000_000
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
        pool.warm(try Self.route(), carrierPath: Self.carrier)
        let began = ContinuousClock.now
        let used = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: used) == "none")
        #expect(ContinuousClock.now - began < .seconds(2))
    }

    /// A run that arrives while the warm start is in flight gets that master
    /// when it comes up.
    @Test
    func testARunDuringTheWarmStartGetsTheMaster() async throws {
        let sshd = MockSSHD()
        sshd.startDelayNanoseconds = 150_000_000
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10))
        pool.warm(try Self.route(), carrierPath: Self.carrier)
        let began = ContinuousClock.now
        let used = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: used) == Self.base)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(sshd.lock.withLock { sshd.starts } == [Self.base])
    }

    /// A host that takes only a password: the batch-mode master's login is
    /// refused, so runs use the carrier's authenticated master, as before these
    /// masters, two at a time, and none fails for want of a session.
    @Test
    func testRunsUseTheCarrierWhenTheMasterCantLogIn() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        sshd.lock.withLock { _ = sshd.alive.insert(MockSSHD.id(Self.destination, Self.carrier)) }
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .seconds(10), carrierMaxWait: .seconds(30))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let failed = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        #expect(failed)
        #expect(pool.carrierPathIfMastersFail(route) == Self.carrier)

        let usedFirst = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: usedFirst) == Self.carrier)
        await Self.burst(pool, sshd: sshd, runs: 40, nanoseconds: 10_000_000)
        let (refused, direct, peak) = sshd.lock.withLock { (sshd.refused, sshd.direct, sshd.peak) }
        #expect(refused == 0)
        #expect(direct == 0)
        #expect((peak[MockSSHD.id(Self.destination, Self.carrier)] ?? 0) == SSHMasterPool.carrierCapacity)

        let lease = try await Self.lease(pool)
        #expect(SSHMasterPool.controlPath(in: lease.sshOptions) == Self.carrier)
        lease.release()
        lease.release()
        #expect(pool.sessionsInUse(route, path: Self.carrier) == 0)
    }

    /// A refused login isn't tried again (each try is a refused login on the
    /// host) until the carrier connects again.
    @Test
    func testARefusedLoginWaitsForTheNextCarrierConnect() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .milliseconds(20), maxWait: .milliseconds(50))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        _ = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        // Past the 1 s a failed start would back off for, with the health
        // loop ticking every 20 ms.
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(sshd.lock.withLock { sshd.starts.count } == 1)
    }

    /// The next carrier connect tries the refused master again at once.
    @Test
    func testTheNextCarrierConnectTriesARefusedMasterAgain() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(50))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        _ = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }

        sshd.lock.withLock { sshd.loginRefused = false }
        pool.warm(route, carrierPath: Self.carrier)
        let back = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(back)
        #expect(pool.carrierPathIfMastersFail(route) == nil)
        let used = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: used) == Self.base)
    }

    /// Past the carrier's share a run queues, and gets the carrier when a
    /// session frees; one that waits it out fails rather than run on a
    /// connection of its own, which couldn't log in.
    @Test
    func testPastTheCarriersShareRunsQueueAndNeverGoDirect() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(50),
                                 carrierMaxWait: .milliseconds(300))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let failed = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        #expect(failed)
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.carrierCapacity { held.append(try await Self.lease(pool)) }
        #expect(held.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.carrier })

        let freed = held.removeLast()
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            freed.release()
        }
        let waited = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: waited) == Self.carrier)

        held.append(try await Self.lease(pool))
        var failure: Error?
        do { _ = try await Self.session(pool) } catch { failure = error }
        #expect(failure as? SSHMasterPool.Unavailable != nil)
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

    /// A lease holds its session until it is released, once, or dropped; one
    /// past the master's share waits and then runs on its own connection.
    @Test
    func testALeaseHoldsItsSessionUntilReleased() async throws {
        let sshd = MockSSHD()
        sshd.onlyFirstMasterStarts = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready)

        var leases: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.capacity { leases.append(try await Self.lease(pool)) }
        #expect(leases.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.base })
        #expect(pool.sessionsInUse(route, path: Self.base) == SSHMasterPool.capacity)
        let overflow = try await Self.lease(pool)
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
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.capacity { held.append(try await Self.lease(pool)) }

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

        // The same host on another port, or with another key, names another socket too.
        sshd.lock.withLock { sshd.startFails = false }
        let otherPort = try Self.route("a@example.invalid", port: 2222, options: template)
        pool.warm(otherPort, carrierPath: nil)
        let portReady = await Self.waitUntil {
            sshd.lock.withLock { sshd.alive.contains(MockSSHD.id("a@example.invalid", otherPort.basePath, port: 2222)) }
        }
        #expect(portReady)
        #expect(otherPort.key != hostA.key)
        #expect(try Self.route("a@example.invalid", identityFile: "/tmp/other-key", options: template).key != hostA.key)
        #expect(try Self.route("a@example.invalid", options: template + ["User=bob"]).key != hostA.key)
        // A warmed path on a route nobody warmed rides no master uncounted.
        let unwarmed = try await pool.withSession(
            destination: "a@example.invalid", port: nil, identityFile: "/tmp/other-key", sshOptions: template
        ) { $0 }
        #expect(SSHMasterPool.controlPath(in: unwarmed) == "none")
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
            let leased = try await pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: options)
            #expect(leased.sshOptions == options)
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

    /// `-O check` names the same socket the master was started at: `%C`
    /// expands from the port, key and route options, so it gets them all.
    @Test
    func testACheckNamesTheSocketTheMasterOpened() throws {
        let route = try #require(SSHMasterPool.Route(
            destination: "alice@example.invalid", port: 2222, identityFile: "/tmp/key",
            sshOptions: ["ProxyJump=jump.invalid", "ControlPath=/tmp/cmux-pool-test-%C-ops"]
        ))
        let path = route.path(ofMaster: 1)
        #expect(path == "/tmp/cmux-pool-test-%C-ops-2")
        let start = SSHMasterPool.ProcessControl.startArguments(route, path: path)
        let check = SSHMasterPool.ProcessControl.checkArguments(route, path: path)
        let routePart = SSHMasterPool.ProcessControl.routeArguments(route, path: path)
        #expect(Array(start.suffix(routePart.count)) == routePart)
        #expect(Array(check.suffix(routePart.count)) == routePart)
        #expect(routePart.contains("2222") && routePart.contains("/tmp/key") && routePart.contains("ProxyJump=jump.invalid"))
    }

    /// The master opens none of the host's configured forwards, ahead of the
    /// route's options (OpenSSH keeps the first value), and outlives the idle
    /// pool's health loop.
    @Test
    func testTheMasterForwardsNothingAndOutlivesTheIdleLoop() throws {
        let route = try #require(SSHMasterPool.Route(
            destination: "alice@example.invalid", port: nil, identityFile: nil,
            sshOptions: ["ClearAllForwardings=no", "ControlPath=/tmp/cmux-pool-test-ops"]
        ))
        let start = SSHMasterPool.ProcessControl.startArguments(route, path: route.basePath)
        for option in ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes"] {
            let index = try #require(start.firstIndex(of: option))
            #expect(index < start.firstIndex(of: "ClearAllForwardings=no")!)
        }
        #expect(start.contains("ControlPersist=\(SSHMasterPool.ProcessControl.controlPersistSeconds)"))
        #expect(SSHMasterPool.ProcessControl.controlPersistSeconds > 30 * 60 + 30)
        for option in ["RemoteCommand=none", "StrictHostKeyChecking=accept-new", "BatchMode=yes"] {
            #expect(start.contains(option))
        }
        let expand = SSHMasterPool.ProcessControl.expandArguments(route, path: route.basePath)
        #expect(Array(expand.dropFirst()) == SSHMasterPool.ProcessControl.batchArguments(route)
            + SSHMasterPool.ProcessControl.routeArguments(route, path: route.basePath))
        // A route's own StrictHostKeyChecking wins.
        let strict = try #require(SSHMasterPool.Route(
            destination: "alice@example.invalid", port: nil, identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=yes", "ControlPath=/tmp/cmux-pool-test-ops"]
        ))
        #expect(!SSHMasterPool.ProcessControl.batchArguments(strict).contains("StrictHostKeyChecking=accept-new"))
        #if canImport(CmuxFoundation)
        let guards = SSHBackgroundForwarding.allOff.optionArguments
        let batch = SSHMasterPool.ProcessControl.batchArguments(route)
        #expect(stride(from: 0, to: guards.count, by: 2).allSatisfy { batch.contains(guards[$0 + 1]) })
        #endif
    }

    /// Only a refused login stops the retries; a network error doesn't.
    @Test
    func testOnlyARefusedLoginCountsAsRefused() {
        #expect(SSHMasterPool.ProcessControl.isRefusedLogin("alice@example.invalid: Permission denied (publickey,password)."))
        #expect(SSHMasterPool.ProcessControl.isRefusedLogin("Received disconnect: Too many authentication failures"))
        #expect(!SSHMasterPool.ProcessControl.isRefusedLogin("ssh: connect to host example.invalid port 22: Operation timed out"))
        #expect(!SSHMasterPool.ProcessControl.isRefusedLogin("Host key verification failed."))
    }

    /// Only a missing socket or a refused connection proves a master gone;
    /// a check that timed out leaves it (and its socket) alone.
    @Test
    func testOnlyAMissingOrRefusedSocketIsDead() {
        typealias P = SSHMasterPool.ProcessControl
        #expect(P.liveness(status: 0, stderr: "Master running (pid=1)") == .alive)
        #expect(P.liveness(status: 255, stderr: "Control socket connect(/tmp/x): No such file or directory") == .dead)
        #expect(P.liveness(status: 255, stderr: "Control socket connect(/tmp/x): Connection refused") == .dead)
        #expect(P.liveness(status: nil, stderr: "") == .unknown)
        #expect(P.liveness(status: 255, stderr: "mux_client_hello_exchange: read: Broken pipe") == .unknown)
    }

    /// Routes that differ as given but name one socket share one count.
    @Test
    func testRoutesNamingOneSocketShareACount() async throws {
        let sshd = MockSSHD()
        sshd.onlyFirstMasterStarts = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(100))
        let plain = try Self.route()
        let withUser = try Self.route(options: Self.options + ["User=alice"])
        sshd.lock.withLock { sshd.sockets = [plain.key: "/sock/one", withUser.key: "/sock/one"] }
        pool.warm(plain, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { !sshd.alive.isEmpty } }
        #expect(ready)
        pool.warm(withUser, carrierPath: Self.carrier)
        _ = await Self.waitUntil { pool.sessionsInUse(withUser, path: Self.base) == 0 && pool.runsWaiting(withUser) == 0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        var held: [SSHMasterPool.Lease] = []
        for index in 0..<SSHMasterPool.capacity {
            held.append(try await pool.lease(destination: Self.destination, port: nil, identityFile: nil,
                                             sshOptions: index.isMultiple(of: 2) ? Self.options : Self.options + ["User=alice"]))
        }
        #expect(held.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.base })
        #expect(pool.sessionsInUse(plain, path: Self.base) == SSHMasterPool.capacity)
        let overflow = try await pool.lease(destination: Self.destination, port: nil, identityFile: nil,
                                            sshOptions: Self.options + ["User=alice"])
        #expect(SSHMasterPool.controlPath(in: overflow.sshOptions) == "none")
        #expect(sshd.lock.withLock { sshd.starts.filter { $0 == Self.base }.count } == 1)
        withExtendedLifetime(held) {}
    }

    /// Options that can only name the carrier's own path get no master and
    /// share the carrier's capped sessions.
    @Test
    func testTheCarriersOwnPathCountsAgainstItsCap() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(50),
                                 carrierMaxWait: .milliseconds(200))
        let options = ["BatchMode=yes", "ControlPath=" + Self.carrier]
        let route = try Self.route(options: options)
        pool.warm(route, carrierPath: Self.carrier)
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.carrierCapacity {
            held.append(try await pool.lease(destination: Self.destination, port: nil, identityFile: nil, sshOptions: options))
        }
        #expect(held.allSatisfy { SSHMasterPool.controlPath(in: $0.sshOptions) == Self.carrier })
        var failure: Error?
        do { _ = try await Self.session(pool, options: options) } catch { failure = error }
        #expect(failure as? SSHMasterPool.Unavailable != nil)
        #expect(sshd.lock.withLock { sshd.starts }.isEmpty)
        withExtendedLifetime(held) {}
    }

    /// A lease gives back the session it took, even after the carrier's path
    /// changed under it.
    @Test
    func testALeaseReleasesWhereItWasTaken() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        _ = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        let lease = try await Self.lease(pool)
        #expect(pool.sessionsInUse(route, path: Self.carrier) == 1)
        pool.warm(route, carrierPath: Self.carrier + "-new")
        _ = await Self.waitUntil { pool.carrierPathIfMastersFail(route) == Self.carrier + "-new" }
        lease.release()
        #expect(pool.sessionsInUse(route, path: Self.carrier + "-new") == 0)
    }

    /// A long-lived run launched while the first start is pending waits for
    /// its answer before choosing the carrier or a connection of its own.
    @Test
    func testALongLivedRunWaitsForThePendingStart() async throws {
        let sshd = MockSSHD()
        sshd.loginRefused = true
        sshd.startDelayNanoseconds = 150_000_000
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        #expect(pool.carrierPathIfMastersFail(route) == nil)
        let known = await pool.carrierPathOnceKnown(route, limit: .seconds(5))
        #expect(known == Self.carrier)

        let keyed = MockSSHD()
        keyed.startDelayNanoseconds = 150_000_000
        let keyedPool = SSHMasterPool(control: keyed, healthInterval: .seconds(60))
        keyedPool.warm(route, carrierPath: Self.carrier)
        let began = ContinuousClock.now
        let none = await keyedPool.carrierPathOnceKnown(route, limit: .seconds(5))
        #expect(none == nil)
        #expect(ContinuousClock.now - began >= .milliseconds(100))
    }

    /// After the idle health loop stops, the masters are checked again before
    /// they are lent: one that died meanwhile isn't handed out.
    @Test
    func testAnIdleHostChecksItsMastersBeforeLending() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .milliseconds(20), maxWait: .seconds(5),
                                 idleTimeout: .milliseconds(50))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let ready = await Self.waitUntil { sshd.lock.withLock { sshd.alive.contains(MockSSHD.id(Self.destination, Self.base)) } }
        #expect(ready)
        try? await Task.sleep(nanoseconds: 200_000_000)
        sshd.kill(Self.base)
        let used = try await Self.session(pool)
        #expect(SSHMasterPool.controlPath(in: used) == Self.base)
        #expect(sshd.lock.withLock { sshd.starts.filter { $0 == Self.base }.count } == 2)
    }

    private static func longLived(_ pool: SSHMasterPool) async throws -> SSHMasterPool.Lease? {
        try await pool.longLivedLease(destination: destination, port: nil, identityFile: nil, sshOptions: options)
    }

    private static func carrierPool(_ sshd: MockSSHD, carrierMaxWait: Duration = .milliseconds(300)) async throws -> (SSHMasterPool, SSHMasterPool.Route) {
        sshd.loginRefused = true
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60), maxWait: .milliseconds(50),
                                 carrierMaxWait: carrierMaxWait)
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        _ = await Self.waitUntil { pool.carrierPathIfMastersFail(route) != nil }
        return (pool, route)
    }

    /// Long-lived runs take at most their share of the carrier's sessions:
    /// the slot kept for one-off runs is never theirs, and one past the share
    /// fails naming that cause.
    @Test
    func testLongLivedRunsCantTakeTheOneOffSlot() async throws {
        let sshd = MockSSHD()
        let (pool, route) = try await Self.carrierPool(sshd)
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.longLivedCarrierCapacity {
            let lease = try #require(try await Self.longLived(pool))
            #expect(SSHMasterPool.controlPath(in: lease.sshOptions) == Self.carrier)
            held.append(lease)
        }
        #expect(pool.longLivedSessionsInUse(route) == SSHMasterPool.longLivedCarrierCapacity)
        var failure: Error?
        do { _ = try await Self.longLived(pool) } catch { failure = error }
        #expect((failure as? SSHMasterPool.Unavailable)?.cause == .longLivedLimit)
        #expect(pool.sessionsInUse(route, path: Self.carrier) == SSHMasterPool.longLivedCarrierCapacity)
        #expect(SSHMasterPool.longLivedCarrierCapacity == SSHMasterPool.carrierCapacity - 1)
        withExtendedLifetime(held) {}
    }

    /// With the long-lived share held, one-off runs still run, on the slot
    /// kept for them, and a burst never puts more than the cap on the carrier.
    @Test
    func testOneOffRunsStillRunWhileLongLivedHoldTheirShare() async throws {
        let sshd = MockSSHD()
        let (pool, route) = try await Self.carrierPool(sshd, carrierMaxWait: .seconds(30))
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.longLivedCarrierCapacity { held.append(try #require(try await Self.longLived(pool))) }

        let peak = PeakCounter()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    (try? await pool.withSession(
                        destination: Self.destination, port: nil, identityFile: nil, sshOptions: Self.options
                    ) { leased in
                        peak.note(pool.sessionsInUse(route, path: Self.carrier))
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        return SSHMasterPool.controlPath(in: leased) == Self.carrier
                    }) ?? false
                }
            }
            for await ok in group { #expect(ok) }
        }
        #expect(peak.value == SSHMasterPool.carrierCapacity)
        #expect(pool.sessionsInUse(route, path: Self.carrier) == SSHMasterPool.longLivedCarrierCapacity)
        withExtendedLifetime(held) {}
    }

    /// A long-lived run queued past its share doesn't hold up the one-off run
    /// behind it.
    @Test
    func testAQueuedLongLivedRunDoesntBlockOneOffRuns() async throws {
        let sshd = MockSSHD()
        let (pool, route) = try await Self.carrierPool(sshd, carrierMaxWait: .seconds(10))
        var held: [SSHMasterPool.Lease] = []
        for _ in 0..<SSHMasterPool.longLivedCarrierCapacity { held.append(try #require(try await Self.longLived(pool))) }
        let oneOff = try await Self.lease(pool)
        let longLivedWaiter = Task { try? await Self.longLived(pool) }
        _ = await Self.waitUntil { pool.runsWaiting(route) == 1 }
        let oneOffWaiter = Task { try await Self.session(pool) }
        _ = await Self.waitUntil { pool.runsWaiting(route) == 2 }
        oneOff.release()
        let used = try await oneOffWaiter.value
        #expect(SSHMasterPool.controlPath(in: used) == Self.carrier)
        #expect(pool.runsWaiting(route) == 1)
        longLivedWaiter.cancel()
        _ = await longLivedWaiter.value
        withExtendedLifetime(held) {}
    }

    /// On a host whose masters work, a long-lived run gets no lease: it opens
    /// a connection of its own, and holds nothing of the pool's.
    @Test
    func testALongLivedRunOnAWorkingHostOpensItsOwnConnection() async throws {
        let sshd = MockSSHD()
        let pool = SSHMasterPool(control: sshd, healthInterval: .seconds(60))
        let route = try Self.route()
        pool.warm(route, carrierPath: Self.carrier)
        let lease = try await Self.longLived(pool)
        #expect(lease == nil)
        #expect(pool.longLivedSessionsInUse(route) == 0)
    }
}

/// The largest value noted, from any task.
private final class PeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    func note(_ value: Int) { lock.withLock { peak = max(peak, value) } }
    var value: Int { lock.withLock { peak } }
}
