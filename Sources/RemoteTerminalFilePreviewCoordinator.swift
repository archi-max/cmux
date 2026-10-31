import CmuxCloud
import AppKit
import CmuxSettings
import CmuxTerminalCore
import Foundation

/// Owns remote click downloads and discards completions whose source terminal has changed.
@MainActor
final class RemoteTerminalFilePreviewCoordinator {
    private let defaults: UserDefaults
    private let transport: any SSHFileExplorerTransport
    private let cacheDirectory: URL
    private let clock: any Clock<Duration>
    private let timeout: Duration
    private var tasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        defaults: UserDefaults,
        transport: any SSHFileExplorerTransport,
        cacheDirectory: URL,
        clock: any Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.transport = transport
        self.cacheDirectory = cacheDirectory
        self.clock = clock
        self.timeout = timeout
    }

    /// Largest host file `cmux open` downloads without a click.
    nonisolated static let maximumCommandLineOpenBytes: Int64 = 32 * 1024 * 1024

    /// What asked for the preview, which decides how it is fetched and shown.
    private enum Request {
        /// ⌘-click: terminal tokens, resolved against the terminal's directory;
        /// the result opens like any ⌘-clicked file (markdown viewer, HTML in
        /// the browser, otherwise the file preview).
        case click(tokens: [String])
        /// `cmux open` through the relay, with no gesture: exactly one
        /// canonical host path, size-capped, shown only in the native file
        /// preview, never as a web page.
        case commandLine(path: String)
    }

    @discardableResult
    func open(workspace: Workspace, sourcePanelID: UUID, tokens: [String]) -> Bool {
        let tokens = tokens.filter { RemoteTerminalPathResolver().isFileReference($0) }
        guard !tokens.isEmpty else { return false }
        return start(.click(tokens: tokens), workspace: workspace, sourcePanelID: sourcePanelID)
    }

    /// Starts a `cmux open` preview of `path` on the terminal's SSH host.
    /// Returns false when nothing will open: not an SSH terminal, or file
    /// previews are off.
    func openFromCommandLine(workspace: Workspace, sourcePanelID: UUID, path: String) -> Bool {
        start(.commandLine(path: path), workspace: workspace, sourcePanelID: sourcePanelID)
    }

    private func start(_ request: Request, workspace: Workspace, sourcePanelID: UUID) -> Bool {
        guard let configuration = workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID),
              let panel = workspace.terminalPanel(for: sourcePanelID) else { return false }
        let settings = FileRouteSettingsStore(defaults: defaults)
        switch request {
        case .click(let tokens):
            tasks[sourcePanelID]?.task.cancel()
            guard !ManagedFileTransferPolicy.isDisabled,
                  settings.supportedFileRouteEnabled ||
                    (settings.markdownRouteEnabled && tokens.contains { FileRouteSettingsStore.isMarkdownPath($0.trimmingTrailingTerminalPunctuation()) }) else {
                return true
            }
        case .commandLine:
            guard !ManagedFileTransferPolicy.isDisabled, settings.supportedFileRouteEnabled else { return false }
            tasks[sourcePanelID]?.task.cancel()
        }
        let directory = workspace.effectivePanelDirectory(panelId: sourcePanelID)
        let provider = SSHFileExplorerProvider(
            destination: configuration.destination,
            port: configuration.port,
            identityFile: configuration.identityFile,
            sshOptions: configuration.fileOperationSSHOptions,
            displayTarget: configuration.displayTarget,
            homePath: "",
            isAvailable: true,
            transport: transport
        )
        let loader = RemoteTerminalFilePreviewLoader(
            provider: provider,
            cacheDirectory: cacheDirectory,
            fileManager: FileManager()
        )
        let clock = self.clock
        let timeout = self.timeout
        let requestID = UUID()
        #if DEBUG
        cmuxDebugLog("remotePreview.start request=\(requestID.uuidString) surface=\(sourcePanelID.uuidString)")
        #endif
        let sourceSurface = panel.surface
        let lifecycleID = sourceSurface.terminalLifecycleId
        let attemptID = workspace.remoteTerminalAttemptIDsBySurfaceId[sourcePanelID]
        let tuiAttemptID = workspace.sshTuiConnectionAttemptID
        let projectionResource = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID)?.resource
        let task = Task { [weak self, weak workspace, weak panel, weak sourceSurface] in
            defer {
                if self?.tasks[sourcePanelID]?.id == requestID {
                    self?.tasks.removeValue(forKey: sourcePanelID)
                }
            }
            do {
                let localURL = try await withThrowingTaskGroup(of: URL.self) { group in
                    group.addTask {
                        switch request {
                        case .click(let tokens):
                            return try await loader.load(tokens: tokens, workingDirectory: directory)
                        case .commandLine(let path):
                            return try await loader.load(exactPath: path, maxBytes: RemoteTerminalFilePreviewCoordinator.maximumCommandLineOpenBytes)
                        }
                    }
                    group.addTask {
                        // A genuine transfer deadline, not a delay used to synchronize UI state.
                        try await clock.sleep(for: timeout)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try Task.checkCancellation()
                guard let self, let workspace, let panel, let sourceSurface,
                      !ManagedFileTransferPolicy.isDisabled,
                      !workspace.isRetiredFromOwningTabManager,
                      workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID) == configuration,
                      workspace.terminalPanel(for: sourcePanelID) === panel,
                      panel.surface === sourceSurface,
                      sourceSurface.terminalLifecycleId == lifecycleID,
                      workspace.remoteTerminalAttemptIDsBySurfaceId[sourcePanelID] == attemptID,
                      workspace.sshTuiConnectionAttemptID == tuiAttemptID,
                      SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID)?.resource == projectionResource,
                      sourceSurface.owningWorkspace() === workspace,
                      workspace.owningTabManager?.selectedTabId == workspace.id,
                      workspace.focusedPanelId == sourcePanelID,
                      panel.hostedView.window?.isKeyWindow == true else {
                    #if DEBUG
                    cmuxDebugLog("remotePreview.discarded request=\(requestID.uuidString)")
                    #endif
                    return
                }
                let opened: Bool
                switch request {
                case .click:
                    opened = CommandClickFileOpenRouter.openInCmux(
                        workspace: workspace,
                        sourcePanelId: sourcePanelID,
                        filePath: localURL.path,
                        defaults: self.defaults
                    )
                case .commandLine:
                    // Never the markdown viewer or the browser: the host chose
                    // this file, so it opens only in the native preview.
                    opened = FileRouteSettingsStore(defaults: self.defaults).shouldRouteSupportedFile(path: localURL.path)
                        && workspace.openOrFocusFilePreviewSplit(from: sourcePanelID, filePath: localURL.path) != nil
                }
                #if DEBUG
                cmuxDebugLog("remotePreview.complete request=\(requestID.uuidString) opened=\(opened)")
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                cmuxDebugLog("remotePreview.failed request=\(requestID.uuidString)")
                #endif
                guard let workspace, let panel,
                      workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID) == configuration,
                      workspace.sshTuiConnectionAttemptID == tuiAttemptID,
                      workspace.terminalPanel(for: sourcePanelID) === panel,
                      workspace.owningTabManager?.selectedTabId == workspace.id,
                      workspace.focusedPanelId == sourcePanelID,
                      panel.hostedView.window?.isKeyWindow == true else { return }
                // Match the existing file-explorer preview failure affordance without exposing SSH diagnostics.
                NSSound.beep()
            }
        }
        tasks[sourcePanelID] = (requestID, task)
        return true
    }

    deinit {
        for entry in tasks.values { entry.task.cancel() }
    }
}
