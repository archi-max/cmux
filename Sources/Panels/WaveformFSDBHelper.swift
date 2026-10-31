import CryptoKit
import Foundation

/// Runs cmux's FSDB helper (`Resources/vaporview/fsdb-helper`) on an SSH
/// workspace's host and relays the waveform viewer's requests to it.
///
/// Verdi's FSDB reader exists only on that host, so the dump is read there and
/// only the hierarchy and the value changes the viewer asks for cross the
/// connection. The reader addon links Verdi's proprietary libraries, so it is
/// built on the host, for its user, on first use (`build.sh`) and cached in
/// `~/.cache/cmux/fsdb-helper/<version>`, where `version` hashes the helper
/// files, so a cmux update with a changed helper rebuilds once.
///
/// One `ssh` (one helper process) runs per viewer. Requests are the page's
/// JSON objects; each gets an `id` and goes out as one line on the helper's
/// stdin. A reply is one JSON line, followed by `binLength` raw bytes when it
/// has that field.
final class WaveformFSDBHelper: @unchecked Sendable {
    /// Builds the `/usr/bin/ssh` arguments that run `remoteCommand` on the host.
    typealias SSHArguments = @Sendable (_ remoteCommand: String) -> [String]

    enum Status: Sendable {
        case connecting
        case building
    }

    enum Failure: Error, Sendable {
        /// `build.sh` failed with its exit code (see the script) and stderr tail.
        case setupFailed(code: Int32, detail: String)
        /// The helper or its `ssh` exited; carries its stderr tail.
        case helperExited(detail: String)
        case stopped
    }

    struct Reply: Sendable {
        let header: Data
        let binary: Data?
    }

    static let sshPath = "/usr/bin/ssh"
    /// Exit status of the launch command when this version is not installed.
    static let notInstalledStatus: Int32 = 87

    private let sshArguments: SSHArguments
    private let resourceRoot: URL
    private let version: String
    private let onStatus: @Sendable (Status) -> Void

    private let lock = NSLock()
    private var startTask: Task<Void, Error>?
    private var process: Process?
    private var input: FileHandle?
    private var isStopped = false
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var stderrTail = Data()
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.waveform-fsdb.write")

    init(
        sshArguments: @escaping SSHArguments,
        resourceRoot: URL,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.sshArguments = sshArguments
        self.resourceRoot = resourceRoot
        self.version = Self.version(of: resourceRoot)
        self.onStatus = onStatus
    }

    static func bundledResourceRoot(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("vaporview/fsdb-helper", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("build.sh").path) else {
            return nil
        }
        return url
    }

    // MARK: Requests

