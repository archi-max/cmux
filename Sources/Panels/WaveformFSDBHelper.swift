import CryptoKit
import Foundation

/// Runs cmux's FSDB helper (`Resources/vaporview/fsdb-helper`) on an SSH
/// workspace's host and relays the waveform viewer's requests to it.
///
/// Verdi's FSDB reader exists only on that host, so the dump is read there and
/// only the hierarchy and the value changes the viewer asks for cross the
/// connection. The reader addon links Verdi's proprietary libraries, so it is
/// built on the host, for its user, on first use (`build.sh`) and cached in
/// `~/.cache/cmux/fsdb-helper/<version>-<machine>`, where `version` hashes the
/// helper files, so a cmux update with a changed helper rebuilds once. An
/// install whose Node.js or Verdi has gone makes the launcher exit 87, the
/// same as a missing one, so it is rebuilt.
///
/// One `ssh` (one helper process) runs per viewer. Requests are the page's
/// JSON objects; each gets an `id` and goes out as one line on the helper's
/// stdin. A reply is one JSON line, followed by `binLength` raw bytes when it
/// has that field.
///
/// Two helpers exist. v1 (`fsdb-helper`) sends whole signals. v2
/// (`fsdb-helper-v2`, WINDOWING.md's protocol 2) also answers windows, point
/// and navigation queries, which the page's windowed viewer uses. The helper
/// tries its installs in order (v2, then v1). It falls back to v1 only when v2
/// is unavailable (see `start()`), and always says so (`Status.fellBack`, which
/// the page shows with a Retry); every reply names the protocol of the one
/// running (`protocolHeader`), so the page enables windowing only with v2.
/// The relay passes only the commands the page uses (`allowedCommands`), and an
/// `open` only of the panel's own file (`allowedFile`). For v2 it also:
/// - keeps a request pending through its `partial: true` lines, until the final reply;
/// - maps the page's request ids to its own, so the page's `cancel {id}` reaches
///   the helper's request (`cancel {id, target}`); a cancel that overtakes its
///   request (two POSTs race) cancels it when it arrives.
final class WaveformFSDBHelper: @unchecked Sendable {
    /// Builds the `/usr/bin/ssh` arguments that run `remoteCommand` on the host.
    typealias SSHArguments = @Sendable (_ remoteCommand: String) -> [String]

    enum Status: Sendable {
        case connecting
        case building
        /// v2 is unavailable (`detail` says why); the v1 helper (whole signals) runs
        /// instead. `remembered`: later viewers of this host skip v2 until
        /// `forgetV2Failure` (the page's Retry) or a changed helper.
        case fellBack(detail: String, remembered: Bool)
    }

    /// The `waveform.fsdbLoading` setting: `auto` windows big signals (v2 helper,
    /// v1 if v2 can't run), `whole` loads every signal whole (v1 helper only).
    enum Loading: String, Sendable {
        case auto
        case whole
    }

    /// One helper the host can run: its protocol and its bundled sources.
    struct Install: Sendable {
        let protocolVersion: Int
        let resourceRoot: URL

        var cacheName: String { protocolVersion >= 2 ? "fsdb-helper-v2" : "fsdb-helper" }
        /// Files an install has; without them the launcher exits `notInstalledStatus`.
        var requiredFiles: [String] {
            protocolVersion >= 2 ? ["addon/build/Release/fsdb_reader.node", "cmux-helper-v2.sh"] : ["fsdb_reader.node", "fsdb-helper.sh"]
        }
        /// The launcher, relative to the install, with its arguments.
        var launcher: String { protocolVersion >= 2 ? "cmux-helper-v2.sh\" --workers 4" : "fsdb-helper.sh\"" }
    }

    /// The installs to try, in order, for a setting.
    static func installs(v2Root: URL?, v1Root: URL?, loading: Loading) -> [Install] {
        var out: [Install] = []
        if loading == .auto, let v2Root { out.append(Install(protocolVersion: 2, resourceRoot: v2Root)) }
        if let v1Root { out.append(Install(protocolVersion: 1, resourceRoot: v1Root)) }
        return out
    }

