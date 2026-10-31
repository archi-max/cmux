import AppKit
import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let waveformSourceLinkLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformSourceLink")

/// Links the SystemVerilog editor and the waveform viewer of a workspace:
/// add the signal under the editor's caret to the waveform, and open a
/// waveform signal's declaration (or driver) in the editor.
///
/// slang-server resolves both directions over the editor's existing language
/// server session (`slang.getInstances`, `slang.getScope`); the viewer is
/// driven through `window.cmuxWaveform.link` in `Resources/vaporview/host.js`.
/// The design's and the dump's hierarchies are lined up by a per-design
/// `HierarchyPathMapping`, inferred on first miss and editable from the View menu.
@MainActor
enum WaveformSourceLink {
    private static let mappingDefaultsPrefix = "waveformSourceLink.pathMapping."
    /// Sessions for which choosing a top level from the waveform already failed.
    private static var failedTopLevelSessions: Set<ObjectIdentifier> = []
    /// The waveform viewer the link used last, preferred when a workspace has several.
    private static weak var lastWaveformPanel: FilePreviewPanel?

    // MARK: Panels

    /// A waveform viewer in the same workspace as `panel`: the focused or last-used one first.
    static func waveformPanel(near panel: FilePreviewPanel?) -> FilePreviewPanel? {
        guard let panel, let workspace = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceId) else { return nil }
        let viewers = workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.previewMode == .waveform }
        if let last = lastWaveformPanel, viewers.contains(where: { $0 === last }) { return last }
        return viewers.min { $0.filePath < $1.filePath }
    }

    /// The focused panel of the selected workspace, when it is a waveform viewer.
    static func focusedWaveformPanel() -> FilePreviewPanel? {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] as? FilePreviewPanel,
              !panel.isClosed, panel.previewMode == .waveform else { return nil }
        return panel
    }

    // MARK: Path mapping

    static func mapping(forRootKey key: String) -> HierarchyPathMapping {
        guard let data = UserDefaults.standard.data(forKey: mappingDefaultsPrefix + key),
              let mapping = try? JSONDecoder().decode(HierarchyPathMapping.self, from: data) else {
            return HierarchyPathMapping()
        }
        return mapping
    }

    static func saveMapping(_ mapping: HierarchyPathMapping, forRootKey key: String) {
        if mapping.rules.isEmpty {
            UserDefaults.standard.removeObject(forKey: mappingDefaultsPrefix + key)
        } else if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: mappingDefaultsPrefix + key)
        }
    }

    // MARK: Editor → waveform

    /// Adds the signal at `position` to the workspace's waveform viewer.
    /// Returns a message for the user when it could not, nil on success or cancel.
    static func addSignal(
        session: LanguageServerSession,
        documentURI: URL,
        position: LSPPosition,
        editorPanel: FilePreviewPanel?,
        rootKey: String,
        chooseInstance: ([String]) async -> [String]
    ) async -> String? {
        guard let waveform = Self.waveformPanel(near: editorPanel) else {
            return String(
                localized: "waveformLink.noWaveform",
                defaultValue: "Open a waveform (VCD, FST, GHW or FSDB) in this workspace first."
            )
        }
        var paths: [String]
        do {
            paths = try await session.slangInstancePaths(uri: documentURI, position: position)
            if paths.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform) {
                paths = try await session.slangInstancePaths(uri: documentURI, position: position)
            }
        } catch {
            waveformSourceLinkLogger.error("getInstances failed: \(String(describing: error), privacy: .public)")
            return String(
                localized: "waveformLink.serverFailed",
                defaultValue: "The language server did not answer. Try again in a moment."
            )
        }
        guard !paths.isEmpty else {
            return String(
                localized: "waveformLink.notInDesign",
                defaultValue: "slang-server could not place this signal in the design. Set a top level or a build file in .slang/server.json if the waveform’s top module is not in this folder."
            )
        }
        let chosen = paths.count > 1 ? await chooseInstance(paths) : paths
        guard !chosen.isEmpty else { return nil }
        var missing: [String] = []
        for designPath in chosen {
            guard let dumpPath = await Self.dumpPath(forDesignPath: designPath, session: session, waveform: waveform, rootKey: rootKey),
                  await waveform.nativeViewSessions.waveform.callLink("addSignal", argument: dumpPath) as? Bool == true else {
                missing.append(designPath)
                continue
            }
        }
        lastWaveformPanel = waveform
        guard !missing.isEmpty else { return nil }
        return String(
            format: String(
                localized: "waveformLink.notInWaveform",
                defaultValue: "%@ is not in this waveform. If the dump names the design differently, edit View > Waveform Path Mapping…"
            ),
            missing.joined(separator: ", ")
        )
    }

    /// The dump path of `designPath`, inferring and saving a prefix rule when the mapped path is not in the dump.
    private static func dumpPath(
        forDesignPath designPath: String,
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        rootKey: String
    ) async -> String? {
        var mapping = Self.mapping(forRootKey: rootKey)
        let mapped = mapping.dumpPath(forDesignPath: designPath)
        if await Self.hasSignal(mapped, in: waveform) { return mapped }
        let root = HierarchyPathMapping.segments(designPath).first ?? ""
        let rootChildren = Set(((try? await session.slangScopeChildren(root)) ?? []).map(\.name))
        guard let rule = await HierarchyPrefixInference.dumpRule(
            forDesignPath: designPath,
            designRootChildren: rootChildren,
            dumpChildren: { path in await Self.dumpChildren(path, in: waveform) }
        ) else { return nil }
        mapping.setRule(rule)
        let inferred = mapping.dumpPath(forDesignPath: designPath)
        guard await Self.hasSignal(inferred, in: waveform) else { return nil }
        Self.saveMapping(mapping, forRootKey: rootKey)
        waveformSourceLinkLogger.info("inferred path mapping \(rule.designPrefix, privacy: .public) = \(rule.dumpPrefix, privacy: .public)")
        return inferred
    }

    private static func hasSignal(_ path: String, in waveform: FilePreviewPanel) async -> Bool {
        await waveform.nativeViewSessions.waveform.callLink("hasSignal", argument: path) as? Bool == true
    }

    private static func dumpChildren(_ path: [String], in waveform: FilePreviewPanel) async -> [HierarchyNode]? {
        let result = await waveform.nativeViewSessions.waveform.callLink("scopeChildren", argument: path.joined(separator: "."))
        guard let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return HierarchyNode(name: name, isScope: item["isScope"] as? Bool ?? false)
        }
    }

    /// slang-server answers design queries only with a top level. When it has
    /// none, use the module the waveform's top scope (or a scope just below a
    /// simulator wrapper such as `TOP`) is named after. True when it set one.
    private static func elaborateDesign(session: LanguageServerSession, waveform: FilePreviewPanel) async -> Bool {
        let key = ObjectIdentifier(session)
        guard !failedTopLevelSessions.contains(key),
              let tops = try? await session.slangScopeChildren(""), tops.isEmpty else { return false }
        var candidates: [String] = []
        for top in await Self.dumpChildren([], in: waveform) ?? [] where top.isScope {
            candidates.append(top.name)
            for child in await Self.dumpChildren([top.name], in: waveform) ?? [] where child.isScope {
                candidates.append(child.name)
            }
        }
        for name in candidates {
            guard let file = (try? await session.slangFilesContainingModule(name))?.first else { continue }
            do {
                try await session.slangSetTopLevel(file)
                if let roots = try? await session.slangScopeChildren(""), !roots.isEmpty {
                    waveformSourceLinkLogger.info("set slang top level to \(name, privacy: .public)")
                    return true
                }
            } catch {
                waveformSourceLinkLogger.error("setTopLevel failed: \(String(describing: error), privacy: .public)")
            }
        }
        failedTopLevelSessions.insert(key)
        return false
    }

    // MARK: Waveform → editor

    /// Opens the selected waveform signal of `panel` in the editor. False when `panel` is not a waveform viewer.
    @discardableResult
    static func revealSelectedSignal(in panel: FilePreviewPanel?) -> Bool {
        guard let panel, panel.previewMode == .waveform else { return false }
        Task { @MainActor in
            guard let path = await panel.nativeViewSessions.waveform.callLink("selectedSignal") as? String else {
                NSSound.beep()
                return
            }
            revealInSource(dumpPath: path, waveformPanel: panel)
        }
        return true
    }

    /// Opens `dumpPath`'s driver, or its declaration, in the SystemVerilog editor.
    static func revealInSource(dumpPath: String, waveformPanel: FilePreviewPanel) {
        lastWaveformPanel = waveformPanel
        guard let editor = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: waveformPanel.workspaceId),
              let session = editor.linkSession?.session else {
            Self.showAlert(String(
                localized: "waveformLink.noEditor",
                defaultValue: "Open a SystemVerilog file of this design in the editor first, so cmux can ask slang-server where the signal is declared."
            ))
            return
        }
        let rootKey = editor.linkRootKey
        Task { @MainActor in
            guard let declaration = await Self.declaration(ofDumpPath: dumpPath, session: session, waveform: waveformPanel, rootKey: rootKey) else {
                Self.showAlert(String(
                    format: String(
                        localized: "waveformLink.notFoundInDesign",
                        defaultValue: "%@ was not found in the design slang-server compiled. If the dump names the design differently, edit View > Waveform Path Mapping…"
                    ),
                    dumpPath
                ))
                return
            }
            editor.navigate(to: declaration)
            await Self.showDrivers(of: declaration, session: session)
        }
    }

    private static func declaration(
        ofDumpPath dumpPath: String,
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        rootKey: String
    ) async -> LSPLocation? {
        var mapping = Self.mapping(forRootKey: rootKey)
        if let location = await Self.location(ofDesignPath: mapping.designPath(forDumpPath: dumpPath), session: session) {
            return location
        }
        var roots = (try? await session.slangScopeChildren("")) ?? []
        if roots.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform) {
            roots = (try? await session.slangScopeChildren("")) ?? []
            if let location = await Self.location(ofDesignPath: mapping.designPath(forDumpPath: dumpPath), session: session) {
                return location
            }
        }
        var designRoots: [String: Set<String>] = [:]
        for root in roots where root.isScope {
            designRoots[root.name] = Set(((try? await session.slangScopeChildren(root.name)) ?? []).map(\.name))
        }
        guard let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: dumpPath,
            designRoots: designRoots,
            dumpChildren: { path in await Self.dumpChildren(path, in: waveform) }
        ) else { return nil }
        mapping.setRule(rule)
        guard let location = await Self.location(ofDesignPath: mapping.designPath(forDumpPath: dumpPath), session: session) else {
            return nil
        }
        Self.saveMapping(mapping, forRootKey: rootKey)
        return location
    }

    /// Declaration of the item at `designPath`, from its parent scope's listing.
    private static func location(ofDesignPath designPath: String, session: LanguageServerSession) async -> LSPLocation? {
        let segments = HierarchyPathMapping.segments(designPath)
        guard let name = segments.last else { return nil }
        let parent = segments.dropLast().joined(separator: ".")
        guard let items = try? await session.slangScopeChildren(parent),
              var location = items.first(where: { $0.name == name })?.location else { return nil }
        // Variables report the declarator; select just the name.
        if location.range.start.line == location.range.end.line {
            location.range.end.character = min(location.range.end.character, location.range.start.character + name.utf16.count)
        }
        return location
    }

    /// After the declaration opens: one assignment to the signal → select it; several → list them.
    private static func showDrivers(of declaration: LSPLocation, session: LanguageServerSession) async {
        guard let references = try? await session.references(
            uri: declaration.uri,
            position: declaration.range.start,
            includeDeclaration: false
        ) else { return }
        let declarationPath = declaration.uri.standardizedFileURL.path
        let sameFile = references.filter { $0.uri.standardizedFileURL.path == declarationPath }
        guard !sameFile.isEmpty, let target = await Self.editor(showing: declarationPath), let text = target.linkText else { return }
        let lines = text.components(separatedBy: "\n")
        let drivers = sameFile.filter { reference in
            guard lines.indices.contains(reference.range.start.line),
                  reference.range.start.line == reference.range.end.line else { return false }
            return SystemVerilogAssignmentScanner.isAssignmentTarget(
                line: lines[reference.range.start.line],
                column: reference.range.start.character,
                length: reference.range.end.character - reference.range.start.character
            )
        }
        if drivers.count == 1 {
            target.navigate(to: drivers[0])
        } else if drivers.count > 1 {
            target.presentLocations([declaration] + drivers, anchoredAt: declaration.range)
        }
    }

    /// The editor that opened `path`, once its text has loaded.
    private static func editor(showing path: String) async -> FilePreviewLanguageFeatures? {
        for _ in 0..<100 {
            if let editor = FilePreviewLanguageFeatures.linkable(showingDocumentPath: path), editor.linkText?.isEmpty == false {
                return editor
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: Mapping editor

    /// Edits the path mapping of the design open in the focused (or last-used) SystemVerilog editor.
    static func editMapping() {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
              let editor = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: workspace.id) else {
            Self.showAlert(String(
                localized: "waveformLink.noEditor",
                defaultValue: "Open a SystemVerilog file of this design in the editor first, so cmux can ask slang-server where the signal is declared."
            ))
            return
        }
        let key = editor.linkRootKey
        let alert = NSAlert()
        alert.messageText = String(localized: "waveformLink.mapping.title", defaultValue: "Waveform Path Mapping")
        alert.informativeText = String(
            localized: "waveformLink.mapping.detail",
            defaultValue: "One rule per line: design prefix = waveform prefix, for example “cpu = top_tb.dut”. cmux fills this in when it finds a signal under a different prefix. Leave it empty to use the same paths."
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = Self.mapping(forRootKey: key).text
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        alert.accessoryView = scrollView
        alert.addButton(withTitle: String(localized: "waveformLink.mapping.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "waveformLink.mapping.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let mapping = HierarchyPathMapping(text: textView.string) else {
            Self.showAlert(String(
                localized: "waveformLink.mapping.invalid",
                defaultValue: "Each line must look like “design prefix = waveform prefix”. The mapping was not changed."
            ))
            return
        }
        Self.saveMapping(mapping, forRootKey: key)
    }

    private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "waveformLink.alertTitle", defaultValue: "Waveform Link")
        alert.informativeText = message
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Records the item picked from a synchronous `NSMenu.popUp`.
final class FilePreviewLinkMenuChooser: NSObject {
    private(set) var chosenTag: Int?

    @objc func choose(_ sender: NSMenuItem) {
        chosenTag = sender.tag
    }
}
