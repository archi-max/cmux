import Foundation

/// Pre-warmed ControlMasters for this app's one-off `ssh` runs to a host
/// (Files listings, reads, writes and downloads, previews, probes), kept apart
/// from the carrier's.
///
/// sshd allows 10 sessions on one connection by default and refuses the rest
/// ("Session open refused by peer", exit 255) without falling back to a direct
/// connection. So the pool:
/// - opens the first master as soon as the host's carrier connects
///   (``warm(_:)``), so the first one-off run doesn't pay the handshake;
/// - keeps it alive (ServerAliveInterval 15, CountMax 4), checks it with
///   `ssh -O check` and, when it dies, starts it again with backoff;
/// - lends at most ``capacity`` sessions per master (10 less a reserve of 2),
///   opens another master (`-ops-<app>2`, `…3`) when they are all in use, and
///   queues a run when it can't;
/// - never fails a run: one that can't get a session soon runs on a
///   connection of its own (`ControlPath=none`).
///
/// A run passes its options with the base path ``Route/basePath`` as its
/// ControlPath (``SSHTuiConnection/fileOperationSSHOptions``); the pool swaps
/// in the master it lends. Batch runs use `ControlMaster=no`, so a run on a
/// master that died meanwhile still connects directly.
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
    }

    /// Starts and checks masters; a mock in tests.
    protocol Control: Sendable {
        /// Opens a master at `path`; true once it accepts sessions.
        func start(_ route: Route, path: String) async -> Bool
        /// `ssh -O check`: true while the master at `path` runs.
        func isAlive(_ route: Route, path: String) async -> Bool
    }

    static let sessionsPerMaster = 10
    static let reserve = 2
    static let maxMasters = 3
    /// Sessions lent per master.
    static var capacity: Int { sessionsPerMaster - reserve }

    static let shared = SSHMasterPool(control: ProcessControl())

    private struct Master {
        var live = false
        var inUse = 0
        var starting = false
        var failures = 0
        var retryAt: ContinuousClock.Instant?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<String?, Never>
    }

    private struct Host {
        var route: Route
        var masters: [Master] = [Master()]
        var waiters: [Waiter] = []
        var health: Task<Void, Never>?
        var lastInterest: ContinuousClock.Instant
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

    /// Opens `route`'s first master now and keeps it alive while the host is
    /// in use. Call when the host's carrier connects.
    func warm(_ route: Route) {
        lock.withLock {
            touch(route)
            startIfNeeded(route.basePath, index: 0)
        }
    }

    /// Runs `body` with `options`, their ControlPath swapped for a master with
    /// a free session (or `none`, a direct connection, when none frees up in
    /// time). Options that name no pool path pass through unchanged.
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
        let path = await acquire(route)
        defer { if let path { release(route.basePath, path: path) } }
        return try await body(Self.replacingControlPath(in: options, with: path ?? "none"))
    }

    /// Sessions lent on the master at `path`.
    func sessionsInUse(_ route: Route, path: String) -> Int {
        lock.withLock {
            guard let host = hosts[route.basePath] else { return 0 }
            return host.masters.indices.first { route.path(ofMaster: $0) == path }.map { host.masters[$0].inUse } ?? 0
        }
    }

    // MARK: Lending

    private func acquire(_ route: Route) async -> String? {
        let id = UUID()
        let path: String? = await withCheckedContinuation { continuation in
            let immediate: String?? = lock.withLock {
                touch(route)
                if let path = lend(route.basePath) { return .some(path) }
                hosts[route.basePath]?.waiters.append(Waiter(id: id, continuation: continuation))
                growIfFull(route.basePath)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
        return path
    }

    /// Called under the lock: a session on the first live master with room.
    private func lend(_ key: String) -> String? {
        guard var host = hosts[key] else { return nil }
        for index in host.masters.indices where host.masters[index].live && host.masters[index].inUse < Self.capacity {
            host.masters[index].inUse += 1
            hosts[key] = host
            return host.route.path(ofMaster: index)
        }
        return nil
    }

    /// Called under the lock: every live master is full, so start the next
    /// (or the first again), and bound the wait.
    private func growIfFull(_ key: String) {
        guard let host = hosts[key] else { return }
        if let index = host.masters.indices.first(where: { !host.masters[$0].live && !host.masters[$0].starting }) {
            startIfNeeded(key, index: index)
        } else if host.masters.count < Self.maxMasters, !host.masters.contains(where: \.starting) {
            hosts[key]?.masters.append(Master())
            startIfNeeded(key, index: host.masters.count)
        }
        guard let waiter = hosts[key]?.waiters.last else { return }
        let maxWait = maxWait
        Task { [weak self] in
            try? await Task.sleep(for: maxWait)
            self?.expire(key, waiter: waiter.id)
        }
    }

    /// A waiter that got no session in time runs on its own connection.
    private func expire(_ key: String, waiter id: UUID) {
        let continuation: CheckedContinuation<String?, Never>? = lock.withLock {
            guard let index = hosts[key]?.waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return hosts[key]?.waiters.remove(at: index).continuation
        }
        continuation?.resume(returning: nil)
    }

    private func release(_ key: String, path: String) {
        let handoffs: [(CheckedContinuation<String?, Never>, String)] = lock.withLock {
            guard var host = hosts[key],
                  let index = host.masters.indices.first(where: { host.route.path(ofMaster: $0) == path }) else { return [] }
            host.masters[index].inUse = max(0, host.masters[index].inUse - 1)
            hosts[key] = host
            return drainWaiters(key)
        }
        for (continuation, path) in handoffs { continuation.resume(returning: path) }
    }

    /// Called under the lock: lends free sessions to waiters, oldest first.
    private func drainWaiters(_ key: String) -> [(CheckedContinuation<String?, Never>, String)] {
        var handoffs: [(CheckedContinuation<String?, Never>, String)] = []
        while let waiter = hosts[key]?.waiters.first, let path = lend(key) {
            hosts[key]?.waiters.removeFirst()
            handoffs.append((waiter.continuation, path))
        }
        return handoffs
    }

    // MARK: Masters

    /// Called under the lock.
    private func touch(_ route: Route) {
        if hosts[route.basePath] == nil {
            hosts[route.basePath] = Host(route: route, lastInterest: clock.now)
        } else {
            hosts[route.basePath]?.route = route
            hosts[route.basePath]?.lastInterest = clock.now
        }
        if hosts[route.basePath]?.health == nil {
            let key = route.basePath
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
        let handoffs: [(CheckedContinuation<String?, Never>, String)] = lock.withLock {
            guard var host = hosts[key], host.masters.indices.contains(index) else { return [] }
            host.masters[index].starting = false
            host.masters[index].live = ok
            if ok {
                host.masters[index].failures = 0
                host.masters[index].retryAt = nil
            } else {
                host.masters[index].failures += 1
                // 1, 2, 4 … 60 seconds.
                let seconds = min(60, 1 << min(host.masters[index].failures - 1, 6))
                host.masters[index].retryAt = clock.now + .seconds(seconds)
            }
            hosts[key] = host
            return drainWaiters(key)
        }
        for (continuation, path) in handoffs { continuation.resume(returning: path) }
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
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == " " }) else { return nil }
        return trimmed[..<separator].lowercased()
    }

    private static func optionValue(_ option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == " " }) else { return "" }
        return trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "= ").union(.whitespaces))
    }
}

