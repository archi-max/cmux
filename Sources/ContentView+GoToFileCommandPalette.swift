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
            let store: FileExplorerStore
            if sidebarStore.workspaceRootIdentity == workspace.id,
               let provider = sidebarStore.provider as? SSHFileExplorerProvider,
               provider.connection == connection, provider.isAvailable {
                store = sidebarStore
            } else {
                guard let root = model.workspaceRoot else { return false }
                store = model.remotePreviewStore
                let bound = store.provider as? SSHFileExplorerProvider
                if store.workspaceRootIdentity != workspace.id || bound?.connection != connection {
                    store.applyWorkspaceRoot(root)
                }
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
}

/// The Go to File result list under the palette's search field.
struct GoToFileResultsView: View {
    @ObservedObject var model: GoToFilePaletteModel
    let onRun: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.results.isEmpty {
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
                                    row(path: path, isSelected: index == model.selectedIndex)
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

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard model.results.indices.contains(model.selectedIndex) else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(model.results[model.selectedIndex], anchor: .center)
        }
    }
}
