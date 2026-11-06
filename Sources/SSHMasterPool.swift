import CryptoKit
import Foundation
import Network

/// Pre-warmed ControlMasters for this app's one-off `ssh` runs to a host
/// (Files listings, reads, writes and downloads, previews, probes, search,
/// git status, Go to File, file drops), kept apart from the carrier's.
///
/// sshd allows 10 sessions on one connection by default and refuses the rest
/// ("Session open refused by peer"). OpenSSH's client then falls back to a
/// login of its own, which works on a host that takes a key but not where a
/// batch login can't sign in (a password-only host, the carrier's master), and
/// a refused session on the carrier's master can refuse a carrier's reconnect.
/// So the pool:
/// - opens the first master as soon as the host's carrier connects
///   (``warm(_:carrierPath:)``), so the first one-off run doesn't pay the
///   handshake;
/// - keeps it alive (ServerAliveInterval 5, CountMax 3), checks it with
///   `ssh -O check` and, when it dies, starts it again with backoff;
/// - after a sleep or a network change (``recycleMasters()``), stops its
///   masters (`ssh -O stop`) and starts the first afresh, since `-O check`
///   only asks the local process and can't see a connection that is gone;
/// - lends at most ``capacity`` sessions per master (10 less a reserve of 2),
///   opens another master (`…-2`, `…-3`) when they are all in use, and queues a
///   run when it can't;
/// - on a host that takes a key, never fails a run: one that can't get a
///   session soon, or finds no master live or starting, runs on a connection
///   of its own (`ControlPath=none`) at once.
///
/// A master logs in in batch mode, so on a host that only takes a password it
/// can't start. When its login is refused (or its path can't hold a socket)
/// the pool stops trying until the carrier connects again, and runs use the
/// carrier's authenticated master instead, as they did before these masters
/// existed: at most ``carrierCapacity`` (3) sessions per app, the rest queued,
/// oldest first, for up to ``carrierMaxWait`` and then failed with
/// ``Unavailable``, never sent to a connection of their own, which couldn't
/// log in either, and never past the cap. Long-lived runs (the language
/// server, waveform helpers, FSM runs; ``longLivedLease(destination:port:identityFile:sshOptions:)``)
/// take at most ``longLivedCarrierCapacity`` (2) of them, so one is always
/// left for one-off runs. Every app's carrier for a host shares that master
/// (10 sessions) and none sees the others' counts: each app holds 1 for its
/// carrier and up to 3 lent, so 1-2 apps on a host use at most 8, and three
/// apps 12 in the worst case, which only a password-only host with three
/// apps all busy at once would reach. Options that can't name a master of
/// their own (the carrier's path itself) are counted against the cap too.
///
/// Until a host's first start has an answer (or its socket is resolved), its
/// mode is unknown: a run queues behind that answer for up to
/// ``startMaxWait`` and never goes to a connection of its own, which on a
/// password-only host couldn't log in. It then gets a master, the carrier's,
/// or (the start failed some other way) its own connection.
///
/// Only routes a carrier registered with ``warm(_:carrierPath:)`` are pooled;
/// any other options pass through untouched, so a user's own ControlPath never
/// gets a master started at it. A warmed path on a route nobody warmed (another
/// identity file, say) is resolved with `ssh -G`: when it names a pooled
/// socket it shares that entry's count and mode (the carrier's on a
/// password-only host), and else runs on a connection of its own.
///
/// A run passes its options with the base path ``Route/basePath`` as its
/// ControlPath (``SSHTuiConnection/fileOperationSSHOptions``); the pool swaps
/// in the master it lends. Batch runs use `ControlMaster=no`, which still uses
/// a master that exists, so a run on a master that died meanwhile connects
/// directly.
///
/// A run inside another run's ``withSession(destination:port:identityFile:sshOptions:isolation:_:)``
/// for the same host can't deadlock: at capacity it waits ``maxWait`` and then
/// runs on its own connection (on the carrier, it fails after
/// ``carrierMaxWait``). No call site nests.
final class SSHMasterPool: @unchecked Sendable {
    /// One host's one-off masters.
    struct Route: Sendable, Equatable {
        let destination: String
        let port: Int?
        let identityFile: String?
        /// The route's options, with no ControlMaster, ControlPersist or ControlPath.
        let options: [String]
        /// The route's ControlPath as the run gives it. Once its socket is
        /// resolved the masters are named from the expanded socket and their
        /// index (``Control/masterPath(_:socket:index:)``); before that, and
        /// in tests, the first is this and the others append -2, -3. The
        /// separator keeps one build's second master from being another
        /// build's first (`-ops-x` + `2` would be `-ops-x2`).
        let basePath: String

        /// The route `options` name, or nil when they don't name a pool path
        /// (no ControlPath, or `none`).
        init?(destination: String, port: Int?, identityFile: String?, sshOptions: [String]) {
            guard let path = SSHMasterPool.controlPath(in: sshOptions), path.lowercased() != "none" else { return nil }
            self.destination = destination
            self.port = port
            self.identityFile = identityFile
            options = sshOptions.filter { !SSHMasterPool.isControlOption($0) }
            basePath = path
        }

        func path(ofMaster index: Int) -> String { index == 0 ? basePath : basePath + "-" + String(index + 1) }

        /// The route as given. Routes that differ here but name one socket
        /// once ssh expands them (a `User=` option against the same user in
        /// ssh_config, say) share one pool entry; see ``Control/socketPath(_:path:)``.
        var key: String {
            ([destination, port.map(String.init) ?? "", identityFile ?? "", basePath] + options)
                .joined(separator: "\u{1F}")
        }
    }

    /// How a master's start went.
    enum StartOutcome: Sendable, Equatable {
        /// It accepts sessions (or one already ran there).
        case started
        /// It can't start until the carrier connects again: the host refused
        /// its batch-mode login, or its path can't hold a socket.
        case unavailable
        /// Something that may pass (the network, say); try again later.
        case failed
    }

    /// What `ssh -O check` said about a master.
    enum Liveness: Sendable, Equatable {
        case alive
        /// No socket, or nothing listening on it.
        case dead
        /// No answer in time, or an error that proves nothing: leave it be.
        case unknown
    }

    /// No session for a run on a host whose masters can't start, after
    /// ``carrierMaxWait`` queued for the carrier's.
    struct Unavailable: LocalizedError, Equatable {
        enum Cause: Sendable, Equatable {
            /// This app's share of the carrier's sessions stayed in use.
            case carrierBusy
            /// Long-lived runs already hold their share of the carrier's sessions.
            case longLivedLimit
            /// The host's first master start had no answer within ``startMaxWait``.
            case signingIn
        }

