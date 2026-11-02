import CryptoKit
import Foundation

/// What driver tracing loads into its design model sidecar (`Resources/vaporview/sv-model`,
/// cmux-sv-model, built on slang): the design slang-server compiles, as slang arguments.
public enum SVModelLoad {
    /// Library extensions searched for modules a top-level file instantiates (`-y`).
    static let libraryExtensions = [".sv", ".v", ".svh"]

    /// slang arguments for the editor's compilation: the chosen build file (a profile), else the
    /// `"build"` of the folder's server.json (relative to `root`), else a top-level file with the
    /// modules it instantiates found by file name in its folder and the root. Nil when nothing
    /// is chosen (explore mode): the design's top is unknown. `buildRelativePaths` (server.json's
    /// option of that name) reads the config's build file with its paths relative to it (`-F`).
    public static func arguments(
        target: SlangCompilationTarget?,
        configBuild: String?,
        buildRelativePaths: Bool = false,
        root: String
    ) -> [String]? {
        switch target {
        case .buildFile(let path)?:
            return ["-f", path]
        case .topLevel(let file)?:
            let folder = (file as NSString).deletingLastPathComponent
            var args = [file, "-y", folder]
            if folder != root { args += ["-y", root] }
            for ext in libraryExtensions { args += ["--libext", ext] }
            return args
        case nil:
            guard let build = configBuild?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty else { return nil }
            return [buildRelativePaths ? "-F" : "-f", build.hasPrefix("/") ? build : (root as NSString).appendingPathComponent(build)]
        }
    }

    /// The prefixes that map design paths onto the dump for one traced signal: what is left of
    /// each path once their common trailing segments are dropped (whole segments, either empty).
    public static func prefixes(dumpPath: [String], designPath: [String]) -> (designPrefix: String, dumpPrefix: String) {
        var common = 0
        while common < min(dumpPath.count, designPath.count),
              dumpPath[dumpPath.count - 1 - common] == designPath[designPath.count - 1 - common] {
            common += 1
        }
        return (
            HierarchyPathMapping.join(Array(designPath.dropLast(common))),
            HierarchyPathMapping.join(Array(dumpPath.dropLast(common)))
        )
    }
}

#if os(macOS)
/// One running cmux-sv-model, local or on an SSH host, and its JSON-lines protocol: a ready
/// line `{"id":0,"ready":true,...}` first (lines before it, a remote shell's banner, are
/// skipped), then one reply line per request, matched by `id`. A reply with `"ok":false`
/// throws `Failure.request`.
///
/// The launch command exits 87 when the build for this version is not installed; the install
/// command then runs (with the sidecar sources as a tar on its stdin) and the launch is retried.
/// A sidecar that exits is started again by the next request, and the last `load` is replayed
/// into it first.
public final class SVModelSidecar: @unchecked Sendable {
    public struct Command: Sendable {
        public let executable: String
        public let arguments: [String]

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Turns a POSIX shell command into the process that runs it where the design is.
    public typealias Runner = @Sendable (_ shellCommand: String) -> Command

    /// A reply object (a JSON object from the sidecar, read-only once made).
    public struct Reply: @unchecked Sendable {
        public let object: [String: Any]

        public subscript(key: String) -> Any? { object[key] }

        public init(object: [String: Any]) { self.object = object }
    }

    public enum Status: Sendable, Equatable {
        case connecting
        case building
    }

    public enum Failure: Error, Sendable, Equatable {
        /// The install command failed with this exit code (build.sh's codes) and stderr tail.
        case setupFailed(code: Int32, detail: String)
        /// ssh could not reach the host (255 before the ready line).
        case connectionFailed(detail: String)
        case timedOut(detail: String)
        case exited(detail: String)
        case protocolError
        case stopped
        /// The sidecar answered `"ok":false`.
        case request(code: String, message: String)
    }

    public static let notInstalledStatus: Int32 = 87
    public static let readyTimeout: TimeInterval = 120
    /// A first build of slang takes minutes on a busy host.
    public static let installTimeout: TimeInterval = 40 * 60
    /// A load of a large design (all of its files elaborated) can take a while.
    public static let requestTimeout: TimeInterval = 15 * 60