    /// Sends one request (a JSON object from the viewer) and waits for its reply.
    func request(_ body: Data) async throws -> Reply {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw Failure.helperExited(detail: "bad request")
        }
        try await ensureRunning()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isStopped, let input else {
                lock.unlock()
                continuation.resume(throwing: Failure.stopped)
                return
            }
            let id = nextRequestId
            nextRequestId += 1
            object["id"] = id
            guard var line = try? JSONSerialization.data(withJSONObject: object) else {
                lock.unlock()
                continuation.resume(throwing: Failure.helperExited(detail: "bad request"))
                return
            }
            pending[id] = continuation
            lock.unlock()
            line.append(0x0A)
            writeQueue.async { try? input.write(contentsOf: line) }
        }
    }

    /// Ends the helper (closing its stdin ends it on the host) and fails waiting requests.
    func stop() {
        lock.lock()
        isStopped = true
        let process = self.process
        self.process = nil
        try? input?.close()
        input = nil
        startTask?.cancel()
        let waiting = Array(pending.values)
        pending.removeAll()
        let ready = readyContinuation
        readyContinuation = nil
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
        waiting.forEach { $0.resume(throwing: Failure.stopped) }
        ready?.resume(throwing: Failure.stopped)
    }

    // MARK: Start, install

    private func ensureRunning() async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if isStopped { return nil }
            if let startTask { return startTask }
            let task = Task { try await self.start() }
            startTask = task
            return task
        }
        guard let task else { throw Failure.stopped }
        try await task.value
    }

    private func start() async throws {
        onStatus(.connecting)
        do {
            try await launch()
        } catch Failure.helperExited(let detail) where detail == Self.notInstalledMarker {
            onStatus(.building)
            try await install()
            onStatus(.connecting)
            try await launch()
        }
    }

    private static let notInstalledMarker = "\u{0}not-installed"

    private var installDirectory: String { "$HOME/.cache/cmux/fsdb-helper/\(version)" }

    /// Starts `fsdb-helper.sh` and waits for its ready line.
    private func launch() async throws {
        let script = "D=\"\(installDirectory)\"; [ -f \"$D/fsdb_reader.node\" ] || exit \(Self.notInstalledStatus); "
            + "exec bash \"$D/fsdb-helper.sh\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = sshArguments("sh -c '\(script)'")
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.appendStderr(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.helperDidExit(status: process.terminationStatus)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isStopped {
                lock.unlock()
                continuation.resume(throwing: Failure.stopped)
                return
            }
            readyContinuation = continuation
            stderrTail = Data()
            self.process = process
            // An early ssh exit surfaces as EPIPE on write instead of SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            self.input = stdin.fileHandleForWriting
            lock.unlock()
            do {
                try process.run()
            } catch {
                lock.lock()
                let ready = readyContinuation
                readyContinuation = nil
                self.process = nil
                lock.unlock()
                ready?.resume(throwing: Failure.helperExited(detail: error.localizedDescription))
                return
            }
            let reader = Thread { [weak self] in
                let handle = stdout.fileHandleForReading
                var parser = FrameParser()
                while true {
                    // availableData blocks until some output arrives; empty means EOF.
                    let chunk = handle.availableData
                    guard !chunk.isEmpty, let self else { return }
                    parser.append(chunk)
                    while let frame = parser.next() { self.dispatch(frame) }
                }
            }
            reader.name = "cmux FSDB helper reader"
            reader.start()
        }
    }

    /// Uploads the helper sources and runs `build.sh` on the host. Its stdin is
    /// a tar of the bundled folder, unpacked into a temporary directory there.
    private func install() async throws {
        let script = "S=$(mktemp -d \"${TMPDIR:-/tmp}/cmux-fsdb-src.XXXXXX\") && tar -xf - -C \"$S\" && "
            + "sh \"$S/build.sh\" \"$S\" \"\(installDirectory)\"; rc=$?; rm -rf \"$S\"; exit $rc"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--no-xattrs", "--no-mac-metadata", "--format", "ustar", "-cf", "-", "-C", resourceRoot.path, "."]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        tar.environment = environment
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: Self.sshPath)
        ssh.arguments = sshArguments("sh -c '\(script)'")
        let archive = Pipe(), stderr = Pipe()
        tar.standardOutput = archive
        tar.standardError = FileHandle.nullDevice
        ssh.standardInput = archive
        _ = fcntl(archive.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        ssh.standardOutput = FileHandle.nullDevice
        ssh.standardError = stderr

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            ssh.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do {
                try tar.run()
                try ssh.run()
            } catch {
                ssh.terminationHandler = nil
                if tar.isRunning { tar.terminate() }
                continuation.resume(throwing: Failure.setupFailed(code: -1, detail: error.localizedDescription))
            }
        }
        if tar.isRunning { tar.terminate() }
        let log = stderr.fileHandleForReading.readDataToEndOfFile()
        guard status == 0 else {
            throw Failure.setupFailed(code: status, detail: Self.tail(of: log))
        }
    }

    // MARK: Reading

    private func dispatch(_ frame: FrameParser.Frame) {
        lock.lock()
        if frame.id == 0 {
            // The ready line, or a startup error before it.
            let ready = readyContinuation
            readyContinuation = nil
            lock.unlock()
            if frame.isReady {
                ready?.resume()
            } else {
                ready?.resume(throwing: Failure.helperExited(detail: frame.errorText ?? ""))
            }
            return
        }
        let continuation = pending.removeValue(forKey: frame.id)
        lock.unlock()
        continuation?.resume(returning: Reply(header: frame.header, binary: frame.binary))
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 16 * 1024 { stderrTail = stderrTail.suffix(8 * 1024) }
        lock.unlock()
    }

    private func helperDidExit(status: Int32) {
        lock.lock()
        let detail = status == Self.notInstalledStatus ? Self.notInstalledMarker : Self.tail(of: stderrTail)
        process = nil
        input = nil
        let ready = readyContinuation
        readyContinuation = nil
        let waiting = Array(pending.values)
        pending.removeAll()
        // A helper that ran and then exited stays failed: the viewer reloads to retry.
        lock.unlock()
        ready?.resume(throwing: Failure.helperExited(detail: detail))
        waiting.forEach { $0.resume(throwing: Failure.helperExited(detail: detail)) }
    }

    /// The last few lines of a log, minus the remote shell's startup noise.
    static func tail(of data: Data, lines: Int = 12) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .joined(separator: "\n")
    }

    // MARK: Version

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

extension WaveformSchemeResponse {
    /// A helper reply for the page: the JSON line, or for signal data
    /// `[u32 LE header length][header JSON][deflated records]`.
    static func fsdb(_ reply: WaveformFSDBHelper.Reply) -> WaveformSchemeResponse {
        guard let binary = reply.binary else {
            return WaveformSchemeResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Content-Length": String(reply.header.count),
                "Cache-Control": "no-store",
            ], body: reply.header)
        }
        var body = Data(capacity: 4 + reply.header.count + binary.count)
        var length = UInt32(reply.header.count).littleEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(reply.header)
        body.append(binary)
        return WaveformSchemeResponse(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ], body: body)
    }

    static func fsdbError(_ message: String) -> WaveformSchemeResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
        return WaveformSchemeResponse(status: 200, headers: [
            "Content-Type": "application/json",
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ], body: body)
    }
}

/// Splits the helper's output into frames: a JSON line, then `binLength` bytes.
/// Lines that are not JSON objects (a remote shell's startup output) are skipped.
struct FrameParser {
    struct Frame {
        let id: Int
        let header: Data
        let binary: Data?
        let isReady: Bool
        let errorText: String?
    }

    private var buffer = Data()
    private var pendingHeader: (header: Data, id: Int, binLength: Int, isReady: Bool, errorText: String?)?

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() -> Frame? {
        while true {
            if let header = pendingHeader {
                guard buffer.count >= header.binLength else { return nil }
                let binary = header.binLength > 0 ? Data(buffer.prefix(header.binLength)) : nil
                buffer = Data(buffer.dropFirst(header.binLength))
                pendingHeader = nil
                return Frame(id: header.id, header: header.header, binary: binary,
                             isReady: header.isReady, errorText: header.errorText)
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            let binLength = (object["binLength"] as? NSNumber)?.intValue ?? 0
            pendingHeader = (line, id, max(0, binLength), object["ready"] as? Bool == true, object["error"] as? String)
        }
    }
}