        let cause: Cause

        var errorDescription: String? {
            switch cause {
            case .carrierBusy:
                return String(
                    localized: "ssh.pool.carrierBusy",
                    defaultValue: "This host accepts only the terminal's sign-in, and its SSH sessions for cmux are all in use. Try again in a moment."
                )
            case .longLivedLimit:
                return String(
                    localized: "ssh.pool.longLivedLimit",
                    defaultValue: "This host accepts only the terminal's sign-in, and cmux's background tools there (language servers, waveform helpers, driver tracing) already use all the SSH sessions they may. Close a waveform viewer, or restart cmux to end its language servers, and try again."
                )
            case .signingIn:
                return String(
                    localized: "ssh.pool.signingIn",
                    defaultValue: "cmux is still connecting to this host. Try again in a moment."
                )
            }
        }
    }

    /// Starts and checks masters; a mock in tests.
    protocol Control: Sendable {
        /// Opens a master at `path`, or adopts a live one.
        func start(_ route: Route, path: String) async -> StartOutcome
        /// `ssh -O check` on the master at `path`.
        func check(_ route: Route, path: String) async -> Liveness
        /// The socket `path` names for `route` once ssh expands it, or nil.
        func socketPath(_ route: Route, path: String) async -> String?
        /// Where master `index` of a route whose base path expands to
        /// `socket` listens. By default ``Route/path(ofMaster:)``.
        func masterPath(_ route: Route, socket: String, index: Int) -> String
        /// `ssh -O stop` on the master at `path`: it takes no new sessions
        /// and gives up its socket; sessions on it carry on.
        func stop(_ route: Route, path: String) async
    }

    /// A lent session for a run whose process outlives one scope
    /// (``lease(destination:port:identityFile:sshOptions:)``). Call
    /// ``release()`` when the run's process exits; it is also released when
    /// the lease goes away.
    final class Lease: @unchecked Sendable {
        let sshOptions: [String]
        private let lock = NSLock()
        private var onRelease: (() -> Void)?

        init(sshOptions: [String], onRelease: (() -> Void)? = nil) {
            self.sshOptions = sshOptions
            self.onRelease = onRelease
        }

        deinit { onRelease?() }

        func release() {
            let release: (() -> Void)? = lock.withLock {
                defer { onRelease = nil }
                return onRelease
            }
            release?()
        }
    }

    static let sessionsPerMaster = 10
    static let reserve = 2
    static let maxMasters = 3
    /// Sessions lent per master.
    static var capacity: Int { sessionsPerMaster - reserve }
    /// Sessions this app lends on the carrier's master when its own masters
    /// can't start: the one per-app cap, which can be lowered on its own.
    static let carrierCapacity = 3
    /// Of those, the most long-lived runs may hold: one is always left for
    /// one-off runs.
    static var longLivedCarrierCapacity: Int { carrierCapacity - 1 }

    static let shared = SSHMasterPool(control: ProcessControl())

    private struct Master {
        var live = false
        var inUse = 0
        var starting = false
        var failures = 0
        var retryAt: ContinuousClock.Instant?
        /// Being stopped by ``recycleMasters()``: not started again until
        /// its old process gave up the socket.
        var stopping = false
    }

    /// Where a lent session is, so its release counts down the same place
    /// even if the host's carrier path changes meanwhile.
    private enum Slot: Sendable, Equatable {
        case master(Int)
        case carrier(longLived: Bool)
    }

    /// What a run is: one-off runs may use any session; long-lived ones only
    /// the carrier's, within their share, and else a connection of their own.
    private enum Use: Sendable, Equatable {
        case oneOff
        case longLived
    }

    private enum Grant: Sendable {
        /// Not a pooled path: run with the options as given.
        case unpooled
        case lent(key: String, slot: Slot, path: String)
        /// A connection of its own.
        case direct
    }

    private struct Waiter {
        let id: UUID
        let use: Use
        let continuation: CheckedContinuation<Grant, Error>
        let queuedAt: ContinuousClock.Instant
    }

    private struct Host {
        var route: Route
        var carrierPath: String?
        var masters: [Master] = [Master()]
        var carrierInUse = 0
        /// Of ``carrierInUse``, those held by long-lived runs.
        var longLivedCarrierInUse = 0
        /// A start was refused or can't bind; no more tries until the carrier
        /// connects again (``warm(_:carrierPath:)``).
        var mastersUnavailable = false
        /// The route names the carrier's own path: it never gets masters of
        /// its own, and its runs count against the carrier's cap while a
        /// master is there.
        var carrierOnly = false
        /// For ``carrierOnly``: false once `ssh -O check` found no master at
        /// the carrier's path (a carrier with ControlMaster=no on a host that
        /// takes a key), so its runs connect directly and aren't capped.
        var carrierLive: Bool?
        /// Its socket is being resolved; runs queue until it is.
        var resolving = false
        /// The socket its base path names, once resolved: its masters are
        /// named from it (``Control/masterPath(_:socket:index:)``).
        var socket: String?
        /// A route nobody warmed that names a warmed path: never gets masters
        /// of its own; once resolved it joins the entry at its socket or goes.
        var borrowed = false
        /// No answer yet from the first master's start since the carrier
        /// connected, so whether the masters can log in is unknown.
        var awaitingFirstOutcome = true
        /// When that answer came: a run queued before it waits for the
        /// carrier's session from then.
        var modeKnownAt: ContinuousClock.Instant?
        var waiters: [Waiter] = []
        var health: Task<Void, Never>?
        /// The health loop ended for want of use.
        var retired = false
        var lastInterest: ContinuousClock.Instant

        /// The masters can't start (no batch-mode login, say), so runs use
        /// the carrier's authenticated master.
        var usesCarrier: Bool {
            carrierPath != nil && ((carrierOnly && carrierLive != false) || mastersUnavailable) && !masters.contains(where: \.live)
        }

        /// A master is up or on its way, so a queued run may get a session.
        var mayLend: Bool { resolving || masters.contains { $0.live || $0.starting } }

        /// Whether the masters can log in isn't known yet: runs wait for it.
        var modePending: Bool { resolving || (!carrierOnly && awaitingFirstOutcome && !masters.contains(where: \.live)) }
    }

