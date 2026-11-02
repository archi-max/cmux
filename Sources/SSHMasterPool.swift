import Foundation

/// Pre-warmed ControlMasters for this app's one-off `ssh` runs to a host
/// (Files listings, reads, writes and downloads, previews, probes, search,
/// git status, Go to File, file drops), kept apart from the carrier's.
///
/// sshd allows 10 sessions on one connection by default and refuses the rest
/// ("Session open refused by peer", exit 255) without falling back to a direct
/// connection. So the pool:
/// - opens the first master as soon as the host's carrier connects
///   (``warm(_:carrierPath:)``), so the first one-off run doesn't pay the
///   handshake;
/// - keeps it alive (ServerAliveInterval 15, CountMax 4), checks it with
///   `ssh -O check` and, when it dies, starts it again with backoff (up to
///   10 minutes);
/// - lends at most ``capacity`` sessions per master (10 less a reserve of 2),
///   opens another master (`…2`, `…3`) when they are all in use, and queues a
///   run when it can't;
/// - never fails a run: one that can't get a session soon runs on a
///   connection of its own (`ControlPath=none`).
///
/// A master logs in in batch mode, so on a host that only takes a password it
/// can't start. Runs there use the carrier's authenticated master instead, as
/// they did before these masters existed, at most ``carrierCapacity`` at a
/// time before they wait, and every one after ``maxWait``.
///
/// Only paths a carrier registered with ``warm(_:carrierPath:)`` are pooled;
/// any other options pass through untouched, so a user's own ControlPath never
/// gets a master started at it.
///
/// A run passes its options with the base path ``Route/basePath`` as its
/// ControlPath (``SSHTuiConnection/fileOperationSSHOptions``); the pool swaps
/// in the master it lends. Batch runs use `ControlMaster=no`, which still uses
/// a master that exists, so a run on a master that died meanwhile connects
/// directly.
///
/// A run inside another run's ``withSession(destination:port:identityFile:sshOptions:isolation:_:)``
/// for the same host can't deadlock: at capacity it waits ``maxWait`` and then
/// runs on its own connection.
final class SSHMasterPool: @unchecked Sendable {
    /// One host's one-off masters.
    struct Route: Sendable, Equatable {
        let destination: String
        let port: Int?
        let identityFile: String?
        /// The route's options, with no ControlMaster, ControlPersist or ControlPath.
        let options: [String]
        /// The first master's ControlPath; the others append 2, 3, ….
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

        func path(ofMaster index: Int) -> String { index == 0 ? basePath : basePath + String(index + 1) }

        /// One host's masters. A template such as `…/%C-ops` names a different
        /// socket for every host, so the destination and port are part of it.
        var key: String { [destination, port.map(String.init) ?? "", basePath].joined(separator: "\u{1F}") }
    }

    /// Starts and checks masters; a mock in tests.
    protocol Control: Sendable {
        /// Opens a master at `path`, or adopts a live one; true once it accepts sessions.
        func start(_ route: Route, path: String) async -> Bool
        /// `ssh -O check`: true while the master at `path` runs.
        func isAlive(_ route: Route, path: String) async -> Bool
    }

    /// Options for a synchronous run (``lease(destination:port:identityFile:sshOptions:)``).
    /// Call ``release()`` when the run's process exits; it is also released
    /// when the lease goes away.
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
    /// Sessions lent on the carrier's master when this app's masters can't start.
    static let carrierCapacity = 3

    static let shared = SSHMasterPool(control: ProcessControl())

    private struct Master {
        var live = false
        var inUse = 0
        var starting = false
        var failures = 0
        var retryAt: ContinuousClock.Instant?
    }

    private enum Grant {
        /// Not a pooled path: run with the options as given.
        case unpooled
        case path(String)
        /// A connection of its own.
        case direct
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Grant, Error>
    }

    private struct Host {
        var route: Route
        var carrierPath: String?
        var masters: [Master] = [Master()]
        var carrierInUse = 0
        var waiters: [Waiter] = []
        var health: Task<Void, Never>?
        var lastInterest: ContinuousClock.Instant

        /// The first master can't start (no batch-mode login, say), so runs
        /// use the carrier's authenticated master.
        var usesCarrier: Bool { carrierPath != nil && !masters[0].live && masters[0].failures > 0 }
    }

    private let control: Control
    private let healthInterval: Duration
    private let maxWait: Duration
    private let idleTimeout: Duration
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var hosts: [String: Host] = [:]