    /// Response header naming the running helper's protocol (1 or 2).
    static let protocolHeader = "X-Cmux-Fsdb-Protocol"

    enum Failure: Error, Sendable {
        /// `build.sh` failed with its exit code (see the script) and stderr tail.
        case setupFailed(code: Int32, detail: String)
        /// `ssh` could not reach the host (exit 255 before the helper was ready).
        case connectionFailed(detail: String)
        /// The helper did not get ready, or the build did not finish, in time.
        case timedOut(detail: String)
        /// The helper or its `ssh` exited; carries its stderr tail.
        case helperExited(detail: String)
        /// The helper's output, or the page's request, could not be read.
        case protocolError
        case stopped
        /// The launcher found no usable install (exit 87). Handled by `start()`.
        case notInstalled
        /// The launcher refused an install others can write (exit 86); never run.
        case refused(detail: String)
        /// The page sent a command the relay does not pass, or an `open` of another file.
        case notAllowed(String)
    }

    struct Reply: Sendable {
        let header: Data
        let binary: Data?
    }

    static let sshPath = "/usr/bin/ssh"
    /// Exit status of the launch command when this version is not installed.
    static let notInstalledStatus: Int32 = 87
    /// Exit status of a launcher that refuses an install others can write.
    static let refusedStatus: Int32 = 86
    /// What the page sends: host.js (open, children, signals, valueAt) and the
    /// windowed viewer (window, valueAt, edge, search, count, cancel).
    static let pageCommands: Set<String> = ["open", "children", "signals", "valueAt", "window", "edge", "search", "count", "cancel"]
    /// Verdi's libraries load slowly from NFS on a busy host.
    static let defaultReadyTimeout: TimeInterval = 90
    static let installTimeout: TimeInterval = 10 * 60
    /// A reply that takes longer (Verdi stuck on an NFS read) fails its request.
    static let requestTimeout: TimeInterval = 5 * 60

    private let sshArguments: SSHArguments
    private let installs: [Install]
    private let executable: URL
    private let hostKey: String
    private let allowedCommands: Set<String>
    private let allowedFile: String?
    private let readyTimeout: TimeInterval
    private let onStatus: @Sendable (Status) -> Void

    private let lock = NSLock()
    private var startTask: Task<Void, Error>?
    private var process: Process?
    private var input: FileHandle?
    private var installProcesses: [Process] = []
    private var isStopped = false
    private var isReady = false
    private var generation = 0
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    /// The page's id of a pending request, both ways (v2 viewer requests carry one).
    private var helperIdForPage: [Int: Int] = [:]
    private var pageIdForHelper: [Int: Int] = [:]
    /// Page ids whose request has arrived (recent ones: the viewer numbers them up
    /// from 1), and ids cancelled before their request arrived, kept until it does.
    private var seenPageIds = Set<Int>()
    private var maxPageId = 0
    private var earlyCancels = Set<Int>()
    /// How far below the newest page id an unseen id is still taken for a request on its way.
    static let pageIdWindow = 4096
    /// The protocol of the helper that got ready (nil before).
    private var runningProtocol: Int?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var stderrTail = Data()
    /// The last `open` the page sent, replayed into a helper started after it
    /// (a retry after a timeout or a dropped connection) so that one has the file open too.
    private var lastOpen: [String: Any]?
    private var openGeneration = 0
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.waveform-fsdb.write")