    private let control: Control
    private let healthInterval: Duration
    private let maxWait: Duration
    private let carrierMaxWait: Duration
    private let startMaxWait: Duration
    private let idleTimeout: Duration
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var hosts: [String: Host] = [:]
    /// Routes that turned out to name another entry's socket.
    private var aliases: [String: String] = [:]
    /// The entry for each resolved socket.
    private var entryBySocket: [String: String] = [:]
    /// Every path a carrier warmed, on whatever route.
    private var warmedPaths: Set<String> = []
    /// Unwarmed routes on a warmed path whose socket no entry pools.
    private var directRoutes: Set<String> = []

    init(
        control: Control,
        healthInterval: Duration = .seconds(30),
        maxWait: Duration = .seconds(5),
        carrierMaxWait: Duration = .seconds(20),
        startMaxWait: Duration = .seconds(25),
        idleTimeout: Duration = .seconds(30 * 60)
    ) {
        self.control = control
        self.healthInterval = healthInterval
        self.maxWait = maxWait
        self.carrierMaxWait = carrierMaxWait
        self.startMaxWait = startMaxWait
        self.idleTimeout = idleTimeout
    }

    deinit {
        for host in hosts.values { host.health?.cancel() }
    }

    // MARK: Use

    /// Registers `route` as a pooled host, opens its first master now and
    /// keeps it alive while the host is in use. Call when the host's carrier
    /// connects; a master whose login was refused is tried again then.
    /// `carrierPath` is the carrier's ControlPath, which runs use when the
    /// masters can't start. A route at the carrier's own path gets no masters:
    /// its runs share the carrier's capped sessions.
    func warm(_ route: Route, carrierPath: String?) {
        lock.withLock {
            warmedPaths.insert(route.basePath)
            // A route found unpooled may name a socket this warm pools.
            directRoutes = []
            let key = entryKey(route.key)
            if hosts[key] == nil || hosts[key]?.borrowed == true {
                // A borrowed entry being resolved is replaced; its waiters
                // stay, and its resolution starts the masters.
                var host = Host(route: route, carrierPath: carrierPath, lastInterest: clock.now)
                host.carrierOnly = route.basePath == carrierPath
                host.resolving = !host.carrierOnly
                host.awaitingFirstOutcome = !host.carrierOnly
                if let borrowed = hosts[key] {
                    host.waiters = borrowed.waiters
                    host.resolving = borrowed.resolving
                } else if host.resolving {
                    resolve(route)
                }
                hosts[key] = host
                touch(key)
                if host.carrierOnly { checkCarrier(key, route: route) }
                if !host.resolving { startIfNeeded(key, index: 0) }
                return
            }
            hosts[key]?.carrierPath = carrierPath
            hosts[key]?.mastersUnavailable = false
            if let host = hosts[key], !host.carrierOnly, !host.masters.contains(where: \.live) {
                // Whether the masters log in now is unknown until this start answers.
                hosts[key]?.awaitingFirstOutcome = true
            }
            for index in hosts[key]?.masters.indices ?? 0..<0 { hosts[key]?.masters[index].retryAt = nil }
            touch(key)
            if hosts[key]?.carrierOnly == true, let route = hosts[key]?.route { checkCarrier(key, route: route) }
            startIfNeeded(key, index: 0)
        }
    }

    /// Starts every host's masters afresh, after a sleep or a network change.
    /// A master's process can outlive its connection: `-O check` asks the
    /// local process, so it still answers, while sessions opened on it hang
    /// until the keepalive ends it. So each live master stops taking new
    /// sessions (`ssh -O stop`; runs already on it carry on, or fail as they
    /// would have) and counts as down, and the first starts again once the old
    /// one gave up its socket. Sessions lent before stay counted until they
    /// end. Hosts on the carrier's master are left alone: the carrier
    /// reconnects (``warm(_:carrierPath:)``).
    func recycleMasters() {
        lock.withLock {
            for key in hosts.keys {
                // A host on the carrier's master has no live master of its own.
                guard var host = hosts[key], !host.carrierOnly, !host.borrowed, !host.resolving else { continue }
                let live = host.masters.indices.filter { host.masters[$0].live }
                guard !live.isEmpty else { continue }
                let paths = live.map { masterPath(host, index: $0) }
                for index in live {
                    host.masters[index].live = false
                    host.masters[index].retryAt = nil
                    host.masters[index].failures = 0
                    if index != 0 { host.masters[index].stopping = true }
                }
                let restart = !host.masters[0].starting
                if restart { host.masters[0].starting = true }
                hosts[key] = host
                let route = host.route
                let first = masterPath(host, index: 0)
                let later = live.filter { $0 != 0 }
                let control = control
                Task { [weak self] in
                    for path in paths { await control.stop(route, path: path) }
                    self?.stopped(key, indices: later)
                    guard restart else { return }
                    let outcome = await control.start(route, path: first)
                    self?.started(key, index: 0, outcome: outcome)
                }
            }
        }
    }

    private func stopped(_ key: String, indices: [Int]) {
        lock.withLock {
            for index in indices where hosts[key]?.masters.indices.contains(index) == true {
                hosts[key]?.masters[index].stopping = false
            }
        }
    }

    /// Registers a carrier's route as soon as its path is known, before it
    /// connects (and ``warm(_:carrierPath:)``). Only a route at the carrier's
    /// own path is taken: its runs count against the carrier's cap from the
    /// first one, rather than ride a master another app's carrier left there
    /// uncounted. The warm then checks whether a master is there at all.
    func registerCarrier(_ route: Route, carrierPath: String?) {
        let handoffs: [(CheckedContinuation<Grant, Error>, Grant)] = lock.withLock {
            guard route.basePath == carrierPath else { return [] }
            warmedPaths.insert(route.basePath)
            let key = entryKey(route.key)
            guard hosts[key] == nil || hosts[key]?.borrowed == true else { return [] }
            var host = Host(route: route, carrierPath: carrierPath, lastInterest: clock.now)
            host.carrierOnly = true
            host.awaitingFirstOutcome = false
            // Runs queued while it resolved as a borrowed route stay queued
            // (its resolution then finds it registered), and get the carrier's.
            host.waiters = hosts[key]?.waiters ?? []
            hosts[key] = host
            return drainWaiters(key)
        }
        for (continuation, grant) in handoffs { continuation.resume(returning: grant) }
    }

    /// Called under the lock: whether a master is at a carrier-only route's
    /// path. Until the check answers its runs are capped, as on the carrier.
    private func checkCarrier(_ key: String, route: Route) {
        let control = control
        Task { [weak self] in
            let liveness = await control.check(route, path: route.basePath)
            self?.carrierChecked(key, live: liveness != .dead)
        }
    }

