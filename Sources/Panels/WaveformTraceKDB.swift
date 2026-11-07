import CmuxSyntaxHighlighting
import Foundation
import os
import SwiftUI

nonisolated private let waveformTraceKDBLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformTraceKDB")

/// Driver tracing's KDB design model (status/tracex.md, T2): when a viewer opens an FSDB on an SSH
/// host with a KDB next to it (`<simv>.daidir` from `vcs -kdb`), cmux asks the host for the model
/// VCS elaborated (KDBModelLaunch: cmux's npi-model.sh and npi-model.py, run with the host's Verdi).
/// The host keeps each KDB's model in the user's cache, so only a new KDB holds a Verdi licence seat,
/// for its export only (seconds), in the background; without a KDB, Verdi or a seat there is no model
/// and tracing is slang's (one log line; the host doesn't try that KDB again until it changes).
/// The model's port aliases go to the viewer's FSDB helper (helper v2's aliasHints), so a port that
/// the dump only rebuilds is read from the net it is bound to.
///
/// Nothing of Verdi is shipped: the two scripts are cmux's own, sent to a private scratch folder.
@MainActor
enum WaveformTraceKDB {
    /// View > Trace with the Compiled Design (KDB): on by default; off, no export is asked for.
    static let enabledKey = "waveformTrace.kdbModel"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Slang's port aliases for a dump without a KDB model (off by default; a hidden setting).
    static let slangAliasesKey = "waveformTrace.slangAliases"
    static var slangAliasesEnabled: Bool { UserDefaults.standard.bool(forKey: slangAliasesKey) }

    /// Which KDBs are exported, and their models (KDBExportSchedule's rules).
    private static var schedule = KDBExportSchedule()
    /// The viewers waiting for each in-flight export's port aliases.
    private static var waiting: [String: NSHashTable<FilePreviewPanel>] = [:]
    /// Each KDB's viewers and host (Retry KDB Export asks again for them).
    private static var viewers: [String: NSHashTable<FilePreviewPanel>] = [:]
    private static var remotes: [String: FilePreviewWaveformSession.RemoteFSDB] = [:]
    /// KDBs whose next export asks the host to run a KDB marked `tried` again (CMUX_KDB_RETRY=1).
    private static var retrying: Set<String> = []
    /// Alias pairs sent at most per dump.
    nonisolated static let maxAliasPairs = 400_000
    /// An export that takes longer is ended (the launcher's own cap is 120 s; then the transfer).
    nonisolated static let exportTimeout: TimeInterval = 300