    init(
        control: Control,
        healthInterval: Duration = .seconds(30),
        maxWait: Duration = .seconds(5),
        idleTimeout: Duration = .seconds(30 * 60)
    ) {
        self.control = control
        self.healthInterval = healthInterval
        self.maxWait = maxWait
        self.idleTimeout = idleTimeout
    }

    deinit {
        for host in hosts.values { host.health?.cancel() }
    }

    // MARK: Use

    /// Registers `route` as a pooled host, opens its first master now and
    /// keeps it alive while the host is in use. Call when the host's carrier
    /// connects. `carrierPath` is the carrier's ControlPath, which runs use
    /// when the master can't start; a route at the carrier's own path is not
    /// pooled.
    func warm(_ route: Route, carrierPath: String?) {
        guard route.basePath != carrierPath else { return }
        lock.withLock {
            let key = route.key
            if hosts[key] == nil {
                hosts[key] = Host(route: route, carrierPath: carrierPath, lastInterest: clock.now)
            } else {
                hosts[key]?.route = route
                hosts[key]?.carrierPath = carrierPath
            }
            touch(key)
            startIfNeeded(key, index: 0)
        }
    }

    /// Runs `body` with `options`, their ControlPath swapped for a master with
    /// a free session (the carrier's when the masters can't start, or `none`, a
    /// direct connection, when none frees up in time). Options that name no
    /// pooled path pass through unchanged.
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
        switch try await acquire(route.key) {
        case .unpooled:
            return try await body(options)
        case .direct:
            return try await body(Self.replacingControlPath(in: options, with: "none"))
        case .path(let path):
            defer { release(route.key, path: path) }
            return try await body(Self.replacingControlPath(in: options, with: path))
        }
    }

    /// ``withSession(destination:port:identityFile:sshOptions:isolation:_:)``
    /// for a run that can't wait: a free session now, else the carrier's when
    /// the masters can't start, else a connection of its own.
    func lease(destination: String, port: Int?, identityFile: String?, sshOptions options: [String]) -> Lease {
        guard let route = Route(destination: destination, port: port, identityFile: identityFile, sshOptions: options) else {
            return Lease(sshOptions: options)
        }
        let key = route.key
        let grant: Grant = lock.withLock {
            guard hosts[key] != nil else { return .unpooled }
            touch(key)
            if let path = lend(key) { return .path(path) }
            if let carrier = overflowToCarrier(key) { return .path(carrier) }
            startMore(key)
            return .direct
        }
        switch grant {
        case .unpooled:
            return Lease(sshOptions: options)
        case .direct:
            return Lease(sshOptions: Self.replacingControlPath(in: options, with: "none"))
        case .path(let path):
            return Lease(sshOptions: Self.replacingControlPath(in: options, with: path)) { [weak self] in
                self?.release(key, path: path)
            }
        }
    }

    /// The carrier's ControlPath while `route`'s masters can't start, for a
    /// long-lived run that would otherwise open its own connection (which
    /// can't log in either).
    func carrierPathIfMastersFail(_ route: Route) -> String? {
        lock.withLock {
            guard let host = hosts[route.key], host.usesCarrier else { return nil }
            return host.carrierPath
        }
    }

    /// Sessions lent on the master (or carrier) at `path`.
    func sessionsInUse(_ route: Route, path: String) -> Int {
        lock.withLock {
            guard let host = hosts[route.key] else { return 0 }
            if path == host.carrierPath { return host.carrierInUse }
            return host.masters.indices.first { route.path(ofMaster: $0) == path }.map { host.masters[$0].inUse } ?? 0
        }
    }

    /// Runs queued for a session on `route`'s masters.
    func runsWaiting(_ route: Route) -> Int {
        lock.withLock { hosts[route.key]?.waiters.count ?? 0 }
    }

    // MARK: Lending

    private func acquire(_ key: String) async throws -> Grant {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Grant, Error>) in
                let immediate: Result<Grant, Error>? = lock.withLock {
                    guard hosts[key] != nil else { return .success(.unpooled) }
                    // A cancel that came before this waiter was queued: the
                    // handler below found nothing to remove.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    touch(key)
                    if let path = lend(key) { return .success(.path(path)) }
                    hosts[key]?.waiters.append(Waiter(id: id, continuation: continuation))
                    startMore(key)
                    scheduleExpiry(key, waiter: id)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Grant, Error>? = lock.withLock { removeWaiter(key, id: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Called under the lock: a session on the first live master with room,
    /// or on the carrier's while the masters can't start.
    private func lend(_ key: String) -> String? {
        guard var host = hosts[key] else { return nil }
        for index in host.masters.indices where host.masters[index].live && host.masters[index].inUse < Self.capacity {
            host.masters[index].inUse += 1
            hosts[key] = host
            return host.route.path(ofMaster: index)
        }
        if host.usesCarrier, let carrier = host.carrierPath, host.carrierInUse < Self.carrierCapacity {
            host.carrierInUse += 1
            hosts[key] = host
            return carrier
        }
        return nil
    }

    /// Called under the lock: past the carrier's share, a run that can't wait
    /// still uses the carrier while the masters can't start; its own
    /// connection couldn't log in.
    private func overflowToCarrier(_ key: String) -> String? {
        guard let host = hosts[key], host.usesCarrier, let carrier = host.carrierPath else { return nil }
        hosts[key]?.carrierInUse += 1
        return carrier
    }

    /// Called under the lock: every live master is full, so start the next
    /// (or the first again).
    private func startMore(_ key: String) {
        guard let host = hosts[key] else { return }
        if let index = host.masters.indices.first(where: { !host.masters[$0].live && !host.masters[$0].starting }) {
            startIfNeeded(key, index: index)
        } else if host.masters.count < Self.maxMasters, !host.masters.contains(where: \.starting) {
            hosts[key]?.masters.append(Master())
            startIfNeeded(key, index: host.masters.count)
        }
    }

    /// Called under the lock: bounds a queued run's wait.
    private func scheduleExpiry(_ key: String, waiter id: UUID) {
        let maxWait = maxWait
        Task { [weak self] in
            try? await Task.sleep(for: maxWait)
            self?.expire(key, waiter: id)
        }
    }

    /// Called under the lock.
    private func removeWaiter(_ key: String, id: UUID) -> CheckedContinuation<Grant, Error>? {
        guard let index = hosts[key]?.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return hosts[key]?.waiters.remove(at: index).continuation
    }

    /// A waiter that got no session in time runs on its own connection, or on
    /// the carrier's while the masters can't start.
    private func expire(_ key: String, waiter id: UUID) {
        let expired: (CheckedContinuation<Grant, Error>, Grant)? = lock.withLock {
            guard let continuation = removeWaiter(key, id: id) else { return nil }
            return (continuation, overflowToCarrier(key).map { .path($0) } ?? .direct)
        }
        if let (continuation, grant) = expired { continuation.resume(returning: grant) }
    }

    private func release(_ key: String, path: String) {
        let handoffs: [(CheckedContinuation<Grant, Error>, String)] = lock.withLock {
            guard var host = hosts[key] else { return [] }
            if path == host.carrierPath {
                host.carrierInUse = max(0, host.carrierInUse - 1)
            } else if let index = host.masters.indices.first(where: { host.route.path(ofMaster: $0) == path }) {
                host.masters[index].inUse = max(0, host.masters[index].inUse - 1)
            } else {
                return []
            }
            hosts[key] = host
            return drainWaiters(key)
        }
        for (continuation, path) in handoffs { continuation.resume(returning: .path(path)) }
    }

    /// Called under the lock: lends free sessions to waiters, oldest first.
    private func drainWaiters(_ key: String) -> [(CheckedContinuation<Grant, Error>, String)] {
        var handoffs: [(CheckedContinuation<Grant, Error>, String)] = []
        while hosts[key]?.waiters.isEmpty == false, let path = lend(key) {
            guard let waiter = hosts[key]?.waiters.removeFirst() else { break }
            handoffs.append((waiter.continuation, path))
        }
        return handoffs
    }

    // MARK: Masters

    /// Called under the lock: the host is in use; keep its health loop running.
    private func touch(_ key: String) {
        hosts[key]?.lastInterest = clock.now
        if hosts[key] != nil, hosts[key]?.health == nil {
            hosts[key]?.health = Task { [weak self] in await self?.watch(key) }
        }
    }

    /// Called under the lock: starts master `index` unless it is live,
    /// starting or waiting out its backoff.
    private func startIfNeeded(_ key: String, index: Int) {
        guard var host = hosts[key], host.masters.indices.contains(index) else { return }
        let master = host.masters[index]
        guard !master.live, !master.starting else { return }
        if let retryAt = master.retryAt, clock.now < retryAt { return }
        host.masters[index].starting = true
        hosts[key] = host
        let route = host.route
        let path = route.path(ofMaster: index)
        let control = control
        Task { [weak self] in
            let ok = await control.start(route, path: path)
            self?.started(key, index: index, ok: ok)
        }
    }

    private func started(_ key: String, index: Int, ok: Bool) {
        let handoffs: [(CheckedContinuation<Grant, Error>, String)] = lock.withLock {
            guard var host = hosts[key], host.masters.indices.contains(index) else { return [] }
            host.masters[index].starting = false
            host.masters[index].live = ok
            if ok {
                host.masters[index].failures = 0
                host.masters[index].retryAt = nil
            } else {
                host.masters[index].failures += 1
                // 1, 2, 4 … 512 seconds, then every 10 minutes: on a host
                // that takes only a password every try is a refused login.
                let seconds = min(600, 1 << min(host.masters[index].failures - 1, 10))
                host.masters[index].retryAt = clock.now + .seconds(seconds)
            }
            hosts[key] = host
            // A first master that can't start hands its waiters the carrier.
            return drainWaiters(key)
        }
        for (continuation, path) in handoffs { continuation.resume(returning: .path(path)) }
    }

    /// The health loop: checks each master and replaces a dead first master
    /// before a run needs it, until the host goes unused for ``idleTimeout``.
    private func watch(_ key: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: healthInterval)
            let snapshot: (route: Route, live: [Int])? = lock.withLock {
                guard let host = hosts[key] else { return nil }
                if clock.now - host.lastInterest > idleTimeout {
                    hosts[key]?.health = nil
                    return nil
                }
                return (host.route, host.masters.indices.filter { host.masters[$0].live })
            }
            guard let snapshot else { return }
            for index in snapshot.live where !(await control.isAlive(snapshot.route, path: snapshot.route.path(ofMaster: index))) {
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

    private static func optionKey(_ option: String) -> String? {
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
        /// macOS caps an AF_UNIX `sun_path` at 104 bytes including the NUL,
        /// and OpenSSH first binds the path plus 17 bytes (`.` and 16 random
        /// characters).
        static func fitsSocketPath(_ expandedPath: String) -> Bool {
            expandedPath.utf8.count + 17 <= 103
        }

        func start(_ route: Route, path: String) async -> Bool {
            // A master an earlier launch of this app left running (ControlPersist).
            if await isAlive(route, path: path) { return true }
            // A master at a path too long for a socket would carry on as a plain
            // connection, unseen, so don't start one; runs use the carrier.
            guard let expanded = await Self.expandedControlPath(route, path: path), Self.fitsSocketPath(expanded) else {
                return false
            }
            // A stale socket would make the master carry on without one, too.
            if FileManager.default.fileExists(atPath: expanded) { try? FileManager.default.removeItem(atPath: expanded) }
            let arguments = ["-T", "-N", "-f",
                             "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                             "-o", "ControlMaster=yes", "-o", "ControlPersist=600",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
                + Self.routeArguments(route, path: path)
            guard await Self.run(arguments, timeout: 25).status == 0 else { return false }
            return await isAlive(route, path: path)
        }

        func isAlive(_ route: Route, path: String) async -> Bool {
            // The route's port, user and options too: `%C` and the like expand from them.
            await Self.run(["-O", "check"] + Self.routeArguments(route, path: path), timeout: 5).status == 0
        }

        private static func routeArguments(_ route: Route, path: String) -> [String] {
            var arguments = ["-o", "ControlPath=" + path]
            if let port = route.port { arguments += ["-p", String(port)] }
            if let identity = route.identityFile, !identity.isEmpty { arguments += ["-i", identity] }
            for option in route.options { arguments += ["-o", option] }
            return arguments + ["--", route.destination]
        }

        /// The socket path `path` names for `route`, as `ssh -G` expands it
        /// (no connection).
        private static func expandedControlPath(_ route: Route, path: String) async -> String? {
            let result = await run(["-G"] + routeArguments(route, path: path), timeout: 5, capturesOutput: true)
            guard result.status == 0 else { return nil }
            for line in result.output.split(separator: "\n") where line.hasPrefix("controlpath ") {
                return String(line.dropFirst("controlpath ".count))
            }
            return nil
        }

        private static func run(
            _ arguments: [String],
            timeout: TimeInterval,
            capturesOutput: Bool = false
        ) async -> (status: Int32?, output: String) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = arguments
                    // No pipes for a master: a backgrounded one must not hold
                    // one open. `ssh -G` exits at once, so its output may.
                    let pipe = capturesOutput ? Pipe() : nil
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe ?? FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do { try process.run() } catch {
                        continuation.resume(returning: (nil, ""))
                        return
                    }
                    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    process.waitUntilExit()
                    timer.cancel()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }
        }
    }
}