    private func carrierChecked(_ key: String, live: Bool) {
        let (handoffs, direct): ([(CheckedContinuation<Grant, Error>, Grant)], [CheckedContinuation<Grant, Error>]) = lock.withLock {
            guard hosts[key] != nil else { return ([], []) }
            hosts[key]?.carrierLive = live
            return (drainWaiters(key), releaseHopelessWaiters(key))
        }
        for (continuation, grant) in handoffs { continuation.resume(returning: grant) }
        for continuation in direct { continuation.resume(returning: .direct) }
    }

    /// Called under the lock: a pooled path on a route nobody warmed (another
    /// identity file, say). Finds the socket it names before it rides one
    /// uncounted, or runs on its own connection where that can't log in.
    private func borrow(_ route: Route) {
        var borrowed = Host(route: route, carrierPath: nil, lastInterest: clock.now)
        borrowed.borrowed = true
        borrowed.resolving = true
        hosts[route.key] = borrowed
        resolve(route)
    }

    /// Called under the lock: finds the socket `route` names.
    private func resolve(_ route: Route) {
        let control = control
        Task { [weak self] in
            let socket = await control.socketPath(route, path: route.basePath)
            self?.resolved(route.key, socket: socket)
        }
    }

    /// Runs `body` with `options`, their ControlPath swapped for a master with
    /// a free session (the carrier's when the masters can't start, or `none`, a
    /// direct connection, when none frees up in time). Options that name no
    /// pooled path pass through unchanged. A cancelled caller leaves the queue
    /// and doesn't run.
    ///
    /// - Throws: `CancellationError`, ``Unavailable``, or what `body` throws.
    func withSession<T>(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions options: [String],
        isolation: isolated (any Actor)? = #isolation,
        _ body: ([String]) async throws -> T
    ) async throws -> T {
        guard let route = Route(destination: destination, port: port, identityFile: identityFile, sshOptions: options) else {
            return try await body(options)
        }
        switch try await acquire(route) {
        case .unpooled:
            return try await body(options)
        case .direct:
            return try await body(Self.replacingControlPath(in: options, with: "none"))
        case .lent(let key, let slot, let path):
            defer { release(key, slot: slot) }
            return try await body(Self.replacingControlPath(in: options, with: path))
        }
    }

    /// A session as ``withSession(destination:port:identityFile:sshOptions:isolation:_:)``
    /// lends one, for a run whose process outlives one scope (a search, a
    /// file drop): held until the lease is released.
    func lease(destination: String, port: Int?, identityFile: String?, sshOptions options: [String]) async throws -> Lease {
        guard let route = Route(destination: destination, port: port, identityFile: identityFile, sshOptions: options) else {
            return Lease(sshOptions: options)
        }
        switch try await acquire(route) {
        case .unpooled:
            return Lease(sshOptions: options)
        case .direct:
            return Lease(sshOptions: Self.replacingControlPath(in: options, with: "none"))
        case .lent(let key, let slot, let path):
            return Lease(sshOptions: Self.replacingControlPath(in: options, with: path)) { [weak self] in
                self?.release(key, slot: slot)
            }
        }
    }

    /// The carrier's ControlPath while `route`'s masters can't start, for a
    /// long-lived run that would otherwise open its own connection (which
    /// can't log in either).
    func carrierPathIfMastersFail(_ route: Route) -> String? {
        lock.withLock {
            guard let host = hosts[entryKey(route.key)], host.usesCarrier else { return nil }
            return host.carrierPath
        }
    }

