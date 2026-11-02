import AppKit
import Bonsplit
import CmuxCommandPalette
import SwiftUI

// Go to File in the command palette. The command id, mode name and string keys
// match manaflow-ai/cmux#18661 (Go to File quick open, local only), whose
// session-snapshot design this follows; this version also lists SSH roots.
extension ContentView {
    static func commandPaletteGoToFileContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.goToFile",
            title: { _ in String(localized: "commandPalette.goToFile.title", defaultValue: "Go to File…") },
            subtitle: { _ in String(localized: "commandPalette.goToFile.subtitle", defaultValue: "Open a file in the focused pane") },
            keywords: ["file", "open", "quick", "quick open", "filename", "workspace", "ssh"],
            dismissOnRun: false
        )
    }
}

/// Resolves where Go to File lists and how it opens, shared by local and SSH workspaces.
@MainActor
enum GoToFilePaletteRouting {
    /// The listing source for `workspace`'s Files root, or nil when it has none.
    ///
    /// SSH uses the Files root (pinned root, else the terminal's remote working
    /// directory), falling back to the sidebar's resolved root for the same workspace.
    static func source(
        for workspace: Workspace,
        sidebarStore: FileExplorerStore
    ) -> (source: GoToFileSnapshotSource, root: FileExplorerWorkspaceRoot)? {
        let root = FileExplorerWorkspaceRootResolver().resolve(workspace)
        switch root {
        case .local(_, let path):
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (.local(rootPath: trimmed), root)
        case .remoteSSH(let workspaceId, let connection, let displayTarget, let rootPath, let isAvailable, let detail):
            guard isAvailable else { return nil }
            var resolved = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if resolved.isEmpty,
               sidebarStore.workspaceRootIdentity == workspace.id,
               let provider = sidebarStore.provider as? SSHFileExplorerProvider,
               provider.connection == connection {
                resolved = sidebarStore.rootPath
            }
            guard !resolved.isEmpty else { return nil }
            let boundRoot = FileExplorerWorkspaceRoot.remoteSSH(
                workspaceId: workspaceId,
                connection: connection,
                displayTarget: displayTarget,
                rootPath: resolved,
                isAvailable: isAvailable,
                unavailableDetail: detail
            )
            return (.ssh(connection: connection, rootPath: resolved), boundRoot)
        case .none, .remoteCloud:
            return nil
        }
    }