    private let runner: Runner
    private let launchCommand: String
    private let installCommand: String?
    private let installSource: URL?
    private let lock = NSLock()
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var startTask: Task<Void, any Error>?
    private var process: Process?
    private var input: FileHandle?
    private var installProcesses: [Process] = []
    private var isStopped = false
    private var isReady = false
    private var generation = 0
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Reply, any Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var stderrTail = Data()
    private var readyLine: Reply?
    private var lastLoad: [String: any Sendable]?
    private var loadGeneration = 0
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.sv-model.write")

    /// `installSource`: the folder sent as a tar on the install command's stdin.
    public init(runner: @escaping Runner, launchCommand: String, installCommand: String?, installSource: URL? = nil) {
        self.runner = runner
        self.launchCommand = launchCommand
        self.installCommand = installCommand
        self.installSource = installSource
    }

    /// The running process's ready line (what it said about itself), once it has started.
    public var lastReady: Reply? { lock.withLock { readyLine } }

    public var onStatus: (@Sendable (Status) -> Void)? {
        get { lock.withLock { statusHandler } }
        set { lock.withLock { statusHandler = newValue } }
    }

    private func report(_ status: Status) {
        lock.withLock { statusHandler }?(status)
    }

    /// The shell commands for the bundled sidecar folder `source` installed under
    /// `$HOME/.cache/cmux/sv-model/<version>-<machine>` (no single quotes: they run in `sh -c '…'`).
    public static func commands(source: URL) -> (launch: String, install: String) {
        let dir = "$HOME/.cache/cmux/sv-model/\(version(of: source))-$(uname -m)"
        let launch = "D=\"\(dir)\"; [ -x \"$D/cmux-sv-model\" ] && [ -f \"$D/sv-model.sh\" ] || exit \(notInstalledStatus); exec sh \"$D/sv-model.sh\""
        let install = "S=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-sv-model-src.XXXXXX\") && tar -xf - -C \"$S\" && "
            + "sh \"$S/build.sh\" \"$S\" \"\(dir)\"; rc=$?; rm -rf \"$S\"; exit $rc"
        return (launch, install)
    }

    // MARK: Requests

    /// Sends one request object and returns the reply object.
    public func request(_ object: [String: any Sendable], timeout: TimeInterval = SVModelSidecar.requestTimeout) async throws -> Reply {
        try await ensureRunning()
        if object["cmd"] as? String == "load" {
            lock.withLock { lastLoad = object }
            let reply = try await send(object, timeout: timeout)
            lock.withLock { loadGeneration = generation }
            return reply
        }
        let replay: [String: any Sendable]? = lock.withLock { loadGeneration == generation ? nil : lastLoad }
        if let replay {
            _ = try await send(replay, timeout: timeout)
            lock.withLock { loadGeneration = generation }
        }
        return try await send(object, timeout: timeout)
    }

    private func send(_ request: [String: any Sendable], timeout: TimeInterval) async throws -> Reply {
        var object: [String: Any] = request
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isStopped, let input else {
                lock.unlock()
                continuation.resume(throwing: Failure.stopped)
                return
            }
            let id = nextId
            nextId += 1
            object["id"] = id
            guard JSONSerialization.isValidJSONObject(object), var line = try? JSONSerialization.data(withJSONObject: object) else {
                lock.unlock()
                continuation.resume(throwing: Failure.protocolError)
                return
            }
            pending[id] = continuation
            lock.unlock()
            line.append(0x0A)
            let message = line
            writeQueue.async { try? input.write(contentsOf: message) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let waiting = self.lock.withLock { self.pending.removeValue(forKey: id) }
                waiting?.resume(throwing: Failure.timedOut(detail: ""))
            }
        }
    }

    /// Ends the sidecar (closing its stdin ends it), any install, and fails waiting requests.
    public func stop() {
        lock.lock()
        isStopped = true
        let process = self.process
        self.process = nil
        let input = self.input
        self.input = nil
        let installs = installProcesses
        installProcesses = []
        startTask?.cancel()
        let waiting = Array(pending.values)
        pending.removeAll()
        let ready = readyContinuation
        readyContinuation = nil
        lock.unlock()
        writeQueue.async { try? input?.close() }
        if let process, process.isRunning { process.terminate() }
        installs.filter(\.isRunning).forEach { $0.terminate() }
        waiting.forEach { $0.resume(throwing: Failure.stopped) }
        ready?.resume(throwing: Failure.stopped)
    }

