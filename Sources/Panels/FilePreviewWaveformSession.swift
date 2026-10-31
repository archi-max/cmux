import AppKit
import CmuxCloud
import CmuxFoundation
import SwiftUI
import UniformTypeIdentifiers
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
///
/// The page also carries the VS Code side of VaporView (menus, keybindings,
/// settings, sessions; `Resources/vaporview/cmux-commands.js`). This session
/// persists its settings, saves and loads session files through AppKit panels,
/// and keeps the last signal list so a reload or file change restores it.
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
    /// The page's last `sessionState` (signal list, marker, zoom) for `fileURL`,
    /// handed back on the next open so a reload keeps the viewer as it was.
    private var restoreState: [String: Any]?
    /// The netlist's top scope names, reported when a file opens.
    private(set) var topScopes: [String] = []

    /// VaporView settings (`vaporview.*` keys) shared by every waveform panel.
    static let settingsDefaultsKey = "filePreview.waveform.settings"
    /// Session files bigger than this are not auto-loaded next to a dump.
    private static let maxSessionFileSize = 8 * 1024 * 1024

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
        if let panel {
            WaveformSourceLink.waveformClosed(panel)
        }
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
        restoreState = nil
        topScopes = []
    }

    /// Whether `responder` is this viewer's web view or one of its subviews.
    func holdsResponder(_ responder: NSResponder) -> Bool {
        guard let webView, let view = responder as? NSView else { return false }
        return view.isDescendant(of: webView)
    }

    /// Whether one of the viewer's text fields (search, value entry) has focus, so its keys are typing.
    var isEditableElementFocused: Bool {
        webView?.isViewerNavigationEditableElementFocused ?? false
    }

    /// Runs a VaporView command id in the page (`cmux-commands.js`).
    func runCommand(_ command: String, args: [String: Any] = [:]) {
        guard isPageReady else { return }
        evaluate(function: "runCommand", argument: ["command": command, "args": args])
    }

    private func makeWebView() -> MarkdownWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: WaveformViewerSchemeHandler.scheme)
        config.userContentController.add(
            WeakMarkdownScriptMessageHandler(self),
            name: Self.messageHandlerName
        )
        let webView = MarkdownWebView(frame: .zero, configuration: config)
        webView.isWaveformViewer = true
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
        if fileURL == url, loadedRevision != revision, isPageReady {
            // The file changed on disk: the page reloads it in place (keeping
            // the signal list) or offers to, per VaporView's Auto Reload.
            loadedRevision = revision
            evaluate(function: "fileChanged", argument: [:])
        } else if fileURL != url || loadedRevision != revision {
            if fileURL != url {
                restoreState = nil
            }
            fileURL = url
            loadedRevision = revision
            loadPage()
        }
    }

    private func loadPage() {
        guard let webView else { return }
        if let panel { WaveformSourceLink.waveformReloading(panel) }
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
        var common: [String: Any] = [
            "path": panel?.cloudPreviewRemotePath ?? fileURL.path,
            "strings": Self.localizedStrings(),
            "settings": Self.storedSettings(),
        ]
        if let restoreState {
            common["restore"] = restoreState
        } else if let sessionFile = Self.siblingSessionFile(for: fileURL) {
            common["sessionFile"] = sessionFile
        }
        let format = fileURL.pathExtension.lowercased()
        if format == "fsdb" {
            var argument: [String: Any] = common.merging([
                "url": fileURL.absoluteString,
                "format": format,
            ]) { _, new in new }
            // Resolved now, not at configure time: Files sets the remote lease
            // right after it creates the panel.
            if let remoteFSDB = panel.flatMap(RemoteFSDB.resolve(panel:)), let relayURL = startFSDBHelper(for: remoteFSDB) {
                argument["fsdb"] = ["url": relayURL.absoluteString, "path": remoteFSDB.remotePath]
            }
            evaluate(function: "open", argument: argument)
            return
        }
        evaluate(function: "open", argument: common.merging(servedFile(fileURL)) { _, new in new }.merging([
            "format": format,
        ]) { _, new in new })
    }

    /// Serves `fileURL` under a fresh token: the page's `url` and `size`.
    private func servedFile(_ fileURL: URL) -> [String: Any] {
        let servedURL = schemeHandler.serve(fileURL: fileURL)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["url": servedURL.absoluteString, "size": size]
    }

    /// Reopens the file in the page, keeping its signal list (VaporView's Reload File).
    private func reloadFileInPage() {
        guard let fileURL, isPageReady else { return }
        if let panel { WaveformSourceLink.waveformReloading(panel) }
        if fileURL.pathExtension.lowercased() == "fsdb" {
            // The FSDB helper rereads the dump on the host for each open.
            evaluate(function: "reload", argument: [:])
        } else {
            evaluate(function: "reload", argument: servedFile(fileURL))
        }
    }

    // MARK: Settings and sessions

    static func storedSettings() -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: settingsDefaultsKey),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }

    private static func storeSettings(_ values: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        UserDefaults.standard.set(data, forKey: settingsDefaultsKey)
    }

    /// VaporView's saved session next to a local dump: `<name>.json` beside `<name>.vcd`.
    private static func siblingSessionFile(for fileURL: URL) -> [String: Any]? {
        guard fileURL.isFileURL else { return nil }
        let sessionURL = fileURL.deletingPathExtension().appendingPathExtension("json")
        guard let size = try? sessionURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maxSessionFileSize,
              let text = try? String(contentsOf: sessionURL, encoding: .utf8) else { return nil }
        return ["path": sessionURL.path, "text": text]
    }

    private func saveSession(text: String, suggestedName: String, path: String?) {
        if let path {
            writeSession(text: text, to: URL(fileURLWithPath: path))
            return
        }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = suggestedName
        if let fileURL, fileURL.isFileURL {
            savePanel.directoryURL = fileURL.deletingLastPathComponent()
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = savePanel.url else { return }
            self.writeSession(text: text, to: url)
        }
        if let window = webView?.window {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(savePanel.runModal())
        }
    }

    private func writeSession(text: String, to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            evaluate(function: "sessionSaved", argument: ["path": url.path])
        } catch {
            evaluate(function: "sessionFailed", argument: ["message": error.localizedDescription])
        }
    }

    private func loadSession() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        if let fileURL, fileURL.isFileURL {
            openPanel.directoryURL = fileURL.deletingLastPathComponent()
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = openPanel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                self.evaluate(function: "applySessionFile", argument: ["text": text, "path": url.path])
            } catch {
                self.evaluate(function: "applySessionFile", argument: ["path": url.path, "error": error.localizedDescription])
            }
        }
        if let window = webView?.window {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    // MARK: Remote FSDB

    /// Where a remote FSDB preview lives: its path on the host and the workspace's SSH route.
    struct RemoteFSDB {
        let remotePath: String
        let host: String
        let sshArguments: WaveformFSDBHelper.SSHArguments

        @MainActor
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
            // Managed file transfer off: no upload of the helper, no waveform data back.
            guard !ManagedFileTransferPolicy.isDisabled else {
                return WaveformSchemeResponse.fsdbError(ManagedFileTransferPolicy.refusalError().localizedDescription)
            }
            return await helper.response(for: body) { error in Self.fsdbFailureMessage(error, host: host) }
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
    nonisolated static func fsdbFailureMessage(_ error: Error, host: String) -> String {
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
        case .connectionFailed(let output)?:
            detail = output
            summary = String(
                localized: "filePreview.waveform.fsdbConnectionFailed",
                defaultValue: "cmux could not connect to %@ to start the FSDB reader."
            )
        case .timedOut(let output)?:
            detail = output
            summary = String(
                localized: "filePreview.waveform.fsdbTimedOut",
                defaultValue: "The FSDB reader on %@ did not respond in time."
            )
        case .protocolError?:
            summary = String(
                localized: "filePreview.waveform.fsdbProtocolError",
                defaultValue: "The FSDB reader on %@ sent output cmux could not read."
            )
        case .helperExited(let output)?:
            detail = output
            summary = String(
                localized: "filePreview.waveform.fsdbHelperExited",
                defaultValue: "The connection to the FSDB reader on %@ ended. Reload to try again."
            )
        case .stopped?, .notInstalled?:
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

    /// Calls `window.cmuxWaveform.link.<function>(argument)` and returns its
    /// (awaited) result; nil when the page is not ready, the call threw, or it returned null.
    func callLink(_ function: String, argument: Any? = nil) async -> Any? {
        guard let webView, isPageReady else { return nil }
        var arguments: [String: Any] = [:]
        if let argument { arguments["argument"] = argument }
        let body = "const link = window.cmuxWaveform && window.cmuxWaveform.link;\n"
            + "return link ? await link.\(function)(\(argument == nil ? "" : "argument")) : null;"
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
            return result is NSNull ? nil : result
        } catch {
            return nil
        }
    }

    private func evaluate(function: String, argument: [String: Any]) {
        guard let webView,
              JSONSerialization.isValidJSONObject(argument),
              let data = try? JSONSerialization.data(withJSONObject: argument),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxWaveform && window.cmuxWaveform.\(function)(\(json))", completionHandler: nil)
    }

    private static func localizedStrings() -> [String: String] {
        WaveformViewerStrings.all().merging([
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
        ]) { _, new in new }
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
        // Only the bundled page's main frame talks to cmux.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              origin.protocol == WaveformViewerSchemeHandler.scheme,
              origin.host == WaveformViewerSchemeHandler.host,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            // Once per page load: a repeated ready would restart the FSDB helper.
            guard !isPageReady else { return }
            isPageReady = true
            openFileInPage()
        case "opened":
            webContentProcessRecoveryAttempts = 0
            topScopes = body["top"] as? [String] ?? []
            if let panel { WaveformSourceLink.waveformOpened(panel) }
        case "signalData":
            if let panel { WaveformSourceLink.waveformDataArrived(panel) }
        case "revealInSource":
            if let path = WaveformSourceLink.dumpPath(fromPage: body["path"]), let panel {
                WaveformSourceLink.revealInSource(dumpPath: path, waveformPanel: panel)
            }
        case "event":
            // VaporView's API events; the marker drives the SV editor's inline values.
            if body["eventType"] as? String == "markerSet", let panel {
                let time = (body["eventData"] as? [String: Any])?["time"] as? NSNumber
                WaveformSourceLink.markerMoved(in: panel, time: time?.int64Value)
            }
        case "settings":
            if let values = body["values"] as? [String: Any] {
                Self.storeSettings(values)
            }
        case "sessionState":
            if let state = body["state"] {
                var restore: [String: Any] = ["state": state, "dirty": body["dirty"] as? Bool ?? false]
                restore["sessionPath"] = body["sessionPath"] as? String
                restoreState = restore
            }
        case "saveSession":
            if let text = body["text"] as? String {
                saveSession(
                    text: text,
                    suggestedName: body["suggestedName"] as? String ?? "untitled.json",
                    path: body["path"] as? String
                )
            }
        case "loadSession":
            loadSession()
        case "reload":
            reloadFileInPage()
        case "openURL":
            if let string = body["url"] as? String, let url = URL(string: string),
               url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
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

/// The keys VaporView binds in its viewer (`KEYBINDINGS` in
/// `Resources/vaporview/cmux-commands.js`, from VaporView's package.json):
/// while the waveform page has focus, cmux lets these through to it instead of
/// running its own shortcut for the same key (rename tab on ⌘R, find on ⌘F,
/// save on ⌘S, zoom reset on ⌘0).
@MainActor
enum WaveformViewerShortcuts {
    static func claims(_ event: NSEvent, editableElementFocused: Bool) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let key = KeyboardLayout.normalizedCharacters(for: event)
        switch flags {
        case [.command]:
            return ["r", "f", "s", "0", "z"].contains(key)
        case [.command, .shift]:
            return key == "z"
        case [.option]:
            // Equal, Minus, keypad plus and minus: ⌥ changes the characters.
            return !editableElementFocused && [24, 27, 69, 78].contains(event.keyCode)
        case []:
            // F2 renames; g groups; 1–8 pick a color.
            return !editableElementFocused
                && (event.keyCode == 120 || key == "g" || ["1", "2", "3", "4", "5", "6", "7", "8"].contains(key))
        default:
            return false
        }
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