extension SSHMasterPool {
    /// The real masters: `ssh -fN` with ControlMaster=yes, and `ssh -O check`.
    struct ProcessControl: Control {
        func start(_ route: Route, path: String) async -> Bool {
            var arguments = ["-T", "-N", "-f",
                             "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                             "-o", "ControlMaster=yes", "-o", "ControlPersist=600",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                             "-o", "ControlPath=" + path]
            if let port = route.port { arguments += ["-p", String(port)] }
            if let identity = route.identityFile, !identity.isEmpty { arguments += ["-i", identity] }
            for option in route.options { arguments += ["-o", option] }
            arguments += ["--", route.destination]
            guard await Self.run(arguments, timeout: 25) == 0 else { return false }
            return await isAlive(route, path: path)
        }

        func isAlive(_ route: Route, path: String) async -> Bool {
            await Self.run(["-o", "ControlPath=" + path, "-O", "check", "--", route.destination], timeout: 5) == 0
        }

        private static func run(_ arguments: [String], timeout: TimeInterval) async -> Int32? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = arguments
                    // No pipes: a backgrounded master must not hold one open.
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    do { try process.run() } catch {
                        continuation.resume(returning: nil)
                        return
                    }
                    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                    process.waitUntilExit()
                    timer.cancel()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }
    }
}
