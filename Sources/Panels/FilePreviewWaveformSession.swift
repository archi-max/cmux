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
/// `.vcd`, `.fst`, `.ghw` or `.fsdb` file preview.
///
/// The page runs VaporView's webview and its wellen WebAssembly parser. This
/// session serves the page and the file through `WaveformViewerSchemeHandler`
/// (range reads from disk), tells the page which file to open once it reports
/// ready, and keeps one WebKit view per panel across SwiftUI remounts.
///
/// An FSDB file on an SSH workspace is never downloaded: the session runs
/// `WaveformFSDBHelper` on the host (one per open viewer) and relays the
/// page's requests to it. Verdi’s reader does not run on macOS, so a local
/// FSDB file shows a message instead.
@MainActor
final class FilePreviewWaveformSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let messageHandlerName = "cmuxWaveform"

    private let schemeHandler = WaveformViewerSchemeHandler()
    private var webView: MarkdownWebView?
    private var fileURL: URL?
    private var loadedRevision: Int?
    private var theme: WaveformViewerTheme?
    private var isPageReady = false
    private weak var panel: FilePreviewPanel?
    private var fsdbHelper: WaveformFSDBHelper?
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
        stopFSDBHelper()
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
        self.panel = panel
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
        stopFSDBHelper()
        schemeHandler.stopServing()
        guard schemeHandler.hasAssets else {
            webView.loadHTMLString(Self.missingAssetsHTML(), baseURL: nil)
            return
        }
        webView.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
    }

    private func openFileInPage() {
        guard let fileURL else { return }
        if let theme {
            evaluate(function: "setTheme", argument: theme.scriptValue)
        }
        let format = fileURL.pathExtension.lowercased()
        if format == "fsdb" {
            var argument: [String: Any] = [
                "url": fileURL.absoluteString,
                "format": format,
                "strings": Self.localizedStrings(),
            ]
            // Resolved now, not at configure time: Files sets the remote lease
            // right after it creates the panel.
            if let remoteFSDB = panel.flatMap(RemoteFSDB.resolve(panel:)), let relayURL = startFSDBHelper(for: remoteFSDB) {
                argument["fsdb"] = ["url": relayURL.absoluteString, "path": remoteFSDB.remotePath]
            }
            evaluate(function: "open", argument: argument)
            return
        }
        let servedURL = schemeHandler.serve(fileURL: fileURL)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        evaluate(function: "open", argument: [
            "url": servedURL.absoluteString,
            "size": size,
            "format": format,
            "strings": Self.localizedStrings(),
        ])
    }

    // MARK: Remote FSDB

    /// Where a remote FSDB preview lives: its path on the host and the workspace's SSH route.
    struct RemoteFSDB {
        let remotePath: String
        let host: String
        let sshArguments: WaveformFSDBHelper.SSHArguments

        static func resolve(panel: FilePreviewPanel) -> RemoteFSDB? {
            guard panel.fileURL.pathExtension.lowercased() == "fsdb",
                  let remotePath = panel.cloudPreviewRemotePath,
                  panel.cloudPreviewProviderIdentity?.hasPrefix("ssh:") == true,
                  let configuration = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceId)?.remoteConfiguration,
                  configuration.transport == .ssh else { return nil }
            // The same batch route as the Files explorer and the remote language
            // server: it reuses the `cmux ssh` ControlPath.
            let options = configuration.fileOperationSSHOptions
            return RemoteFSDB(remotePath: remotePath, host: configuration.destination) { command in
                configuration.batchSSHCommandArguments(command: command, effectiveSSHOptions: options)
            }
        }
    }

    private func startFSDBHelper(for remote: RemoteFSDB) -> URL? {
        guard let resourceRoot = WaveformFSDBHelper.bundledResourceRoot() else { return nil }
        stopFSDBHelper()
        let host = remote.host
        let helper = WaveformFSDBHelper(sshArguments: remote.sshArguments, resourceRoot: resourceRoot) { [weak self] status in
            Task { @MainActor [weak self] in self?.showFSDBStatus(status, host: host) }
        }
        fsdbHelper = helper
        return schemeHandler.serve(fsdbRelay: { body in
            do {
                return WaveformSchemeResponse.fsdb(try await helper.request(body))
            } catch {
                return WaveformSchemeResponse.fsdbError(Self.fsdbFailureMessage(error, host: host))
            }
        })
    }

    private func stopFSDBHelper() {
        fsdbHelper?.stop()
        fsdbHelper = nil
    }

    private func showFSDBStatus(_ status: WaveformFSDBHelper.Status, host: String) {
        guard isPageReady, fsdbHelper != nil else { return }
        let title: String
        let detail: String
        switch status {
        case .connecting:
            title = String(localized: "filePreview.waveform.loading", defaultValue: "Loading waveform…")
            detail = ""
        case .building:
            title = String(localized: "filePreview.waveform.fsdbBuilding", defaultValue: "Setting up the FSDB reader…")
            detail = String(
                format: String(
                    localized: "filePreview.waveform.fsdbBuildingDetail",
                    defaultValue: "First FSDB file on %@: cmux is building Verdi’s FSDB reader there. Later files open right away."
                ),
                host
            )
        }
        evaluate(function: "setStatus", argument: ["title": title, "detail": detail])
    }

    /// A message for a failed helper start or request, with the host's own output as detail.
    static func fsdbFailureMessage(_ error: Error, host: String) -> String {
        let summary: String
        var detail = ""
        switch error as? WaveformFSDBHelper.Failure {
        case .setupFailed(let code, let output)?:
            detail = output
            switch code {
            case 10:
                summary = String(
                    localized: "filePreview.waveform.fsdbNoVerdi",
                    defaultValue: "Verdi’s FSDB reader was not found on %@. Load the Synopsys module or set VERDI_HOME in your shell startup file there."
                )
            case 11:
                summary = String(
                    localized: "filePreview.waveform.fsdbNoNode",
                    defaultValue: "Node.js 18 or later was not found on %@. Install it there, or set CMUX_FSDB_NODE to its path in your shell startup file."
                )
            case 12:
                summary = String(
                    localized: "filePreview.waveform.fsdbNoCompiler",
                    defaultValue: "No C++ compiler (g++) was found on %@."
                )
            default:
                summary = String(
                    localized: "filePreview.waveform.fsdbSetupFailed",
                    defaultValue: "The FSDB reader could not be built on %@."
                )
            }
        case .helperExited(let output)?:
            detail = output
            summary = String(
                localized: "filePreview.waveform.fsdbHelperExited",
                defaultValue: "The connection to the FSDB reader on %@ ended. Reload to try again."
            )
        case .stopped?:
            summary = String(
                localized: "filePreview.waveform.fsdbHelperExited",
                defaultValue: "The connection to the FSDB reader on %@ ended. Reload to try again."
            )
        case nil:
            // The helper's own error for this request (bad file, unreadable dump).
            return error.localizedDescription
        }
        let text = String(format: summary, host)
        return detail.isEmpty ? text : text + "\n\n" + detail
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
            "fsdbNeedsRemoteTitle": String(
                localized: "filePreview.waveform.fsdbNeedsRemote",
                defaultValue: "FSDB files open from an SSH workspace"
            ),
            "fsdbNeedsRemoteDetail": String(
                localized: "filePreview.waveform.fsdbNeedsRemoteDetail",
                defaultValue: "Reading FSDB needs Verdi’s FSDB reader, which runs only on Linux. Open this file from an SSH workspace on the host where Verdi is installed."
            ),
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
