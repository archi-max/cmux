import Foundation

/// Keeps the last lines a child process wrote to stderr for error messages.
///
/// stderr is read on its own queue, so it can still be arriving when the exit is seen:
/// `waitForEnd(timeout:)` waits for its end of file before the text is read.
final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    private let limit: Int
    private var ended = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(limit: Int = 100) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        partial += String(decoding: data, as: UTF8.self)
        var pieces = partial.components(separatedBy: "\n")
        partial = pieces.removeLast()
        lines.append(contentsOf: pieces)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return (lines + (partial.isEmpty ? [] : [partial])).joined(separator: "\n")
    }

    /// stderr reached end of file (or the tool failed to launch).
    func finish() {
        lock.lock()
        ended = true
        let resumed = waiters.values
        waiters.removeAll()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    /// Returns once stderr has ended, or after `timeout` (a grandchild may keep it open).
    func waitForEnd(timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.end() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func end() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if ended || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }
}

/// A spawned language tool with piped stdio.
///
/// stdout arrives in order on `stdout`; the exit status is yielded once on
/// `exit`. Writes go through a serial queue so callers never block on a full
/// pipe, and SIGPIPE is suppressed on stdin so a dead child cannot kill the app.
final class LanguageToolProcess: @unchecked Sendable {
    let stdout: AsyncStream<Data>
    let exit: AsyncStream<Int32>
    let stderrTail = StderrTail()

    #if os(macOS)
    private let process: Process
    private let stdinHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "cmux.language-tool.stdin")

    private init(process: Process, stdinHandle: FileHandle, stdout: AsyncStream<Data>, exit: AsyncStream<Int32>) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.stdout = stdout
        self.exit = exit
    }
    #else
    private init(stdout: AsyncStream<Data>, exit: AsyncStream<Int32>) {
        self.stdout = stdout
        self.exit = exit
    }
    #endif

    /// Spawns the tool described by `launch`.
    static func spawn(_ launch: LanguageToolLaunch, currentDirectory: URL? = nil) throws -> LanguageToolProcess {
        #if os(macOS)
        let (executable, arguments) = launch.commandLine
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LanguageToolRegistry.searchDirectories.joined(separator: ":")
        process.environment = environment
        if let currentDirectory, !launch.isRemote,
           FileManager.default.fileExists(atPath: currentDirectory.path) {
            process.currentDirectoryURL = currentDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (stdoutStream, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (exitStream, exitContinuation) = AsyncStream<Int32>.makeStream()
        let tool = LanguageToolProcess(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdout: stdoutStream,
            exit: exitStream
        )

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
            } else {
                stdoutContinuation.yield(data)
            }
        }
        let tail = tool.stderrTail
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                tail.finish()
            } else {
                tail.append(data)
            }
        }
        process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            tool.stderrTail.finish()
            stdoutContinuation.finish()
            exitContinuation.finish()
            throw LanguageServerError.launchFailed("\(executable): \(error.localizedDescription)")
        }
        return tool
        #else
        throw LanguageServerError.unsupportedPlatform
        #endif
    }

    /// Queues `data` for stdin. Errors (child gone) are ignored; exit is reported via `exit`.
    func write(_ data: Data) {
        #if os(macOS)
        let handle = stdinHandle
        writeQueue.async {
            try? handle.write(contentsOf: data)
        }
        #endif
    }

    /// Closes stdin after all queued writes.
    func closeStdin() {
        #if os(macOS)
        let handle = stdinHandle
        writeQueue.async {
            try? handle.close()
        }
        #endif
    }

    var isRunning: Bool {
        #if os(macOS)
        return process.isRunning
        #else
        return false
        #endif
    }

    /// Sends SIGTERM.
    func terminate() {
        #if os(macOS)
        if process.isRunning { process.terminate() }
        #endif
    }

    /// Sends SIGKILL.
    func kill() {
        #if os(macOS)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        #endif
    }
}
