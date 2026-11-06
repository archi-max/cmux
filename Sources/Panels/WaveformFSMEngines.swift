import AppKit
import CmuxCore
import CmuxSyntaxHighlighting

/// The waveform viewer's state machine pane (cmux-fsm.js): Show State Machine on a row asks for
/// the row's machine (`requested`); this runs the engines in order (`FsmPipeline`) and shows
/// what the first one that could found.
/// - Verdi's FSM analysis, for an FSDB on an SSH host: `cmux-fsm-verdi.sh` runs there with the
///   user's own Verdi and licence. cmux ships nothing built against Verdi.
/// - Yosys's FSM extraction over the design slang-server has open, where its sources are: here,
///   or on the host through `cmux-fsm-yosys.sh`. The user's own Yosys (OSS CAD Suite's has
///   read_slang for full SystemVerilog).
/// - The dump alone: slang's enum members or localparams as the states, the dump's transitions.
@MainActor
enum WaveformFSMEngines {
    /// The answers so far and the engine runs, per waveform and dump path, until the waveform is
    /// opened or reloaded again (an answer computed across a reload is neither kept nor shown).
    private static var cache = FsmAnswerCache<[String: Any]>()
    /// A Yosys to use instead of looking for one (a hidden default; empty: look on PATH and in
    /// the usual OSS CAD Suite and Homebrew folders).
    static let yosysPathKey = "filePreview.waveform.fsm.yosysPath"

    private static func waveformKey(_ waveform: FilePreviewPanel) -> String { "\(ObjectIdentifier(waveform).hashValue)" }

    /// The waveform was opened or reloaded: its answers may be out of date. An open pane asks
    /// again itself (cmux-fsm.js, `refresh`).
    static func waveformOpened(_ waveform: FilePreviewPanel) {
        knownWaveforms.add(waveform)
        cache.opened(waveformKey(waveform))
    }

    /// A SystemVerilog design was opened or changed: answers are worked out again on the next Show
    /// (states may now be named, Yosys may now run).
    static func designChanged() {
        cache.designChanged()
    }

    /// Waveform viewers the pane answered or was opened for (to find a server's waveforms).
    private static let knownWaveforms = NSHashTable<FilePreviewPanel>.weakObjects()

    /// `session`'s design changed (a profile switch, a new top): only the answers of the
    /// waveforms linked to it are dropped; other roots' waveforms keep theirs (verify L4).
    static func designChanged(session: LanguageServerSession) {
        let waveforms = knownWaveforms.allObjects.filter { WaveformSourceLink.linkedSession(for: $0) === session }
        cache.designChanged(waveforms: waveforms.map(waveformKey))
    }

    /// The page's `fsmRequest`: the state machine of the register at dump path `value`.
    /// - refresh: the pane asks again after a reload; its graph stays up until the answer.
    static func requested(_ value: Any?, refresh: Bool = false, waveform: FilePreviewPanel) {
        guard let path = WaveformSourceLink.dumpPath(fromPage: value), let signal = path.last else { return }
        knownWaveforms.add(waveform)
        let waveformKey = waveformKey(waveform)
        let pathKey = HierarchyPathMapping.join(path)
        let page = waveform.nativeViewSessions.waveform
        if let answer = cache.answer(waveformKey, pathKey) {
            Task { @MainActor in _ = await page.callFsm("answer", argument: answer) }
            return
        }
        guard let ticket = cache.start(waveformKey, pathKey) else { return }
        Task { @MainActor in
            if !refresh {
                _ = await page.callFsm("answer", argument: [
                    "path": path,
                    "status": String(localized: "waveformFSM.looking", defaultValue: "Looking for the state machine…"),
                ] as [String: Any])
            }
            let dumpScope = Array(path.dropLast())
            let lookup = await WaveformSourceLink.designLookup(for: waveform)
            var context: SlangFsmContext?
            if let lookup, !dumpScope.isEmpty {
                let instance = lookup.mapping.designPath(forDumpPath: HierarchyPathMapping.join(dumpScope))
                context = try? await lookup.session.slangFsmContext(instance: instance, signal: signal)
            }
            let verdi = verdiEngine(waveform: waveform, scope: dumpScope.joined(separator: "."), signal: signal)
            let yosys = lookup.flatMap { yosysEngine(session: $0.session, waveform: waveform, signal: signal) }
            let result = await FsmPipeline.run(signal: signal, context: context, verdi: verdi, yosys: yosys)
            let answer: [String: Any] = [
                "path": path,
                "model": result.model.pageObject(),
                "note": note(for: result, hasDesign: lookup != nil),
            ]
            // Not kept: a transient failure. Kept with no design open too (a Verdi run is ~20 s and a
            // seat); opening or changing the design drops it (designChanged).
            guard cache.finish(ticket, answer, keep: !result.hasTransientFailure) else { return }
            _ = await page.callFsm("answer", argument: answer)
        }
    }

