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
    /// Local completion server for a remote document.
    private var completionMirror: LanguageCompletionMirror?
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
    /// The waveform link's message, kept apart from hover so moving the mouse does not close it.
    private var linkMessagePopover: NSPopover?
    private var linkMessageShownAt = Date.distantPast
    private var linkMessageIsProgress = false
    /// Closes the link message once the editor is hidden or loses focus (a tab or pane switch).
    private var linkMessageWatch: Task<Void, Never>?
    /// What had focus in the editor's window when the message was shown.
    private weak var linkMessageResponder: NSResponder?
    /// A link message stays up at least this long against clicks and typing; Esc closes it at once.
    private static let linkMessageMinimumDuration: TimeInterval = 8
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
    /// Add to Waveform; separate from `requestTask` so it and go-to-definition don't cancel each other.
    private var linkTask: Task<Void, Never>?
    /// Waveform values drawn after the visible lines, at the waveform's marker.
    private var inlineValueTask: Task<Void, Never>?
    private var inlineValueOverlay: FilePreviewInlineValueOverlay?
    /// Per module of this file: slang's design instances of it, and when to ask again while it has none.
    private var inlineModuleInstances: [String: InlineModuleInstances] = [:]
    /// Instances signals were last added to the waveform from (design path, dump path), newest first.
    private var linkedInstances: [(design: String, dump: String)] = []
    /// Per module: the dump instance picked with Show Waveform Values For.
    private var inlineInstanceChoices: [String: String] = [:]
    /// Per module: the dump instances its values could come from, as of the last refresh.
    private var inlineInstanceCandidates: [String: [String]] = [:]
    private var inlineScrollObserver: NSObjectProtocol?
    private var inlineFrameObserver: NSObjectProtocol?
    private var inlineEditObserver: NSObjectProtocol?
    /// The text as the inline values' scanner last read it, with its checkpoints.
    private var inlineScan = SystemVerilogInlineScan.Cache()
    /// Where the text changed since the scanner last read it (nil: it has not).
    private var inlineScanEditedFrom: Int? = 0
    /// Counts text changes, so a scan or refresh that outlived one is dropped.
    private var inlineTextGeneration = 0
    private var completionTask: Task<Void, Never>?
    private var formatTask: Task<Void, Never>?

    /// Every attached instance, for the waveform link's lookup of a workspace's language server.
    private static let liveInstances = NSHashTable<FilePreviewLanguageFeatures>.weakObjects()
    /// When the user last clicked or typed in this editor.
    private(set) var lastActivity = Date.distantPast

    private init(filePath: String, textView: SavingTextView) {
        self.filePath = filePath
        self.textView = textView
        super.init()
        installTrackingArea()
        Self.liveInstances.add(self)
    }

    deinit {
        startTask?.cancel()
        changeTask?.cancel()
        diagnosticsTask?.cancel()
        hoverTask?.cancel()
        requestTask?.cancel()
        linkTask?.cancel()
        completionTask?.cancel()
        if let session, let documentURI {
            Task { await session.close(uri: documentURI) }
        }
        if let completionMirror {
            Task { await completionMirror.shutdown() }
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
        Self.liveInstances.remove(self)
        startTask?.cancel()
        changeTask?.cancel()
        diagnosticsTask?.cancel()
        hoverTask?.cancel()
        requestTask?.cancel()
        linkTask?.cancel()
        completionTask?.cancel()
        clearInlineValues()
        closeLinkMessage()
        inlineValueOverlay?.removeFromSuperview()
        inlineValueOverlay = nil
        for observer in [inlineScrollObserver, inlineFrameObserver, inlineEditObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        inlineScrollObserver = nil
        inlineFrameObserver = nil
        inlineEditObserver = nil
        inlineScan = SystemVerilogInlineScan.Cache()
        hideHover()
        if let textView {
            if let trackingArea { textView.removeTrackingArea(trackingArea) }
            removeDiagnosticAttributes(in: textView)
        }
        trackingArea = nil
        if let session, let documentURI {
            Task { await session.close(uri: documentURI) }
        }
        if let completionMirror {
            Task { await completionMirror.shutdown() }
        }
        session = nil
        documentURI = nil
        completionMirror = nil
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
            textChangedForInlineValues(from: 0)
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
        // Edits move the lines the values were drawn after, and may change what a module declares.
        inlineModuleInstances = [:]
        if inlineValueOverlay != nil {
            clearInlineValues()
            scheduleInlineValues(after: .milliseconds(600))
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
        if let remote = context.remote {
            await startCompletionMirror(documentURI: context.documentURI, remote: remote)
        }
        let session: LanguageServerSession
        do {
            session = try await LanguageServerPool.shared.session(
                launch: context.serverLaunch,
                rootURI: context.rootURI,
                languageId: Self.languageId
            )
        } catch {
            // Keep feeding the local completion server.
            isUnavailable = completionMirror == nil
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

    /// Remote slang-server builds can hang on completion, so a remote document
    /// completes from a local server fed only this buffer.
    private func startCompletionMirror(
        documentURI: URL,
        remote: FilePreviewLanguageDocumentContext.RemoteRoute
    ) async {
        guard let launch = LanguageToolRegistry.languageServer(forLanguage: Self.languageId, remoteDestination: nil),
              let text = textView?.string else { return }
        let mirror = LanguageCompletionMirror(
            remoteURI: documentURI,
            identity: remote.providerIdentity,
            languageId: Self.languageId,
            launch: launch
        )
        do {
            try await mirror.open(text: text)
        } catch {
            Self.logOnce(key: "completion-mirror", "local completion server unavailable: \(error)")
            await mirror.shutdown()
            return
        }
        guard !Task.isCancelled, !isDetached else {
            await mirror.shutdown()
            return
        }
        completionMirror = mirror
    }

    func sendCurrentText() async {
        guard let text = textView?.string else { return }
        await completionMirror?.change(text: text)
        guard let session, let documentURI, text != lastSentText else { return }
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
        lastActivity = Date()
        linkMessageMayClose()
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
        lastActivity = Date()
        guard !isDetached, let textView else { return false }
        if event.keyCode == 53, linkMessagePopover != nil { // Esc
            closeLinkMessage()
            return true
        }
        linkMessageMayClose()
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
        var separatorIndex = 2
        if canAddToWaveform {
            let addToWaveform = NSMenuItem(
                title: String(localized: "filePreview.language.addToWaveform", defaultValue: "Add to Waveform"),
                action: #selector(addToWaveformFromMenu(_:)),
                keyEquivalent: ""
            )
            let shortcut = KeyboardShortcutSettings.shortcut(for: .addSignalToWaveform)
            if let key = shortcut.menuItemKeyEquivalent {
                addToWaveform.keyEquivalent = key
                addToWaveform.keyEquivalentModifierMask = shortcut.modifierFlags
            }
            addToWaveform.target = self
            menu.insertItem(addToWaveform, at: separatorIndex)
            separatorIndex += 1
            let addScope = NSMenuItem(
                title: String(localized: "filePreview.language.addScopeToWaveform", defaultValue: "Add All Signals in Scope to Waveform"),
                action: #selector(addScopeToWaveformFromMenu(_:)),
                keyEquivalent: ""
            )
            addScope.target = self
            menu.insertItem(addScope, at: separatorIndex)
            separatorIndex += 1
            if let instances = instanceMenu(at: contextMenuCharacterIndex) {
                menu.insertItem(instances, at: separatorIndex)
                separatorIndex += 1
            }
        }
        for item in compilationMenuItems(at: contextMenuCharacterIndex) {
            menu.insertItem(item, at: separatorIndex)
            separatorIndex += 1
        }
        menu.insertItem(.separator(), at: separatorIndex)
    }

    /// Set as SystemVerilog Top Level on a module, and the undo of what cmux set the server to compile.
    private func compilationMenuItems(at index: Int?) -> [NSMenuItem] {
        guard let textView, let session = linkSession?.session else { return [] }
        var items: [NSMenuItem] = []
        if let index, let declaration = SystemVerilogModuleLocator.declaration(at: index, in: textView.string) {
            let item = NSMenuItem(
                title: String(localized: "filePreview.language.setTopLevel", defaultValue: "Set as SystemVerilog Top Level"),
                action: #selector(setTopLevelFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = declaration.name
            item.toolTip = declaration.name
            items.append(item)
        }
        if WaveformSourceLink.canResetTopLevel(session: session) {
            let item = NSMenuItem(
                title: String(localized: "filePreview.language.resetTopLevel", defaultValue: "Reset Top Level"),
                action: #selector(resetTopLevelFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            items.append(item)
        }
        if case .buildFile? = SlangCompilationActions.target(of: session) {
            let item = NSMenuItem(
                title: String(localized: "slangTop.clearBuildFile", defaultValue: "Clear Build File"),
                action: #selector(clearBuildFileFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            items.append(item)
        }
        return items
    }

    @objc private func setTopLevelFromMenu(_ sender: NSMenuItem) {
        guard let module = sender.representedObject as? String, let textView else { return }
        SlangCompilationActions.setTopLevel(
            module: module,
            editor: self,
            anchor: contextMenuCharacterIndex ?? textView.selectedRange().location
        )
    }

    @objc private func resetTopLevelFromMenu(_ sender: Any?) {
        guard let session = linkSession?.session else { return }
        SlangCompilationActions.resetTopLevel(session: session)
    }

    @objc private func clearBuildFileFromMenu(_ sender: Any?) {
        guard let workspaceId = linkWorkspaceId else { return }
        SlangCompilationActions.clearBuildFile(workspaceId: workspaceId, window: textView?.window)
    }

    /// Show Waveform Values For ▸ the dump instances of the module at `index`, when there are several.
    private func instanceMenu(at index: Int?) -> NSMenuItem? {
        guard let textView, let index else { return nil }
        var scan = syncedInlineScan(of: textView)
        let module = scan.lines(in: NSRange(location: index, length: 0)).first?.module
        inlineScan = scan
        guard let module, let candidates = inlineInstanceCandidates[module], candidates.count > 1 else { return nil }
        let item = NSMenuItem(
            title: String(localized: "filePreview.language.showValuesFor", defaultValue: "Show Waveform Values For"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        let current = chosenDumpInstance(module: module, candidates: candidates)
        for candidate in candidates {
            let entry = NSMenuItem(title: candidate, action: #selector(chooseInlineInstance(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [module, candidate]
            entry.state = candidate == current ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func chooseInlineInstance(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        inlineInstanceChoices[pair[0]] = pair[1]
        scheduleInlineValues(after: .zero)
    }

    @objc private func addToWaveformFromMenu(_ sender: Any?) {
        guard let textView else { return }
        addSignalToWaveform(at: contextMenuCharacterIndex ?? textView.selectedRange().location)
    }

    @objc private func addScopeToWaveformFromMenu(_ sender: Any?) {
        guard let textView else { return }
        addSignalToWaveform(at: contextMenuCharacterIndex ?? textView.selectedRange().location, wholeScope: true)
    }

    /// Adds every signal of the instance at (or around) the caret to the waveform. False when there is no waveform.
    @discardableResult
    func addScopeUnderCaretToWaveform() -> Bool {
        guard canAddToWaveform, let textView else { return false }
        addSignalToWaveform(at: textView.selectedRange().location, wholeScope: true)
        return true
    }

    /// Whether the workspace has a waveform viewer to add signals to. The
    /// add shortcut is claimed only then, so Ctrl-W keeps its AppKit meaning otherwise.
    var canAddToWaveform: Bool {
        !isDetached && WaveformSourceLink.waveformPanel(near: linkPanel) != nil
    }

    /// Adds the signal under the caret to the workspace's waveform viewer. False when there is none.
    @discardableResult
    func addSignalUnderCaretToWaveform() -> Bool {
        guard canAddToWaveform, let textView else { return false }
        addSignalToWaveform(at: textView.selectedRange().location)
        return true
    }

    /// `wholeScope`: the instance's signals rather than the one signal.
    private func addSignalToWaveform(at index: Int, wholeScope: Bool = false) {
        guard let textView else { return }
        guard let session, let documentURI, let storage = textView.textStorage,
              let identifier = FilePreviewLanguageIdentifier.range(containing: index, in: storage.string as NSString)
                ?? FilePreviewLanguageIdentifier.range(containing: index - 1, in: storage.string as NSString) else {
            NSSound.beep()
            return
        }
        let position = FilePreviewLSPLineIndex(textView.string).position(at: identifier.location)
        var scan = syncedInlineScan(of: textView)
        let symbol = WaveformSourceLink.LinkSymbol(
            name: (storage.string as NSString).substring(with: identifier),
            isInModule: scan.lines(in: NSRange(location: identifier.location, length: 0)).first?.module != nil
        )
        inlineScan = scan
        linkTask?.cancel()
        linkTask = Task { [weak self] in
            // The server must see the current text.
            await self?.sendCurrentText()
            guard let self, !Task.isCancelled else { return }
            let chooseInstance: ([String]) async -> [String] = { [weak self] paths in
                await self?.chooseInstance(paths, anchoredAt: identifier.location) ?? []
            }
            let progress: @MainActor @Sendable (String) -> Void = { [weak self] note in
                self?.showLinkMessage(note, at: identifier.location, isProgress: true)
            }
            let message = wholeScope
                ? await WaveformSourceLink.addScope(
                    session: session,
                    documentURI: documentURI,
                    position: position,
                    symbol: symbol,
                    editor: self,
                    rootKey: self.linkRootKey,
                    chooseInstance: chooseInstance,
                    progress: progress
                )
                : await WaveformSourceLink.addSignal(
                    session: session,
                    documentURI: documentURI,
                    position: position,
                    symbol: symbol,
                    editor: self,
                    rootKey: self.linkRootKey,
                    chooseInstance: chooseInstance,
                    progress: progress
                )
            guard !Task.isCancelled else { return }
            guard let message else {
                self.closeLinkProgress()
                return
            }
            self.showLinkMessage(message, at: identifier.location)
        }
    }

    // MARK: - Waveform link support

    /// The language server and document of this editor, once started.
    var linkSession: (session: LanguageServerSession, documentURI: URL)? {
        guard !isDetached, let session, let documentURI else { return nil }
        return (session, documentURI)
    }

    /// Identifies this editor's design for the saved path mapping: the server root, plus the SSH host for remote files.
    var linkRootKey: String {
        let root = context?.rootURI?.standardizedFileURL.path ?? (filePath as NSString).deletingLastPathComponent
        return linkHostIdentity + "|" + root
    }

    /// The panel showing this editor.
    var linkPanel: FilePreviewPanel? {
        textView?.panel as? FilePreviewPanel
    }

    var linkWorkspaceId: UUID? {
        linkPanel?.workspaceId
    }

    /// The SSH host of a remote file, `local` otherwise.
    var linkHostIdentity: String {
        context?.remote?.providerIdentity ?? "local"
    }

    /// Live editors with a language server in `workspaceId`.
    static var allLinkables: [FilePreviewLanguageFeatures] {
        liveInstances.allObjects.filter { $0.linkSession != nil }
    }

    static func linkables(inWorkspace workspaceId: UUID) -> [FilePreviewLanguageFeatures] {
        liveInstances.allObjects.filter { $0.linkWorkspaceId == workspaceId && $0.linkSession != nil }
    }

    /// The most recently used live editor with a language server in `workspaceId`.
    static func mostRecentLinkable(inWorkspace workspaceId: UUID) -> FilePreviewLanguageFeatures? {
        liveInstances.allObjects
            .filter { $0.linkWorkspaceId == workspaceId && $0.linkSession != nil }
            .max { $0.lastActivity < $1.lastActivity }
    }

    /// The live editor whose document is `path` (a remote path for SSH files),
    /// on the same host as `editor`, preferring `editor`'s workspace.
    static func linkable(showingDocumentPath path: String, like editor: FilePreviewLanguageFeatures) -> FilePreviewLanguageFeatures? {
        let matches = liveInstances.allObjects.filter {
            $0.linkHostIdentity == editor.linkHostIdentity && $0.linkSession?.documentURI.standardizedFileURL.path == path
        }
        return matches.first { $0.linkWorkspaceId == editor.linkWorkspaceId } ?? matches.first
    }

    // MARK: - Navigation history

    /// The caret (or selection) as a location, for the navigation history.
    var currentLocation: LSPLocation? {
        guard !isDetached, let textView, let documentURI else { return nil }
        let lineIndex = FilePreviewLSPLineIndex(textView.string)
        let selection = textView.selectedRange()
        return LSPLocation(
            uri: documentURI,
            range: LSPRange(start: lineIndex.position(at: selection.location), end: lineIndex.position(at: NSMaxRange(selection)))
        )
    }

    var canNavigateBack: Bool { linkWorkspaceId.map { FilePreviewNavigationHistory.canGoBack(inWorkspace: $0) } ?? false }
    var canNavigateForward: Bool { linkWorkspaceId.map { FilePreviewNavigationHistory.canGoForward(inWorkspace: $0) } ?? false }

    /// Returns to where the last go-to-source jump in this workspace started. False when there is none.
    @discardableResult
    func navigateBack() -> Bool { FilePreviewNavigationHistory.step(.back, from: self) }

    /// Redoes the jump the last Go Back undid. False when there is none.
    @discardableResult
    func navigateForward() -> Bool { FilePreviewNavigationHistory.step(.forward, from: self) }

    // MARK: - Inline waveform values

    private struct InlineModuleInstances {
        var designInstances: [String]
        var lookedUpAt: Date
        /// Lookups in a row that found none; the next waits longer.
        var misses: Int
    }

    /// Signals were added to the waveform from design instance `design`, dumped as `dump`: values follow it.
    func recordLinkedInstance(design: String, dump: String) {
        linkedInstances.removeAll { $0.design == design && $0.dump == dump }
        linkedInstances.insert((design, dump), at: 0)
        linkedInstances = Array(linkedInstances.prefix(16))
        scheduleInlineValues(after: .milliseconds(120))
    }

    /// The linked waveform's marker moved.
    func waveformMarkerDidMove() {
        inlineValueOverlay?.isStale = true
        scheduleInlineValues(after: .milliseconds(120))
    }

    /// The waveform reloaded, closed or got another mapping: the values shown are no longer its.
    func waveformValuesDidChange() {
        clearInlineValues()
        scheduleInlineValues(after: .milliseconds(120))
    }

    /// The server's design changed (a top level set or reset): instances are looked up again.
    static func designHierarchyDidChange(session: LanguageServerSession) {
        for editor in liveInstances.allObjects where editor.session === session {
            editor.inlineModuleInstances = [:]
            editor.scheduleInlineValues(after: .milliseconds(120))
        }
    }

    private func scheduleInlineValues(after delay: Duration) {
        inlineValueTask?.cancel()
        inlineValueTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshInlineValues()
        }
    }

    private func clearInlineValues() {
        inlineValueTask?.cancel()
        inlineValueOverlay?.clear()
    }

    /// The dump instance whose values a module's lines show: the one picked in the menu,
    /// else the one signals were last added from, else the only one. Nil when it is ambiguous.
    private func chosenDumpInstance(module: String, candidates: [String]) -> String? {
        if let choice = inlineInstanceChoices[module], candidates.contains(choice) { return choice }
        if let linked = linkedInstances.first(where: { candidates.contains($0.dump) }) { return linked.dump }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Files past this many UTF-16 units are scanned off the main actor (a first read of 4 MB takes ~20 ms optimized).
    private static let backgroundScanThreshold = 500_000

    private func textChangedForInlineValues(from location: Int) {
        inlineScanEditedFrom = min(inlineScanEditedFrom ?? location, location)
        inlineTextGeneration += 1
    }

    /// The scanner, caught up with the text view's current text.
    private func syncedInlineScan(of textView: NSTextView) -> SystemVerilogInlineScan.Cache {
        if let editedFrom = inlineScanEditedFrom {
            let string = (textView.textStorage?.string ?? textView.string) as NSString
            inlineScan.replaceUnits(SystemVerilogInlineScan.units(of: string), editedFrom: editedFrom)
            inlineScanEditedFrom = nil
        }
        return inlineScan
    }

    /// The scanned lines `range` touches; nil when the text changed while a big file was scanned in the background.
    private func inlineLines(in range: NSRange, of textView: NSTextView) async -> [SystemVerilogInlineScan.Line]? {
        var scan = syncedInlineScan(of: textView)
        guard scan.units.count > Self.backgroundScanThreshold else {
            let lines = scan.lines(in: range)
            inlineScan = scan
            return lines
        }
        let generation = inlineTextGeneration
        let snapshot = scan
        let (lines, updated) = await Task.detached(priority: .userInitiated) { () -> ([SystemVerilogInlineScan.Line], SystemVerilogInlineScan.Cache) in
            var cache = snapshot
            return (cache.lines(in: range), cache)
        }.value
        guard generation == inlineTextGeneration else { return nil }
        inlineScan = updated
        return lines
    }

    /// slang's design instances of `module`, probed with the identifiers of its lines. In explore
    /// mode there are none; asks again after 10 s, doubling up to 5 min while none are found.
    private func designInstances(
        ofModule module: String,
        lines: [SystemVerilogInlineScan.Line],
        text: String,
        session: LanguageServerSession,
        documentURI: URL
    ) async -> [String] {
        let cached = inlineModuleInstances[module]
        if let cached {
            let wait = min(300, 10 * pow(2, Double(max(0, cached.misses - 1))))
            if !cached.designInstances.isEmpty || Date().timeIntervalSince(cached.lookedUpAt) < wait {
                return cached.designInstances
            }
        }
        let lineIndex = FilePreviewLSPLineIndex(text)
        var seen: Set<String> = []
        let probes = lines.filter { $0.module == module }.flatMap(\.identifiers)
            .filter { seen.insert($0.name).inserted }
            .prefix(12)
            .map { (name: $0.name, position: lineIndex.position(at: $0.offset)) }
        let found = await WaveformSourceLink.instancePaths(session: session, documentURI: documentURI, probes: Array(probes))
        inlineModuleInstances[module] = InlineModuleInstances(
            designInstances: found,
            lookedUpAt: Date(),
            misses: found.isEmpty ? (cached?.misses ?? 0) + 1 : 0
        )
        return found
    }

    /// Draws, after each visible line, the values its signals have at the marker of the workspace's waveform.
    private func refreshInlineValues() async {
        guard !isDetached, let textView, let session, let documentURI,
              let waveform = WaveformSourceLink.waveformPanel(near: linkPanel),
              let time = WaveformSourceLink.markerTime(of: waveform) else {
            inlineValueOverlay?.clear()
            return
        }
        observeLayoutForInlineValues(textView)
        let generation = inlineTextGeneration
        guard let lines = await inlineLines(in: Self.visibleCharacterRange(in: textView), of: textView), !Task.isCancelled else { return }
        let text = textView.string
        let modules = lines.compactMap(\.module).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !modules.isEmpty, lines.contains(where: { !$0.identifiers.isEmpty }) else {
            inlineValueOverlay?.clear()
            return
        }
        inlineValueOverlay?.isStale = true
        let rootKey = linkRootKey
        var valueByModule: [String: [String: String]] = [:]
        var hints: [String: String] = [:]
        for module in modules.prefix(4) {
            var names: [String] = []
            for line in lines where line.module == module {
                for identifier in line.identifiers where !names.contains(identifier.name) {
                    names.append(identifier.name)
                }
            }
            guard !names.isEmpty else { continue }
            let designInstances = await designInstances(
                ofModule: module, lines: lines, text: text, session: session, documentURI: documentURI
            )
            guard !Task.isCancelled else { return }
            guard !designInstances.isEmpty else {
                hints[module] = String(
                    localized: "filePreview.inlineValues.noInstance",
                    defaultValue: "No waveform values: slang-server can’t place this module in the design. Add a signal with Add to Waveform to set the design up."
                )
                continue
            }
            var candidates: [String] = []
            for designInstance in designInstances {
                guard let dumps = await WaveformSourceLink.dumpInstances(
                    ofDesignInstance: designInstance, rootKey: rootKey, waveform: waveform
                ) else {
                    // The viewer is loading; its open will refresh.
                    inlineValueOverlay?.clear()
                    return
                }
                for dump in dumps where !candidates.contains(dump) { candidates.append(dump) }
            }
            guard !Task.isCancelled else { return }
            inlineInstanceCandidates[module] = candidates
            guard let dumpInstance = chosenDumpInstance(module: module, candidates: candidates) else {
                hints[module] = String(
                    format: String(
                        localized: "filePreview.inlineValues.severalInstances",
                        defaultValue: "No waveform values: %@ has several instances. Choose one with Show Waveform Values For in the context menu."
                    ),
                    module
                )
                continue
            }
            let values = await WaveformSourceLink.inlineValues(names: names, dumpInstance: dumpInstance, waveform: waveform, time: time)
            guard !Task.isCancelled else { return }
            var byName: [String: String] = [:]
            for (name, value) in zip(names, values) {
                if let value { byName[name] = value }
            }
            valueByModule[module] = byName
            if byName.isEmpty {
                hints[module] = WaveformSourceLink.showsUnshownValues(in: waveform)
                    ? String(
                        format: String(
                            localized: "filePreview.inlineValues.noneDumped",
                            defaultValue: "No waveform values: the waveform has none of these signals under %@."
                        ),
                        dumpInstance
                    )
                    : String(
                        localized: "filePreview.inlineValues.onlyShown",
                        defaultValue: "No waveform values: FSDB values are shown for signals in the waveform only. Add them, or turn on View > Show FSDB Values for Signals Not in the Waveform."
                    )
            }
        }
        // A newer refresh, an edit or a scroll since: the positions are stale.
        guard !Task.isCancelled, !isDetached, self.textView === textView, inlineTextGeneration == generation,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        var annotations: [FilePreviewInlineValueOverlay.Annotation] = []
        var hinted: Set<String> = []
        let origin = textView.textContainerOrigin
        for line in lines {
            guard let module = line.module else { continue }
            var pairs: [(name: String, value: String)] = []
            var note: String?
            if let values = valueByModule[module] {
                var seen: Set<String> = []
                for identifier in line.identifiers where seen.insert(identifier.name).inserted {
                    if let value = values[identifier.name] { pairs.append((identifier.name, value)) }
                }
            }
            // A module's hint goes after its first visible line with identifiers.
            if pairs.isEmpty, let hint = hints[module], !line.identifiers.isEmpty, hinted.insert(module).inserted {
                note = hint
            }
            guard !pairs.isEmpty || note != nil, line.contentRange.length > 0 else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: line.contentRange, actualCharacterRange: nil)
            // The line's last fragment: a wrapped line ends there.
            let lastGlyph = max(glyphs.location, NSMaxRange(glyphs) - 1)
            let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let end = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
            annotations.append(.init(
                origin: NSPoint(x: origin.x + end.maxX + 24, y: origin.y + fragment.minY + 1),
                pairs: pairs,
                note: note
            ))
        }
        let overlay = inlineValueOverlay ?? FilePreviewInlineValueOverlay()
        inlineValueOverlay = overlay
        let baseFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let font = NSFont.monospacedSystemFont(ofSize: max(9, baseFont.pointSize - 1), weight: .regular)
        overlay.show(annotations, font: font, in: textView)
    }

    /// New lines scroll into view, or the layout changes (zoom, wrap width): place the values again.
    private func observeLayoutForInlineValues(_ textView: NSTextView) {
        if inlineScrollObserver == nil, let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            inlineScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleInlineValues(after: .milliseconds(150))
                }
            }
        }
        if inlineEditObserver == nil {
            // Any storage: the text view may swap its storage on reload.
            inlineEditObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let storage = notification.object as? NSTextStorage,
                          storage === self.textView?.textStorage, storage.editedMask.contains(.editedCharacters) else { return }
                    self.textChangedForInlineValues(from: storage.editedRange.location)
                }
            }
        }
        if inlineFrameObserver == nil {
            textView.postsFrameChangedNotifications = true
            inlineFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.inlineValueOverlay?.hasAnnotations == true else { return }
                    self.inlineValueOverlay?.isStale = true
                    self.scheduleInlineValues(after: .milliseconds(150))
                }
            }
        }
    }

    private static func visibleCharacterRange(in textView: NSTextView) -> NSRange {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// The editor's current text.
    var linkText: String? {
        textView?.string
    }

    /// A short note anchored at `index` (or the caret), shown like a hover.
    /// Shows a waveform link message by the caret (or `index`), selectable so it can be copied.
    /// `isProgress`: a note the link replaces or closes when it finishes.
    func showLinkMessage(_ message: String, at index: Int? = nil, isProgress: Bool = false) {
        guard let textView else { return }
        let location = index ?? textView.selectedRange().location
        guard let rect = viewRect(forCharacterRange: NSRange(location: location, length: 0)) else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = FilePreviewLanguageHoverViewController(sections: [message], isSelectable: true)
        hideHover()
        closeLinkMessage()
        linkMessagePopover = popover
        linkMessageShownAt = Date()
        linkMessageIsProgress = isProgress
        let window = textView.window
        let wasKey = window?.isKeyWindow == true
        // The link may start from the waveform pane, so focus need not be in the editor.
        linkMessageResponder = window?.firstResponder
        popover.show(relativeTo: rect, of: textView, preferredEdge: .minY)
        // Like hover, the message never takes typing (or Esc) from the editor.
        if wasKey, window?.isKeyWindow == false {
            window?.makeKey()
        }
        watchLinkMessage()
    }

    /// Polls (cheaply) for the editor going away under the message: hidden by a tab switch,
    /// out of its window, or another view of the window taking focus (a pane switch).
    private func watchLinkMessage() {
        linkMessageWatch?.cancel()
        linkMessageWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.linkMessagePopover != nil else { return }
                guard let textView = self.textView, let window = textView.window,
                      !textView.isHiddenOrHasHiddenAncestor, window.isVisible else {
                    self.closeLinkMessage()
                    return
                }
                // Focus moved to another view of this window since the message was shown (a pane
                // switch); a sheet, menu or other app leaves the window not key.
                if window.isKeyWindow, let responder = window.firstResponder, responder !== self.linkMessageResponder,
                   responder !== textView, !((responder as? NSView)?.isDescendant(of: textView) ?? false) {
                    self.closeLinkMessage()
                    return
                }
            }
        }
    }

    /// Closes the link's progress note, if that is what is shown.
    func closeLinkProgress() {
        guard linkMessageIsProgress else { return }
        closeLinkMessage()
    }

    private func closeLinkMessage() {
        linkMessageWatch?.cancel()
        linkMessageWatch = nil
        let popover = linkMessagePopover
        linkMessagePopover = nil
        linkMessageIsProgress = false
        popover?.close()
    }

    /// A click or key in the editor closes a link message (or a progress note a finished or
    /// cancelled link left behind) once it has been up long enough.
    private func linkMessageMayClose() {
        guard linkMessagePopover != nil,
              Date().timeIntervalSince(linkMessageShownAt) >= Self.linkMessageMinimumDuration else { return }
        closeLinkMessage()
    }

    /// The window showing this editor, for sheets.
    var linkPanelWindow: NSWindow? {
        textView?.window
    }

    /// Asks which instance's signal to add when the module is instantiated more than once.
    private func chooseInstance(_ paths: [String], anchoredAt index: Int) async -> [String] {
        guard let textView else { return [] }
        let menu = NSMenu(title: String(localized: "filePreview.language.chooseInstance", defaultValue: "Add Which Instance?"))
        menu.autoenablesItems = false
        let chooser = FilePreviewLinkMenuChooser()
        for (offset, path) in paths.enumerated() {
            let item = NSMenuItem(title: path, action: #selector(FilePreviewLinkMenuChooser.choose(_:)), keyEquivalent: "")
            item.target = chooser
            item.tag = offset
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(
            title: String(localized: "filePreview.language.addAllInstances", defaultValue: "All Instances"),
            action: #selector(FilePreviewLinkMenuChooser.choose(_:)),
            keyEquivalent: ""
        )
        all.target = chooser
        all.tag = -1
        menu.addItem(all)
        let anchor = viewRect(forCharacterRange: NSRange(location: index, length: 0)) ?? .zero
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.maxY), in: textView)
        guard let tag = chooser.chosenTag else { return [] }
        return tag < 0 ? paths : [paths[tag]]
    }

    /// Lists `locations` in a menu like Find References, anchored at `range`.
    func presentLocations(_ locations: [LSPLocation], anchoredAt range: LSPRange) {
        guard let textView else { return }
        let index = FilePreviewLSPLineIndex(textView.string).offset(for: range.start)
        presentReferences(locations, anchoredAt: index)
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

    func presentReferences(_ locations: [LSPLocation], anchoredAt index: Int) {
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

    /// Opens `location`, recording where this editor was for Go Back unless the jump is a history step.
    func navigate(to location: LSPLocation, recordingHistory: Bool = true) {
        guard let textView, let context else { return }
        if recordingHistory, let here = currentLocation, here != location {
            FilePreviewNavigationHistory.record(here, from: self)
        }
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
        guard completionMirror != nil || (context?.remote == nil && session != nil),
              let textView, textView.isEditable else {
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
                items = try await self.completionItems(at: position)
            } catch {
                filePreviewLanguageLogger.error("completion failed: \(String(describing: error), privacy: .public)")
                // The mirror relaunches its own server on the next request.
                if self.completionMirror == nil {
                    self.recoverSessionIfStopped(after: error)
                }
                items = []
            }
            guard !Task.isCancelled, let textView = self.textView,
                  textView.string == text, textView.selectedRange() == selection else { return }
            self.presentCompletions(items, isExplicit: isExplicit)
        }
    }

    /// Remote documents complete from the local mirror, never the remote server.
    private func completionItems(at position: LSPPosition) async throws -> [LSPCompletionItem] {
        if let completionMirror {
            return try await completionMirror.completion(position: position)
        }
        guard context?.remote == nil, let session, let documentURI else { return [] }
        return try await session.completion(uri: documentURI, position: position)
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

/// Where go-to-source jumps (Go to Definition, references, drivers, waveform
/// reveals) started, per workspace: Go Back returns there, Go Forward redoes.
@MainActor
enum FilePreviewNavigationHistory {
    typealias Direction = BackForwardHistory<Entry>.Direction

    struct Entry {
        var location: LSPLocation
        /// The editor that was there; it (or another on the same host) opens the location again.
        weak var editor: FilePreviewLanguageFeatures?
        var host: String
    }

    private static var histories: [UUID: BackForwardHistory<Entry>] = [:]

    static func canGoBack(inWorkspace id: UUID) -> Bool { !(histories[id]?.back.isEmpty ?? true) }
    static func canGoForward(inWorkspace id: UUID) -> Bool { !(histories[id]?.forward.isEmpty ?? true) }

    /// A jump leaves `location` in `editor`: remember it, and drop what Go Forward could redo.
    static func record(_ location: LSPLocation, from editor: FilePreviewLanguageFeatures) {
        guard let workspace = editor.linkWorkspaceId else { return }
        // Closed workspaces' histories go.
        histories = histories.filter { AppDelegate.shared?.workspaceFor(tabId: $0.key) != nil }
        var history = histories[workspace] ?? BackForwardHistory(limit: 50)
        history.record(Entry(location: location, editor: editor, host: editor.linkHostIdentity)) { $0.location == $1.location }
        histories[workspace] = history
    }

    /// Moves one step from `editor`'s current location. False when there is nowhere to go.
    static func step(_ direction: Direction, from editor: FilePreviewLanguageFeatures) -> Bool {
        guard let workspace = editor.linkWorkspaceId, var history = histories[workspace] else { return false }
        // This editor opens it in its pane; a file from another host needs an editor on that host.
        func opener(for entry: Entry) -> FilePreviewLanguageFeatures? {
            [editor, entry.editor].compactMap({ $0 }).first(where: { $0.linkHostIdentity == entry.host })
                ?? FilePreviewLanguageFeatures.linkables(inWorkspace: workspace).first(where: { $0.linkHostIdentity == entry.host })
        }
        let here = editor.currentLocation.map { Entry(location: $0, editor: editor, host: editor.linkHostIdentity) }
        let entry = history.step(direction, current: here) { opener(for: $0) != nil }
        histories[workspace] = history
        guard let entry, let target = opener(for: entry) else { return false }
        target.navigate(to: entry.location, recordingHistory: false)
        return true
    }
}

extension FilePreviewLanguageFeatures: NSPopoverDelegate {
    /// AppKit closed the link message itself (its anchor left the window, its window closed).
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === linkMessagePopover else { return }
        linkMessageWatch?.cancel()
        linkMessageWatch = nil
        linkMessagePopover = nil
        linkMessageIsProgress = false
    }
}