    /// `executable` runs `sshArguments(command)`: `/usr/bin/ssh`, or a local shell in tests.
    /// `hostKey` names the host for the remembered v2 failures; `allowedFile`, if
    /// set, is the one file an `open` may name.
    init(
        sshArguments: @escaping SSHArguments,
        installs: [Install],
        executable: URL = URL(fileURLWithPath: WaveformFSDBHelper.sshPath),
        hostKey: String = "",
        allowedCommands: Set<String> = WaveformFSDBHelper.pageCommands,
        allowedFile: String? = nil,
        readyTimeout: TimeInterval = WaveformFSDBHelper.defaultReadyTimeout,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.sshArguments = sshArguments
        self.installs = installs
        self.executable = executable
        self.hostKey = hostKey
        self.allowedCommands = allowedCommands
        self.allowedFile = allowedFile
        self.readyTimeout = readyTimeout
        self.onStatus = onStatus
    }

    // MARK: Remembered v2 failures

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var v2Failures: [String: String] = [:]

    /// Per host and v2 helper version (a changed helper is tried afresh).
    private static func failureKey(host: String, install: Install) -> String {
        host + "\u{0}" + cachedVersion(of: install.resourceRoot)
    }

    /// Forgets the v2 failures remembered for a host (the page's Retry windowed).
    static func forgetV2Failure(hostKey: String) {
        failureLock.withLock { v2Failures = v2Failures.filter { !$0.key.hasPrefix(hostKey + "\u{0}") } }
    }

    /// The v1 helper only.
    convenience init(
        sshArguments: @escaping SSHArguments,
        resourceRoot: URL,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.init(sshArguments: sshArguments, installs: [Install(protocolVersion: 1, resourceRoot: resourceRoot)], onStatus: onStatus)
    }

