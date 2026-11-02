import AppKit
import Bonsplit

/// Both sidebar entrypoints capture the displayed provider before suspending.
@MainActor
struct FileExplorerPreviewCoordinator {
    let store: FileExplorerStore

    /// Where a remote preview opens and how a failure is reported, for
    /// entrypoints other than the Files panel (`cmux open`). Without it the
    /// preview opens as a tab in `pane` and a failure shows an alert.
    struct Presentation {
        /// Opens the preview of the local (lease) path, or returns nil.
        let openPreview: @MainActor (Workspace, String) -> FilePreviewPanel?
        /// Whether showing the preview (new, or one already open) may move
        /// keyboard focus to it, read when it is shown.
        let takesFocus: @MainActor () -> Bool
        /// Reports a failure, including a preview that didn't open or a refresh that failed.
        let reportFailure: @MainActor (Error) -> Void
        /// Whether the opened panel may still refresh from its host, for the
        /// panel's lifetime; looser than the open's `isCurrent` (the source
        /// terminal may close while the preview stays).
        let isPanelCurrent: @MainActor () -> Bool
    }

    func open(
        path: String,
        workspace: Workspace,
        pane: PaneID,
        isCurrent: @escaping @MainActor () -> Bool,
        presentation: Presentation? = nil
    ) {
        guard store.workspaceRootIdentity == workspace.id, let provider = store.provider,
              provider.isAvailable else { return }
        let context = store.resourceContextID
        if provider is LocalFileExplorerProvider {
            guard !workspace.usesRemoteDirectoryProvenance else { return }
            _ = workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true,
                                          reuseExisting: true, duplicateWhenFocused: true)
            return
        }
        guard let remoteProvider = provider as? any RemoteFileExplorerProvider else { return }
        let providerIdentity = remoteProvider.remoteIdentity
        Task { [weak workspace, store] in
            guard let workspace else { return }
            do {
                guard isCurrent(), store.resourceContextID == context else { return }
                if let cloud = provider as? CloudVMFileExplorerProvider {
                    guard let target = cloud.target else { throw FileExplorerError.providerUnavailable }
                    try target.validate(vmID: cloud.vmID)
                    if try await Self.refreshExistingRemotePreview(
                        path: path, providerIdentity: providerIdentity, workspace: workspace, pane: pane,
                        store: store, context: context, isCurrent: isCurrent,
                        validate: { try target.validate(vmID: cloud.vmID) }, provider: cloud
                    ) { return }
                    let lease = try await store.cloudPreviewCache.materialize(path: path, provider: cloud)
                    guard isCurrent(), store.resourceContextID == context else { return }
                    try target.validate(vmID: cloud.vmID)
                    // Markdown also opens in the file preview. Its rendered preview
                    // resolves links and images on the VM, never on this Mac.
                    if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                        focus: true, reuseExisting: false).first {
                        panel.cloudPreviewLease = lease
                        Self.installRemotePreviewRefresh(
                            on: panel, workspace: workspace,
                            isCurrent: isCurrent, provider: cloud, vmID: cloud.vmID, target: target
                        )
                        Self.installRemoteLinkOpener(on: panel, workspace: workspace, store: store, isCurrent: isCurrent)
                        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
                    }
                } else if let remote = provider as? any RemoteFileExplorerProvider {
                    if try await Self.refreshExistingRemotePreview(
                        path: path, providerIdentity: providerIdentity, workspace: workspace, pane: pane,
                        store: store, context: context, isCurrent: isCurrent,
                        validate: {}, provider: remote, takesFocus: presentation?.takesFocus
                    ) { return }
                    // The waveform viewer reads FSDB on the SSH host; dumps run to
                    // hundreds of MB, so none is downloaded.
                    let lease = remote is SSHFileExplorerProvider && FilePreviewKindResolver.isReadInPlaceOnRemoteHost(path)
                        ? try await store.cloudPreviewCache.placeholder(path: path, provider: remote)
                        : try await store.cloudPreviewCache.materialize(path: path, provider: remote,
                                                                         allowRecentCopy: true)
                    guard isCurrent(), store.resourceContextID == context else { return }
                    let opened = presentation.map { $0.openPreview(workspace, lease.url.path) }
                        ?? workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                            focus: true, reuseExisting: false).first
                    if let panel = opened {
                        panel.cloudPreviewLease = lease
                        Self.installRemotePreviewRefresh(
                            on: panel, workspace: workspace,
                            isCurrent: presentation?.isPanelCurrent ?? isCurrent,
                            provider: remote, vmID: nil, target: nil,
                            reportFailure: presentation?.reportFailure
                        )
                        // Linked files open through the Files panel's own store; a
                        // preview-only store (cmux open) has no Files panel to follow.
                        if presentation == nil {
                            Self.installRemoteLinkOpener(on: panel, workspace: workspace, store: store, isCurrent: isCurrent)
                        }
                        if presentation?.takesFocus() ?? true {
                            workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
                        }
                        // A recent copy painted at once; now check it against the host.
                        if lease.isUnverified {
                            try await Self.revalidate(panel: panel, lease: lease, workspace: workspace, provider: remote,
                                                      isCurrent: presentation?.isPanelCurrent ?? isCurrent)
                        }
                    } else {
                        presentation?.reportFailure(FileExplorerError.providerUnavailable)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(), store.resourceContextID == context else { return }
                if let presentation {
                    presentation.reportFailure(error)
                } else {
                    Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                }
            }
        }
    }

    private static func refreshExistingRemotePreview(
        path: String,
        providerIdentity: String,
        workspace: Workspace,
        pane: PaneID,
        store: FileExplorerStore,
        context: UUID,
        isCurrent: @escaping @MainActor () -> Bool,
        validate: @escaping @MainActor () throws -> Void,
        provider: any RemoteFileExplorerProvider,
        takesFocus: (@MainActor () -> Bool)? = nil
    ) async throws -> Bool {
        guard let existing = workspace.panels.values
            .compactMap({ $0 as? FilePreviewPanel })
            .first(where: {
                !$0.isClosed &&
                    $0.cloudPreviewRemotePath == path &&
                    $0.cloudPreviewProviderIdentity == providerIdentity &&
                    FileManager.default.fileExists(atPath: $0.filePath)
            }) else { return false }
        guard let lease = existing.cloudPreviewLease else { return false }
        guard !existing.isClosed else { return true }
        try validate()
        if provider is SSHFileExplorerProvider {
            // The open copy shows at once; a newer host file then replaces it in place.
            let focus = takesFocus?() ?? true
            _ = workspace.openOrFocusFilePreviewSurface(inPane: pane, filePath: existing.filePath, focus: focus)
            if focus { workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: existing) }
            try await revalidate(panel: existing, lease: lease, workspace: workspace, provider: provider,
                                 isCurrent: { isCurrent() && store.resourceContextID == context })
            return true
        }
        try await lease.refresh(using: provider)
        guard isCurrent(), store.resourceContextID == context, !existing.isClosed,
              workspace.panels[existing.id] != nil else { return true }
        try validate()
        _ = existing.reloadFromDisk()
        let focus = takesFocus?() ?? true
        _ = workspace.openOrFocusFilePreviewSurface(inPane: pane, filePath: existing.filePath, focus: focus)
        if focus { workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: existing) }
        return true
    }

    /// Checks a shown SSH copy against the host (one stat when unchanged) and
    /// reloads the panel when a newer host file replaced it. A buffer edited
    /// before that keeps the old copy's stamp, so its save reports the host's
    /// change as a conflict instead of overwriting it.
    static func revalidate(
        panel: FilePreviewPanel,
        lease: CloudFilePreviewLease,
        workspace: Workspace,
        provider: any RemoteFileExplorerProvider,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        let shownStamp = lease.remoteStamp
        guard try await lease.refresh(using: provider), !panel.isClosed, panel.cloudPreviewLease === lease else { return }
        if isCurrent(), workspace.panels[panel.id] != nil {
            await panel.reloadFromDisk().value
        }
        if panel.isDirty { lease.remoteStamp = shownStamp }
    }

    private static func installRemotePreviewRefresh(
        on panel: FilePreviewPanel,
        workspace: Workspace,
        isCurrent: @escaping @MainActor () -> Bool,
        provider: any RemoteFileExplorerProvider,
        vmID: String?,
        target: CloudFileExplorerTarget?,
        reportFailure: (@MainActor (Error) -> Void)? = nil
    ) {
        panel.remotePreviewRefresh = { [weak panel, weak workspace] in
            Task { @MainActor [weak panel, weak workspace] in
                guard let panel, let workspace, let lease = panel.cloudPreviewLease,
                      !panel.isClosed, isCurrent() else { return }
                do {
                    if let target, let vmID { try target.validate(vmID: vmID) }
                    try await lease.refresh(using: provider)
                    guard isCurrent(),
                          !panel.isClosed, workspace.panels[panel.id] != nil else { return }
                    if let target, let vmID { try target.validate(vmID: vmID) }
                    _ = panel.reloadFromDisk()
                } catch is CancellationError {
                    return
                } catch {
                    if let reportFailure {
                        reportFailure(error)
                    } else {
                        Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                    }
                }
            }
        }
    }

    /// Opens files linked from the panel's rendered Markdown through this same
    /// path, as long as the Files sidebar still shows the panel's remote host.
    private static func installRemoteLinkOpener(
        on panel: FilePreviewPanel,
        workspace: Workspace,
        store: FileExplorerStore,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        panel.remoteLinkOpener = { [weak panel, weak workspace, weak store] remotePath in
            guard let panel, let workspace, let store, !panel.isClosed,
                  let remote = store.provider as? any RemoteFileExplorerProvider,
                  remote.remoteIdentity == panel.cloudPreviewProviderIdentity,
                  let pane = workspace.paneId(forPanelId: panel.id) else { return }
            FileExplorerPreviewCoordinator(store: store)
                .open(path: remotePath, workspace: workspace, pane: pane, isCurrent: isCurrent)
        }
    }

    private static func present(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = (error as? FileExplorerError)?.localizedDescription
            ?? String(localized: "fileExplorer.preview.genericFailure", defaultValue: "The remote file could not be downloaded. Reconnect and try again.")
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: window)
    }
}
