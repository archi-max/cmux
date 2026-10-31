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

    /// What a `cmux open` request led to, for the socket reply.
    enum CommandLineOpenOutcome: Equatable {
        /// The download started; the preview opens when it lands (if the
        /// terminal is still focused), else a notice says why it didn't.
        case started
        /// Not an SSH terminal, or file previews are off.
        case unavailable
        /// The type previews only through Quick Look; open it from the Files panel.
        case unsupportedType
    }

    @discardableResult
    func open(workspace: Workspace, sourcePanelID: UUID, tokens: [String]) -> Bool {
        let tokens = tokens.filter { RemoteTerminalPathResolver().isFileReference($0) }
        guard !tokens.isEmpty else { return false }
        return start(.click(tokens: tokens), workspace: workspace, sourcePanelID: sourcePanelID) != .unavailable
    }

    /// Starts a `cmux open` preview of `path` on the terminal's SSH host.
    func openFromCommandLine(workspace: Workspace, sourcePanelID: UUID, path: String) -> CommandLineOpenOutcome {
        start(.commandLine(path: path), workspace: workspace, sourcePanelID: sourcePanelID)
    }

    private func start(_ request: Request, workspace: Workspace, sourcePanelID: UUID) -> CommandLineOpenOutcome {
        guard let configuration = workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID),
              let panel = workspace.terminalPanel(for: sourcePanelID) else { return .unavailable }
        let settings = FileRouteSettingsStore(defaults: defaults)
        switch request {
        case .click(let tokens):
            tasks[sourcePanelID]?.task.cancel()
            guard !ManagedFileTransferPolicy.isDisabled,
                  settings.supportedFileRouteEnabled ||
                    (settings.markdownRouteEnabled && tokens.contains { FileRouteSettingsStore.isMarkdownPath($0.trimmingTrailingTerminalPunctuation()) }) else {
                return .started
            }
        case .commandLine(let path):
            guard !ManagedFileTransferPolicy.isDisabled, settings.supportedFileRouteEnabled else { return .unavailable }
            // Refused before any transfer when the extension already says so.
            guard !FilePreviewKindResolver.opensOnlyThroughQuickLook(path: path) else { return .unsupportedType }
            tasks[sourcePanelID]?.task.cancel()
        }
        let cacheRoot = cacheDirectory
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
                    Self.discardUnlessShown(localURL, workspace: workspace, cacheRoot: cacheRoot)
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
                    // Quick Look renders some types (web archives, mail, Office)
                    // through WebKit, so those wait for a click in the Files panel;
                    // most are refused by extension before the download.
                    if FilePreviewKindResolver.mode(for: localURL) == .quickLook {
                        opened = false
                        panel.hostedView.showTerminalNotice(RemotePreviewNotice.typeOpensFromFilesPanel)
                    } else {
                        opened = FileRouteSettingsStore(defaults: self.defaults).shouldRouteSupportedFile(path: localURL.path)
                            && workspace.openOrFocusFilePreviewSplit(from: sourcePanelID, filePath: localURL.path) != nil
                    }
                    if !opened { Self.discardUnlessShown(localURL, workspace: workspace, cacheRoot: cacheRoot) }
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
                switch request {
                case .click:
                    // Match the existing file-explorer preview failure affordance without exposing SSH diagnostics.
                    NSSound.beep()
                case .commandLine:
                    // No click to answer with a beep: say what happened, still without SSH diagnostics.
                    panel.hostedView.showTerminalNotice(
                        error as? RemoteTerminalFilePreviewError == .fileTooLarge
                            ? RemotePreviewNotice.fileTooLarge
                            : RemotePreviewNotice.downloadFailed
                    )
                }
            }
        }
        tasks[sourcePanelID] = (requestID, task)
        return .started
    }

    /// Deletes a download that won't be shown, unless a preview in this
    /// window already shows that cache file (the same host path opened before).
    private static func discardUnlessShown(_ url: URL, workspace: Workspace?, cacheRoot: URL) {
        let workspaces = workspace?.owningTabManager?.tabs ?? workspace.map { [$0] } ?? []
        let shown = workspaces.contains { candidate in
            candidate.panels.values.contains { ($0 as? FilePreviewPanel)?.filePath == url.path }
        }
        if !shown { RemotePreviewCacheBudget.discard(url, cacheRoot: cacheRoot) }
    }

    deinit {
        for entry in tasks.values { entry.task.cancel() }
    }
}

/// Notices shown on the terminal when a `cmux open` preview can't open.
enum RemotePreviewNotice {
    static var fileTooLarge: String {
        String(localized: "remotePreview.notice.fileTooLarge", defaultValue: "Too large to preview from cmux open; use the Files panel")
    }

    static var typeOpensFromFilesPanel: String {
        String(localized: "remotePreview.notice.typeOpensFromFilesPanel", defaultValue: "This file type opens from the Files panel")
    }

    static var downloadFailed: String {
        String(localized: "remotePreview.notice.downloadFailed", defaultValue: "Couldn’t download the file from the host")
    }
}