    // MARK: Engines

    /// Verdi for an FSDB on an SSH host: the script on standard input over the workspace's route.
    private static func verdiEngine(waveform: FilePreviewPanel, scope: String, signal: String) -> (@Sendable () async -> VerdiFsmEngine.Outcome)? {
        guard !scope.isEmpty, let remote = FilePreviewWaveformSession.RemoteFSDB.resolve(panel: waveform),
              let script = bundledScript("cmux-fsm-verdi.sh") else { return nil }
        let command = VerdiFsmEngine.remoteCommand(fsdb: remote.remotePath, scope: scope, signal: signal)
        let configuration = remote.configuration
        return {
            // A long-lived run (KDB load and the analysis take about 20 s for a
            // small design): its own connection, or a long-lived carrier session.
            let session: LongLivedSSHSession
            do { session = try await configuration.longLivedSession() } catch {
                return .unavailable(reason: "failed", detail: error.localizedDescription)
            }
            defer { session.release() }
            let arguments = configuration.batchSSHCommandArguments(command: command, effectiveSSHOptions: session.sshOptions)
            guard let result = try? await FsmProcess.run("/usr/bin/ssh", arguments, input: script, timeout: 900) else {
                return .unavailable(reason: "failed", detail: "ssh")
            }
            return VerdiFsmEngine.outcome(ofOutput: result.output)
        }
    }

    /// Yosys where slang-server's sources are: here for a local server, else over the workspace's route.
    private static func yosysEngine(session: LanguageServerSession, waveform: FilePreviewPanel, signal: String)
        -> (@Sendable (SlangFsmContext) async -> Result<[String: FsmModel], YosysFsm.Failure>)? {
        let configured = UserDefaults.standard.string(forKey: yosysPathKey) ?? ""
        if !session.launch.isRemote {
            guard let yosys = localYosys(configured) else { return nil }
            return { context in
                let slang = await YosysFsm.hasSlangFrontend(yosys: yosys)
                do {
                    return .success(try await YosysFsm.runLocally(
                        yosys: yosys, files: context.files, module: context.module, parameters: literalParameters(context),
                        signal: signal, force: true, slangFrontend: slang
                    ))
                } catch let failure as YosysFsm.Failure {
                    return .failure(failure)
                } catch {
                    return .failure(.failed(error.localizedDescription))
                }
            }
        }
        guard let configuration = sshConfiguration(waveform: waveform), let runner = bundledScript("cmux-fsm-yosys.sh") else { return nil }
        return { context in
            let script = { (slang: Bool) in
                YosysFsm.script(files: context.files, module: context.module, parameters: literalParameters(context),
                                signal: signal, force: true, slangFrontend: slang, output: "fsm.json")
            }
            let command = YosysFsm.remoteCommand(slangScript: script(true), nativeScript: script(false), yosys: configured)
            // A long-lived run: its own connection, or a long-lived carrier session.
            let session: LongLivedSSHSession
            do { session = try await configuration.longLivedSession() } catch {
                return .failure(.failed(error.localizedDescription))
            }
            defer { session.release() }
            let arguments = configuration.batchSSHCommandArguments(command: command, effectiveSSHOptions: session.sshOptions)
            guard let result = try? await FsmProcess.run("/usr/bin/ssh", arguments, input: runner, timeout: 600) else {
                return .failure(.failed("ssh"))
            }
            switch YosysFsm.remoteOutcome(ofOutput: result.output) {
            case .json(let text):
                let models = YosysFsm.models(json: Data(text.utf8))
                return models.isEmpty ? .failure(.notFound) : .success(models)
            case .unavailable(let reason, let detail):
                return reason == "no-yosys" ? .failure(.failed("")) : .failure(.failed(detail))
            }
        }
    }