    /// ``carrierPathIfMastersFail(_:)`` once the host's first start (or the
    /// resolution before it) has an answer, waiting up to `limit` for it.
    func carrierPathOnceKnown(_ route: Route, limit: Duration = .seconds(25)) async -> String? {
        let deadline = clock.now + limit
        lock.withLock {
            // An unwarmed route on a warmed path learns its socket's mode too.
            if hosts[entryKey(route.key)] == nil, warmedPaths.contains(route.basePath),
               !directRoutes.contains(route.key) {
                borrow(route)
            }
        }
        while clock.now < deadline {
            let pending: Bool = lock.withLock {
                hosts[entryKey(route.key)]?.modePending ?? false
            }
            guard pending else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return carrierPathIfMastersFail(route)
    }

    /// A long-lived run's session (the language server, a waveform helper, an
    /// FSM run), given the route's one-off options: nil on a host whose
    /// masters work (or that isn't pooled), where it opens a connection of its
    /// own; else one of the carrier's sessions within the long-lived share,
    /// queued for up to ``carrierMaxWait``. Waits first for a pending first
    /// start, so a run launched just after the carrier connects doesn't pick
    /// a connection that can't log in.
    ///
    /// - Throws: ``Unavailable`` (``Unavailable/Cause/longLivedLimit`` when
    ///   long-lived runs hold their share), or `CancellationError`.
    func longLivedLease(destination: String, port: Int?, identityFile: String?, sshOptions options: [String]) async throws -> Lease? {
        guard let route = Route(destination: destination, port: port, identityFile: identityFile, sshOptions: options) else {
            return nil
        }
        guard await carrierPathOnceKnown(route) != nil else { return nil }
        switch try await acquire(route, use: .longLived) {
        case .unpooled, .direct:
            return nil
        case .lent(let key, let slot, let path):
            return Lease(sshOptions: Self.replacingControlPath(in: options, with: path)) { [weak self] in
                self?.release(key, slot: slot)
            }
        }
    }

    /// Sessions lent on the master (or the carrier, at its path) at `path`.
    func sessionsInUse(_ route: Route, path: String) -> Int {
        lock.withLock {
            guard let host = hosts[entryKey(route.key)] else { return 0 }
            if path == host.carrierPath { return host.carrierInUse }
            return host.masters.indices.first { masterPath(host, index: $0) == path }.map { host.masters[$0].inUse } ?? 0
        }
    }

    /// The carrier's sessions long-lived runs hold for `route`'s host.
    func longLivedSessionsInUse(_ route: Route) -> Int {
        lock.withLock { hosts[entryKey(route.key)]?.longLivedCarrierInUse ?? 0 }
    }

    /// Runs queued for a session on `route`'s masters.
    func runsWaiting(_ route: Route) -> Int {
        lock.withLock { hosts[entryKey(route.key)]?.waiters.count ?? 0 }
    }

    // MARK: Lending

    /// Called under the lock: the entry a route's key resolves to.
    private func entryKey(_ key: String) -> String { aliases[key] ?? key }

    /// Where `host`'s master `index` listens: named from its resolved socket,
    /// or the route's own path before that.
    private func masterPath(_ host: Host, index: Int) -> String {
        guard let socket = host.socket else { return host.route.path(ofMaster: index) }
        return control.masterPath(host.route, socket: socket, index: index)
    }

    private func acquire(_ route: Route, use: Use = .oneOff) async throws -> Grant {
        let id = UUID()
        let routeKey = route.key
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Grant, Error>) in
                let immediate: Result<Grant, Error>? = lock.withLock {
                    let key = entryKey(routeKey)
                    // A cancel that came before this waiter was queued: the
                    // handler below found nothing to remove.
                    if hosts[key] != nil || warmedPaths.contains(route.basePath), Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if hosts[key] == nil {
                        guard warmedPaths.contains(route.basePath) else { return .success(.unpooled) }
                        if directRoutes.contains(key) { return .success(.direct) }
                        borrow(route)
                    }
                    guard let host = hosts[key] else { return .success(.direct) }
                    touch(key)
                    if let grant = lend(key, use: use) { return .success(grant) }
                    // A long-lived run that can't have the carrier's opens its own connection.
                    // While the mode is pending it queues for the answer:
                    // longLivedLease waited for it already, so only a warm
                    // between those lock sections reaches this, and no test
                    // does (the drain's twin is pinned).
                    if use == .longLived, !host.usesCarrier, !host.modePending { return .success(.direct) }
                    if !host.usesCarrier {
                        startMore(key)
                        // Nothing could free a session: don't wait for one.
                        guard hosts[key]?.mayLend == true else { return .success(.direct) }
                    }
                    hosts[key]?.waiters.append(Waiter(id: id, use: use, continuation: continuation, queuedAt: clock.now))
                    scheduleExpiry(key, waiter: id, after: host.usesCarrier ? carrierMaxWait : maxWait)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Grant, Error>? = lock.withLock {
                removeWaiter(entryKey(routeKey), id: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Called under the lock: a session on the first live master with room,
    /// or on the carrier's while the masters can't start.
    private func lend(_ key: String, use: Use = .oneOff) -> Grant? {
        guard var host = hosts[key] else { return nil }
        if use == .longLived {
            // Callers check `usesCarrier` first (acquire after
            // longLivedLease's carrier check, drainWaiters before lending),
            // but in another lock section: a warm or a master coming up in
            // between flips it. Then this guard sends the run to its own
            // connection instead of a carrier session the host no longer
            // needs. No test reaches that window, so mutation testing leaves
            // it alive; it is not strictly redundant.
            guard host.usesCarrier, let carrier = host.carrierPath, host.carrierInUse < Self.carrierCapacity,
                  host.longLivedCarrierInUse < Self.longLivedCarrierCapacity else { return nil }
            host.carrierInUse += 1
            host.longLivedCarrierInUse += 1
            hosts[key] = host
            return .lent(key: key, slot: .carrier(longLived: true), path: carrier)
        }
        for index in host.masters.indices where host.masters[index].live && host.masters[index].inUse < Self.capacity {
            host.masters[index].inUse += 1
            hosts[key] = host
            return .lent(key: key, slot: .master(index), path: masterPath(host, index: index))
        }
        if host.usesCarrier, let carrier = host.carrierPath, host.carrierInUse < Self.carrierCapacity {
            host.carrierInUse += 1
            hosts[key] = host
            return .lent(key: key, slot: .carrier(longLived: false), path: carrier)
        }
        return nil
    }

    /// Called under the lock: every live master is full, so start the next
    /// (or the first again).
    private func startMore(_ key: String) {
        guard let host = hosts[key], !host.resolving else { return }
        // (One being stopped is picked too; startIfNeeded holds it back.)
        if let index = host.masters.indices.first(where: { !host.masters[$0].live && !host.masters[$0].starting }) {
            startIfNeeded(key, index: index)
        } else if host.masters.count < Self.maxMasters, !host.masters.contains(where: \.starting) {
            hosts[key]?.masters.append(Master())
            startIfNeeded(key, index: host.masters.count)
        }
    }

    /// Called under the lock: bounds a queued run's wait.
    private func scheduleExpiry(_ key: String, waiter id: UUID, after wait: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            self?.expire(key, waiter: id)
        }
    }

    /// Called under the lock.
    private func removeWaiter(_ key: String, id: UUID) -> CheckedContinuation<Grant, Error>? {
        guard let index = hosts[key]?.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return hosts[key]?.waiters.remove(at: index).continuation
    }

    /// A waiter that got no session in time runs on its own connection; one
    /// queued for the carrier's waits out ``carrierMaxWait`` and then fails,
    /// since its own connection couldn't log in.
    private func expire(_ key: String, waiter id: UUID) {
        let expired: (CheckedContinuation<Grant, Error>, Result<Grant, Error>)? = lock.withLock {
            let key = entryKey(key)
            guard let host = hosts[key], let waiter = host.waiters.first(where: { $0.id == id }) else { return nil }
            if host.modePending {
                // Its own connection may not log in either: wait for the
                // start's answer, and fail rather than guess past the bound.
                let remaining = startMaxWait - (clock.now - waiter.queuedAt)
                if remaining > .zero {
                    scheduleExpiry(key, waiter: id, after: remaining)
                    return nil
                }
                return removeWaiter(key, id: id).map { ($0, .failure(Unavailable(cause: .signingIn))) }
            }
            if host.usesCarrier {
                let since = max(waiter.queuedAt, host.modeKnownAt ?? waiter.queuedAt)
                let remaining = carrierMaxWait - (clock.now - since)
                // Queued for a master that then couldn't start: wait on for the carrier.
                if remaining > .zero {
                    scheduleExpiry(key, waiter: id, after: remaining)
                    return nil
                }
                let cause: Unavailable.Cause = waiter.use == .longLived
                    && host.longLivedCarrierInUse >= Self.longLivedCarrierCapacity ? .longLivedLimit : .carrierBusy
                return removeWaiter(key, id: id).map { ($0, .failure(Unavailable(cause: cause))) }
            }
            return removeWaiter(key, id: id).map { ($0, .success(.direct)) }
        }
        if let (continuation, result) = expired { continuation.resume(with: result) }
    }

    /// Called under the lock: when no master can lend (none live or
    /// starting) and the carrier isn't an option, queued runs go direct now.
    private func releaseHopelessWaiters(_ key: String) -> [CheckedContinuation<Grant, Error>] {
        guard let host = hosts[key], !host.mayLend, !host.usesCarrier else { return [] }
        hosts[key]?.waiters = []
        return host.waiters.map(\.continuation)
    }

    private func release(_ key: String, slot: Slot) {
        let handoffs: [(CheckedContinuation<Grant, Error>, Grant)] = lock.withLock {
            guard var host = hosts[key] else { return [] }
            switch slot {
            case .carrier(let longLived):
                host.carrierInUse = max(0, host.carrierInUse - 1)
                if longLived { host.longLivedCarrierInUse = max(0, host.longLivedCarrierInUse - 1) }
            case .master(let index):
                guard host.masters.indices.contains(index) else { return [] }
                host.masters[index].inUse = max(0, host.masters[index].inUse - 1)
            }
            hosts[key] = host
            return drainWaiters(key)
        }
        for (continuation, grant) in handoffs { continuation.resume(returning: grant) }
    }

    /// Called under the lock: lends free sessions to waiters, oldest first. A
    /// long-lived waiter past its share doesn't hold up the one-off runs
    /// behind it, and one whose host has masters again opens its own
    /// connection.
    private func drainWaiters(_ key: String) -> [(CheckedContinuation<Grant, Error>, Grant)] {
        var handoffs: [(CheckedContinuation<Grant, Error>, Grant)] = []
        var index = 0
        while let waiters = hosts[key]?.waiters, index < waiters.count {
            let waiter = waiters[index]
            let grant: Grant?
            if waiter.use == .longLived, hosts[key]?.modePending == true {
                // Its own connection may not log in: wait for the answer.
                index += 1
                continue
            } else if waiter.use == .longLived, hosts[key]?.usesCarrier != true {
                grant = .direct
            } else {
                grant = lend(key, use: waiter.use)
            }
            guard let grant else {
                // A one-off run that can't be served means none behind it can be.
                if waiter.use == .oneOff { break }
                index += 1
                continue
            }
            hosts[key]?.waiters.remove(at: index)
            handoffs.append((waiter.continuation, grant))
        }
        return handoffs
    }

    // MARK: Masters

    /// The route's socket is known: join the entry already at that socket, or
    /// start this one's first master.
    private func resolved(_ key: String, socket: String?) {
        let (handoffs, direct): ([(CheckedContinuation<Grant, Error>, Grant)], [CheckedContinuation<Grant, Error>]) = lock.withLock {
            guard var host = hosts[key] else { return ([], []) }
            host.resolving = false
            if host.borrowed, socket.flatMap({ entryBySocket[$0] }).flatMap({ hosts[$0] }) == nil {
                if hosts.values.contains(where: { !$0.borrowed && $0.resolving && $0.route.basePath == host.route.basePath }) {
                    // A warmed route on this path hasn't resolved yet; it may
                    // be the socket this one names. Look again shortly.
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(20))
                        self?.resolved(key, socket: socket)
                    }
                    return ([], [])
                }
                // It names no pooled socket: it rides no master, so it runs
                // on its own connection.
                hosts[key] = nil
                directRoutes.insert(key)
                return ([], host.waiters.map(\.continuation))
            }
            if let socket, let existing = entryBySocket[socket], existing != key, hosts[existing] != nil {
                // Another route already pools this socket: one count for it.
                aliases[key] = existing
                hosts[existing]?.waiters += host.waiters
                // (Read first: `??` reading `hosts` inside the write is an
                // exclusivity violation.)
                if let carrierPath = host.carrierPath { hosts[existing]?.carrierPath = carrierPath }
                hosts[key] = nil
                host.health?.cancel()
                touch(existing)
                startIfNeeded(existing, index: 0)
                return (drainWaiters(existing), releaseHopelessWaiters(existing))
            }
            if let socket { entryBySocket[socket] = key }
            host.socket = socket
            hosts[key] = host
            startIfNeeded(key, index: 0)
            return (drainWaiters(key), releaseHopelessWaiters(key))
        }
        for (continuation, grant) in handoffs { continuation.resume(returning: grant) }
        for continuation in direct { continuation.resume(returning: .direct) }
    }

    /// Called under the lock: the host is in use; keep its health loop running.
    /// After the loop retired nobody checked the masters, so they count as
    /// down until a start finds them still running (and adopts them).
    private func touch(_ key: String) {
        guard var host = hosts[key] else { return }
        host.lastInterest = clock.now
        if host.health == nil, !host.borrowed {
            if host.retired {
                for index in host.masters.indices where host.masters[index].inUse == 0 { host.masters[index].live = false }
                host.retired = false
            }
            host.health = Task { [weak self] in await self?.watch(key) }
        }
        hosts[key] = host
    }

    /// Called under the lock: starts master `index` unless it is live,
    /// starting, waiting out its backoff, or can't start until the carrier
    /// connects again.
    private func startIfNeeded(_ key: String, index: Int) {
        guard var host = hosts[key], host.masters.indices.contains(index),
              !host.resolving, !host.borrowed, !host.carrierOnly, !host.mastersUnavailable else { return }
        let master = host.masters[index]
        guard !master.live, !master.starting, !master.stopping else { return }
        if let retryAt = master.retryAt, clock.now < retryAt { return }
        host.masters[index].starting = true
        hosts[key] = host
        let route = host.route
        let path = masterPath(host, index: index)
        let control = control
        Task { [weak self] in
            let outcome = await control.start(route, path: path)
            self?.started(key, index: index, outcome: outcome)
        }
    }

    private func started(_ key: String, index: Int, outcome: StartOutcome) {
        let (handoffs, direct): ([(CheckedContinuation<Grant, Error>, Grant)], [CheckedContinuation<Grant, Error>]) = lock.withLock {
            guard var host = hosts[key], host.masters.indices.contains(index) else { return ([], []) }
            let ok = outcome == .started
            host.masters[index].starting = false
            host.masters[index].live = ok
            if index == 0, host.awaitingFirstOutcome {
                host.awaitingFirstOutcome = false
                host.modeKnownAt = clock.now
            }
            // A refused later master while another is live (a host that
            // rations logins, say) only backs off: the flag would also stop
            // the first master from coming back when it dies.
            if outcome == .unavailable, !host.masters.contains(where: \.live) { host.mastersUnavailable = true }
            if ok {
                host.masters[index].failures = 0
                host.masters[index].retryAt = nil
            } else {
                host.masters[index].failures += 1
                // 1, 2, 4 … 60 seconds. A refused login isn't retried at all
                // until the carrier connects again.
                let seconds = min(60, 1 << min(host.masters[index].failures - 1, 6))
                host.masters[index].retryAt = clock.now + .seconds(seconds)
            }
            hosts[key] = host
            // A new master serves the queue; one that can't start hands it the
            // carrier, or sends it direct when nothing else could serve it.
            return (drainWaiters(key), releaseHopelessWaiters(key))
        }
        for (continuation, grant) in handoffs { continuation.resume(returning: grant) }
        for continuation in direct { continuation.resume(returning: .direct) }
    }

    /// The health loop: checks each master and replaces a dead first master
    /// before a run needs it, until the host goes unused for ``idleTimeout``.
    private func watch(_ key: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: healthInterval)
            let snapshot: (route: Route, live: [(Int, String)])? = lock.withLock {
                guard let host = hosts[key] else { return nil }
                if clock.now - host.lastInterest > idleTimeout {
                    hosts[key]?.health = nil
                    hosts[key]?.retired = true
                    return nil
                }
                return (host.route, host.masters.indices.filter { host.masters[$0].live }.map { ($0, masterPath(host, index: $0)) })
            }
            guard let snapshot else { return }
            for (index, path) in snapshot.live
            where await control.check(snapshot.route, path: path) == .dead {
                lock.withLock { hosts[key]?.masters[index].live = false }
            }
            lock.withLock { startIfNeeded(key, index: 0) }
        }
    }

    // MARK: Options

    static func isControlOption(_ option: String) -> Bool {
        let key = optionKey(option)
        return key == "controlmaster" || key == "controlpersist" || key == "controlpath"
    }

    /// The first ControlPath in `options` (OpenSSH keeps the first value).
    static func controlPath(in options: [String]) -> String? {
        for option in options where optionKey(option) == "controlpath" {
            let value = optionValue(option)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func replacingControlPath(in options: [String], with path: String) -> [String] {
        options.filter { optionKey($0) != "controlpath" } + ["ControlPath=" + path]
    }

    fileprivate static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else { return nil }
        return trimmed[..<separator].lowercased()
    }

    private static func optionValue(_ option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else { return "" }
        return trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "=").union(.whitespaces))
    }
}