    /// A typed-paths-only session for a workspace with no Files root: over
    /// the SSH connection of a terminal on the host (the focused one, else
    /// any), `./` and `../` against that terminal's live directory.
    static func typedPathsOnlySource(
        for workspace: Workspace,
        focusedPanelId: UUID?
    ) -> (source: GoToFileSnapshotSource, root: FileExplorerWorkspaceRoot, liveRoot: @MainActor () async -> String?)? {
        let candidates = [focusedPanelId].compactMap { $0 } + workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
        guard let terminalID = candidates.first(where: {
            workspace.terminalPanel(for: $0) != nil && workspace.remoteTerminalFilePreviewConfiguration(for: $0) != nil
        }), let configuration = workspace.remoteTerminalFilePreviewConfiguration(for: terminalID) else { return nil }
        let connection = SSHFileExplorerConnection(
            destination: configuration.destination, port: configuration.port,
            identityFile: configuration.identityFile, sshOptions: configuration.fileOperationSSHOptions
        )
        let snapshot = workspace.effectivePanelDirectory(panelId: terminalID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = FileExplorerWorkspaceRoot.remoteSSH(
            workspaceId: workspace.id, connection: connection, displayTarget: configuration.displayTarget,
            rootPath: snapshot, isAvailable: true, unavailableDetail: nil
        )
        let lookup: @MainActor @Sendable () async -> String? = { [weak workspace] in
            guard let workspace, workspace.usesSSHTui,
                  let resource = SurfaceCatalog.shared.resource(forPanel: terminalID),
                  let provider = SurfaceCatalog.shared.provider(for: resource.machine) else { return nil }
            return await provider.currentWorkingDirectory(of: resource)
        }
        // Bounded like a terminal link's lookup: a stalled query falls back to the last reported directory.
        let liveRoot: @MainActor () async -> String? = {
            await withTaskGroup(of: String?.self) { group in
                group.addTask { await lookup() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        return (.ssh(connection: connection, rootPath: snapshot), root, liveRoot)
    }

    /// Opens a Go to File result in `pane`: local files directly, SSH files
    /// through the Files panel's remote preview path.
    static func open(
        relativePath: String,
        model: GoToFilePaletteModel,
        workspace: Workspace,
        pane: PaneID,
        sidebarStore: FileExplorerStore,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Bool {
        guard model.workspaceId == workspace.id,
              let source = model.source,
              let absolutePath = model.absolutePath(forRelativePath: relativePath) else { return false }
        switch source {
        case .local:
            return !workspace.openFileSurfaces(
                inPane: pane,
                filePaths: [absolutePath],
                focus: true,
                reuseExisting: true
            ).isEmpty
        case .ssh(let connection, _):
            guard let store = sshStore(connection: connection, model: model, workspace: workspace, sidebarStore: sidebarStore) else {
                return false
            }
            FileExplorerPreviewCoordinator(store: store).open(
                path: absolutePath,
                workspace: workspace,
                pane: pane,
                isCurrent: isCurrent
            )
            return true
        }
    }

    /// Opens a typed path (``GoToFileTypedPath``) in `pane`, wherever it is on
    /// the session's host: `~/` against the host's `$HOME` (looked up over
    /// ssh, never evaluated by a shell), `./` and `../` against the root. SSH
    /// files open through the Files preview path, as listed results do: a
    /// lease that names the host path and saves back, an FSDB dump read in
    /// place on the host.
    static func open(
        typedPath: String,
        model: GoToFilePaletteModel,
        workspace: Workspace,
        pane: PaneID,
        sidebarStore: FileExplorerStore,
        isCurrent: @escaping @MainActor () -> Bool
    ) -> Bool {
        guard model.workspaceId == workspace.id, let source = model.source else { return false }
        switch source {
        case .local(let root):
            guard let path = GoToFileTypedPath.resolve(typedPath, root: root, home: NSHomeDirectory()) else { return false }
            return !workspace.openFileSurfaces(inPane: pane, filePaths: [path], focus: true, reuseExisting: true).isEmpty
        case .ssh(let connection, let root):
            guard let store = sshStore(connection: connection, model: model, workspace: workspace, sidebarStore: sidebarStore),
                  let provider = store.provider as? SSHFileExplorerProvider else { return false }
            let open: @MainActor (String) -> Void = { [weak workspace] path in
                guard let workspace, isCurrent() else { return }
                FileExplorerPreviewCoordinator(store: store).open(path: path, workspace: workspace, pane: pane, isCurrent: isCurrent)
            }
            let isRelative = !typedPath.hasPrefix("/") && !GoToFileTypedPath.needsHome(typedPath)
            if isRelative, let liveRoot = model.liveRoot {
                // Typed paths only: the terminal's live directory, as for its links.
                Task { @MainActor in
                    let base = GoToFileTypedPath.relativeRoot(live: await liveRoot(), fallback: root) ?? ""
                    guard let path = GoToFileTypedPath.resolve(typedPath, root: base, home: nil) else {
                        if isCurrent() { NSSound.beep() }
                        return
                    }
                    open(path)
                }
                return true
            }
            guard GoToFileTypedPath.needsHome(typedPath) else {
                guard let path = GoToFileTypedPath.resolve(typedPath, root: root, home: nil) else { return false }
                open(path)
                return true
            }
            let knownHome = provider.homePath
            Task { @MainActor in
                var home: String? = knownHome.hasPrefix("/") ? knownHome : nil
                if home == nil { home = try? await provider.resolveHomePath() }
                guard let path = GoToFileTypedPath.resolve(typedPath, root: root, home: home) else {
                    if isCurrent() { NSSound.beep() }
                    return
                }
                open(path)
            }
            return true
        }
    }

    /// The store that serves SSH previews for `connection`: the Files
    /// sidebar's when it shows this workspace, else the palette's own.
    private static func sshStore(
        connection: SSHFileExplorerConnection,
        model: GoToFilePaletteModel,
        workspace: Workspace,
        sidebarStore: FileExplorerStore
    ) -> FileExplorerStore? {
        if !model.listsFiles {
            // Typed paths only: bound for previews, no folder listing on the host.
            guard case .remoteSSH(_, _, let displayTarget, _, _, _) = model.workspaceRoot else { return nil }
            let store = model.remotePreviewStore
            store.bindSSHPreviewProvider(
                workspaceId: workspace.id, connection: connection, displayTarget: displayTarget,
                sshTransport: ProcessSSHFileExplorerTransport.shared
            )
            model.remotePreviewRoot = nil
            return store
        }
        if sidebarStore.workspaceRootIdentity == workspace.id,
           let provider = sidebarStore.provider as? SSHFileExplorerProvider,
           provider.connection == connection, provider.isAvailable {
            return sidebarStore
        }
        guard let root = model.workspaceRoot else { return nil }
        let store = model.remotePreviewStore
        // Rebind when the workspace, connection, root folder or availability changed.
        if store.workspaceRootIdentity != workspace.id || model.remotePreviewRoot != root {
            store.applyWorkspaceRoot(root)
            model.remotePreviewRoot = root
        }
        return store
    }
}

/// The Go to File result list under the palette's search field.
struct GoToFileResultsView: View {
    @ObservedObject var model: GoToFilePaletteModel
    let onRun: (String) -> Void
    let onRunTypedPath: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let typedPath = model.typedPath {
                Button { onRunTypedPath(typedPath) } label: {
                    typedPathRow(typedPath, isSelected: model.selectedIndex == 0)
                }
                .buttonStyle(.plain)
            }
            if model.results.isEmpty, model.typedPath != nil, model.errorMessage == nil {
                // The typed path is the answer; no "no match" line under it.
                EmptyView()
            } else if model.results.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element) { index, path in
                                Button { onRun(path) } label: {
                                    row(path: path, isSelected: index + model.resultRowOffset == model.selectedIndex)
                                }
                                .buttonStyle(.plain)
                                .id(path)
                            }
                        }
                    }
                    .frame(maxHeight: 450)
                    .onAppear { scrollToSelection(proxy) }
                    .onChange(of: model.selectedIndex) { _, _ in scrollToSelection(proxy) }
                }
            }
            if model.isTruncated {
                Divider()
                Text(String(
                    localized: "commandPalette.goToFile.truncated",
                    defaultValue: "This folder has too many files; only part of it is listed."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyText: String {
        if !model.listsFiles {
            return String(
                localized: "commandPalette.goToFile.typedPathsOnly",
                defaultValue: "No Files folder here; type a path such as ~/.bashrc or ./notes.md"
            )
        }
        if let message = model.errorMessage {
            return String(
                format: String(localized: "commandPalette.goToFile.failed", defaultValue: "Could not list files: %@"),
                message
            )
        }
        if model.isLoading {
            return String(localized: "commandPalette.goToFile.searching", defaultValue: "Searching files…")
        }
        return String(localized: "commandPalette.goToFile.empty", defaultValue: "No files match your search.")
    }

    private func row(path: String, isSelected: Bool) -> some View {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "doc")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
            if !directory.isEmpty {
                Text(directory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
    }

    private func typedPathRow(_ path: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(String(
                format: String(localized: "commandPalette.goToFile.openTypedPath", defaultValue: "Open %@"),
                path
            ))
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        let index = model.selectedIndex - model.resultRowOffset
        guard model.results.indices.contains(index) else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(model.results[index], anchor: .center)
        }
    }
}