    /// The bundled sources of a helper: `fsdb-helper` (v1) or `fsdb-helper-v2`.
    static func bundledResourceRoot(bundle: Bundle = .main, folder: String = "fsdb-helper") -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("vaporview/\(folder)", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("build.sh").path) else {
            return nil
        }
        return url
    }

    // MARK: Requests

    /// Answers one page request with the scheme response for it. Runs off the
    /// main actor: the reply is copied into the response body here.
    func response(
        for body: Data,
        failureMessage: @Sendable (Error) -> String
    ) async -> WaveformSchemeResponse {
        do {
            let reply = try await request(body)
            return WaveformSchemeResponse.fsdb(reply, protocolVersion: lock.withLock { runningProtocol })
        } catch {
            return WaveformSchemeResponse.fsdbError(failureMessage(error), protocolVersion: lock.withLock { runningProtocol })
        }
    }

    /// Sends one request (a JSON object from the viewer) and waits for its reply.
    func request(_ body: Data) async throws -> Reply {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Failure.protocolError
        }
        let command = object["cmd"] as? String ?? ""
        guard allowedCommands.contains(command) else { throw Failure.notAllowed(command) }
        if command == "open", let allowedFile, object["file"] as? String != allowedFile {
            throw Failure.notAllowed("open")
        }
        let pageId = (object["id"] as? NSNumber)?.intValue
        if command == "cancel" {
            return try await cancel(pageId: pageId)
        }
        try await ensureRunning()
        if command == "open" {
            lock.withLock { lastOpen = object }
            let reply = try await send(object)
            lock.withLock { openGeneration = generation }
            return reply
        }
        let reopen: [String: Any]? = lock.withLock {
            openGeneration == generation ? nil : lastOpen
        }
        if let reopen {
            _ = try await send(reopen)
            lock.withLock { openGeneration = generation }
        }
        return try await send(object, pageId: pageId)
    }

    /// The page's `cancel {id}`: cancels the helper's request for that page id.
    /// The id of a request that hasn't arrived yet (its POST is still on its
    /// way) is kept until it does, which then is cancelled at once; a finished
    /// one is ignored. Both answer `{cancelled: false}`.
    private func cancel(pageId: Int?) async throws -> Reply {
        let target: Int? = lock.withLock {
            guard let pageId else { return nil }
            if let helperId = helperIdForPage[pageId] { return helperId }
            if !seenPageIds.contains(pageId), pageId > maxPageId - Self.pageIdWindow { earlyCancels.insert(pageId) }
            return nil
        }
        guard let target else { return Self.jsonReply(["cancelled": false]) }
        // Replies under its own id; the target's reply becomes {id, cancelled: true}.
        return try await send(["cmd": "cancel", "target": target])
    }

    static func jsonReply(_ object: [String: Any]) -> Reply {
        Reply(header: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), binary: nil)
    }

    /// Records a page id whose request arrived. Call with `lock` held.
    private func notePageIdLocked(_ pageId: Int) {
        seenPageIds.insert(pageId)
        maxPageId = max(maxPageId, pageId)
        if seenPageIds.count > 2 * Self.pageIdWindow {
            let floor = maxPageId - Self.pageIdWindow
            seenPageIds = seenPageIds.filter { $0 > floor }
            earlyCancels = earlyCancels.filter { $0 > floor }
        }
    }

    /// Removes a pending request (and its page id). Call with `lock` held.
    private func takePendingLocked(_ id: Int) -> CheckedContinuation<Reply, Error>? {
        if let pageId = pageIdForHelper.removeValue(forKey: id) { helperIdForPage.removeValue(forKey: pageId) }
        return pending.removeValue(forKey: id)
    }

    private func send(_ request: [String: Any], pageId: Int? = nil) async throws -> Reply {
        var object = request
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isStopped, let input else {
                lock.unlock()
                continuation.resume(throwing: Failure.stopped)
                return
            }
            if let pageId {
                notePageIdLocked(pageId)
                if earlyCancels.remove(pageId) != nil {
                    lock.unlock()
                    continuation.resume(returning: Self.jsonReply(["id": pageId, "cancelled": true]))
                    return
                }
            }
            let id = nextRequestId
            nextRequestId += 1
            object["id"] = id
            guard var line = try? JSONSerialization.data(withJSONObject: object) else {
                lock.unlock()
                continuation.resume(throwing: Failure.protocolError)
                return
            }
            pending[id] = continuation
            if let pageId, helperIdForPage[pageId] == nil {
                helperIdForPage[pageId] = id
                pageIdForHelper[id] = pageId
            }
            line.append(0x0A)
            let message = line
            // Queued under the lock: a cancel that finds the mapping queues its line after this one.
            writeQueue.async { try? input.write(contentsOf: message) }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
                guard let self else { return }
                let waiting = self.lock.withLock { self.takePendingLocked(id) }
                guard let waiting else { return }
                waiting.resume(throwing: Failure.timedOut(detail: ""))
                // Stop the helper's work on it; the reply to this cancel finds nothing pending.
                if let cancel = try? JSONSerialization.data(withJSONObject: ["cmd": "cancel", "id": id]) {
                    self.writeQueue.async { try? input.write(contentsOf: cancel + Data([0x0A])) }
                }
            }
        }
    }

    /// Ends the helper (closing its stdin ends it on the host), any install in
    /// progress, and fails waiting requests.
    func stop() {
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
        helperIdForPage.removeAll()
        pageIdForHelper.removeAll()
        let ready = readyContinuation
        readyContinuation = nil
        lock.unlock()
        // Closed after any write already queued, never under one.
        writeQueue.async { try? input?.close() }
        if let process, process.isRunning { process.terminate() }
        installs.filter(\.isRunning).forEach { $0.terminate() }
        waiting.forEach { $0.resume(throwing: Failure.stopped) }
        ready?.resume(throwing: Failure.stopped)
    }

    // MARK: Start, install

    private func ensureRunning() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if isStopped { return nil }
            if let startTask { return startTask }
            let task = Task {
                do {
                    try await self.start()
                } catch {
                    self.startDidFail(error)
                    throw error
                }
            }
            startTask = task
            return task
        }
        guard let task else { throw Failure.stopped }
        try await task.value
    }

    /// A start that failed for a reason that may pass (the connection, a
    /// timeout) is retried by the next request; a setup failure stays until reload.
    /// (A helper that got ready and later exited is not: see helperDidExit.)
    private func startDidFail(_ error: Error) {
        switch error as? Failure {
        case .connectionFailed?, .timedOut?, .helperExited?:
            lock.withLock { startTask = nil }
        default:
            break
        }
    }

    /// Starts the first install that can run. v2 gives way to v1 (with
    /// `Status.fellBack`, never silently) when it is unavailable:
    /// - its build fails to compile or load (13, 14) or the built install still
    ///   can't run: remembered for this host and helper version;
    /// - it doesn't get ready in time: remembered too, so one wait per session;
    /// - it exits or reports an error before its ready line (perhaps passing:
    ///   out of memory, /tmp full): not remembered, the next viewer tries v2.
    /// Anything v1 would hit the same way (no Verdi, Node.js or compiler, a
    /// failed install, an unreachable host) or a refused install is an error.
    private func start() async throws {
        var candidates = installs
        if let v2 = candidates.first, v2.protocolVersion >= 2, candidates.count > 1 {
            let key = Self.failureKey(host: hostKey, install: v2)
            if let detail = Self.failureLock.withLock({ Self.v2Failures[key] }) {
                onStatus(.fellBack(detail: detail, remembered: true))
                candidates.removeFirst()
            }
        }
        var lastError: Error = Failure.setupFailed(code: -1, detail: "no FSDB helper is bundled")
        for (index, install) in candidates.enumerated() {
            do {
                try await start(install)
                lock.withLock { runningProtocol = install.protocolVersion }
                return
            } catch let failure as Failure {
                lastError = failure
                let isLast = index == candidates.count - 1
                guard install.protocolVersion >= 2, !isLast, let fallback = Self.fallback(for: failure) else { throw failure }
                if fallback.remember {
                    let key = Self.failureKey(host: hostKey, install: install)
                    Self.failureLock.withLock { Self.v2Failures[key] = fallback.detail }
                }
                onStatus(.fellBack(detail: fallback.detail, remembered: fallback.remember))
            }
        }
        throw lastError
    }

    /// Whether a v2 failure falls back to v1, with the reason and whether to remember it.
    static func fallback(for failure: Failure) -> (detail: String, remember: Bool)? {
        switch failure {
        case .setupFailed(let code, let detail) where code == 13 || code == 14 || code == notInstalledStatus:
            return (detail, true)
        case .timedOut(let detail):
            return (detail.isEmpty ? "timed out" : detail, true)
        case .helperExited(let detail):
            return (detail, false)
        default:
            return nil
        }
    }

    private func start(_ install: Install) async throws {
        let version = Self.cachedVersion(of: install.resourceRoot)
        // Per machine type too: an NFS home is shared by hosts that may differ.
        let installDirectory = "$HOME/.cache/cmux/\(install.cacheName)/\(version)-$(uname -m)"
        onStatus(.connecting)
        do {
            try await launch(install, installDirectory: installDirectory)
        } catch Failure.notInstalled {
            onStatus(.building)
            try await self.install(install, installDirectory: installDirectory)
            onStatus(.connecting)
            do {
                try await launch(install, installDirectory: installDirectory)
            } catch Failure.notInstalled {
                // Built, yet the launcher still finds it unusable.
                throw Failure.setupFailed(code: Self.notInstalledStatus, detail: lock.withLock { Self.tail(of: stderrTail) })
            }
        }
    }

    /// Starts the install's launcher and waits for its ready line.
    private func launch(_ install: Install, installDirectory: String) async throws {
        let checks = install.requiredFiles.map { "[ -f \"$D/\($0)\" ]" }.joined(separator: " && ")
        let script = "D=\"\(installDirectory)\"; \(checks) "
            + "|| exit \(Self.notInstalledStatus); exec bash \"$D/\(install.launcher)"
        let process = Process()
        process.executableURL = executable
        process.arguments = sshArguments("sh -c '\(script)'")
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
            self.appendStderr(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.helperDidExit(status: process.terminationStatus, generation: generation)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
            // An early ssh exit surfaces as EPIPE on write instead of SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            self.input = stdin.fileHandleForWriting
            lock.unlock()
            do {
                try process.run()
            } catch {
                failReady(Failure.helperExited(detail: error.localizedDescription), generation: generation)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.readyTimeout) { [weak self] in
                guard let self else { return }
                let tail = self.lock.withLock { Self.tail(of: self.stderrTail) }
                if self.failReady(Failure.timedOut(detail: tail), generation: generation), process.isRunning {
                    process.terminate()
                }
            }
            let reader = Thread { [weak self] in
                let handle = stdout.fileHandleForReading
                var parser = FrameParser()
                while true {
                    // availableData blocks until some output arrives; empty means EOF.
                    let chunk = handle.availableData
                    guard !chunk.isEmpty, let self else { return }
                    parser.append(chunk)
                    while let event = parser.next() {
                        guard self.handle(event, generation: generation) else {
                            // Unreadable output after the ready line: the stream
                            // can't be resynchronized, so end the helper.
                            if process.isRunning { process.terminate() }
                            return
                        }
                    }
                }
            }
            reader.name = "cmux FSDB helper reader"
            reader.start()
        }
    }

    /// Fails the wait for the ready line of launch `generation`, if it is
    /// still waiting. Returns whether it was.
    @discardableResult
    private func failReady(_ error: Error, generation: Int) -> Bool {
        let ready: CheckedContinuation<Void, Error>? = lock.withLock {
            guard generation == self.generation, let ready = readyContinuation else { return nil }
            readyContinuation = nil
            return ready
        }
        ready?.resume(throwing: error)
        return ready != nil
    }

    /// Uploads the helper sources and runs `build.sh` on the host. Its stdin is
    /// a tar of the bundled folder, unpacked into a temporary directory there.
    private func install(_ install: Install, installDirectory: String) async throws {
        let script = "S=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-fsdb-src.XXXXXX\") && tar -xf - -C \"$S\" && "
            + "sh \"$S/build.sh\" \"$S\" \"\(installDirectory)\"; rc=$?; rm -rf \"$S\"; exit $rc"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-xattrs", "--no-mac-metadata", "--format", "ustar", "-cf", "-", "-C", install.resourceRoot.path, "."]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        tar.environment = environment
        let ssh = Process()
        ssh.executableURL = executable
        ssh.arguments = sshArguments("sh -c '\(script)'")
        let archive = Pipe(), stderr = Pipe()
        tar.standardOutput = archive
        tar.standardError = FileHandle.nullDevice
        ssh.standardInput = archive
        _ = fcntl(archive.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        ssh.standardOutput = FileHandle.nullDevice
        ssh.standardError = stderr
        // Drained as it arrives, so a chatty build never blocks on a full pipe.
        let log = InstallLog()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            ssh.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            let stopped: Bool = lock.withLock {
                if isStopped { return true }
                installProcesses = [tar, ssh]
                return false
            }
            guard !stopped else {
                ssh.terminationHandler = nil
                continuation.resume(throwing: Failure.stopped)
                return
            }
            do {
                try tar.run()
                try ssh.run()
            } catch {
                ssh.terminationHandler = nil
                if tar.isRunning { tar.terminate() }
                continuation.resume(throwing: Failure.setupFailed(code: -1, detail: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.installTimeout) {
                if ssh.isRunning {
                    log.timedOut = true
                    ssh.terminate()
                }
            }
        }
        lock.withLock { installProcesses = [] }
        if tar.isRunning { tar.terminate() }
        // The handler may not have had the last lines yet; they are usually the useful ones.
        stderr.fileHandleForReading.readabilityHandler = nil
        log.append(stderr.fileHandleForReading.readDataToEndOfFile())
        if lock.withLock({ isStopped }) { throw Failure.stopped }
        let detail = Self.tail(of: log.data)
        if log.timedOut { throw Failure.timedOut(detail: detail) }
        if status == 255 { throw Failure.connectionFailed(detail: detail) }
        guard status == 0 else {
            throw Failure.setupFailed(code: status, detail: detail)
        }
    }

    // MARK: Reading

    /// Handles one parsed event. Returns false when the stream is unusable.
    private func handle(_ event: FrameParser.Event, generation: Int) -> Bool {
        switch event {
        case .frame(let frame):
            dispatch(frame, generation: generation)
            return true
        case .unreadableLine:
            // A remote shell's startup output may precede the ready line.
            return !lock.withLock { isReady }
        case .tooLarge:
            failReady(Failure.protocolError, generation: generation)
            return false
        }
    }

    private func dispatch(_ frame: FrameParser.Frame, generation: Int) {
        if frame.id == 0 {
            // The ready line, or a startup error before it.
            let ready: CheckedContinuation<Void, Error>? = lock.withLock {
                guard generation == self.generation else { return nil }
                if frame.isReady { isReady = true }
                let ready = readyContinuation
                readyContinuation = nil
                return ready
            }
            if frame.isReady {
                ready?.resume()
            } else {
                ready?.resume(throwing: Failure.helperExited(detail: frame.errorText ?? ""))
            }
            return
        }
        guard frame.id > 0 else { return }
        // searchAll's progress lines: the request stays pending until its final reply.
        if frame.isPartial { return }
        let continuation = lock.withLock { takePendingLocked(frame.id) }
        continuation?.resume(returning: Reply(header: frame.header, binary: frame.binary))
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrTail.append(data)
            if stderrTail.count > 16 * 1024 { stderrTail = stderrTail.suffix(8 * 1024) }
        }
    }

    private func helperDidExit(status: Int32, generation: Int) {
        let (ready, waiting, error): (CheckedContinuation<Void, Error>?, [CheckedContinuation<Reply, Error>], Failure)
            = lock.withLock {
                let detail = Self.tail(of: stderrTail)
                let error: Failure
                if status == Self.notInstalledStatus, !isReady {
                    error = .notInstalled
                } else if status == Self.refusedStatus, !isReady {
                    error = .refused(detail: detail)
                } else if status == 255, !isReady {
                    error = .connectionFailed(detail: detail)
                } else {
                    error = .helperExited(detail: detail)
                }
                guard generation == self.generation else { return (nil, [], error) }
                process = nil
                input = nil
                let ready = readyContinuation
                readyContinuation = nil
                let waiting = Array(pending.values)
                pending.removeAll()
                helperIdForPage.removeAll()
                pageIdForHelper.removeAll()
                // A helper that ran and then exited is not restarted: a new one
                // would have no file open, so the page reloads instead.
                return (ready, waiting, error)
            }
        ready?.resume(throwing: error)
        waiting.forEach { $0.resume(throwing: error) }
    }

    /// The last few lines of a log.
    static func tail(of data: Data, lines: Int = 12) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }

    // MARK: Version

    private static let versionLock = NSLock()
    nonisolated(unsafe) private static var versions: [String: String] = [:]

    /// `version(of:)`, hashed once per helper folder per run.
    static func cachedVersion(of root: URL) -> String {
        if let known = versionLock.withLock({ versions[root.path] }) { return known }
        let version = version(of: root)
        versionLock.withLock { versions[root.path] = version }
        return version
    }

    /// The first 16 hex digits of a SHA-256 over every helper file's relative
    /// path and contents, in path order.
    static func version(of root: URL) -> String {
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

/// The build's stderr, collected off the reading thread.
private final class InstallLog: @unchecked Sendable {
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

extension WaveformSchemeResponse {
    /// A helper reply for the page: the JSON line, or for signal data
    /// `[u32 LE header length][header JSON][deflated records]`.
    static func fsdb(_ reply: WaveformFSDBHelper.Reply, protocolVersion: Int? = nil) -> WaveformSchemeResponse {
        guard let binary = reply.binary else {
            return WaveformSchemeResponse(status: 200, headers: withProtocol([
                "Content-Type": "application/json",
                "Content-Length": String(reply.header.count),
                "Cache-Control": "no-store",
            ], protocolVersion), body: reply.header)
        }
        var body = Data(capacity: 4 + reply.header.count + binary.count)
        var length = UInt32(reply.header.count).littleEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(reply.header)
        body.append(binary)
        return WaveformSchemeResponse(status: 200, headers: withProtocol([
            "Content-Type": "application/octet-stream",
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ], protocolVersion), body: body)
    }

    static func fsdbError(_ message: String, protocolVersion: Int? = nil) -> WaveformSchemeResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
        return WaveformSchemeResponse(status: 200, headers: withProtocol([
            "Content-Type": "application/json",
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ], protocolVersion), body: body)
    }

    private static func withProtocol(_ headers: [String: String], _ protocolVersion: Int?) -> [String: String] {
        guard let protocolVersion else { return headers }
        var out = headers
        out[WaveformFSDBHelper.protocolHeader] = String(protocolVersion)
        return out
    }
}

/// Splits the helper's output into frames: a JSON line, then `binLength` bytes.
///
/// Scans each byte once: `scanned` remembers how far the search for the next
/// newline got, and consumed bytes are dropped only once they are most of the
/// buffer. A line is read from its first `{`, so a shell's startup output with
/// no newline (a title escape) in front of the ready line doesn't hide it.
struct FrameParser {
    /// Largest `binLength` accepted; a corrupt header must not make the reader buffer forever.
    static let maxBinaryLength = 1 << 30

    struct Frame {
        let id: Int
        let header: Data
        let binary: Data?
        let isReady: Bool
        let errorText: String?
        /// A `partial: true` line (searchAll progress): not the request's reply.
        var isPartial = false
    }

    enum Event {
        case frame(Frame)
        /// A line that is not a protocol object.
        case unreadableLine
        /// A header announced more binary than `maxBinaryLength`.
        case tooLarge
    }

    private var buffer = Data()
    /// Offset of the first byte not yet consumed.
    private var start = 0
    /// Offset up to which the current line has been searched for a newline.
    private var scanned = 0
    private var pendingHeader: (header: Data, id: Int, binLength: Int, isReady: Bool, errorText: String?, isPartial: Bool)?

    mutating func append(_ data: Data) {
        if start > 0, start >= buffer.count / 2 {
            buffer = buffer.subdata(in: buffer.startIndex + start..<buffer.endIndex)
            scanned -= start
            start = 0
        }
        buffer.append(data)
    }

    mutating func next() -> Event? {
        let base = buffer.startIndex
        if let header = pendingHeader {
            guard buffer.count - start >= header.binLength else { return nil }
            let binary = header.binLength > 0
                ? buffer.subdata(in: base + start..<base + start + header.binLength)
                : nil
            start += header.binLength
            scanned = start
            pendingHeader = nil
            return .frame(Frame(id: header.id, header: header.header, binary: binary,
                                isReady: header.isReady, errorText: header.errorText, isPartial: header.isPartial))
        }
        guard let newline = buffer[(base + max(scanned, start))...].firstIndex(of: 0x0A) else {
            scanned = buffer.count
            return nil
        }
        var lineStart = base + start
        start = newline - base + 1
        scanned = start
        if let brace = buffer[lineStart..<newline].firstIndex(of: UInt8(ascii: "{")) { lineStart = brace }
        let line = buffer.subdata(in: lineStart..<newline)
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = (object["id"] as? NSNumber)?.intValue else { return .unreadableLine }
        let binLength = (object["binLength"] as? NSNumber)?.intValue ?? 0
        guard binLength >= 0, binLength <= Self.maxBinaryLength else { return .tooLarge }
        pendingHeader = (line, id, binLength, object["ready"] as? Bool == true, object["error"] as? String, object["partial"] as? Bool == true)
        return next()
    }
}
