import Foundation

extension RemotePreviewCacheBudget {
    /// Local files that open panels show, in every window: file previews,
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
        for manager in managers {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    if let preview = panel as? FilePreviewPanel {
                        paths.insert(preview.filePath)
                    } else if let markdown = panel as? MarkdownPanel {
                        paths.insert(markdown.filePath)
                    } else if let browser = panel as? BrowserPanel, let url = browser.currentURL, url.isFileURL {
                        paths.insert(url.path)
                    }
                }
            }
        }
        return paths
    }
}
