import AppKit
import CmuxFoundation
import SwiftUI
import WebKit

/// The panel colors handed to the waveform viewer's VS Code theme variables.
struct WaveformViewerTheme: Equatable {
    let isDark: Bool
    let background: String
    let foreground: String

    static func resolve(backgroundColor: NSColor, foregroundColor: NSColor) -> WaveformViewerTheme {
        let background = backgroundColor.markdownOpaqueSRGB
        return WaveformViewerTheme(
            isDark: !background.isLightColor,
            background: background.markdownCSSColor,
            foreground: foregroundColor.markdownOpaqueSRGB.markdownCSSColor
        )
    }

    var scriptValue: [String: Any] {
        ["kind": isDark ? "dark" : "light", "background": background, "foreground": foreground]
    }
}

/// Hosts the bundled VaporView waveform viewer (`Resources/vaporview`) for a
/// `.vcd`, `.fst` or `.ghw` file preview.
///
/// The page runs VaporView's webview and its wellen WebAssembly parser. This
/// session serves the page and the file through `WaveformViewerSchemeHandler`
/// (range reads from disk), tells the page which file to open once it reports
/// ready, and keeps one WebKit view per panel across SwiftUI remounts.
@MainActor
final class FilePreviewWaveformSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let messageHandlerName = "cmuxWaveform"

    private let schemeHandler = WaveformViewerSchemeHandler()
    private var webView: MarkdownWebView?
    private var fileURL: URL?
    private var loadedRevision: Int?
    private var theme: WaveformViewerTheme?
    private var isPageReady = false
    private var webContentProcessRecoveryAttempts = 0
    private let maxWebContentProcessRecoveryAttempts = 2

    deinit {
        // WebKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        theme: WaveformViewerTheme
    ) -> NSView {
        let webView = self.webView ?? makeWebView()
        if webView.superview != nil {
            webView.removeFromSuperview()
        }
        configure(webView, panel: panel, revision: revision, isVisibleInUI: isVisibleInUI, theme: theme)
        return webView
    }

    func update(
        _ view: NSView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        theme: WaveformViewerTheme
    ) {
        guard let webView, view === webView else { return }
        configure(webView, panel: panel, revision: revision, isVisibleInUI: isVisibleInUI, theme: theme)
    }

    func close() {
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        webView = nil
        schemeHandler.stopServing()
        fileURL = nil
        loadedRevision = nil
        theme = nil
        isPageReady = false
        webContentProcessRecoveryAttempts = 0
    }

    private func makeWebView() -> MarkdownWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: WaveformViewerSchemeHandler.scheme)
        config.userContentController.add(
            WeakMarkdownScriptMessageHandler(self),
            name: Self.messageHandlerName
        )
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        self.webView = webView
        return webView
    }

    private func configure(
        _ webView: MarkdownWebView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        theme: WaveformViewerTheme
    ) {
        webView.setVisibleInUI(isVisibleInUI)
        panel.attachPreviewFocus(root: webView, primaryResponder: webView, intent: .waveformViewer)
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
        if self.theme != theme {
            self.theme = theme
            if isPageReady {
                evaluate(function: "setTheme", argument: theme.scriptValue)
            }
        }
        let url = panel.fileURL
        if fileURL != url || loadedRevision != revision {
            // A new revision means the file changed on disk or was refreshed:
            // reload the page so wellen parses the new contents from scratch.
            fileURL = url
            loadedRevision = revision
            loadPage()
        }
    }

    private func loadPage() {
        guard let webView else { return }
        isPageReady = false
        schemeHandler.stopServing()
        guard schemeHandler.hasAssets else {
            webView.loadHTMLString(Self.missingAssetsHTML(), baseURL: nil)
            return
        }
        webView.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
    }

    private func openFileInPage() {
        guard let fileURL else { return }
        let servedURL = schemeHandler.serve(fileURL: fileURL)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let theme {
            evaluate(function: "setTheme", argument: theme.scriptValue)
        }
        evaluate(function: "open", argument: [
            "url": servedURL.absoluteString,
            "size": size,
            "format": fileURL.pathExtension.lowercased(),
            "strings": Self.localizedStrings(),
        ])
    }

    private func evaluate(function: String, argument: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: argument),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxWaveform && window.cmuxWaveform.\(function)(\(json))", completionHandler: nil)
    }

    private static func localizedStrings() -> [String: String] {
        [
            "netlist": String(localized: "filePreview.waveform.netlist", defaultValue: "Netlist"),
            "loading": String(localized: "filePreview.waveform.loading", defaultValue: "Loading waveform…"),
            "openFailed": String(localized: "filePreview.waveform.openFailed", defaultValue: "Unable to open waveform"),
            "addSignal": String(localized: "filePreview.waveform.addSignal", defaultValue: "Add to viewer"),
        ]
    }

    private static func missingAssetsHTML() -> String {
        let message = String(
            localized: "filePreview.waveform.assetsMissing",
            defaultValue: "The waveform viewer is missing from this build of cmux."
        )
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!DOCTYPE html><html><body style="font: 13px -apple-system; color: gray; display: flex; \
        align-items: center; justify-content: center; height: 90vh;">\(escaped)</body></html>
        """
    }

    // MARK: WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isPageReady = true
            openFileInPage()
        case "opened":
            webContentProcessRecoveryAttempts = 0
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "error":
#if DEBUG
            NSLog("FilePreviewWaveform.error \(body["message"] as? String ?? "")")
#endif
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // Only the bundled page and its viewer frame load; links and script
        // navigations elsewhere are dropped.
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let allowed = scheme == WaveformViewerSchemeHandler.scheme
            || (scheme == "about" && navigationAction.targetFrame?.isMainFrame == false)
            || (!schemeHandler.hasAssets && navigationAction.request.url?.absoluteString == "about:blank")
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView,
              webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else { return }
        webContentProcessRecoveryAttempts += 1
        loadPage()
    }
}

struct FilePreviewWaveformView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let theme: WaveformViewerTheme

    func makeNSView(context: Context) -> NSView {
        panel.nativeViewSessions.waveform.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            theme: theme
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        panel.nativeViewSessions.waveform.update(
            nsView,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            theme: theme
        )
    }
}