    static func bundledScripts(bundle: Bundle = .main) -> (launcher: Data, exporter: Data)? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("vaporview/verdi-trace", isDirectory: true) else { return nil }
        return KDBModelLaunch.scripts(in: dir)
    }

    private static func key(for waveform: FilePreviewPanel) -> (key: String, remote: FilePreviewWaveformSession.RemoteFSDB)? {
        guard let remote = FilePreviewWaveformSession.RemoteFSDB.resolve(panel: waveform) else { return nil }
        return (KDBExportSchedule.key(host: remote.host, dumpPath: remote.remotePath), remote)
    }

    /// The viewer opened (or reopened) its dump: its KDB's model is asked for in the background
    /// (the host's cache answers unless the KDB changed; one export per KDB at a time), and its
    /// port aliases go to the viewer's helper. The open and its traces never wait for it. An open
    /// while the export runs joins it, and the export runs once more when it ends (it may have
    /// read the KDB before the simulation that this open follows rewrote it).
    static func waveformOpened(_ waveform: FilePreviewPanel) {
        guard let (key, remote) = key(for: waveform) else { return }
        pruneClosed()
        let all = Self.viewers[key] ?? NSHashTable<FilePreviewPanel>.weakObjects()
        all.add(waveform)
        Self.viewers[key] = all
        remotes[key] = remote
        let viewers = waiting[key] ?? NSHashTable<FilePreviewPanel>.weakObjects()
        viewers.add(waveform)
        switch schedule.opened(key, enabled: isEnabled) {
        case .off:
            return
        case .join:
            waiting[key] = viewers
            return
        case .start:
            waiting[key] = viewers
            export(key: key, remote: remote)
        }
    }

    /// Drops the KDBs no viewer has open any more, unless an export of one is in flight or its
    /// failure is one Retry KDB Export may ask for again (their host is kept for that).
    private static func pruneClosed() {
        let failed = Set(schedule.failed)
        for (key, open) in viewers where open.allObjects.isEmpty && !schedule.pending(key) && !failed.contains(key) {
            viewers.removeValue(forKey: key)
            remotes.removeValue(forKey: key)
        }
    }

    /// View > Retry KDB Export: each KDB whose export failed this session (a seat denied, the time
    /// cap under load) is asked for again, with CMUX_KDB_RETRY=1 so the host runs it although it
    /// marked it `tried`; a new failure is logged again. Beeps when there is none.
    static func retryFailedExports() {
        let keys = schedule.failed.filter { remotes[$0] != nil }
        guard isEnabled, !keys.isEmpty else {
            NSSound.beep()
            return
        }
        for key in keys {
            guard let remote = remotes[key] else { continue }
            let decision = schedule.retry(key, enabled: true)
            if case .off = decision { return }
            retrying.insert(key)
            // The open viewers wait for the retried run (they saw the failure), whether it starts now
            // or is the run after the one in flight (.join), which asks with the retry.
            let open = viewers[key] ?? NSHashTable<FilePreviewPanel>.weakObjects()
            let waiters = waiting[key] ?? NSHashTable<FilePreviewPanel>.weakObjects()
            for viewer in open.allObjects { waiters.add(viewer) }
            waiting[key] = waiters
            if case .start = decision { export(key: key, remote: remote) }
        }
    }

    /// One export of the KDB `key`; run again while the schedule says it is still pending.
    private static func export(key: String, remote: FilePreviewWaveformSession.RemoteFSDB) {
        guard let scripts = bundledScripts() else {
            waiting.removeValue(forKey: key)
            _ = schedule.finished(key, .unavailable(code: "start", message: "no bundled scripts"))
            return
        }
        let command = KDBModelLaunch.command(launcher: scripts.launcher, exporter: scripts.exporter, fsdbPath: remote.remotePath,
                                             retry: retrying.remove(key) != nil)
        let arguments = remote.sshArguments("sh -c '\(command)'")
        Task { @MainActor in
            // The export and its alias pairs (a sort over every instance) off the main actor.
            let (outcome, pairs) = await Task.detached(priority: .utility) { () -> (KDBModelLaunch.Outcome, [[String]]) in
                let outcome = await Self.run(arguments: arguments)
                guard case .model(let model, _) = outcome else { return (outcome, []) }
                return (outcome, model.aliasPairs(limit: maxAliasPairs))
            }.value
            let line = schedule.finished(key, outcome)
            if schedule.pending(key) {
                // An open joined it: its answer is dropped, and the viewers wait for the next one.
                export(key: key, remote: remote)
                return
            }
            let viewers = waiting.removeValue(forKey: key)?.allObjects ?? []
            if let line {
                waveformTraceKDBLogger.info("\(line, privacy: .public)")
            }
            guard case .model(let model, let cached) = outcome else { return }
            waveformTraceKDBLogger.info("KDB model: \(model.instancePaths.count) instances, cached \(cached), \(pairs.count) alias pairs")
            // In calls of DesignAliasPairs.pageChunk (each call's JSON crosses the web view whole).
            for chunk in DesignAliasPairs.chunked(pairs) {
                for viewer in viewers {
                    _ = await viewer.nativeViewSessions.waveform.callTrace("aliasHints", argument: ["pairs": chunk])
                }
            }
        }
    }

    /// Whether the viewer's dump has a KDB export in flight: a trace now uses slang's design.
    static func pending(for waveform: FilePreviewPanel) -> Bool {
        guard isEnabled, let (key, _) = key(for: waveform) else { return false }
        return schedule.pending(key)
    }

    /// The dump's KDB model, when an export gave one; never waits (nil: none yet, or none to have).
    static func model(for waveform: FilePreviewPanel) -> KDBDesignModel? {
        guard isEnabled, let (key, _) = key(for: waveform) else { return nil }
        return schedule.model(key)
    }

    /// Runs the launch over ssh and reads its output; ended past `exportTimeout`. Ending it ends the
    /// local ssh only: the host's launcher runs on to its own time cap (CMUX_NPI_SECONDS, 120 s),
    /// the real bound on the seat.
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

/// View > Retry KDB Export: asks again for the KDBs whose export failed (WaveformTraceKDB.retryFailedExports).
struct WaveformTraceKDBRetryButton: View {
    var body: some View {
        Button(String(localized: "menu.view.waveformTraceKDBRetry", defaultValue: "Retry KDB Export")) {
            WaveformTraceKDB.retryFailedExports()
        }
    }
}

/// View > Trace with the Compiled Design (KDB): whether opening a remote dump asks its host for
/// the KDB's model (a Verdi seat for seconds, once per KDB).
struct WaveformTraceKDBToggle: View {
    @AppStorage(WaveformTraceKDB.enabledKey) private var enabled = true

    var body: some View {
        Toggle(String(localized: "menu.view.waveformTraceKDB", defaultValue: "Trace with the Compiled Design (KDB)"), isOn: $enabled)
    }
}
