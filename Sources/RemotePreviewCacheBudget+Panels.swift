import Foundation

extension RemotePreviewCacheBudget {
    /// Local files that open panels show, in every window and Dock: file previews,
    /// markdown viewers and `file:` browser pages. Remote preview cleanup
    /// (eviction and discarded downloads) leaves these alone.
    @MainActor
    static func pathsShownInPanels() -> Set<String> {
        guard let app = AppDelegate.shared else { return [] }
        var managers = app.mainWindowContexts.values.map(\.tabManager)
        if let current = app.tabManager, !managers.contains(where: { $0 === current }) {
            managers.append(current)
        }
        var paths = Set<String>()
        func collect(_ panels: some Collection<any Panel>) {
            for panel in panels {
                if let preview = panel as? FilePreviewPanel {
                    paths.insert(preview.filePath)
                } else if let markdown = panel as? MarkdownPanel {
                    paths.insert(markdown.filePath)
                } else if let browser = panel as? BrowserPanel, let url = browser.currentURL, url.isFileURL {
                    paths.insert(url.path)
                }
            }
        }
        // Workspace panels, workspace Docks and window Docks, as
        // openAgentSessionIdsForRecovery walks them.
        for manager in managers {
            for workspace in manager.tabs {
                collect(workspace.panels.values)
                if let dock = workspace._dockSplit { collect(dock.panels.values) }
            }
        }
        for dock in app.existingWindowDocks { collect(dock.panels.values) }
        return paths
    }
}
