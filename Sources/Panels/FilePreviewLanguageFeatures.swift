import AppKit
import Bonsplit
import CmuxCore
import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let filePreviewLanguageLogger = Logger(subsystem: "com.cmuxterm.app", category: "FilePreviewLanguage")

/// Language-server features for one File Preview text view: lint underlines,
/// hover, go to definition, find references, completion and format on save.
///
/// Only SystemVerilog/Verilog documents get one. Every server call is async
/// and best effort: when the server is missing or fails, the editor behaves
/// exactly as it does without this object.
@MainActor
final class FilePreviewLanguageFeatures: NSObject {
    static let formatOnSaveDefaultsKey = "fileEditor.formatOnSave.verilog"
    private static let languageId = "verilog"
    private static let changeDebounce: Duration = .milliseconds(300)
    private static let hoverDelay: Duration = .milliseconds(500)
    private static let completionDebounce: Duration = .milliseconds(250)
    private static let formatTimeout: TimeInterval = 5
    private static let minimumAutomaticCompletionPrefix = 2
    private static let remotePreviewCache = CloudFilePreviewCache()
    private static var loggedFailures: Set<String> = []

    let filePath: String
    private weak var textView: SavingTextView?
    private var context: FilePreviewLanguageDocumentContext?
    private var session: LanguageServerSession?
    private var documentURI: URL?
    private var documentVersion = 0
    private var lastSentText: String?
    private var isUnavailable = false
    private var isDetached = false
    private var lastTextLength = 0
    private var diagnostics: [LSPDiagnostic] = []
    private var trackingArea: NSTrackingArea?
    private var hoverPopover: NSPopover?
    private var hoverCharacterRange: NSRange?
    private var contextMenuCharacterIndex: Int?
    private var referenceLocations: [LSPLocation] = []
    private var completionWords: [String]?
    private var completionAnchor: Int?
    private var isShowingCompletion = false
    private var isWritingFormattedSave = false
    private var startTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var formatTask: Task<Void, Never>?

    private init(filePath: String, textView: SavingTextView) {
        self.filePath = filePath
        self.textView = textView
        super.init()
        installTrackingArea()
    }

    deinit {
        startTask?.cancel()
        changeTask?.cancel()
        diagnosticsTask?.cancel()
        hoverTask?.cancel()
        requestTask?.cancel()
        completionTask?.cancel()
        if let session, let documentURI {
            Task { await session.close(uri: documentURI) }
        }
    }

    static func isSupported(filePath: String) -> Bool {
        LanguageCatalog().language(for: URL(fileURLWithPath: filePath)) == languageId
    }

    static var isFormatOnSaveEnabled: Bool {
        UserDefaults.standard.object(forKey: formatOnSaveDefaultsKey) as? Bool ?? true
    }

    /// Keeps `textView.languageFeatures` matched to the file the editor shows.
    static func sync(_ textView: SavingTextView, filePath: String) {
        if let existing = textView.languageFeatures, existing.filePath == filePath { return }
        textView.languageFeatures?.detach()
        textView.languageFeatures = nil
        guard isSupported(filePath: filePath) else { return }
        let features = FilePreviewLanguageFeatures(filePath: filePath, textView: textView)
        textView.languageFeatures = features
        features.textDidChange(isUserEdit: false)
    }

    /// Ends the server document and removes everything drawn on the text view.
    func detach() {
        isDetached = true
        startTask?.cancel()
        changeTask?.cancel()
        diagnosticsTask?.cancel()
        hoverTask?.cancel()
        requestTask?.cancel()
        completionTask?.cancel()
        hideHover()
        if let textView {
            if let trackingArea { textView.removeTrackingArea(trackingArea) }
            removeDiagnosticAttributes(in: textView)
        }
        trackingArea = nil
        if let session, let documentURI {
            Task { await session.close(uri: documentURI) }
        }
        session = nil
        documentURI = nil
    }

    // MARK: - Document sync

