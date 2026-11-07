import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let waveformTraceKDBLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformTraceKDB")

/// Driver tracing's KDB design model (status/tracex.md, T2): when a viewer opens an FSDB on an SSH
/// host with a KDB next to it (`<simv>.daidir` from `vcs -kdb`), cmux asks the host for the model
/// VCS elaborated (KDBModelLaunch: cmux's npi-model.sh and npi-model.py, run with the host's Verdi).
/// The host keeps each KDB's model in the user's cache, so only a new KDB holds a Verdi licence seat,
/// for its export only (seconds); without a KDB, Verdi or a seat there is no model and nothing changes.
/// The model's port aliases go to the viewer's FSDB helper (helper v2's aliasHints), so a port that
/// the dump only rebuilds is read from the net it is bound to.
///
/// Nothing of Verdi is shipped: the two scripts are cmux's own, sent to a private scratch folder.
@MainActor
enum WaveformTraceKDB {
    /// Each dump's latest export (`host|path`), least recently opened first.
    private static var exports: [String: Task<KDBModelLaunch.Outcome, Never>] = [:]
    private static var order = VerdiTraceLaunch.SessionKeys()
    /// Models kept at most (each is the whole design's instances and signals).
    private static let maxModels = 4
    /// Alias pairs sent at most per dump.
    static let maxAliasPairs = 400_000
    /// An export that takes longer is ended (the launcher's own cap is 120 s; then the transfer).
    nonisolated static let exportTimeout: TimeInterval = 300

    static func bundledScripts(bundle: Bundle = .main) -> (launcher: Data, exporter: Data)? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("vaporview/verdi-trace", isDirectory: true) else { return nil }
        return KDBModelLaunch.scripts(in: dir)
    }

    /// The viewer opened (or reopened) its dump: the dump's model is asked for again (the host's
    /// cache answers unless the KDB changed), and its port aliases go to the viewer's helper.
    static func waveformOpened(_ waveform: FilePreviewPanel) {
        guard let remote = FilePreviewWaveformSession.RemoteFSDB.resolve(panel: waveform),
              let scripts = bundledScripts() else { return }
        let key = remote.host + "|" + remote.remotePath
        let command = KDBModelLaunch.command(launcher: scripts.launcher, exporter: scripts.exporter, fsdbPath: remote.remotePath)
        let arguments = remote.sshArguments("sh -c '\(command)'")
        let export = Task.detached(priority: .utility) { await Self.run(arguments: arguments) }
        exports[key] = export
        order.use(key)
        for gone in order.evict(keeping: maxModels) { exports.removeValue(forKey: gone)?.cancel() }
        Task { @MainActor [weak waveform] in
            let outcome = await export.value
            switch outcome {
            case .model(let model, let cached):
                let pairs = model.aliasPairs(limit: maxAliasPairs)
                waveformTraceKDBLogger.info("KDB model: \(model.instancePaths.count) instances, cached \(cached), \(pairs.count) alias pairs")
                guard !pairs.isEmpty, let waveform, exports[key] == export else { return }
                _ = await waveform.nativeViewSessions.waveform.callTrace("aliasHints", argument: ["pairs": pairs])
            case .unavailable(let code, _):
                waveformTraceKDBLogger.info("KDB model unavailable: \(code, privacy: .public)")
            }
        }
    }

    /// The dump's model, when its latest export gave one (nil: none yet, or none to have).
    static func model(for waveform: FilePreviewPanel) async -> KDBDesignModel? {
        guard let remote = FilePreviewWaveformSession.RemoteFSDB.resolve(panel: waveform),
              let export = exports[remote.host + "|" + remote.remotePath] else { return nil }
        if case .model(let model, _) = await export.value { return model }
        return nil
    }

    /// Runs the launch over ssh and reads its output; ended past `exportTimeout`.
    nonisolated private static func run(arguments: [String]) async -> KDBModelLaunch.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .unavailable(code: "start", message: error.localizedDescription)
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + exportTimeout, execute: timer)
        let output: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Read to the end first (a model of many MB fills the pipe), then reap.
                let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
        timer.cancel()
        if Task.isCancelled { return .unavailable(code: "start", message: "") }
        return KDBModelLaunch.parse(output: output)
    }
}
