import AppKit
import Bonsplit

/// Both sidebar entrypoints capture the displayed provider before suspending.
@MainActor
struct FileExplorerPreviewCoordinator {
    let store: FileExplorerStore

    func open(path: String, workspace: Workspace, pane: PaneID, isCurrent: @escaping @MainActor () -> Bool) {
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
                        isCurrent: { isCurrent() && store.resourceContextID == context },
                        validate: { try target.validate(vmID: cloud.vmID) }, provider: cloud
                    ) { return }
                    let lease = try await store.cloudPreviewCache.materialize(path: path, provider: cloud)
                    guard isCurrent(), store.resourceContextID == context else { return }
                    try target.validate(vmID: cloud.vmID)
                    // Markdown also uses the read-only file preview: its links must
                    // never resolve relative remote paths through the Mac browser.
                    if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                        focus: true, reuseExisting: false).first {
                        panel.cloudPreviewLease = lease
                        Self.installRemotePreviewRefresh(
                            on: panel, workspace: workspace,
                            isCurrent: isCurrent, provider: cloud, vmID: cloud.vmID, target: target
                        )
                        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
                    }
                } else if let remote = provider as? any RemoteFileExplorerProvider {
                    try await Self.openRemotePreview(
                        path: path, provider: remote, cache: store.cloudPreviewCache,
                        workspace: workspace, pane: pane,
                        isCurrent: { isCurrent() && store.resourceContextID == context }
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(), store.resourceContextID == context else { return }
                Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
            }
        }
    }

    /// Opens an SSH file's downloaded copy: Markdown in the rendered viewer,
    /// any other file in the editable file preview. A panel already showing
    /// the remote file is refreshed and focused instead.
    private static func openRemotePreview(
        path: String,
        provider: any RemoteFileExplorerProvider,
        cache: CloudFilePreviewCache,
        workspace: Workspace,
        pane: PaneID,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        let providerIdentity = provider.remoteIdentity
        let rendersMarkdown = provider is SSHFileExplorerProvider
            && MarkdownPanelFileLinkResolver.isMarkdownPathLike(path)
        if rendersMarkdown {
            if try await refreshExistingRemoteMarkdown(
                path: path, providerIdentity: providerIdentity, workspace: workspace,
                isCurrent: isCurrent, provider: provider
            ) { return }
            // A source editor left open after its viewer closed keeps the
            // newest copy; render that one so both stay on the same lease.
            if let lease = existingRemoteSourceLease(
                path: path, providerIdentity: providerIdentity, workspace: workspace
            ), let document = MarkdownRemoteDocument(lease: lease) {
                openRemoteMarkdown(document, provider: provider, cache: cache, workspace: workspace, pane: pane)
                return
            }
        } else if try await refreshExistingRemotePreview(
            path: path, providerIdentity: providerIdentity, workspace: workspace, pane: pane,
            isCurrent: isCurrent, validate: {}, provider: provider
        ) { return }
        let lease = try await cache.materialize(path: path, provider: provider)
        guard isCurrent() else { return }
        if rendersMarkdown, let document = MarkdownRemoteDocument(lease: lease) {
            openRemoteMarkdown(document, provider: provider, cache: cache, workspace: workspace, pane: pane)
            return
        }
        if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
            focus: true, reuseExisting: false).first {
            panel.cloudPreviewLease = lease
            Self.installRemotePreviewRefresh(
                on: panel, workspace: workspace,
                isCurrent: isCurrent, provider: provider, vmID: nil, target: nil
            )
            workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
        }
    }

    /// Shows a remote Markdown file rendered. Its links open other remote files
    /// through this same path, and Edit Source opens the editable preview of
    /// the same downloaded copy, which saves back to the host.
    private static func openRemoteMarkdown(
        _ document: MarkdownRemoteDocument,
        provider: any RemoteFileExplorerProvider,
        cache: CloudFilePreviewCache,
        workspace: Workspace,
        pane: PaneID
    ) {
        guard let panel = workspace.newMarkdownSurface(
            inPane: pane, filePath: document.lease.url.path, focus: true, remoteDocument: document
        ) else { return }
        let isLinkCurrent: @MainActor () -> Bool = { [weak workspace, weak panel] in
            guard let workspace, let panel else { return false }
            return !panel.isClosed && workspace.panels[panel.id] != nil
        }
        document.openRemoteFile = { [weak workspace, weak panel] remotePath in
            guard let workspace, let panel, isLinkCurrent(),
                  let pane = workspace.paneId(forPanelId: panel.id) else { return }
            Task { [weak workspace] in
                guard let workspace else { return }
                do {
                    try await Self.openRemotePreview(
                        path: remotePath, provider: provider, cache: cache,
                        workspace: workspace, pane: pane, isCurrent: { [weak workspace] in workspace != nil }
                    )
                } catch is CancellationError {
                    return
                } catch {
                    Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                }
            }
        }
        document.editSource = { [weak workspace, weak panel, weak document] in
            guard let workspace, let panel, let document, isLinkCurrent(),
                  let pane = workspace.paneId(forPanelId: panel.id),
                  let source = workspace.openOrFocusFilePreviewSurface(
                      inPane: pane, filePath: document.lease.url.path, focus: true
                  ) else { return }
            if source.cloudPreviewLease == nil {
                source.cloudPreviewLease = document.lease
                // The editor can outlive this viewer, so its refresh must not depend on it.
                Self.installRemotePreviewRefresh(
                    on: source, workspace: workspace,
                    isCurrent: { [weak workspace] in workspace != nil }, provider: provider, vmID: nil, target: nil
                )
            }
        }
        document.refresh = { [weak workspace, weak panel, weak document] in
            guard let workspace, let panel, let document, isLinkCurrent() else { return }
            // An open source editor with unsaved edits owns the copy: replacing
            // it would also move the save-time conflict stamp past the remote change.
            guard !Self.hasDirtySourceEditor(for: document, in: workspace) else {
                _ = panel.reloadFromDisk()
                return
            }
            Task { @MainActor [weak workspace, weak panel] in
                do {
                    try await document.lease.refresh(using: provider)
                    guard let panel, isLinkCurrent() else { return }
                    _ = panel.reloadFromDisk()
                } catch is CancellationError {
                    return
                } catch {
                    guard let workspace else { return }
                    Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                }
            }
        }
        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
    }

    private static func existingRemoteSourceLease(
        path: String,
        providerIdentity: String,
        workspace: Workspace
    ) -> CloudFilePreviewLease? {
        let source = workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .first(where: {
                !$0.isClosed &&
                    $0.cloudPreviewRemotePath == path &&
                    $0.cloudPreviewProviderIdentity == providerIdentity &&
                    FileManager.default.fileExists(atPath: $0.filePath)
            })
        guard let lease = source?.cloudPreviewLease, lease.isEditable else { return nil }
        return lease
    }

    private static func hasDirtySourceEditor(for document: MarkdownRemoteDocument, in workspace: Workspace) -> Bool {
        workspace.panels.values.contains { panel in
            guard let source = panel as? FilePreviewPanel else { return false }
            return !source.isClosed && source.cloudPreviewLease === document.lease && source.isDirty
        }
    }

    private static func refreshExistingRemoteMarkdown(
        path: String,
        providerIdentity: String,
        workspace: Workspace,
        isCurrent: @escaping @MainActor () -> Bool,
        provider: any RemoteFileExplorerProvider
    ) async throws -> Bool {
        guard let existing = workspace.panels.values
            .compactMap({ $0 as? MarkdownPanel })
            .first(where: {
                !$0.isClosed &&
                    $0.remoteDocument?.remotePath == path &&
                    $0.remoteDocument?.remoteIdentity == providerIdentity &&
                    FileManager.default.fileExists(atPath: $0.filePath)
            }),
            let document = existing.remoteDocument else { return false }
        if !hasDirtySourceEditor(for: document, in: workspace) {
            try await document.lease.refresh(using: provider)
        }
        guard isCurrent(), !existing.isClosed, workspace.panels[existing.id] != nil else { return true }
        _ = existing.reloadFromDisk()
        // Focus the viewer itself: a path-based open could add a viewer of the
        // copy that resolves links on this Mac.
        workspace.focusPanel(existing.id)
        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: existing)
        return true
    }

    private static func refreshExistingRemotePreview(
        path: String,
        providerIdentity: String,
        workspace: Workspace,
        pane: PaneID,
        isCurrent: @escaping @MainActor () -> Bool,
        validate: @escaping @MainActor () throws -> Void,
        provider: any RemoteFileExplorerProvider
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
        try await lease.refresh(using: provider)
        guard isCurrent(), !existing.isClosed,
              workspace.panels[existing.id] != nil else { return true }
        try validate()
        _ = existing.reloadFromDisk()
        _ = workspace.openOrFocusFilePreviewSurface(inPane: pane, filePath: existing.filePath, focus: true)
        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: existing)
        return true
    }

    private static func installRemotePreviewRefresh(
        on panel: FilePreviewPanel,
        workspace: Workspace,
        isCurrent: @escaping @MainActor () -> Bool,
        provider: any RemoteFileExplorerProvider,
        vmID: String?,
        target: CloudFileExplorerTarget?
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
                    Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                }
            }
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
