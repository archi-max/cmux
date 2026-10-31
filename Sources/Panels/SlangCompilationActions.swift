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
/// path), and is restarted to read it.
@MainActor
enum SlangCompilationActions {
    private static let languageId = "verilog"
    private static let diagnosticsSettleDelay: Duration = .milliseconds(400)

    /// What cmux set a session to compile, for the menus (the session's own record is async).
    private final class Entry {
        weak var session: LanguageServerSession?
        var target: SlangCompilationTarget?
        /// The config file cmux wrote `"build"` into instead of the runtime command.
        var configFile: ConfigFileLocation?
        /// Workspaces whose Files explorer chose the build file, so Clear Build File finds the
        /// server after its editors closed.
        var workspaceIds: Set<UUID> = []

        init(session: LanguageServerSession) {
            self.session = session
        }
    }

    struct ConfigFileLocation {
        let path: String
        /// Set for a workspace on an SSH host.
        let sshProvider: SSHFileExplorerProvider?
    }

    private static var entries: [Entry] = []
    /// Sessions with a top level or build change in flight.
    private static var busySessions: Set<ObjectIdentifier> = []

    private static func entry(for session: LanguageServerSession) -> Entry {
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

    // MARK: Top level

    /// Elaborates the design with the file of `module` (the editor's document) as the top level.
    static func setTopLevel(module: String, editor: FilePreviewLanguageFeatures, anchor: Int) {
        guard let (session, documentURI) = editor.linkSession,
              busySessions.insert(ObjectIdentifier(session)).inserted else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { busySessions.remove(ObjectIdentifier(session)) }
            // The server must see the current text.
            await editor.sendCurrentText()
            editor.showLinkMessage(String(
                format: String(
                    localized: "slangTop.progress.topLevel",
                    defaultValue: "Elaborating the design with %@ as the top level…"
                ),
                module
            ), at: anchor)
            _ = await session.takeRecentErrorMessages()
            let previous = await session.slangCompilationTarget
            let outcome: Outcome
            do {
                try await session.slangSetTopLevel(session.serverPath(for: documentURI))
                outcome = await Self.outcome(of: session)
            } catch {
                slangCompilationLogger.error("setTopLevel failed: \(String(describing: error), privacy: .public)")
                outcome = Outcome(tops: [], instanceCount: 0, summary: await session.diagnosticsSummary(), serverErrors: [String(describing: error)])
            }
            guard !outcome.tops.isEmpty else {
                // Nothing elaborated: back to what the server compiled before (explore mode if nothing).
                switch previous {
                case .topLevel(let path)?: try? await session.slangSetTopLevel(path)
                case .buildFile(let path)?: try? await session.slangSetBuildFile(path)
                case nil: try? await session.slangSetTopLevel("")
                }
                recordTarget(previous, for: session)
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

    /// Puts `session` back in explore mode after a top level was set.
    static func resetTopLevel(session: LanguageServerSession) {
        WaveformSourceLink.resetTopLevel(session: session)
    }

    /// The link's reset ran: forget the top level.
    static func topLevelWasReset(session: LanguageServerSession) {
        if case .topLevel? = target(of: session) {
            recordTarget(nil, for: session)
        }
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
            let targets = [primary.session] + sessions(inWorkspace: file.workspaceId).filter {
                $0 !== primary.session && $0.launch == primary.session.launch
            }
            guard targets.allSatisfy({ !busySessions.contains(ObjectIdentifier($0)) }) else {
                NSSound.beep()
                return
            }
            for session in targets { busySessions.insert(ObjectIdentifier(session)) }
            defer { for session in targets { busySessions.remove(ObjectIdentifier(session)) } }

            let name = (file.path as NSString).lastPathComponent
            let progress = SlangProgressSheet(
                message: String(
                    format: String(localized: "slangTop.progress.build", defaultValue: "Elaborating the design from %@…"),
                    name
                ),
                window: file.window
            )
            var outcome: Outcome?
            if await primary.session.supportsCommand("slang.setBuildFile") != false {
                for session in targets {
                    _ = await session.takeRecentErrorMessages()
                    do {
                        try await session.slangSetBuildFile(session.serverPath(for: URL(fileURLWithPath: file.path)))
                    } catch {
                        slangCompilationLogger.error("setBuildFile failed: \(String(describing: error), privacy: .public)")
                        continue
                    }
                    entry(for: session).workspaceIds.insert(file.workspaceId)
                    let result = await Self.outcome(of: session)
                    if session === primary.session { outcome = result }
                    recordTarget(result.tops.isEmpty ? nil : .buildFile(session.serverPath(for: URL(fileURLWithPath: file.path))), for: session)
                    if result.tops.isEmpty { try? await session.slangSetBuildFile("") }
                    FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
                }
            } else {
                progress.close()
                outcome = await useBuildFileThroughConfig(file, primary: primary, sessions: targets)
                guard outcome != nil else { return }
            }
            progress.close()
            guard let outcome, !outcome.tops.isEmpty else {
                showAlert(
                    title: String(localized: "slangTop.build.failed.title", defaultValue: "Couldn’t Use the Build File"),
                    message: [
                        String(
                            format: String(localized: "slangTop.build.failed.detail", defaultValue: "slang-server elaborated nothing from %@."),
                            name
                        ),
                        outcome?.failureDetail ?? "",
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

    /// Puts the workspace's servers that build from a `.f` file back in explore mode.
    static func clearBuildFile(workspaceId: UUID, window: NSWindow?) {
        let targets = sessions(inWorkspace: workspaceId).filter {
            if case .buildFile? = target(of: $0) { return true }
            return false
        }
        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            for session in targets {
                let entry = entry(for: session)
                if let configFile = entry.configFile {
                    do {
                        try await writeBuild(nil, to: configFile)
                        entry.configFile = nil
                        try await session.restart()
                    } catch {
                        showAlert(
                            title: String(localized: "slangTop.build.clearFailed.title", defaultValue: "Couldn’t Clear the Build File"),
                            message: error.localizedDescription,
                            window: window
                        )
                        continue
                    }
                } else {
                    try? await session.slangSetBuildFile("")
                }
                entry.target = nil
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            }
        }
    }

    /// The server a document in the build file's folder would get, started if needed.
    private static func primarySession(for file: ExplorerFile) async -> (session: LanguageServerSession, context: FilePreviewLanguageDocumentContext)? {
        let workspace = AppDelegate.shared?.workspaceFor(tabId: file.workspaceId)
        guard let context = FilePreviewLanguageDocumentContext.resolve(
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
    /// Nil when the user declined or the file could not be written (already reported).
    private static func useBuildFileThroughConfig(
        _ file: ExplorerFile,
        primary: (session: LanguageServerSession, context: FilePreviewLanguageDocumentContext),
        sessions: [LanguageServerSession]
    ) async -> Outcome? {
        guard let root = primary.context.rootURI?.path else { return nil }
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
        do {
            try await writeBuild(file.path, to: location)
        } catch {
            showAlert(
                title: String(localized: "slangTop.build.failed.title", defaultValue: "Couldn’t Use the Build File"),
                message: error.localizedDescription,
                window: file.window
            )
            return nil
        }
        let session = primary.session
        let entry = entry(for: session)
        entry.configFile = location
        entry.workspaceIds.insert(file.workspaceId)
        do {
            try await session.restart()
        } catch {
            return Outcome(tops: [], instanceCount: 0, summary: SlangDiagnosticsSummary(), serverErrors: [String(describing: error)])
        }
        let outcome = await Self.outcome(of: session)
        entry.target = .buildFile(file.path)
        FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        return outcome
    }

    private static func displayPath(of location: ConfigFileLocation) -> String {
        guard let provider = location.sshProvider else { return location.path }
        return "\(provider.displayTarget):\(location.path)"
    }

    /// Sets (or with nil removes) `"build"` in the config file, creating its folders, locally or over SSH.
    private static func writeBuild(_ buildPath: String?, to location: ConfigFileLocation) async throws {
        let directory = (location.path as NSString).deletingLastPathComponent
        if let provider = location.sshProvider {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-slang-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: scratch) }
            var existing: Data?
            var stamp: SSHRemoteFileStamp?
            if let current = try? await provider.fileStamp(path: location.path) {
                stamp = current
                try await provider.downloadFile(path: location.path, to: scratch)
                existing = try Data(contentsOf: scratch)
            }
            let data = try SlangServerConfigFile.settingBuild(buildPath, in: existing)
            if stamp == nil {
                try? await provider.createDirectory(path: (directory as NSString).deletingLastPathComponent)
                try? await provider.createDirectory(path: directory)
            }
            _ = try await provider.writeFile(path: location.path, contents: data, expectedStamp: stamp)
        } else {
            let url = URL(fileURLWithPath: location.path)
            let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let data = try SlangServerConfigFile.settingBuild(buildPath, in: existing)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Distinct live language servers of the workspace's SystemVerilog editors.
    private static func sessions(inWorkspace workspaceId: UUID) -> [LanguageServerSession] {
        var seen = Set<ObjectIdentifier>()
        var sessions: [LanguageServerSession] = []
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: workspaceId) {
            guard let session = editor.linkSession?.session, seen.insert(ObjectIdentifier(session)).inserted else { continue }
            sessions.append(session)
        }
        for entry in entries where entry.target != nil {
            guard let session = entry.session, seen.insert(ObjectIdentifier(session)).inserted,
                  entry.workspaceIds.contains(workspaceId) else { continue }
            sessions.append(session)
        }
        return sessions
    }

    // MARK: Outcome

    private struct Outcome {
        var tops: [String]
        var instanceCount: Int
        var summary: SlangDiagnosticsSummary
        var serverErrors: [String]

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
    private static func outcome(of session: LanguageServerSession) async -> Outcome {
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

    // MARK: Alerts

    private static func runAlert(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private static func showAlert(title: String, message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        Task { @MainActor in
            _ = await runAlert(alert, window: window)
        }
    }
}

/// A sheet with a spinner while slang-server elaborates (the Files explorer has no editor to show it in).
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
        parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        parent?.beginSheet(sheet)
    }

    func close() {
        guard sheet.sheetParent != nil else { return }
        parent?.endSheet(sheet)
    }
}
