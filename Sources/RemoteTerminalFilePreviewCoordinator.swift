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
    /// Serves `cmux open` of dumps read in place, through the Files panel's preview path.
    private lazy var inPlaceStore = FileExplorerStore()
    /// The workspace and connection ``inPlaceStore`` is bound to. Paths are
    /// absolute, so a new folder needs no rebind (which would list it and run
    /// git status on the host, and drop an earlier open still in flight).
    private var inPlaceBinding: (workspaceID: UUID, connection: SSHFileExplorerConnection)?

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
        /// Queued. A download started, and the preview opens when it lands;
        /// when it can't open, a notice on the terminal says why. Nothing
        /// opens, silently, if the terminal lost focus or its workspace or
        /// connection changed meanwhile. Or the waveform viewer is opening an
        /// FSDB dump in place on the host, whose failures show as the Files
        /// panel's alert; a terminal with no pane for it (in a Dock) gets a
        /// notice instead.
        case started
        /// Not an SSH terminal, file previews are off, or the workspace's
        /// Files root isn't a connected SSH root.
        case unavailable
        /// Refused by extension before anything is downloaded: the type
        /// previews only through Quick Look, so it opens with a click in the
        /// Files panel.
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
            switch FilePreviewKindResolver.commandLineOpenRoute(path: path) {
            case .readInPlaceOnHost:
                tasks[sourcePanelID]?.task.cancel()
                return openInPlaceOnHost(path: path, workspace: workspace, sourcePanelID: sourcePanelID)
            case .filesPanelOnly:
                // Refused before any transfer when the extension already says so.
                return .unsupportedType
            case .download:
                tasks[sourcePanelID]?.task.cancel()
            }
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
            fileManager: FileManager(),
            shownPaths: { RemotePreviewCacheBudget.pathsShownInPanels() }
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
                let download = try await withThrowingTaskGroup(of: RemotePreviewDownload.self) { group in
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
                let localURL = download.url
                if Task.isCancelled {
                    // A newer open replaced this one after the file arrived.
                    Self.discardUnlessShown(download, cacheRoot: cacheRoot)
                    return
                }
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
                    Self.discardUnlessShown(download, cacheRoot: cacheRoot)
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
                    if !opened {
                        NSSound.beep()
                        Self.discardUnlessShown(download, cacheRoot: cacheRoot)
                    }
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
                        if !opened { panel.hostedView.showTerminalNotice(RemotePreviewNotice.couldNotOpen) }
                    }
                    if !opened { Self.discardUnlessShown(download, cacheRoot: cacheRoot) }
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

    /// Deletes a download that won't be shown, if it created its cache file
    /// and no panel in any window shows that file.
    private static func discardUnlessShown(_ download: RemotePreviewDownload, cacheRoot: URL) {
        RemotePreviewCacheBudget.discard(download, cacheRoot: cacheRoot, keeping: RemotePreviewCacheBudget.pathsShownInPanels())
    }

    /// Opens a dump the waveform viewer reads on the host (FSDB) the way the
    /// Files panel does: a placeholder lease, the helper on the host, no
    /// download. It opens in the pane to the terminal's right if there is
    /// one, else as a tab in the terminal's pane (as the Files panel opens
    /// files in the focused pane).
    private func openInPlaceOnHost(path: String, workspace: Workspace, sourcePanelID: UUID) -> CommandLineOpenOutcome {
        guard case .remoteSSH(let workspaceId, let connection, let displayTarget, let rootPath, let isAvailable, let detail) =
                FileExplorerWorkspaceRootResolver().resolve(workspace),
              isAvailable else { return .unavailable }
        guard let pane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelID)
                ?? workspace.paneId(forPanelId: sourcePanelID) else {
            // A Dock terminal: no workspace pane to open the viewer in.
            workspace.terminalPanel(for: sourcePanelID)?.hostedView.showTerminalNotice(RemotePreviewNotice.couldNotOpen)
            return .started
        }
        let pinned = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = FileExplorerWorkspaceRoot.remoteSSH(
            workspaceId: workspaceId,
            connection: connection,
            displayTarget: displayTarget,
            rootPath: pinned.isEmpty ? (path as NSString).deletingLastPathComponent : pinned,
            isAvailable: isAvailable,
            unavailableDetail: detail
        )
        // Rebind only when the workspace or connection changed.
        if inPlaceStore.workspaceRootIdentity != workspace.id
            || inPlaceBinding?.workspaceID != workspace.id
            || inPlaceBinding?.connection != connection
            || inPlaceStore.provider?.isAvailable != true {
            inPlaceStore.applyWorkspaceRoot(root, sshTransport: transport)
            inPlaceBinding = (workspace.id, connection)
        }
        let workspaceID = workspace.id
        FileExplorerPreviewCoordinator(store: inPlaceStore).open(
            path: path,
            workspace: workspace,
            pane: pane,
            isCurrent: { [weak workspace] in
                guard let workspace, !workspace.isRetiredFromOwningTabManager else { return false }
                return workspace.owningTabManager?.selectedTabId == workspaceID
            }
        )
        return .started
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

    static var couldNotOpen: String {
        String(localized: "remotePreview.notice.couldNotOpen", defaultValue: "Couldn’t open the file in cmux")
    }

    static var downloadFailed: String {
        String(localized: "remotePreview.notice.downloadFailed", defaultValue: "Couldn’t download the file from the host")
    }
}