    // MARK: Start

    private func ensureRunning() async throws {
        let task: Task<Void, any Error>? = lock.withLock {
            if isStopped { return nil }
            if let startTask { return startTask }
            let task = Task {
                do {
                    try await self.start()
                } catch {
                    // A setup failure stays until the sidecar is made again; others are retried.
                    if case Failure.setupFailed? = error as? Failure {} else { self.lock.withLock { self.startTask = nil } }
                    throw error
                }
            }
            startTask = task
            return task
        }
        guard let task else { throw Failure.stopped }
        try await task.value
    }

    private struct NotInstalled: Error {}

    private func start() async throws {
        report(.connecting)
        do {
            try await launch()
        } catch is NotInstalled {
            guard let installCommand else { throw Failure.setupFailed(code: Self.notInstalledStatus, detail: "") }
            report(.building)
            try await install(installCommand)
            report(.connecting)
            do {
                try await launch()
            } catch is NotInstalled {
                throw Failure.setupFailed(code: Self.notInstalledStatus, detail: lock.withLock { Self.tail(of: stderrTail) })
            }
        }
    }

    private func launch() async throws {
        let command = runner(launchCommand)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let generation: Int = lock.withLock {
            self.generation += 1
            return self.generation
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.withLock {
                self.stderrTail.append(data)
                if self.stderrTail.count > 16 * 1024 { self.stderrTail = self.stderrTail.suffix(8 * 1024) }
            }
        }
        // The exit is handled once stdout is read to its end: a last line (a refused ready line)
        // is never lost to the exit.
        let outputRead = DispatchGroup()
        outputRead.enter()
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // (At most 2 s: a child left running may hold stdout open.)
            DispatchQueue.global().async {
                _ = outputRead.wait(timeout: .now() + 2)
                self?.didExit(status: status, generation: generation)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if isStopped {
                lock.unlock()
                continuation.resume(throwing: Failure.stopped)
                return
            }
            readyContinuation = continuation
            isReady = false
            stderrTail = Data()
            self.process = process
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            input = stdin.fileHandleForWriting
            lock.unlock()
            do {
                try process.run()
            } catch {
                failReady(Failure.exited(detail: error.localizedDescription), generation: generation)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
                guard let self else { return }
                let tail = self.lock.withLock { Self.tail(of: self.stderrTail) }
                if self.failReady(Failure.timedOut(detail: tail), generation: generation), process.isRunning { process.terminate() }
            }
            let reader = Thread { [weak self] in
                let handle = stdout.fileHandleForReading
                var buffer = Data()
                defer { outputRead.leave() }
                while true {
                    let chunk = handle.availableData
                    guard !chunk.isEmpty, let self else { return }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer = Data(buffer[(newline + 1)...])
                        self.handle(line: Data(line), generation: generation)
                    }
                }
            }
            reader.name = "cmux sv-model reader"
            reader.start()
        }
    }

    private func handle(line: Data, generation: Int) {
        // Read from the first `{`: a shell's title escape may share the ready line.
        guard let brace = line.firstIndex(of: UInt8(ascii: "{")),
              let object = (try? JSONSerialization.jsonObject(with: line[brace...])) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue else { return }
        if id == 0 {
            let ready: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard generation == self.generation else { return nil }
                if object["ready"] as? Bool == true { isReady = true }
                readyLine = Reply(object: object)
                let ready = readyContinuation
                readyContinuation = nil
                return ready
            }
            if object["ready"] as? Bool == true {
                ready?.resume()
            } else if let code = object["error"] as? String {
                // A session that can't start says why (a missing KDB, no licence seat).
                ready?.resume(throwing: Failure.request(code: code, message: object["message"] as? String ?? ""))
            } else {
                ready?.resume(throwing: Failure.exited(detail: object["message"] as? String ?? ""))
            }
            return
        }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        if object["ok"] as? Bool == false {
            continuation?.resume(throwing: Failure.request(code: object["error"] as? String ?? "", message: object["message"] as? String ?? ""))
        } else {
            continuation?.resume(returning: Reply(object: object))
        }
    }

    @discardableResult
    private func failReady(_ error: any Error, generation: Int) -> Bool {
        let ready: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard generation == self.generation, let ready = readyContinuation else { return nil }
            readyContinuation = nil
            return ready
        }
        ready?.resume(throwing: error)
        return ready != nil
    }

    private func didExit(status: Int32, generation: Int) {
        let (ready, waiting, error): (CheckedContinuation<Void, any Error>?, [CheckedContinuation<Reply, any Error>], any Error) = lock.withLock {
            let detail = Self.tail(of: stderrTail)
            let error: any Error
            if status == Self.notInstalledStatus, !isReady {
                error = NotInstalled()
            } else if status == 255, !isReady {
                error = Failure.connectionFailed(detail: detail)
            } else {
                error = Failure.exited(detail: detail)
            }
            guard generation == self.generation else { return (nil, [], error) }
            process = nil
            input = nil
            // The next request starts a new one.
            if isReady { startTask = nil }
            isReady = false
            let ready = readyContinuation
            readyContinuation = nil
            let waiting = Array(pending.values)
            pending.removeAll()
            return (ready, waiting, error)
        }
        ready?.resume(throwing: error)
        waiting.forEach { $0.resume(throwing: error is NotInstalled ? Failure.exited(detail: "") : error) }
    }

    private func install(_ command: String) async throws {
        let shell = runner(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.executable)
        process.arguments = shell.arguments
        var tar: Process?
        if let installSource {
            let archive = Pipe()
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            t.arguments = ["--no-xattrs", "--no-mac-metadata", "--format", "ustar", "-cf", "-", "-C", installSource.path, "."]
            var environment = ProcessInfo.processInfo.environment
            environment["COPYFILE_DISABLE"] = "1"
            t.environment = environment
            t.standardOutput = archive
            t.standardError = FileHandle.nullDevice
            _ = fcntl(archive.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.standardInput = archive
            tar = t
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let log = SVModelInstallLog()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            let stopped: Bool = lock.withLock {
                if isStopped { return true }
                installProcesses = [process] + (tar.map { [$0] } ?? [])
                return false
            }
            guard !stopped else {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure.stopped)
                return
            }
            do {
                try tar?.run()
                try process.run()
            } catch {
                process.terminationHandler = nil
                if let tar, tar.isRunning { tar.terminate() }
                continuation.resume(throwing: Failure.setupFailed(code: -1, detail: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.installTimeout) {
                if process.isRunning {
                    log.timedOut = true
                    process.terminate()
                }
            }
        }
        lock.withLock { installProcesses = [] }
        if let tar, tar.isRunning { tar.terminate() }
        stderr.fileHandleForReading.readabilityHandler = nil
        log.append(stderr.fileHandleForReading.readDataToEndOfFile())
        if lock.withLock({ isStopped }) { throw Failure.stopped }
        let detail = Self.tail(of: log.data)
        if log.timedOut { throw Failure.timedOut(detail: detail) }
        if status == 255 { throw Failure.connectionFailed(detail: detail) }
        guard status == 0 else { throw Failure.setupFailed(code: status, detail: detail) }
    }

    static func tail(of data: Data, lines: Int = 12) -> String {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines).joined(separator: "\n")
    }

    // MARK: Version

    /// The first 16 hex digits of a SHA-256 over the folder's files (relative path and contents,
    /// in path order), so a cmux update with changed sidecar sources builds once more.
    public static func version(of root: URL) -> String {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var paths: [String] = []
        if let enumerator = fileManager.enumerator(atPath: rootPath) {
            for case let path as String in enumerator {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: rootPath + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    paths.append(path)
                }
            }
        }
        var hasher = SHA256()
        for path in paths.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            if let data = fileManager.contents(atPath: rootPath + "/" + path) { hasher.update(data: data) }
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private final class SVModelInstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var didTimeOut = false

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > 64 * 1024 { buffer = buffer.suffix(32 * 1024) }
        }
    }

    var data: Data { lock.withLock { buffer } }

    var timedOut: Bool {
        get { lock.withLock { didTimeOut } }
        set { lock.withLock { didTimeOut = newValue } }
    }
}
#endif
