import CmuxFoundation
import Darwin
import Foundation

/// Where a Go to File palette session lists files.
enum GoToFileSnapshotSource: Equatable, Sendable {
    case local(rootPath: String)
    case ssh(connection: SSHFileExplorerConnection, rootPath: String)

    var rootPath: String {
        switch self {
        case .local(let rootPath), .ssh(_, let rootPath): return rootPath
        }
    }
}

enum GoToFileSnapshotError: Error, Equatable, LocalizedError {
    case timedOut
    case folderNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return SSHFileSearchMessages.timedOut
        case .folderNotFound: return SSHFileSearchMessages.folderNotFound
        case .failed(let message): return message
        }
    }
}

/// Takes the one file-list snapshot a Go to File session ranks against.
///
/// Local and SSH roots run the same ``SSHFileSearchCommand/fileList(rootPath:maxDepth:remoteTimeoutSeconds:)``
/// script, locally under `/bin/sh` and remotely over the workspace's ssh
/// ControlPath. Cancelling the calling task terminates the child.
enum GoToFileSnapshotLoader {
    static let timeoutSeconds = 20
    /// Output beyond this many bytes stops the listing and marks it truncated.
    static let maxOutputBytes = 16 * 1024 * 1024

    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    static func invocation(
        for source: GoToFileSnapshotSource,
        sshArguments: (SSHFileExplorerConnection, String) -> [String] = ProcessSSHFileExplorerTransport.sshArguments
    ) -> Invocation {
        // The remote deadline sits just inside the local one so a slow host
        // reports a timeout status rather than a killed ssh.
        let command = SSHFileSearchCommand.fileList(
            rootPath: source.rootPath,
            maxDepth: GoToFileSnapshot.maxFindDepth,
            remoteTimeoutSeconds: max(1, timeoutSeconds - 2)
        ).command
        switch source {
        case .local:
            return Invocation(executable: "/bin/sh", arguments: ["-c", command])
        case .ssh(let connection, _):
            return Invocation(executable: "/usr/bin/ssh", arguments: sshArguments(connection, command))
        }
    }

    static func load(_ source: GoToFileSnapshotSource) async throws -> GoToFileSnapshot {
        try await load(invocation(for: source))
    }

    static func load(
        _ invocation: Invocation,
        timeoutSeconds: Int = GoToFileSnapshotLoader.timeoutSeconds,
        maxOutputBytes: Int = GoToFileSnapshotLoader.maxOutputBytes
    ) async throws -> GoToFileSnapshot {
        let run = SnapshotProcess(invocation: invocation, maxOutputBytes: maxOutputBytes)
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try run.run(timeoutSeconds: timeoutSeconds) })
                }
            }
        } onCancel: {
            run.terminate()
        }
        try Task.checkCancellation()
        if outcome.timedOut || outcome.status == SSHFileSearchCommand.remoteTimeoutStatus {
            throw GoToFileSnapshotError.timedOut
        }
        if outcome.hitByteCap {
            var snapshot = GoToFileSnapshot.parse(listOutput: outcome.stdout)
            // The last path may be cut mid-name.
            if !snapshot.paths.isEmpty { snapshot.paths.removeLast() }
            snapshot.isTruncated = true
            return snapshot
        }
        switch outcome.status {
        case 0:
            return GoToFileSnapshot.parse(listOutput: outcome.stdout)
        case SSHFileSearchCommand.missingRootStatus:
            throw GoToFileSnapshotError.folderNotFound
        default:
            // find exits 1 after unreadable directories but still lists the rest.
            let snapshot = GoToFileSnapshot.parse(listOutput: outcome.stdout)
            if outcome.status == 1, !snapshot.paths.isEmpty { return snapshot }
            let toolRan = outcome.stdout.starts(with: Data(SSHFileSearchCommand.gitListMarker.utf8))
                || outcome.stdout.starts(with: Data(SSHFileSearchCommand.findListMarker.utf8))
            throw GoToFileSnapshotError.failed(
                SSHRemoteStderr.diagnosis(outcome.stderr, toolRan: toolRan)
                    ?? SSHFileSearchMessages.exited(status: outcome.status)
            )
        }
    }

    private struct Outcome: Sendable {
        let stdout: Data
        let stderr: String
        let status: Int32
        let timedOut: Bool
        let hitByteCap: Bool
    }

    /// Written once by the stderr reader before it signals; read after the wait.
    private final class StderrBox: @unchecked Sendable {
        var data = Data()
    }

    /// Keeps the child reachable from the cancellation handler while the
    /// blocking reads run off Swift's cooperative executor.
    private final class SnapshotProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let maxOutputBytes: Int
        private let lock = NSLock()
        private var gate = ProcessTerminationGate()
        private var cancelled = false
        private var timedOut = false

        init(invocation: Invocation, maxOutputBytes: Int) {
            self.maxOutputBytes = maxOutputBytes
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run(timeoutSeconds: Int) throws -> Outcome {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            do {
                try process.run()
            } catch {
                lock.lock()
                gate.markFinished()
                lock.unlock()
                throw error
            }
            lock.lock()
            let terminateNow = gate.markLaunched() || cancelled
            lock.unlock()
            if terminateNow { process.terminate() }

            let deadline = DispatchWorkItem { [weak self] in self?.terminate(timedOut: true) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: deadline)
            defer { deadline.cancel() }

            // Drained concurrently so a chatty stderr can't block the listing.
            let stderrBox = StderrBox()
            let stderrHandle = errPipe.fileHandleForReading
            let stderrDone = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                stderrBox.data = stderrHandle.readDataToEndOfFileOrEmpty().suffix(8_192)
                stderrDone.signal()
            }

            var stdout = Data()
            var hitByteCap = false
            let descriptor = outPipe.fileHandleForReading.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                stdout.append(contentsOf: chunk[0..<count])
                if stdout.count > maxOutputBytes {
                    hitByteCap = true
                    terminate(timedOut: false, cancelling: false)
                    break
                }
            }
            process.waitUntilExit()
            stderrDone.wait()
            lock.lock()
            gate.markFinished()
            let wasCancelledAfterExit = cancelled
            let didTimeOut = timedOut
            lock.unlock()
            if wasCancelledAfterExit { throw CancellationError() }
            return Outcome(
                stdout: stdout,
                stderr: String(decoding: stderrBox.data, as: UTF8.self),
                status: process.terminationStatus,
                timedOut: didTimeOut,
                hitByteCap: hitByteCap
            )
        }

        func terminate() {
            terminate(timedOut: false, cancelling: true)
        }

        private func terminate(timedOut didTimeOut: Bool, cancelling: Bool = false) {
            lock.lock()
            if cancelling { cancelled = true }
            if didTimeOut { timedOut = true }
            let shouldTerminate = gate.requestTermination()
            lock.unlock()
            guard shouldTerminate, process.isRunning else { return }
            process.terminate()
        }
    }
}