extension SSHMasterPool {
    /// The real masters: `ssh -fN` with ControlMaster=yes, and `ssh -O check`.
    struct ProcessControl: Control {
        /// Longer than the pool's idle timeout plus a health check, so a
        /// master outlives the loop that watches it instead of exiting and
        /// logging in again while the app sits idle.
        static let controlPersistSeconds = 35 * 60

        /// What a batch run sets ahead of the route's options (OpenSSH keeps
        /// the first value), on the master and on `ssh -G` alike: no
        /// forwards (`SSHBackgroundForwarding.allOff`; `-fN` is how a tunnel
        /// is opened, so a master would otherwise set up the host's
        /// configured ones), no configured RemoteCommand, and a first-seen
        /// host key accepted, as batch runs do.
        static func batchArguments(_ route: Route) -> [String] {
            var arguments = [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "ClearAllForwardings=yes",
                "-o", "RemoteCommand=none",
            ]
            if !route.options.contains(where: { optionKey($0) == "stricthostkeychecking" }) {
                arguments += ["-o", "StrictHostKeyChecking=accept-new"]
            }
            return arguments
        }

        /// macOS caps an AF_UNIX `sun_path` at 104 bytes including the NUL,
        /// and OpenSSH first binds the path plus 17 bytes (`.` and 16 random
        /// characters).
        static func fitsSocketPath(_ expandedPath: String) -> Bool {
            expandedPath.utf8.count + 17 <= 103
        }

