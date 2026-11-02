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
    /// Serves `cmux open` of dumps read in place, through the Files panel's
    /// preview path. Bound with ``FileExplorerStore/bindSSHPreviewProvider``:
    /// no root folder, so it never lists or runs git status on the host.
    private lazy var inPlaceStore = FileExplorerStore()
    /// Holds the leases of previews opened in the native file preview, so
    /// they name their host path, save back and refresh like Files-panel ones.
    private let leaseCache = CloudFilePreviewCache()

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
        /// Queued: a download started, or the waveform viewer is opening an
        /// FSDB dump in place on the host; the preview opens beside the
        /// terminal. When it can't open, a notice on the terminal says why.
        /// A download that lands after the user moved on opens without
        /// taking focus (in a workspace they left: with a notification);
        /// it is dropped only if its terminal or connection is gone.
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
        let tokens = tokens.filter { RemoteTerminalPathResolver().isClickedFileCandidate($0) }
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
        let snapshotDirectory = workspace.effectivePanelDirectory(panelId: sourcePanelID)
        // A cmux-tui terminal's reported cwd is the directory it was spawned
        // in; only a live process query knows where the shell `cd`'d to.
        let liveDirectory: @MainActor @Sendable () async -> String? = { [weak workspace] in
            guard let workspace, workspace.usesSSHTui,
                  let resource = SurfaceCatalog.shared.resource(forPanel: sourcePanelID),
                  let provider = SurfaceCatalog.shared.provider(for: resource.machine) else { return nil }
            return await provider.currentWorkingDirectory(of: resource)
        }
        let workingDirectory: @Sendable () async -> String? = {
            let resolved = await RemotePreviewOpenRules.resolvedWorkingDirectory(
                needsDirectory: true,
                live: {
                    // Bounded: a link that stalls must not hold the click for the whole download deadline.
                    await withTaskGroup(of: String?.self) { group in
                        group.addTask { await liveDirectory() }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(3))
                            return nil
                        }
                        let first = await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }
                },
                snapshot: snapshotDirectory
            )
            #if DEBUG
            cmuxDebugLog("remotePreview.cwd surface=\(sourcePanelID.uuidString) source=\(resolved.source.rawValue)")
            #endif
            return resolved.directory
        }
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
        if case .commandLine(let path) = request,
           let existing = Self.openPreview(of: path, identity: provider.remoteIdentity, in: workspace) {
            // Already open: show it now and refresh it in place, instead of
            // waiting for a fresh download into a second tab. The request
            // crossed the relay, so focus moves only if the user is still
            // on the terminal.
            let placement = RemotePreviewOpenRules.placement(
                isSelected: workspace.owningTabManager?.selectedTabId == workspace.id,
                isRetired: workspace.isRetiredFromOwningTabManager,
                sourceUnchanged: true,
                configurationUnchanged: true,
                sourceIsFocused: workspace.focusedPanelId == sourcePanelID,
                windowIsKey: panel.hostedView.window?.isKeyWindow == true
            )
            guard let placement,
                  workspace.openOrFocusFilePreviewSplit(
                      from: sourcePanelID, filePath: existing.filePath, focus: placement.takesFocus
                  ) != nil else { return .started }
            if placement.announcesOpen { Self.announceOpen(of: path, in: workspace, from: sourcePanelID) }
            if !existing.isDirty { existing.refreshRemotePreview() }
            return .started
        }
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
        // Whether and how a result may still open: read after every await before
        // an open, for a download and for a located dump alike.
        let currentPlacement: @MainActor () -> RemotePreviewPlacement? = { [weak workspace, weak panel, weak sourceSurface] in
            guard let workspace, let panel, let sourceSurface,
                  !ManagedFileTransferPolicy.isDisabled else { return nil }
            let terminalIsTheSame = workspace.terminalPanel(for: sourcePanelID) === panel
                && panel.surface === sourceSurface
                && sourceSurface.terminalLifecycleId == lifecycleID
                && sourceSurface.owningWorkspace() === workspace
            let projectionIsTheSame = workspace.remoteTerminalAttemptIDsBySurfaceId[sourcePanelID] == attemptID
                && SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: sourcePanelID)?.resource
                    == projectionResource
            let connectionIsTheSame = workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID) == configuration
                && workspace.sshTuiConnectionAttemptID == tuiAttemptID
            return RemotePreviewOpenRules.placement(
                isSelected: workspace.owningTabManager?.selectedTabId == workspace.id,
                isRetired: workspace.isRetiredFromOwningTabManager,
                sourceUnchanged: terminalIsTheSame && projectionIsTheSame,
                configurationUnchanged: connectionIsTheSame,
                sourceIsFocused: workspace.focusedPanelId == sourcePanelID,
                windowIsKey: panel.hostedView.window?.isKeyWindow == true
            )
        }
        if case .click(let tokens) = request, RemoteTerminalFilePreviewLoader.readsInPlaceOnHost(tokens: tokens) {
            // A waveform dump: find it on the host (relative links against the
            // shell's live directory) and open the viewer that reads it there,
            // as `cmux open` does; never download it.
            let task = Task { [weak self, weak workspace, weak panel] in
                defer {
                    if self?.tasks[sourcePanelID]?.id == requestID {
                        self?.tasks.removeValue(forKey: sourcePanelID)
                    }
                }
                do {
                    let header = try await withThrowingTaskGroup(of: RemoteFileProbe.Header.self) { group in
                        group.addTask { try await loader.locate(tokens: tokens, workingDirectory: workingDirectory) }
                        group.addTask {
                            // A genuine transfer deadline, not a delay used to synchronize UI state.
                            try await clock.sleep(for: timeout)
                            throw URLError(.timedOut)
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                    guard !Task.isCancelled, let self, let workspace else { return }
                    // The same source check as a finished download: a reconnect to
                    // another host during the lookup must not open the old path there.
                    switch RemotePreviewOpenRules.locatedAction(
                        placement: currentPlacement(),
                        readsInPlace: FilePreviewKindResolver.isReadInPlaceOnRemoteHost(header.path)
                    ) {
                    case .drop:
                        #if DEBUG
                        cmuxDebugLog("remotePreview.discarded request=\(requestID.uuidString)")
                        #endif
                    case .refuse(let beeps):
                        #if DEBUG
                        cmuxDebugLog("remotePreview.complete request=\(requestID.uuidString) inPlace=false")
                        #endif
                        if beeps { NSSound.beep() }
                    case .openInPlace:
                        let outcome = self.openInPlaceOnHost(path: header.path, workspace: workspace, sourcePanelID: sourcePanelID)
                        #if DEBUG
                        cmuxDebugLog("remotePreview.complete request=\(requestID.uuidString) inPlace=\(outcome == .started)")
                        #endif
                        if outcome != .started, currentPlacement()?.takesFocus == true { NSSound.beep() }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    #if DEBUG
                    cmuxDebugLog("remotePreview.failed request=\(requestID.uuidString) reason=\(Self.failureReason(error))")
                    #endif
                    guard let workspace, let panel,
                          workspace.terminalPanel(for: sourcePanelID) === panel,
                          workspace.focusedPanelId == sourcePanelID,
                          panel.hostedView.window?.isKeyWindow == true else { return }
                    NSSound.beep()
                }
            }
            tasks[sourcePanelID] = (requestID, task)
            return .started
        }
        let task = Task { [weak self, weak workspace, weak panel] in
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
                            return try await loader.load(tokens: tokens, workingDirectory: workingDirectory)
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
                guard let self, let workspace, let panel,
                      !ManagedFileTransferPolicy.isDisabled else {
                    Self.discardUnlessShown(download, cacheRoot: cacheRoot)
                    return
                }
                guard let placement = currentPlacement() else {
                    #if DEBUG
                    cmuxDebugLog("remotePreview.discarded request=\(requestID.uuidString)")
                    #endif
                    Self.discardUnlessShown(download, cacheRoot: cacheRoot)
                    return
                }
                let opened: Bool
                switch request {
                case .click:
                    if let viewer = Self.clickViewer(localURL.path, defaults: self.defaults),
                       let remotePath = download.remotePath {
                        opened = await self.openLeased(
                            download, remotePath: remotePath, provider: provider,
                            workspace: workspace, sourcePanelID: sourcePanelID,
                            viewer: viewer, placement: currentPlacement
                        )
                    } else {
                        opened = false
                    }
                    if !opened {
                        if placement.takesFocus { NSSound.beep() }
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
                        if FileRouteSettingsStore(defaults: self.defaults).shouldRouteSupportedFile(path: localURL.path),
                           let remotePath = download.remotePath {
                            opened = await self.openLeased(
                                download, remotePath: remotePath, provider: provider,
                                workspace: workspace, sourcePanelID: sourcePanelID,
                                viewer: .source, placement: currentPlacement
                            )
                        } else {
                            opened = false
                        }
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
                cmuxDebugLog("remotePreview.failed request=\(requestID.uuidString) reason=\(Self.failureReason(error))")
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

    /// Why a preview failed, for the debug log: no path or ssh output.
    private static func failureReason(_ error: Error) -> String {
        error as? RemoteTerminalFilePreviewError == .fileTooLarge ? "tooLarge" : RemotePreviewOpenRules.failureReason(error)
    }

    /// The leased viewer of a clicked host file under the user's routing settings.
    private static func clickViewer(_ path: String, defaults: UserDefaults) -> RemoteClickViewer? {
        let settings = FileRouteSettingsStore(defaults: defaults)
        return RemotePreviewOpenRules.clickViewer(
            isMarkdown: FileRouteSettingsStore.isMarkdownPath(path),
            routesMarkdown: settings.shouldRouteMarkdown(path: path),
            routesSupportedFile: settings.shouldRouteSupportedFile(path: path)
        )
    }

    /// The open preview of host file `path` on the connection `identity`, if any.
    private static func openPreview(of path: String, identity: String, in workspace: Workspace) -> FilePreviewPanel? {
        workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .first { !$0.isClosed && $0.cloudPreviewRemotePath == path && $0.cloudPreviewProviderIdentity == identity }
    }

    /// Opens a download in the native file preview under an editable SSH
    /// lease: the header shows the host path, Save writes to the host (with
    /// the Files panel's conflict check), Refresh re-reads it. A preview of
    /// the same host file that is already open is reused: its text is
    /// replaced with the fresh bytes unless it has unsaved edits.
    /// `placement` is read again after the lease is prepared; the preview
    /// takes focus only for ``RemotePreviewPlacement/focused``.
    private func openLeased(
        _ download: RemotePreviewDownload,
        remotePath: String,
        provider: SSHFileExplorerProvider,
        workspace: Workspace,
        sourcePanelID: UUID,
        viewer: RemoteClickViewer,
        placement: @MainActor () -> RemotePreviewPlacement?
    ) async -> Bool {
        let target: FilePreviewPanel
        let finalPlacement: RemotePreviewPlacement
        if let existing = Self.openPreview(of: remotePath, identity: provider.remoteIdentity, in: workspace) {
            guard let now = placement() else {
                Self.discardUnlessShown(download, cacheRoot: cacheDirectory)
                return false
            }
            if !existing.isDirty, let lease = existing.cloudPreviewLease, lease.isEditable,
               (try? FileManager.default.replaceItemAt(URL(fileURLWithPath: existing.filePath), withItemAt: download.url)) != nil {
                lease.remoteStamp = download.remoteStamp
                _ = existing.reloadFromDisk()
            }
            Self.discardUnlessShown(download, cacheRoot: cacheDirectory)
            guard workspace.openOrFocusFilePreviewSplit(
                from: sourcePanelID, filePath: existing.filePath, focus: now.takesFocus
            ) != nil else { return false }
            target = existing
            finalPlacement = now
        } else {
            let leaseCache = self.leaseCache
            // The adopt is an await: the user may have moved on, or the terminal
            // may be gone, by the time it returns. A dropped lease removes its file.
            guard case let (lease, now)? = await RemotePreviewOpenRules.openAfter({
                try? await leaseCache.adopt(
                    file: download.url, path: remotePath, provider: provider, stamp: download.remoteStamp
                )
            }, placement: placement),
                  let panel = workspace.openOrFocusFilePreviewSplit(
                      from: sourcePanelID, filePath: lease.url.path, focus: now.takesFocus
                  ) else {
                return false
            }
            panel.cloudPreviewLease = lease
            if viewer == .renderedMarkdown, !panel.isShowingMarkdownPreview {
                panel.toggleMarkdownPreview()
                if now.takesFocus { panel.focus() }
            }
            target = panel
            finalPlacement = now
        }
        if let line = download.line {
            FilePreviewLanguageFeatures.reveal(
                line: line, column: download.column, in: target, takesFocus: finalPlacement.takesFocus
            )
        }
        if finalPlacement.announcesOpen { Self.announceOpen(of: remotePath, in: workspace, from: sourcePanelID) }
        return true
    }

    /// Says where a preview went when it opened in a workspace that isn't on
    /// screen, instead of opening it silently.
    private static func announceOpen(of remotePath: String, in workspace: Workspace, from sourcePanelID: UUID) {
        TerminalNotificationStore.shared.addNotification(
            tabId: workspace.id,
            surfaceId: sourcePanelID,
            title: RemotePreviewNotice.opened(
                fileName: (remotePath as NSString).lastPathComponent,
                workspaceName: workspace.title
            ),
            subtitle: "",
            body: remotePath
        )
    }

    /// Deletes a download that won't be shown, if it created its cache file
    /// and no panel in any window shows that file.
    private static func discardUnlessShown(_ download: RemotePreviewDownload, cacheRoot: URL) {
        RemotePreviewCacheBudget.discard(download, cacheRoot: cacheRoot, keeping: RemotePreviewCacheBudget.pathsShownInPanels())
    }

    /// Opens a dump the waveform viewer reads on the host (FSDB) the way the
    /// Files panel does: a placeholder lease, the helper on the host, no
    /// download. It opens like a downloaded preview, in the pane to the
    /// terminal's right or a new split beside it, and a failure shows as a
    /// notice on the terminal.
    private func openInPlaceOnHost(path: String, workspace: Workspace, sourcePanelID: UUID) -> CommandLineOpenOutcome {
        let configuration = workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID)
        // The terminal's own SSH connection, as a download of the same link
        // uses: the Files panel needn't be connected to the host.
        let sshConnection = RemotePreviewOpenRules.inPlaceConnection(
            terminal: configuration.map {
                SSHFileExplorerConnection(
                    destination: $0.destination, port: $0.port,
                    identityFile: $0.identityFile, sshOptions: $0.fileOperationSSHOptions
                )
            }
        )
        let terminal = workspace.terminalPanel(for: sourcePanelID)
        let pane = workspace.paneId(forPanelId: sourcePanelID)
        let notice: @MainActor () -> Void = { [weak terminal] in
            guard let view = terminal?.hostedView, view.window?.isKeyWindow == true else { return }
            view.showTerminalNotice(RemotePreviewNotice.couldNotOpen)
        }
        switch RemotePreviewInPlaceGate.route(
            sshRootAvailable: sshConnection != nil,
            terminalIsRemote: configuration != nil && terminal != nil,
            hasWorkspacePane: pane != nil
        ) {
        case .unavailable:
            return .unavailable
        case .noticeNoPane:
            // A Dock terminal: no workspace pane to open the viewer beside.
            notice()
            return .started
        case .open:
            break
        }
        guard let sshConnection, let configuration, let pane else { return .unavailable }
        // Bound for previews only: no folder listing or git status on the host.
        inPlaceStore.bindSSHPreviewProvider(
            workspaceId: workspace.id,
            connection: sshConnection,
            displayTarget: configuration.displayTarget,
            sshTransport: transport
        )
        let workspaceID = workspace.id
        // What the viewer's refresh follows, mapped the same way at open and on
        // every refresh so a one-sided edit can't silently disable it.
        let identity: @MainActor (Workspace) -> SSHFileExplorerConnection? = {
            $0.remoteConfiguration.flatMap {
                RemotePreviewInPlaceGate.sshIdentity(
                    transportIsSSH: $0.transport == .ssh,
                    destination: $0.destination,
                    port: $0.port,
                    identityFile: $0.identityFile,
                    sshOptions: $0.fileOperationSSHOptions
                )
            }
        }
        guard let viewerIdentity = identity(workspace) else { return .unavailable }
        // The viewer opens after a host round trip: it takes focus only if the
        // user is still on the terminal, like a downloaded preview.
        let takesFocus: @MainActor () -> Bool = { [weak workspace, weak terminal] in
            guard let workspace, let terminal else { return false }
            return RemotePreviewOpenRules.placement(
                isSelected: workspace.owningTabManager?.selectedTabId == workspaceID,
                isRetired: workspace.isRetiredFromOwningTabManager,
                sourceUnchanged: workspace.terminalPanel(for: sourcePanelID) === terminal,
                configurationUnchanged: workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID) == configuration,
                sourceIsFocused: workspace.focusedPanelId == sourcePanelID,
                windowIsKey: terminal.hostedView.window?.isKeyWindow == true
            )?.takesFocus ?? false
        }
        FileExplorerPreviewCoordinator(store: inPlaceStore).open(
            path: path,
            workspace: workspace,
            pane: pane,
            isCurrent: { [weak workspace] in
                guard let workspace else { return false }
                return RemotePreviewInPlaceGate.openIsCurrent(
                    isSelected: workspace.owningTabManager?.selectedTabId == workspaceID,
                    isRetired: workspace.isRetiredFromOwningTabManager,
                    terminalConfiguration: workspace.remoteTerminalFilePreviewConfiguration(for: sourcePanelID),
                    openedWith: configuration
                )
            },
            presentation: FileExplorerPreviewCoordinator.Presentation(
                openPreview: { workspace, localPath in
                    workspace.openOrFocusFilePreviewSplit(from: sourcePanelID, filePath: localPath, focus: takesFocus())
                },
                takesFocus: takesFocus,
                reportFailure: { _ in notice() },
                isPanelCurrent: { [weak workspace] in
                    guard let workspace else { return false }
                    return RemotePreviewInPlaceGate.panelIsCurrent(
                        isSelected: workspace.owningTabManager?.selectedTabId == workspaceID,
                        isRetired: workspace.isRetiredFromOwningTabManager,
                        workspaceConfiguration: identity(workspace),
                        openedWith: viewerIdentity
                    )
                }
            )
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

    /// The notification for a preview that opened in a workspace the user had left.
    static func opened(fileName: String, workspaceName: String) -> String {
        String(
            format: String(localized: "remotePreview.notification.openedInWorkspace", defaultValue: "Opened %1$@ in %2$@"),
            fileName, workspaceName
        )
    }

    static var downloadFailed: String {
        String(localized: "remotePreview.notice.downloadFailed", defaultValue: "Couldn’t download the file from the host")
    }
}
