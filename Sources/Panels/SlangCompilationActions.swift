import AppKit
import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let slangCompilationLogger = Logger(subsystem: "com.cmuxterm.app", category: "SlangCompilation")

/// The SystemVerilog editor's and Files explorer's right-click actions that
/// choose what slang-server compiles: Set as SystemVerilog Top Level (on a
/// `module`), Use as SystemVerilog Build File (on a `.f` file), and their undo.
///
/// Both go through the pooled `LanguageServerSession` the folder's editors
/// share (`slang.setTopLevel` / `slang.setBuildFile`). A server that does not
/// advertise `slang.setBuildFile` gets `"build"` in the workspace's
/// `.slang/local/server.json` instead (after the user confirms the exact
/// path), and is restarted to read it. One change per server at a time.
@MainActor
enum SlangCompilationActions {
    private static let languageId = "verilog"
    private static let diagnosticsSettleDelay: Duration = .milliseconds(400)

    /// What cmux set a session to compile, for the menus (the session's own record is async).
    final class Entry {
        weak var session: LanguageServerSession?
        var target: SlangCompilationTarget?
        /// The config file cmux wrote `"build"` into instead of the runtime command.
        var configFile: ConfigFileEdit?
        /// Workspaces whose Files explorer chose the build file, so Clear Build File finds the
        /// server after its editors closed.
        var workspaceIds: Set<UUID> = []
        /// The user chose Explore Mode (No Top): nothing is compiled, not even the config's build.
        var isExplore = false
        /// The design's top instances as last read (nil: not read yet), for the editor's slang header.
        var tops: [String]?
        /// The profile the waveform link picked by itself, what it replaced, and when (for Undo).
        var autoPick: AutoPick?
        /// The user undid an auto-pick: the link doesn't pick for this server again.
        var autoPickDeclined = false

        init(session: LanguageServerSession) {
            self.session = session
        }
    }

    /// A profile the waveform link chose by itself (offered for Undo in the header).
    struct AutoPick {
        let profile: String
        let picked: SlangCompilationTarget?
        let previous: CompilationState
        let at: Date
    }

    struct ConfigFileLocation {
        let path: String
        /// Set for a workspace on an SSH host.
        let sshProvider: SSHFileExplorerProvider?
    }

    /// A `"build"` cmux wrote, and the value it replaced (put back by Clear Build File).
    struct ConfigFileEdit {
        let location: ConfigFileLocation
        let previousBuild: String?
    }

    private static var entries: [Entry] = []
    /// Sessions with a top level or build change in flight.
    private static var busySessions: Set<ObjectIdentifier> = []

    static func entry(for session: LanguageServerSession) -> Entry {
        entries.removeAll { $0.session == nil }
        if let entry = entries.first(where: { $0.session === session }) { return entry }
        let entry = Entry(session: session)
        entries.append(entry)
        return entry
    }

    static func target(of session: LanguageServerSession) -> SlangCompilationTarget? {
        entries.first { $0.session === session }?.target
    }

    /// Records a top level or build file set elsewhere (the waveform link's elaboration).
    static func recordTarget(_ target: SlangCompilationTarget?, for session: LanguageServerSession) {
        entry(for: session).target = target
    }

    /// Whether a top level or build change is running on `session`; the link waits its turn.
    static func isBusy(_ session: LanguageServerSession) -> Bool {
        busySessions.contains(ObjectIdentifier(session))
    }

    static func claim(_ sessions: [LanguageServerSession]) -> Bool {
        guard !sessions.contains(where: isBusy) else { return false }
        for session in sessions { busySessions.insert(ObjectIdentifier(session)) }
        return true
    }

    static func release(_ sessions: [LanguageServerSession]) {
        for session in sessions { busySessions.remove(ObjectIdentifier(session)) }
    }

    typealias CompilationState = LanguageServerSession.SlangCompilationState