        /// The route and socket every call about one master names: `%C` and
        /// the like expand from the port, user, host and ProxyJump, so a check
        /// without them would look at another socket.
        static func routeArguments(_ route: Route, path: String) -> [String] {
            var arguments = ["-o", "ControlPath=" + path]
            if let port = route.port { arguments += ["-p", String(port)] }
            if let identity = route.identityFile, !identity.isEmpty { arguments += ["-i", identity] }
            for option in route.options { arguments += ["-o", option] }
            return arguments + ["--", route.destination]
        }

        static func startArguments(_ route: Route, path: String) -> [String] {
            ["-T", "-N", "-f",
             "-o", "ControlMaster=yes", "-o", "ControlPersist=" + String(controlPersistSeconds),
             // A dead connection ends within 15 s: these carry no
             // interactive state, so a short keepalive costs nothing.
             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3"]
                + batchArguments(route)
                + routeArguments(route, path: path)
        }

        static func stopArguments(_ route: Route, path: String) -> [String] {
            ["-O", "stop"] + batchArguments(route) + routeArguments(route, path: path)
        }

        /// What a start's exit says. A refused login, or a batch start that
        /// got no answer in time, is ``StartOutcome/unavailable``: the latter
        /// is a login waiting on the user (a security key's touch, an agent's
        /// confirm), which every run on a connection of its own would ask for
        /// again; the carrier's master asked once. Else ``StartOutcome/failed``.
        static func startOutcome(status: Int32?, timedOut: Bool, stderr: String) -> StartOutcome {
            if timedOut { return .unavailable }
            return status == 255 && isRefusedLogin(stderr) ? .unavailable : .failed
        }

        static func checkArguments(_ route: Route, path: String) -> [String] {
            ["-O", "check"] + batchArguments(route) + routeArguments(route, path: path)
        }

        static func expandArguments(_ route: Route, path: String) -> [String] {
            ["-G"] + batchArguments(route) + routeArguments(route, path: path)
        }

        /// Whether a failed start's stderr says the host refused the login.
        static func isRefusedLogin(_ stderr: String) -> Bool {
            stderr.contains("Permission denied") || stderr.contains("Too many authentication failures")
        }

        /// What a check's exit status and stderr say: only a missing socket
        /// or a refused connection proves the master gone.
        static func liveness(status: Int32?, stderr: String) -> Liveness {
            if status == 0 { return .alive }
            if stderr.contains("No such file or directory") || stderr.contains("Connection refused") { return .dead }
            return .unknown
        }

        func start(_ route: Route, path: String) async -> StartOutcome {
            // A live master there (an earlier launch's, or one a check missed):
            // starting another would carry on as a plain connection, unseen.
            switch await check(route, path: path) {
            case .alive: return .started
            case .unknown: return .failed
            case .dead: break
            }
            guard let expanded = await socketPath(route, path: path) else { return .failed }
            // A path too long for a socket never binds.
            guard Self.fitsSocketPath(expanded) else { return .unavailable }
            // A stale socket (the check found nothing listening) would make the
            // master carry on without one, too.
            if FileManager.default.fileExists(atPath: expanded) { try? FileManager.default.removeItem(atPath: expanded) }
            let result = await Self.run(Self.startArguments(route, path: path), timeout: 25, stderrToFile: true)
            if result.status == 0 { return await check(route, path: path) == .alive ? .started : .failed }
            return Self.startOutcome(status: result.status, timedOut: result.timedOut, stderr: result.output)
        }

        func stop(_ route: Route, path: String) async {
            _ = await Self.run(Self.stopArguments(route, path: path), timeout: 5, stderrToFile: true)
        }

        /// `<directory of socket>/<40 hex digits>`: the digest of the expanded
        /// socket (the carrier's plus this build's suffix) and the index. As
        /// long as a `%C` carrier socket, so it fits wherever that does,
        /// whatever the suffix and index.
        func masterPath(_ route: Route, socket: String, index: Int) -> String {
            Self.masterPath(socket: socket, index: index) ?? route.path(ofMaster: index)
        }

        static func masterPath(socket: String, index: Int) -> String? {
            let directory = (socket as NSString).deletingLastPathComponent
            guard socket.hasPrefix("/"), !directory.isEmpty else { return nil }
            let digest = SHA256.hash(data: Data((socket + "\u{1F}" + String(index)).utf8))
                .prefix(20).map { String(format: "%02x", $0) }.joined()
            return (directory as NSString).appendingPathComponent(digest)
        }

        func check(_ route: Route, path: String) async -> Liveness {
            let result = await Self.run(Self.checkArguments(route, path: path), timeout: 5, stderrToFile: true)
            return Self.liveness(status: result.status, stderr: result.output)
        }

        /// The socket path `path` names for `route`, as `ssh -G` expands it
        /// (no connection).
        func socketPath(_ route: Route, path: String) async -> String? {
            let result = await Self.run(Self.expandArguments(route, path: path), timeout: 5, capturesOutput: true)
            guard result.status == 0 else { return nil }
            for line in result.output.split(separator: "\n") where line.hasPrefix("controlpath ") {
                return String(line.dropFirst("controlpath ".count))
            }
            return nil
        }

        /// Runs ssh; `output` is its stdout (`capturesOutput`) or its stderr
        /// (`stderrToFile`). A master started with `-f` keeps the descriptors
        /// it was given, so its stderr goes to a file, never a pipe that
        /// would not reach end of file while it runs.
        private static func run(
            _ arguments: [String],
            timeout: TimeInterval,
            capturesOutput: Bool = false,
            stderrToFile: Bool = false
        ) async -> (status: Int32?, output: String, timedOut: Bool) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = arguments
                    let pipe = capturesOutput ? Pipe() : nil
                    let errorURL = stderrToFile
                        ? FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-master-" + UUID().uuidString)
                        : nil
                    defer { if let errorURL { try? FileManager.default.removeItem(at: errorURL) } }
                    let errorHandle = errorURL.flatMap { url in
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                            ? try? FileHandle(forWritingTo: url) : nil
                    }
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe ?? FileHandle.nullDevice
                    process.standardError = errorHandle ?? FileHandle.nullDevice
                    do { try process.run() } catch {
                        try? errorHandle?.close()
                        continuation.resume(returning: (nil, "", false))
                        return
                    }
                    let fired = TimerFlag()
                    let timer = DispatchWorkItem {
                        guard process.isRunning else { return }
                        fired.set()
                        process.terminate()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    process.waitUntilExit()
                    timer.cancel()
                    let timedOut = fired.isSet
                    try? errorHandle?.close()
                    let output = errorURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                        ?? String(decoding: data, as: UTF8.self)
                    // A run the timer ended proves nothing about the master.
                    continuation.resume(returning: (timedOut ? nil : process.terminationStatus, timedOut ? "" : output, timedOut))
                }
            }
        }
    }
}