    /// Call after every buffer change, typed or loaded from disk.
    func textDidChange(isUserEdit: Bool) {
        guard !isDetached, let textView else { return }
        hideHover()
        let length = textView.textStorage?.length ?? 0
        let grewByOneCharacter = length == lastTextLength + 1
        lastTextLength = length
        if !isUserEdit {
            // A reload replaces the storage and its temporary attributes.
            renderDiagnostics()
        }
        guard !isUnavailable else { return }
        if startTask == nil {
            // Wait for the loaded text: a remote preview's route is attached
            // to its panel only after the panel is created.
            guard length > 0 else { return }
            startTask = Task { [weak self] in
                await self?.startSession()
            }
            return
        }
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            await self?.sendCurrentText()
        }
        if isUserEdit, grewByOneCharacter {
            scheduleAutomaticCompletion()
        }
    }

    func documentDidSave(_ text: String) {
        guard let session, let documentURI else { return }
        Task { await session.save(uri: documentURI, text: text) }
    }

    private func startSession() async {
        guard let textView,
              let context = FilePreviewLanguageDocumentContext.resolve(
                  languageId: Self.languageId,
                  panel: textView.panel as? FilePreviewPanel,
                  filePath: filePath
              ) else {
            isUnavailable = true
            Self.logOnce(key: "unresolved", "no language server for verilog documents")
            return
        }
        self.context = context
        let session: LanguageServerSession
        do {
            session = try await LanguageServerPool.shared.session(
                launch: context.serverLaunch,
                rootURI: context.rootURI,
                languageId: Self.languageId
            )
        } catch {
            isUnavailable = true
            Self.logOnce(key: "server:\(context.serverLaunch)", "language server unavailable: \(error)")
            return
        }
        guard !Task.isCancelled, !isDetached, let text = self.textView?.string else { return }
        self.session = session
        documentURI = context.documentURI
        // Subscribe before opening so the first publish is not missed.
        let updates = await session.diagnosticsUpdates()
        let documentPath = context.documentURI.standardizedFileURL.path
        diagnosticsTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard update.uri.standardizedFileURL.path == documentPath else { continue }
                self?.applyDiagnostics(update.diagnostics)
            }
        }
        documentVersion = 1
        lastSentText = text
        await session.open(uri: context.documentURI, text: text, version: documentVersion)
        // Edits made while the server was starting.
        await sendCurrentText()
    }

    private func sendCurrentText() async {
        guard let session, let documentURI, let text = textView?.string, text != lastSentText else { return }
        documentVersion += 1
        lastSentText = text
        await session.change(uri: documentURI, text: text, version: documentVersion)
    }

    /// The pool restarts a dead server in place and re-opens its documents.
    private func recoverSessionIfStopped(after error: Error) {
        guard let serverError = error as? LanguageServerError, let context, !isDetached else { return }
        switch serverError {
        case .notRunning, .processExited:
            Task {
                _ = try? await LanguageServerPool.shared.session(
                    launch: context.serverLaunch,
                    rootURI: context.rootURI,
                    languageId: Self.languageId
                )
            }
        default:
            break
        }
    }

    private static func logOnce(key: String, _ message: String) {
        guard loggedFailures.insert(key).inserted else { return }
        filePreviewLanguageLogger.error("\(message, privacy: .public)")
    }

    // MARK: - Diagnostics

    private func applyDiagnostics(_ next: [LSPDiagnostic]) {
        guard !isDetached else { return }
        diagnostics = next
        renderDiagnostics()
    }

    private func renderDiagnostics() {
        guard let textView, let layoutManager = textView.layoutManager,
              let storage = textView.textStorage else { return }
        removeDiagnosticAttributes(in: textView)
        guard !diagnostics.isEmpty, storage.length > 0 else { return }
        let text = storage.string as NSString
        let lineIndex = FilePreviewLSPLineIndex(storage.string)
        // Less severe first, so an error wins where ranges overlap.
        for diagnostic in diagnostics.sorted(by: { $0.severity.rawValue > $1.severity.rawValue }) {
            let range = lineIndex.underlineRange(for: diagnostic.range, in: text)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttributes(
                Self.underlineAttributes(for: diagnostic.severity),
                forCharacterRange: range
            )
        }
    }

    private func removeDiagnosticAttributes(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length, length > 0 else { return }
        let full = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
    }

    private static func underlineAttributes(for severity: LSPDiagnosticSeverity) -> [NSAttributedString.Key: Any] {
        let style: NSUnderlineStyle
        let color: NSColor
        switch severity {
        case .error:
            style = [.thick, .patternDot]
            color = .systemRed
        case .warning:
            style = [.thick, .patternDot]
            color = .systemOrange
        case .information, .hint:
            style = [.single, .patternDot]
            color = .tertiaryLabelColor
        }
        return [.underlineStyle: style.rawValue, .underlineColor: color]
    }

    // MARK: - Hover

    private func installTrackingArea() {
        guard let textView else { return }
        if let trackingArea, textView.trackingAreas.contains(trackingArea) { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: textView,
            userInfo: nil
        )
        textView.addTrackingArea(area)
        trackingArea = area
    }

    func updateTrackingAreas() {
        guard !isDetached else { return }
        installTrackingArea()
    }

    func mouseMoved(_ event: NSEvent) {
        guard !isDetached else { return }
        let index = characterIndex(for: event)
        if let index, let hoverCharacterRange, NSLocationInRange(index, hoverCharacterRange) { return }
        hideHover()
        guard let index else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            await self?.showHover(at: index)
        }
    }

    func mouseExited(_ event: NSEvent) {
        // Moving into the popover itself keeps it open.
        if let window = hoverPopover?.contentViewController?.view.window,
           window.frame.contains(NSEvent.mouseLocation) {
            return
        }
        hideHover()
    }

    func hideHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverCharacterRange = nil
        if let hoverPopover {
            self.hoverPopover = nil
            hoverPopover.close()
        }
    }

    private func showHover(at index: Int) async {
        guard let textView, textView.window != nil, let storage = textView.textStorage else { return }
        let snapshot = storage.string
        let text = snapshot as NSString
        guard index < text.length else { return }
        let lineIndex = FilePreviewLSPLineIndex(snapshot)
        let messages = diagnostics
            .filter { NSLocationInRange(index, lineIndex.underlineRange(for: $0.range, in: text)) }
            .map(\.message)
        let wordRange = FilePreviewLanguageIdentifier.range(containing: index, in: text)
        var hoverText: String?
        if wordRange != nil, let session, let documentURI {
            do {
                hoverText = try await session.hover(uri: documentURI, position: lineIndex.position(at: index))
            } catch {
                recoverSessionIfStopped(after: error)
            }
        }
        guard !Task.isCancelled, let textView = self.textView,
              textView.textStorage?.string == snapshot else { return }
        var sections = messages
        if let hoverText = hoverText?.trimmingCharacters(in: .whitespacesAndNewlines), !hoverText.isEmpty {
            sections.append(hoverText)
        }
        guard !sections.isEmpty else { return }
        let anchor = wordRange ?? NSRange(location: index, length: 1)
        guard let rect = viewRect(forCharacterRange: anchor) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = FilePreviewLanguageHoverViewController(sections: sections)
        hoverPopover?.close()
        hoverPopover = popover
        hoverCharacterRange = anchor
        let window = textView.window
        let wasKey = window?.isKeyWindow == true
        popover.show(relativeTo: rect, of: textView, preferredEdge: .minY)
        // Hover never takes typing focus from the editor.
        if wasKey, window?.isKeyWindow == false {
            window?.makeKey()
        }
    }

    // MARK: - Navigation

    /// Cmd-click on an identifier goes to its definition.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard !isDetached, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let textView, let storage = textView.textStorage,
              let index = characterIndex(for: event),
              FilePreviewLanguageIdentifier.range(containing: index, in: storage.string as NSString) != nil else {
            return false
        }
        hideHover()
        textView.setSelectedRange(NSRange(location: index, length: 0))
        goToDefinition(at: index)
        return true
    }

    /// F12, Shift-F12 and Ctrl-Space.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !isDetached, let textView else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           scalar.value == UInt32(NSF12FunctionKey) {
            let location = textView.selectedRange().location
            if flags.isEmpty {
                goToDefinition(at: location)
                return true
            }
            if flags == .shift {
                findReferences(at: location)
                return true
            }
            return false
        }
        if event.keyCode == 49, flags == .control {
            requestCompletion(isExplicit: true)
            return true
        }
        return false
    }

    func addContextMenuItems(to menu: NSMenu, for event: NSEvent) {
        guard !isDetached else { return }
        contextMenuCharacterIndex = characterIndex(for: event)
        let f12 = String(Character(UnicodeScalar(UInt16(NSF12FunctionKey))!))
        let definition = NSMenuItem(
            title: String(localized: "filePreview.language.goToDefinition", defaultValue: "Go to Definition"),
            action: #selector(goToDefinitionFromMenu(_:)),
            keyEquivalent: f12
        )
        definition.keyEquivalentModifierMask = []
        definition.target = self
        let references = NSMenuItem(
            title: String(localized: "filePreview.language.findReferences", defaultValue: "Find References"),
            action: #selector(findReferencesFromMenu(_:)),
            keyEquivalent: f12
        )
        references.keyEquivalentModifierMask = [.shift]
        references.target = self
        menu.insertItem(definition, at: 0)
        menu.insertItem(references, at: 1)
        menu.insertItem(.separator(), at: 2)
    }

    @objc private func goToDefinitionFromMenu(_ sender: Any?) {
        guard let textView else { return }
        goToDefinition(at: contextMenuCharacterIndex ?? textView.selectedRange().location)
    }

    @objc private func findReferencesFromMenu(_ sender: Any?) {
        guard let textView else { return }
        findReferences(at: contextMenuCharacterIndex ?? textView.selectedRange().location)
    }

    private func goToDefinition(at index: Int) {
        guard let session, let documentURI, let textView else {
            NSSound.beep()
            return
        }
        let position = FilePreviewLSPLineIndex(textView.string).position(at: index)
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            let locations: [LSPLocation]
            do {
                locations = try await session.definition(uri: documentURI, position: position)
            } catch {
                filePreviewLanguageLogger.error("definition failed: \(String(describing: error), privacy: .public)")
                self?.recoverSessionIfStopped(after: error)
                locations = []
            }
            guard !Task.isCancelled, let self else { return }
            guard let location = locations.first else {
                NSSound.beep()
                return
            }
            self.navigate(to: location)
        }
    }

    private func findReferences(at index: Int) {
        guard let session, let documentURI, let textView else {
            NSSound.beep()
            return
        }
        let position = FilePreviewLSPLineIndex(textView.string).position(at: index)
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            let locations: [LSPLocation]
            do {
                locations = try await session.references(uri: documentURI, position: position, includeDeclaration: true)
            } catch {
                filePreviewLanguageLogger.error("references failed: \(String(describing: error), privacy: .public)")
                self?.recoverSessionIfStopped(after: error)
                locations = []
            }
            guard !Task.isCancelled, let self else { return }
            self.presentReferences(locations, anchoredAt: index)
        }
    }

    private func presentReferences(_ locations: [LSPLocation], anchoredAt index: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        guard !locations.isEmpty else {
            NSSound.beep()
            return
        }
        referenceLocations = locations
        let menu = NSMenu(title: String(localized: "filePreview.language.references", defaultValue: "References"))
        menu.autoenablesItems = false
        let currentPath = context?.documentURI.standardizedFileURL.path
        let text = storage.string as NSString
        let lineIndex = FilePreviewLSPLineIndex(storage.string)
        for (offset, location) in locations.enumerated() {
            let path = location.uri.standardizedFileURL.path
            var title = "\(displayPath(path)):\(location.range.start.line + 1)"
            if path == currentPath {
                let start = lineIndex.offset(for: LSPPosition(line: location.range.start.line, character: 0))
                let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
                let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { title += "  " + String(line.prefix(80)) }
            }
            let item = NSMenuItem(title: title, action: #selector(openReference(_:)), keyEquivalent: "")
            item.target = self
            item.tag = offset
            menu.addItem(item)
        }
        let anchor = viewRect(forCharacterRange: NSRange(location: index, length: 0))
            ?? NSRect(origin: .zero, size: .zero)
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.maxY), in: textView)
    }

    @objc private func openReference(_ sender: NSMenuItem) {
        guard referenceLocations.indices.contains(sender.tag) else { return }
        navigate(to: referenceLocations[sender.tag])
    }

    private func displayPath(_ path: String) -> String {
        if let root = context?.rootURI?.standardizedFileURL.path {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return (path as NSString).lastPathComponent
    }

    private func navigate(to location: LSPLocation) {
        guard let textView, let context else { return }
        let targetPath = location.uri.standardizedFileURL.path
        if targetPath == context.documentURI.standardizedFileURL.path {
            Self.select(location.range, in: textView)
            return
        }
        guard let panel = textView.panel as? FilePreviewPanel,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceId),
              let paneId = workspace.paneId(forPanelId: panel.id)
                ?? workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return }
        if let remote = context.remote {
            openRemoteDocument(path: targetPath, range: location.range, workspace: workspace, paneId: paneId, remote: remote)
            return
        }
        guard let target = workspace.openOrFocusFilePreviewSurface(inPane: paneId, filePath: targetPath, focus: true) else {
            return
        }
        Self.selectWhenLoaded(location.range, in: target)
    }

    /// Opens another remote file the way the Files explorer does: a
    /// read-only preview of a downloaded copy, reused when already open.
    private func openRemoteDocument(
        path: String,
        range: LSPRange,
        workspace: Workspace,
        paneId: PaneID,
        remote: FilePreviewLanguageDocumentContext.RemoteRoute
    ) {
        if let existing = workspace.panels.values
            .compactMap({ $0 as? FilePreviewPanel })
            .first(where: {
                !$0.isClosed &&
                    $0.cloudPreviewRemotePath == path &&
                    $0.cloudPreviewProviderIdentity == remote.providerIdentity
            }) {
            _ = workspace.openOrFocusFilePreviewSurface(inPane: paneId, filePath: existing.filePath, focus: true)
            Self.selectWhenLoaded(range, in: existing)
            return
        }
        let configuration = remote.configuration
        let provider = SSHFileExplorerProvider(
            destination: configuration.destination,
            port: configuration.port,
            identityFile: configuration.identityFile,
            sshOptions: configuration.fileOperationSSHOptions,
            displayTarget: configuration.displayTarget,
            homePath: "",
            isAvailable: true
        )
        Task { [weak workspace] in
            do {
                let lease = try await Self.remotePreviewCache.materialize(path: path, provider: provider)
                guard let workspace,
                      let panel = workspace.openFilePreviewSurfaces(
                          inPane: paneId,
                          filePaths: [lease.url.path],
                          focus: true,
                          reuseExisting: false
                      ).first else { return }
                panel.cloudPreviewLease = lease
                Self.selectWhenLoaded(range, in: panel)
            } catch is CancellationError {
                return
            } catch {
                filePreviewLanguageLogger.error("remote definition download failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
            }
        }
    }

    private static func select(_ range: LSPRange, in textView: NSTextView) {
        let target = FilePreviewLSPLineIndex(textView.string).characterRange(for: range)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        if target.length > 0 {
            textView.showFindIndicator(for: target)
        }
    }

    /// A freshly opened panel loads its text asynchronously; wait for it.
    private static func selectWhenLoaded(_ range: LSPRange, in panel: FilePreviewPanel) {
        Task { @MainActor [weak panel] in
            for _ in 0..<100 {
                guard let panel, !panel.isClosed else { return }
                if let textView = panel.textView, !panel.textContent.isEmpty, textView.string == panel.textContent {
                    select(range, in: textView)
                    textView.window?.makeFirstResponder(textView)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Completion

    private func scheduleAutomaticCompletion() {
        guard let textView, textView.isEditable,
              textView.window?.firstResponder === textView,
              let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        let text = storage.string as NSString
        let word = FilePreviewLanguageIdentifier.range(endingAt: selection.location, in: text)
        if isShowingCompletion {
            // The list is still tracking this word; a different word means it closed.
            guard word.location != completionAnchor else { return }
            completionDidFinish()
        }
        guard word.length >= Self.minimumAutomaticCompletionPrefix else { return }
        // Skip numbers and based literals such as `8'hFF`.
        let first = text.character(at: word.location)
        if (0x30...0x39).contains(first) { return }
        if word.location > 0, text.character(at: word.location - 1) == 0x27 { return }
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.completionDebounce)
            guard !Task.isCancelled else { return }
            self?.requestCompletion(isExplicit: false)
        }
    }

    private func requestCompletion(isExplicit: Bool) {
        // Local only: remote slang-server builds can hang on completion.
        guard context?.remote == nil,
              let session, let documentURI, let textView, textView.isEditable else {
            if isExplicit { NSSound.beep() }
            return
        }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return }
        if isExplicit { completionDidFinish() }
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            // The server must see the text being completed.
            await self?.sendCurrentText()
            guard !Task.isCancelled, let self, let text = self.textView?.string else { return }
            let position = FilePreviewLSPLineIndex(text).position(at: selection.location)
            let items: [LSPCompletionItem]
            do {
                items = try await session.completion(uri: documentURI, position: position)
            } catch {
                filePreviewLanguageLogger.error("completion failed: \(String(describing: error), privacy: .public)")
                self.recoverSessionIfStopped(after: error)
                items = []
            }
            guard !Task.isCancelled, let textView = self.textView,
                  textView.string == text, textView.selectedRange() == selection else { return }
            self.presentCompletions(items, isExplicit: isExplicit)
        }
    }

    private func presentCompletions(_ items: [LSPCompletionItem], isExplicit: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        let partial = FilePreviewLanguageIdentifier.range(endingAt: textView.selectedRange().location, in: text)
        let prefix = text.substring(with: partial)
        var seen: Set<String> = []
        let words = items.map(Self.completionText).filter { word in
            !word.isEmpty && Self.word(word, matches: prefix) && seen.insert(word).inserted
        }
        guard !words.isEmpty else {
            if isExplicit { NSSound.beep() }
            return
        }
        if !isExplicit, words == [prefix] { return }
        completionWords = words
        completionAnchor = partial.location
        isShowingCompletion = true
        textView.complete(nil)
    }

    /// Plain insert text: snippet placeholders (`$1`, `${1:x}`) fall back to the label.
    private static func completionText(_ item: LSPCompletionItem) -> String {
        if let insertText = item.insertText, !insertText.isEmpty,
           insertText.range(of: #"\$\{?[0-9]"#, options: .regularExpression) == nil {
            return insertText
        }
        return item.label
    }

    private static func word(_ word: String, matches prefix: String) -> Bool {
        prefix.isEmpty || word.lowercased().hasPrefix(prefix.lowercased())
    }

    /// The identifier being completed, including SystemVerilog's `$`.
    var userCompletionRange: NSRange? {
        guard !isDetached, completionWords != nil, let textView, let storage = textView.textStorage else { return nil }
        return FilePreviewLanguageIdentifier.range(endingAt: textView.selectedRange().location, in: storage.string as NSString)
    }

    /// Server items for `complete(_:)`; nil defers to NSTextView's own list.
    func completions(forPartialWordRange range: NSRange) -> [String]? {
        guard let completionWords, completionAnchor == range.location,
              let storage = textView?.textStorage,
              NSMaxRange(range) <= storage.length else { return nil }
        let prefix = (storage.string as NSString).substring(with: range)
        return completionWords.filter { Self.word($0, matches: prefix) }
    }

    func completionDidFinish() {
        completionWords = nil
        completionAnchor = nil
        isShowingCompletion = false
    }

    // MARK: - Format on save

    /// Formats the buffer, then runs `save`. Returns nil when `save` should
    /// run directly: formatting is off, unavailable, or this is that save.
    func formatThenSave(_ save: @escaping @MainActor () -> Task<Void, Never>?) -> Task<Void, Never>? {
        if isWritingFormattedSave || isDetached { return nil }
        if let formatTask { return formatTask }
        guard Self.isFormatOnSaveEnabled, let textView, textView.isEditable,
              let launch = LanguageToolRegistry.formatter(forLanguage: Self.languageId, remoteDestination: nil) else {
            return nil
        }
        let original = textView.string
        let task = Task { [weak self] in
            var formatted: String?
            do {
                formatted = try await SourceFormatter.format(original, using: launch, timeout: Self.formatTimeout)
            } catch {
                filePreviewLanguageLogger.error("format on save failed: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            if let formatted, self.textView?.string == original {
                self.replaceBuffer(with: formatted)
            }
            self.formatTask = nil
            self.isWritingFormattedSave = true
            let saveTask = save()
            self.isWritingFormattedSave = false
            await saveTask?.value
        }
        formatTask = task
        return task
    }

    /// Replaces the whole buffer as one undoable edit, keeping the caret's line and column.
    private func replaceBuffer(with formatted: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let current = storage.string
        guard formatted != current else { return }
        let caret = FilePreviewLSPLineIndex(current).position(at: textView.selectedRange().location)
        let full = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: full, replacementString: formatted) else { return }
        let clipView = textView.enclosingScrollView?.contentView
        let visibleOrigin = clipView?.bounds.origin
        storage.replaceCharacters(in: full, with: formatted)
        textView.didChangeText()
        textView.undoManager?.setActionName(
            String(localized: "filePreview.language.formatUndo", defaultValue: "Format Document")
        )
        let location = FilePreviewLSPLineIndex(formatted).offset(for: caret)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if let clipView, let visibleOrigin, let scrollView = textView.enclosingScrollView {
            let constrained = clipView.constrainBoundsRect(NSRect(origin: visibleOrigin, size: clipView.bounds.size))
            clipView.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    // MARK: - Geometry

    private func characterIndex(for event: NSEvent) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < length ? index : nil
    }

    private func viewRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        if rect.width < 1 { rect.size.width = 1 }
        return rect
    }
}