    nonisolated private static func literalParameters(_ context: SlangFsmContext) -> [(name: String, value: String)] {
        context.parameters.map { (name: $0.name, value: $0.value) }
    }

    private static func localYosys(_ configured: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = (configured.isEmpty ? [] : [configured]) + [
            "\(home)/oss-cad-suite/bin/yosys", "/opt/oss-cad-suite/bin/yosys", "/opt/homebrew/bin/yosys", "/usr/local/bin/yosys",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The SSH configuration of the waveform's workspace, whose batch route the
    /// remote FSDB and language server use too.
    private static func sshConfiguration(waveform: FilePreviewPanel) -> WorkspaceRemoteConfiguration? {
        guard let configuration = AppDelegate.shared?.workspaceFor(tabId: waveform.workspaceId)?.remoteConfiguration,
              configuration.transport == .ssh else { return nil }
        return configuration
    }

    private static func bundledScript(_ name: String) -> Data? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("vaporview/fsm/\(name)") else { return nil }
        return FileManager.default.contents(atPath: url.path)
    }

    // MARK: Note

    /// Where the model came from, and why the engines before it gave nothing (when it's news:
    /// no Verdi or no Yosys installed is the usual case and says nothing).
    static func note(for result: FsmPipeline.Result, hasDesign: Bool) -> String {
        var parts: [String] = []
        switch result.model.engine {
        case .verdi:
            parts.append(String(localized: "waveformFSM.fromVerdi", defaultValue: "From Verdi's FSM analysis of the design."))
        case .yosys:
            parts.append(String(localized: "waveformFSM.fromYosys", defaultValue: "From Yosys's FSM extraction of the design."))
        case .observed:
            parts.append(String(localized: "waveformFSM.fromWaveform", defaultValue: "From the waveform: the transitions are the ones it takes."))
            if !hasDesign {
                parts.append(String(
                    localized: "waveformFSM.noDesign",
                    defaultValue: "Open a SystemVerilog file of this design to name the states and read the transitions from its source."
                ))
            }
        }
        for note in result.notes {
            switch note {
            case .verdi(let reason, let detail):
                switch reason {
                case "no-kdb":
                    parts.append(String(localized: "waveformFSM.verdi.noKdb", defaultValue: "Verdi: no VCS -kdb database found next to the waveform."))
                case "licence":
                    parts.append(String(localized: "waveformFSM.verdi.licence", defaultValue: "Verdi: no licence available."))
                case "no-fsm":
                    parts.append(String(localized: "waveformFSM.verdi.noFsm", defaultValue: "Verdi found no state machine for this signal."))
                case "failed":
                    let text = String(localized: "waveformFSM.verdi.failed", defaultValue: "Verdi failed: %@")
                    parts.append(String(format: text, detail))
                default:
                    break
                }
            case .yosys(.notFound):
                parts.append(String(localized: "waveformFSM.yosys.notFound", defaultValue: "Yosys found no state machine for this signal."))
            case .yosys(.failed(let detail)):
                guard !detail.isEmpty else { continue }
                let text = String(localized: "waveformFSM.yosys.failed", defaultValue: "Yosys failed: %@")
                parts.append(String(format: text, detail))
            }
        }
        return parts.joined(separator: " ")
    }
}
