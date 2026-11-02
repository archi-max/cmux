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

    /// Stub (red): does nothing yet.
    func warm(_ route: Route) {}

    /// Stub (red): runs `body` with `options` unchanged.
    func withSession<T>(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions options: [String],
        isolation: isolated (any Actor)? = #isolation,
        _ body: ([String]) async throws -> T
    ) async throws -> T {
        try await body(options)
    }

    /// Stub (red).
    func sessionsInUse(_ route: Route, path: String) -> Int { 0 }

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
