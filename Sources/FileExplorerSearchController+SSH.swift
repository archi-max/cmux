import Darwin
import Foundation

/// Accumulates one SSH search's streamed output off the main actor.
actor SSHFileSearchOutputPipeline {
    private var accumulator: SSHFileSearchAccumulator

    init(rootPath: String, query: String, maxResults: Int, snapshotInterval: TimeInterval) {
        accumulator = SSHFileSearchAccumulator(
            rootPath: rootPath,
            query: query,
            maxResults: maxResults,
            snapshotInterval: snapshotInterval
        )
    }

    func consumeStdout(_ data: Data) -> FileSearchPipelineUpdate? {
        accumulator.consume(data)
    }

    func consumeStderr(_ data: Data) {
        accumulator.consumeStderr(data)
    }

    func markTimedOut() {
        accumulator.markTimedOut()
    }

    func finish(status: Int32) -> FileSearchPipelineUpdate {
        accumulator.finish(status: status)
    }
}

@MainActor
extension FileSearchController {
    /// Local deadline for one SSH search; the remote `timeout` fires a little earlier.
    static let sshSearchTimeoutSeconds = 30

    /// Runs Find in Files on an SSH workspace's host and streams matches like the local search.
    ///
    /// The search reuses the Files panel's ssh options (its ControlPath master),
    /// is cancelled by a newer query through the generation guard and
    /// ``stopAndAdvanceGeneration()`` (which terminates the ssh child), stops at
    /// ``maxResults`` with a `.limited` note, and fails after
    /// ``sshSearchTimeoutSeconds``.
    func startSSHSearch(provider: SSHFileExplorerProvider, query: String, rootPath: String) {
        guard provider.isAvailable else {
            emit(
                status: .failed(String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")),
                isSearching: false
            )
            return
        }
        generation += 1
        let searchGeneration = generation
        emit(status: .searching, isSearching: true)

        let timeoutSeconds = Self.sshSearchTimeoutSeconds
        let command = SSHFileSearchCommand.contentSearch(
            query: query,
            rootPath: rootPath,
            remoteTimeoutSeconds: max(1, timeoutSeconds - 3)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ProcessSSHFileExplorerTransport.sshArguments(
            connection: provider.connection,
            command: command.command
        )
        // ssh must never read the app's stdin.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let pipeline = SSHFileSearchOutputPipeline(
            rootPath: rootPath,
            query: query,
            maxResults: maxResults,
            snapshotInterval: snapshotInterval
        )
        let terminationSignal = FileSearchTerminationSignal()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationSignal.complete(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            process.standardOutput = nil
            process.standardError = nil
            emit(status: .failed(error.localizedDescription), isSearching: false)
            return
        }
        self.process = process
        let stdoutReadHandle = FileSearchReadHandle(stdout.fileHandleForReading)
        let stderrReadHandle = FileSearchReadHandle(stderr.fileHandleForReading)
        searchTask = Task.detached(priority: .userInitiated) { [weak self, pipeline, terminationSignal, stdoutReadHandle, stderrReadHandle] in
            let stderrTask = Task.detached(priority: .utility) { [stderrReadHandle, pipeline] in
                await Self.streamSSHStderr(from: stderrReadHandle, pipeline: pipeline)
            }
            let applyUpdate: @Sendable (FileSearchPipelineUpdate, Int) async -> Void = { [weak self] update, generation in
                await self?.applyPipelineUpdate(update, generation: generation)
            }
            let stdoutTask = Task.detached(priority: .userInitiated) { [stdoutReadHandle, pipeline, searchGeneration, applyUpdate] in
                await Self.streamSSHStdout(
                    from: stdoutReadHandle,
                    pipeline: pipeline,
                    generation: searchGeneration,
                    applyUpdate: applyUpdate
                )
            }
            let deadlineTask = Task.detached(priority: .utility) { [weak self, pipeline, searchGeneration] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await pipeline.markTimedOut()
                await self?.terminateSSHSearchProcess(generation: searchGeneration)
            }
            defer {
                deadlineTask.cancel()
                stderrTask.cancel()
                stdoutTask.cancel()
            }
            guard let status = await terminationSignal.wait() else { return }
            deadlineTask.cancel()
            await stdoutTask.value
            guard !Task.isCancelled else { return }
            if status != 0 && status != 1 {
                await stderrTask.value
            }
            let update = await pipeline.finish(status: status)
            await self?.finish(generation: searchGeneration, update: update)
        }
    }

    /// Ends a timed-out search's ssh child; its exit then reports the timeout.
    private func terminateSSHSearchProcess(generation searchGeneration: Int) {
        guard searchGeneration == generation, let process, process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
    }

    private nonisolated static func streamSSHStdout(
        from readHandle: FileSearchReadHandle,
        pipeline: SSHFileSearchOutputPipeline,
        generation: Int,
        applyUpdate: @Sendable (FileSearchPipelineUpdate, Int) async -> Void
    ) async {
        while !Task.isCancelled {
            let readResult = await FileSearchPipeReader.read(from: readHandle, maxByteCount: 32 * 1024)
            guard !Task.isCancelled else { return }
            switch readResult {
            case .chunk(let data):
                guard let update = await pipeline.consumeStdout(data) else { continue }
                await applyUpdate(update, generation)
                if update.shouldStopProcess { return }
            case .endOfFile:
                return
            case .failure(let errorNumber) where errorNumber == EINTR:
                continue
            case .failure(let errorNumber):
                await pipeline.consumeStderr(Data(String(cString: strerror(errorNumber)).utf8))
                return
            }
        }
    }

    private nonisolated static func streamSSHStderr(
        from readHandle: FileSearchReadHandle,
        pipeline: SSHFileSearchOutputPipeline
    ) async {
        while !Task.isCancelled {
            let readResult = await FileSearchPipeReader.read(from: readHandle, maxByteCount: 8 * 1024)
            guard !Task.isCancelled else { return }
            switch readResult {
            case .chunk(let data):
                await pipeline.consumeStderr(data)
            case .endOfFile:
                return
            case .failure(let errorNumber) where errorNumber == EINTR:
                continue
            case .failure(let errorNumber):
                await pipeline.consumeStderr(Data(String(cString: strerror(errorNumber)).utf8))
                return
            }
        }
    }
}