extension SSHMasterPool.Control {
    func stop(_ route: SSHMasterPool.Route, path: String) async {}

    func masterPath(_ route: SSHMasterPool.Route, socket: String, index: Int) -> String {
        route.path(ofMaster: index)
    }
}

extension SSHMasterPool {
    /// Recycles a pool's masters (``recycleMasters()``) when the network path
    /// changes: another Wi-Fi, a VPN coming up or down, a cable. The app
    /// starts one for ``shared``; waking from sleep recycles too.
    final class NetworkWatch: @unchecked Sendable {
        private let monitor = NWPathMonitor()
        private let lock = NSLock()
        private var last: String?
        private var started = false

        func start(recycling pool: SSHMasterPool) {
            let begin: Bool = lock.withLock {
                defer { started = true }
                return !started
            }
            guard begin else { return }
            monitor.pathUpdateHandler = { [weak self, weak pool] path in
                guard let self else { return }
                let signature = Self.signature(
                    satisfied: path.status == .satisfied,
                    interfaces: path.availableInterfaces.map(\.name),
                    gateways: path.gateways.map { "\($0)" }
                )
                if self.changed(to: signature), path.status == .satisfied { pool?.recycleMasters() }
            }
            monitor.start(queue: DispatchQueue(label: "com.cmuxterm.ssh-master-pool.network"))
        }

        /// What identifies a path for this purpose.
        static func signature(satisfied: Bool, interfaces: [String], gateways: [String]) -> String {
            ([satisfied ? "up" : "down"] + interfaces + ["|"] + gateways.sorted()).joined(separator: ",")
        }

        /// Whether `signature` differs from the last one seen; the first one
        /// (the monitor's initial report) is no change.
        func changed(to signature: String) -> Bool {
            lock.withLock {
                defer { last = signature }
                return last != nil && last != signature
            }
        }
    }

    static let networkWatch = NetworkWatch()
}

/// Set once by a timer, read by the thread it may have interrupted.
private final class TimerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Long-lived sessions held as long as the app runs, one per key (a remote
/// language server's route, root and language;
/// ``key(route:rootPath:languageId:)``), so each server holds one of the
/// carrier's counted sessions and none rides another's. Concurrent asks for
/// one key share one ``session(for:keep:make:)``.
actor HeldLongLivedSessions<Session: Sendable> {
    private var held: [String: Session] = [:]
    private var pending: [String: Task<Session, Error>] = [:]

    init() {}

    static func key(route: String, rootPath: String, languageId: String) -> String {
        [route, rootPath, languageId].joined(separator: "\u{1E}")
    }

    /// The session held for `key`, else a new one from `make`, held when
    /// `keep` says so (it has a lease).
    func session(
        for key: String,
        keep: @Sendable (Session) -> Bool,
        make: @escaping @Sendable () async throws -> Session
    ) async throws -> Session {
        if let session = held[key] { return session }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await make() }
        pending[key] = task
        defer { pending[key] = nil }
        let session = try await task.value
        if keep(session) { held[key] = session }
        return session
    }

    var heldCount: Int { held.count }
}