    /// Puts `session` back to what it compiled before `previous`'s replacement failed:
    /// the config's build (by a restart that drops the runtime choice), a top level or
    /// build file, or explore mode (chosen again, so it outlives a restart).
    static func restore(_ previous: CompilationState, on session: LanguageServerSession) async {
        if previous.target == nil, !previous.isExplore, entry(for: session).configFile != nil {
            try? await session.restart(keepingCompilation: false)
            return
        }
        try? await session.slangRestore(previous)
    }

    /// What the session compiles as far as cmux knows: the mirror, else the session's own record.
    static func currentState(of session: LanguageServerSession) async -> CompilationState {
        var state = await session.slangCompilationState
        if let target = target(of: session) {
            state.target = target
            state.isExplore = false
        }
        return state
    }

    // MARK: Top level

    /// Elaborates the design with the file of `module` (the editor's document) as the top level.
    static func setTopLevel(module: String, editor: FilePreviewLanguageFeatures, anchor: Int) {
        guard let (session, documentURI) = editor.linkSession, claim([session]) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { release([session]) }
            // The server must see the current text.
            await editor.sendCurrentText()
            editor.showLinkMessage(String(
                format: String(
                    localized: "slangTop.progress.topLevel",
                    defaultValue: "Elaborating the design with %@ as the top level…"
                ),
                module
            ), at: anchor, isProgress: true)
            _ = await session.takeRecentErrorMessages()
            let previous = await currentState(of: session)
            let outcome: Outcome
            do {
                try await session.slangSetTopLevel(session.serverPath(for: documentURI))
                outcome = await Self.outcome(of: session)
            } catch {
                slangCompilationLogger.error("setTopLevel failed: \(String(describing: error), privacy: .public)")
                outcome = Outcome(failure: error, summary: await session.diagnosticsSummary())
            }
            guard !outcome.tops.isEmpty else {
                // Nothing elaborated: back to what the server compiled before.
                await restore(previous, on: session)
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
                editor.closeLinkProgress()
                showAlert(
                    title: String(localized: "slangTop.failed.title", defaultValue: "Couldn’t Set the Top Level"),
                    message: [
                        String(
                            format: String(
                                localized: "slangTop.failed.topLevel",
                                defaultValue: "slang-server elaborated nothing with %@ as the top level."
                            ),
                            module
                        ),
                        outcome.failureDetail,
                        String(
                            localized: "slangTop.failed.suggestBuildFile",
                            defaultValue: "If the design needs defines, include directories or files outside this folder, right-click its .f file in the Files panel and choose Use as SystemVerilog Build File instead."
                        ),
                    ].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                    window: editor.linkPanelWindow
                )
                return
            }
            recordTarget(.topLevel(session.serverPath(for: documentURI)), for: session)
            WaveformSourceLink.topLevelWasChosen(session: session)
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            var lines = [outcome.successLine]
            if !outcome.tops.contains(module) {
                lines.append(String(
                    format: String(
                        localized: "slangTop.success.otherTop",
                        defaultValue: "%1$@ is instantiated in this file, so slang used %2$@ as the top level."
                    ),
                    module,
                    outcome.tops.joined(separator: ", ")
                ))
            }
            editor.showLinkMessage(lines.joined(separator: "\n"), at: anchor)
        }
    }

    /// Puts `session` back to explore mode (or its config's build) after a top level was set.
    static func resetTopLevel(session: LanguageServerSession) {
        guard !isBusy(session) else {
            NSSound.beep()
            return
        }
        WaveformSourceLink.resetTopLevel(session: session)
    }

    /// The link's reset: back to the config's build if cmux wrote one, else explore mode.
    static func returnToConfiguredCompilation(_ session: LanguageServerSession) async {
        guard claim([session]) else { return }
        defer { release([session]) }
        if case .topLevel? = target(of: session) {
            recordTarget(nil, for: session)
        }
        await restore(CompilationState(target: nil, isExplore: false), on: session)
    }

    // MARK: Build file

    /// Where a Files explorer entry lives.
    struct ExplorerFile {
        let path: String
        let workspaceId: UUID
        /// The explorer's provider for a workspace on an SSH host; nil for a local file.
        let sshProvider: SSHFileExplorerProvider?
        let window: NSWindow?
    }

    static func isBuildFileCandidate(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "f"
    }

    /// Whether some server of the workspace builds from `file` (or any build file, when `file` is nil).
    static func isBuildFileInUse(_ file: ExplorerFile?, workspaceId: UUID) -> Bool {
        sessions(inWorkspace: workspaceId).contains { session in
            guard case .buildFile(let path)? = target(of: session) else { return false }
            guard let file else { return true }
            return path == session.serverPath(for: URL(fileURLWithPath: file.path))
        }
    }

    /// Makes the workspace's language servers build from the `.f` file.
    static func useBuildFile(_ file: ExplorerFile) {
        Task { @MainActor in
            guard let primary = await primarySession(for: file) else {
                showAlert(
                    title: String(localized: "slangTop.build.failed.title", defaultValue: "Couldn’t Use the Build File"),
                    message: String(localized: "slangTop.build.noServer", defaultValue: "slang-server isn’t available for this workspace."),
                    window: file.window
                )
                return
            }
            let name = (file.path as NSString).lastPathComponent
            let outcome: Outcome?
            if await primary.session.supportsCommand("slang.setBuildFile") == true {
                outcome = await useBuildFileAtRuntime(file, primary: primary.session)
            } else {
                outcome = await useBuildFileThroughConfig(file, primary: primary)
            }
            guard let outcome else { return }
            guard !outcome.tops.isEmpty else {
                showAlert(
                    title: String(localized: "slangTop.build.failed.title", defaultValue: "Couldn’t Use the Build File"),
                    message: [
                        String(
                            format: String(localized: "slangTop.build.failed.detail", defaultValue: "slang-server elaborated nothing from %@."),
                            name
                        ),
                        outcome.failureDetail,
                    ].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                    window: file.window
                )
                return
            }
            showAlert(
                title: String(localized: "slangTop.build.done.title", defaultValue: "Build File in Use"),
                message: [
                    String(format: String(localized: "slangTop.build.done.detail", defaultValue: "slang-server now builds the design from %@."), name),
                    outcome.successLine,
                ].joined(separator: "\n"),
                window: file.window
            )
        }
    }

    /// `slang.setBuildFile` on every server of the workspace on the same host. A server that
    /// elaborates nothing goes back to what it compiled. The primary server's outcome; nil when busy.
    private static func useBuildFileAtRuntime(_ file: ExplorerFile, primary: LanguageServerSession) async -> Outcome? {
        let targets = [primary] + sessions(inWorkspace: file.workspaceId).filter {
            $0 !== primary && $0.launch == primary.launch
        }
        guard claim(targets) else {
            NSSound.beep()
            return nil
        }
        defer { release(targets) }
        let progress = SlangProgressSheet(
            message: String(
                format: String(localized: "slangTop.progress.build", defaultValue: "Elaborating the design from %@…"),
                (file.path as NSString).lastPathComponent
            ),
            window: file.window
        )
        defer { progress.close() }
        var primaryOutcome = Outcome(tops: [], instanceCount: 0, summary: SlangDiagnosticsSummary(), serverErrors: [])
        for session in targets {
            let previous = await currentState(of: session)
            let serverPath = session.serverPath(for: URL(fileURLWithPath: file.path))
            _ = await session.takeRecentErrorMessages()
            var result: Outcome
            do {
                try await session.slangSetBuildFile(serverPath)
                result = await Self.outcome(of: session)
            } catch {
                slangCompilationLogger.error("setBuildFile failed: \(String(describing: error), privacy: .public)")
                result = Outcome(failure: error, summary: await session.diagnosticsSummary())
            }
            if result.tops.isEmpty {
                await restore(previous, on: session)
            } else {
                let entry = entry(for: session)
                entry.target = .buildFile(serverPath)
                entry.workspaceIds.insert(file.workspaceId)
                WaveformSourceLink.topLevelWasChosen(session: session)
            }
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            if session === primary { primaryOutcome = result }
        }
        return primaryOutcome
    }

    /// Puts the workspace's servers that build from a `.f` file back to what they compiled before.
    static func clearBuildFile(workspaceId: UUID, window: NSWindow?) {
        let targets = sessions(inWorkspace: workspaceId).filter {
            if case .buildFile? = target(of: $0) { return true }
            return false
        }
        guard !targets.isEmpty, claim(targets) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { release(targets) }
            for session in targets {
                let entry = entry(for: session)
                do {
                    if let edit = entry.configFile {
                        try await writeBuild(edit.previousBuild, to: edit.location)
                        entry.configFile = nil
                        try await session.restart(keepingCompilation: false)
                    } else {
                        try await session.slangSetBuildFile("")
                    }
                    entry.target = nil
                } catch {
                    showAlert(
                        title: String(localized: "slangTop.build.clearFailed.title", defaultValue: "Couldn’t Clear the Build File"),
                        message: userMessage(for: error),
                        window: window
                    )
                }
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            }
        }
    }

    /// The server a document in the build file's folder would get, started if needed.
    private static func primarySession(for file: ExplorerFile) async -> (session: LanguageServerSession, context: FilePreviewLanguageDocumentContext)? {
        let workspace = AppDelegate.shared?.workspaceFor(tabId: file.workspaceId)
        guard let context = await FilePreviewLanguageDocumentContext.resolve(
            languageId: languageId,
            workspace: workspace,
            filePath: file.path,
            remotePath: file.sshProvider == nil ? nil : file.path,
            providerIdentity: file.sshProvider?.remoteIdentity
        ) else { return nil }
        do {
            let session = try await LanguageServerPool.shared.session(
                launch: context.serverLaunch,
                rootURI: context.rootURI,
                languageId: languageId
            )
            return (session, context)
        } catch {
            slangCompilationLogger.error("no language server for the build file: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Servers without `slang.setBuildFile`: `"build"` in `.slang/local/server.json`, then a restart.
    /// Nil when the user declined, the server was busy, or the file could not be written (reported).
    private static func useBuildFileThroughConfig(
        _ file: ExplorerFile,
        primary: (session: LanguageServerSession, context: FilePreviewLanguageDocumentContext)
    ) async -> Outcome? {
        guard let root = primary.context.rootURI?.path else { return nil }
        let session = primary.session
        guard claim([session]) else {
            NSSound.beep()
            return nil
        }
        defer { release([session]) }
        let location = ConfigFileLocation(path: SlangServerConfigFile.path(inWorkspace: root), sshProvider: file.sshProvider)
        let alert = NSAlert()
        alert.messageText = String(localized: "slangTop.config.confirm.title", defaultValue: "Write the Build File to the Server Config?")
        alert.informativeText = String(
            format: String(
                localized: "slangTop.config.confirm.detail",
                defaultValue: "This slang-server can’t switch build files while it runs. cmux will set \"build\" to %1$@ in %2$@, keeping the file’s other settings, and restart the language server."
            ),
            file.path,
            displayPath(of: location)
        )
        alert.addButton(withTitle: String(localized: "slangTop.config.confirm.write", defaultValue: "Write and Restart"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        guard await runAlert(alert, window: file.window) == .alertFirstButtonReturn else { return nil }
        let previousBuild: String?
        do {
            previousBuild = try await writeBuild(file.path, to: location)
        } catch {
            showAlert(
                title: String(localized: "slangTop.build.failed.title", defaultValue: "Couldn’t Use the Build File"),
                message: userMessage(for: error, configPath: displayPath(of: location)),
                window: file.window
            )
            return nil
        }
        let entry = entry(for: session)
        let progress = SlangProgressSheet(
            message: String(
                format: String(localized: "slangTop.progress.build", defaultValue: "Elaborating the design from %@…"),
                (file.path as NSString).lastPathComponent
            ),
            window: file.window
        )
        defer { progress.close() }
        var outcome: Outcome
        do {
            // The config's build, not an earlier runtime top level, decides now.
            try await session.restart(keepingCompilation: false)
            outcome = await Self.outcome(of: session)
        } catch {
            outcome = Outcome(failure: error, summary: SlangDiagnosticsSummary())
        }
        if outcome.tops.isEmpty {
            // Put the file back as it was.
            _ = try? await writeBuild(previousBuild, to: location)
            try? await session.restart(keepingCompilation: false)
            entry.target = nil
        } else {
            entry.configFile = ConfigFileEdit(location: location, previousBuild: entry.configFile?.previousBuild ?? previousBuild)
            entry.target = .buildFile(session.serverPath(for: URL(fileURLWithPath: file.path)))
            entry.workspaceIds.insert(file.workspaceId)
            WaveformSourceLink.topLevelWasChosen(session: session)
        }
        FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        return outcome
    }

    private static func displayPath(of location: ConfigFileLocation) -> String {
        guard let provider = location.sshProvider else { return location.path }
        return "\(provider.displayTarget):\(location.path)"
    }

    /// Sets (or with nil removes) `"build"` in the config file, creating its folders, locally or
    /// over SSH. Returns the `"build"` the file had. A file that cannot be read is never overwritten.
    @discardableResult
    private static func writeBuild(_ buildPath: String?, to location: ConfigFileLocation) async throws -> String? {
        let directory = (location.path as NSString).deletingLastPathComponent
        if let provider = location.sshProvider {
            var existing: Data?
            var stamp: SSHRemoteFileStamp?
            if try await remoteFileExists(location.path, provider: provider) {
                stamp = try await provider.fileStamp(path: location.path)
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-slang-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: scratch) }
                try await provider.downloadFile(path: location.path, to: scratch)
                existing = try Data(contentsOf: scratch)
            } else {
                let parent = (directory as NSString).deletingLastPathComponent
                if try await !remoteFileExists(parent, provider: provider) { try await provider.createDirectory(path: parent) }
                if try await !remoteFileExists(directory, provider: provider) { try await provider.createDirectory(path: directory) }
            }
            let data = try SlangServerConfigFile.settingBuild(buildPath, in: existing)
            // The expected stamp makes the write fail rather than clobber a file changed meanwhile.
            _ = try await provider.writeFile(path: location.path, contents: data, expectedStamp: stamp)
            return SlangServerConfigFile.build(in: existing)
        }
        // Write through a symlinked config to its target.
        let url = URL(fileURLWithPath: location.path).resolvingSymlinksInPath()
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let data = try SlangServerConfigFile.settingBuild(buildPath, in: existing)
        try FileManager.default.createDirectory(atPath: url.deletingLastPathComponent().path, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return SlangServerConfigFile.build(in: existing)
    }

    /// Whether `path` exists on the SSH host, from its folder's listing (errors are rethrown,
    /// never read as "absent"). A folder that does not exist has no entries.
    private static func remoteFileExists(_ path: String, provider: SSHFileExplorerProvider, depth: Int = 0) async throws -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !parent.isEmpty, parent != path else { return true }
        // Below the workspace root (three levels for .slang/local/server.json) check the folder first.
        if depth < 3, try await !remoteFileExists(parent, provider: provider, depth: depth + 1) { return false }
        return try await provider.listDirectory(path: parent, showHidden: true).contains { $0.name == name }
    }

    /// Distinct live language servers of the workspace's SystemVerilog editors.
    static func sessions(inWorkspace workspaceId: UUID) -> [LanguageServerSession] {
        var seen = Set<ObjectIdentifier>()
        var sessions: [LanguageServerSession] = []
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: workspaceId) {
            guard let session = editor.linkSession?.session, seen.insert(ObjectIdentifier(session)).inserted else { continue }
            sessions.append(session)
        }
        for entry in entries where entry.target != nil && entry.workspaceIds.contains(workspaceId) {
            guard let session = entry.session, seen.insert(ObjectIdentifier(session)).inserted else { continue }
            sessions.append(session)
        }
        return sessions
    }

    // MARK: Outcome

    struct Outcome {
        var tops: [String]
        var instanceCount: Int
        var summary: SlangDiagnosticsSummary
        var serverErrors: [String]

        init(tops: [String], instanceCount: Int, summary: SlangDiagnosticsSummary, serverErrors: [String]) {
            self.tops = tops
            self.instanceCount = instanceCount
            self.summary = summary
            self.serverErrors = serverErrors
        }

        init(failure: any Error, summary: SlangDiagnosticsSummary) {
            self.init(tops: [], instanceCount: 0, summary: summary, serverErrors: [SlangCompilationActions.userMessage(for: failure)])
        }

        var successLine: String {
            var lines = [String(
                format: String(localized: "slangTop.success.instances", defaultValue: "Elaborated %lld instances."),
                Int64(instanceCount)
            ) + " " + String(
                format: String(localized: "slangTop.success.tops", defaultValue: "Top level: %@."),
                tops.joined(separator: ", ")
            )]
            if summary.errorCount > 0 {
                lines.append(String(
                    format: String(localized: "slangTop.summary.errors", defaultValue: "slang reports %lld errors."),
                    Int64(summary.errorCount)
                ))
            }
            return lines.joined(separator: "\n")
        }

        var failureDetail: String {
            var lines = serverErrors
            if summary.errorCount > 0 {
                lines.append(String(
                    format: String(localized: "slangTop.summary.errors", defaultValue: "slang reports %lld errors."),
                    Int64(summary.errorCount)
                ))
                lines.append(contentsOf: summary.firstErrors)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The design the server compiled, once its diagnostics have arrived.
    static func outcome(of session: LanguageServerSession) async -> Outcome {
        try? await Task.sleep(for: diagnosticsSettleDelay)
        // getScope("") also lists packages; only instances are tops.
        let tops = ((try? await session.slangScopeChildren("")) ?? []).filter { $0.kind != "Package" }.map(\.name)
        let count = tops.isEmpty ? 0 : ((try? await session.slangInstanceCount()) ?? 0)
        return Outcome(
            tops: tops,
            instanceCount: count,
            summary: await session.diagnosticsSummary(),
            serverErrors: await session.takeRecentErrorMessages()
        )
    }

    /// A short, localized description of a failure for an alert.
    nonisolated static func userMessage(for error: any Error, configPath: String? = nil) -> String {
        switch error {
        case LanguageServerError.timeout:
            return String(localized: "slangTop.error.timeout", defaultValue: "slang-server didn’t answer in time.")
        case LanguageServerError.notRunning, LanguageServerError.processExited:
            return String(localized: "slangTop.error.notRunning", defaultValue: "slang-server isn’t running.")
        case LanguageServerError.responseError(_, let message):
            return message
        case SlangServerConfigFile.EditError.notAJSONObject:
            return String(
                format: String(
                    localized: "slangTop.error.invalidConfig",
                    defaultValue: "%@ isn’t a JSON object, so cmux left it unchanged. Fix or remove it, then try again."
                ),
                configPath ?? SlangServerConfigFile.relativePath
            )
        default:
            return error.localizedDescription
        }
    }

    // MARK: Alerts

    static func runAlert(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    static func showAlert(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // The message can be selected and copied.
        alert.layout()
        for case let field as NSTextField in alert.window.contentView?.subviews ?? [] where field.stringValue == message {
            field.isSelectable = true
        }
        Task { @MainActor in
            _ = await runAlert(alert, window: window)
        }
    }
}

/// A sheet with a spinner while slang-server elaborates (the Files explorer has no editor to show it in).
/// Not shown when the window already has a sheet.
@MainActor
private final class SlangProgressSheet {
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    init(message: String, window: NSWindow?) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72), styleMask: [.titled], backing: .buffered, defer: true)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: message)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        sheet.contentView = stack
        let parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let parent, parent.attachedSheet == nil else { return }
        self.parent = parent
        parent.beginSheet(sheet)
    }

    func close() {
        guard let parent else { return }
        self.parent = nil
        parent.endSheet(sheet)
        sheet.orderOut(nil)
    }
}
