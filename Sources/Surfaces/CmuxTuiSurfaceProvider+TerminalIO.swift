import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    nonisolated static let defaultWaitTimeoutMs = 30_000
    nonisolated static let maxWaitTimeoutMs = 3_600_000

    nonisolated static func clampedWaitTimeoutMs(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultWaitTimeoutMs }
        return min(requested, maxWaitTimeoutMs)
    }
}

/// Two more headless terminal primitives over the machine's link, beside `readScreen`
/// and `waitForScreen`: the process's EXIT (a fact the daemon records) and its retained
/// OUTPUT (the whole log, not the visible rows). Together they turn "run this to
/// completion and give me the result" into `wait-exit` + `output` instead of a prompt
/// regex and a screenful of text.
extension CmuxTuiSurfaceProvider {
    /// Returns the cwd of the process group currently owning the remote PTY.
    /// This is deliberately a live process query: the snapshot's `cwd` is the
    /// terminal's spawn directory and remains stale after a remote `cd`.
    func currentWorkingDirectory(of resource: SurfaceResource) async -> String? {
        guard resource.kind == .terminal else { return nil }
        do {
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { return nil }
            let data = try await link.run(
                arguments: CloudTuiRequests.processInfoArguments(
                    socketPath: connected.socketPath,
                    terminalID: resource.id.key
                )
            )
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return CloudTuiCommandLine.foregroundWorkingDirectory(fromProcessInfo: result)
        } catch {
            // Directory inheritance is best effort. A daemon without the process
            // query capability must retain the existing workspace fallback.
            return nil
        }
    }

    /// The Files fallback's query (`CloudTerminalDirectoryFallback`). It uses only a link
    /// that is already connected: `links.connected` can wait minutes for a reconnect,
    /// past the probe's 3 s bound, or start one, and a probe must do neither. No
    /// connected link answers `.skipped`, so the next graph event asks again.
    func foregroundDirectoryAnswer(of resource: SurfaceResource) async -> CloudTerminalDirectoryFallback.Answer {
        guard resource.kind == .terminal,
              let link = await links.link(machineID: machineID),
              await link.isConnected,
              let connected = await link.connected else { return .skipped }
        do {
            let data = try await link.run(
                arguments: CloudTuiRequests.processInfoArguments(
                    socketPath: connected.socketPath,
                    terminalID: resource.id.key
                )
            )
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed }
            return CloudTerminalDirectoryFallback.Answer(
                foregroundDirectory: CloudTuiCommandLine.foregroundWorkingDirectory(fromProcessInfo: result),
                foregroundExecutable: CloudTuiCommandLine.foregroundExecutable(fromProcessInfo: result)
            )
        } catch {
            return Task.isCancelled ? .skipped : .failed
        }
    }

    /// Block until the remote terminal's process exits or `timeoutMs` elapses (the same
    /// clamp as `waitForScreen`: nil/non-positive → 30 s, at most an hour). The daemon's
    /// answer: `{state: "exited", terminal_id, lifecycle, outcome: {kind: exit, code} |
    /// {kind: signal, signal, core_dumped} | {kind: unknown, reason}, exited_at}` or
    /// `{state: "pending", terminal_id, lifecycle, …}`.
    func waitForExit(terminalID: String, timeoutMs: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let effectiveMs = Self.clampedWaitTimeoutMs(timeoutMs)
        let linkTimeout = Duration.milliseconds(effectiveMs + 5_000)
        let data = try await link.run(
            arguments: CloudTuiRequests.processWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, timeoutMs: effectiveMs),
            timeout: linkTimeout
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The remote terminal's retained output from `after` (a `next_offset` the daemon
    /// handed back earlier; nil = the earliest byte still kept), at most `maxBytes` of raw
    /// stream per call (nil = the daemon's 256 KiB window): `{text, start_offset,
    /// next_offset, complete}`. `complete == false` means "call again with next_offset".
    func readOutput(terminalID: String, after: Int?, maxBytes: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(
            arguments: CloudTuiRequests.outputReadArguments(socketPath: connected.socketPath, terminalID: terminalID, after: after, maxBytes: maxBytes)
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
