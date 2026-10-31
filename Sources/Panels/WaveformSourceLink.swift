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
/// The design's and the dump's hierarchies are lined up by a
/// `HierarchyPathMapping` per design and dump, which the user can edit from
/// the View menu and cmux extends with inferred rules (never replacing the user's).
@MainActor
enum WaveformSourceLink {
    private static let mappingDefaultsPrefix = "waveformSourceLink.pathMapping."
    /// Bounds on what the viewer page may hand back (it is untrusted).
    private static let maxPathSegments = 64
    private static let maxSegmentLength = 1024
    private static let maxScopeChildren = 5000
    /// How long a failed automatic top level choice stops further tries.
    private static let topLevelRetryInterval: TimeInterval = 120

    /// The waveform viewer the link used last, preferred when a workspace has several.
    private static weak var lastWaveformPanel: FilePreviewPanel?
    /// The editor that last linked with each waveform viewer, asked first for its signals.
    private static let pairedEditors = NSMapTable<FilePreviewPanel, FilePreviewLanguageFeatures>.weakToWeakObjects()
    /// Waveform viewers with a reveal in flight; further double-clicks wait for it.
    private static var revealingPanels: Set<ObjectIdentifier> = []
    private static var isAlertShown = false

    /// What the link did to a language server's top level.
    @MainActor
    private final class TopLevelState {
        weak var session: LanguageServerSession?
        var elaboration: Task<Bool, Never>?
        var declined = false
        var failedAt: Date?
        var setByLink = false

        init(session: LanguageServerSession) {
            self.session = session
        }
    }

    private static var topLevelStates: [TopLevelState] = []

    private static func topLevelState(for session: LanguageServerSession) -> TopLevelState {
        topLevelStates.removeAll { $0.session == nil }
        if let state = topLevelStates.first(where: { $0.session === session }) { return state }
        let state = TopLevelState(session: session)
        topLevelStates.append(state)
        return state
    }

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

    /// The waveform viewer whose web view has focus in `window` (the key window by default).
    static func focusedWaveformPanel(in window: NSWindow? = nil) -> FilePreviewPanel? {
        AppDelegate.shared?.shortcutFocusedWaveformPanel(in: window ?? NSApp.keyWindow)
    }

    /// The editor to ask about `waveform`'s signals: the one that last linked with it, else the workspace's most recent.
    private static func linkedEditor(for waveform: FilePreviewPanel) -> FilePreviewLanguageFeatures? {
        if let paired = pairedEditors.object(forKey: waveform), paired.linkSession != nil,
           paired.linkWorkspaceId == waveform.workspaceId {
            return paired
        }
        return FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: waveform.workspaceId)
    }

    /// A dump path posted by the viewer page: an array of segments, within bounds.
    static func dumpPath(fromPage value: Any?) -> [String]? {
        guard let parts = value as? [Any], !parts.isEmpty, parts.count <= maxPathSegments else { return nil }
        let segments = parts.compactMap { $0 as? String }
        guard segments.count == parts.count,
              segments.allSatisfy({ !$0.isEmpty && $0.utf16.count <= maxSegmentLength }) else { return nil }
        return segments
    }

    // MARK: Path mapping

    /// Mappings are kept per design (the editor's server root) and dump (its file name and
    /// top scope names), so a unit testbench and a system testbench of one design keep
    /// separate rules even when both dumps start at `TOP` or `tb`. Nil while the viewer
    /// has no hierarchy (loading or reloading), so nothing reads or writes a key without tops.
    private static func mappingKey(rootKey: String, waveform: FilePreviewPanel) async -> String? {
        guard let tops = await Self.dumpChildren([], in: waveform), !tops.isEmpty else { return nil }
        let file = (waveform.filePath as NSString).lastPathComponent
        return rootKey + "|" + file + "|" + tops.map(\.name).sorted().joined(separator: ",")
    }

    private static var waveformLoadingMessage: String {
        String(
            localized: "waveformLink.waveformLoading",
            defaultValue: "The waveform is still loading. Try again in a moment."
        )
    }

    static func mapping(forKey key: String) -> HierarchyPathMapping {
        guard let data = UserDefaults.standard.data(forKey: mappingDefaultsPrefix + key),
              let mapping = try? JSONDecoder().decode(HierarchyPathMapping.self, from: data) else {
            return HierarchyPathMapping()
        }
        return mapping
    }

    static func saveMapping(_ mapping: HierarchyPathMapping, forKey key: String) {
        if mapping.rules.isEmpty {
            UserDefaults.standard.removeObject(forKey: mappingDefaultsPrefix + key)
        } else if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: mappingDefaultsPrefix + key)
        }
    }

    /// Adds inferred rules to the saved mapping. Reads and writes with no
    /// suspension in between, so concurrent link operations don't drop each other's rules.
    private static func addInferredRules(_ rules: [HierarchyPathMapping.Rule], forKey key: String) {
        var mapping = Self.mapping(forKey: key)
        for rule in rules {
            mapping.addInferredRule(designPrefix: rule.designPrefix, dumpPrefix: rule.dumpPrefix)
        }
        Self.saveMapping(mapping, forKey: key)
    }

    // MARK: Editor → waveform

    /// Adds the signal at `position` to the workspace's waveform viewer.
    /// Returns a message for the user when it could not, nil on success or cancel.
    static func addSignal(
        session: LanguageServerSession,
        documentURI: URL,
        position: LSPPosition,
        editor: FilePreviewLanguageFeatures,
        rootKey: String,
        chooseInstance: ([String]) async -> [String],
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> String? {
        guard let waveform = Self.waveformPanel(near: editor.linkPanel) else {
            return String(
                localized: "waveformLink.noWaveform",
                defaultValue: "Open a waveform (VCD, FST, GHW or FSDB) in this workspace first."
            )
        }
        var paths: [String]
        do {
            paths = try await session.slangInstancePaths(uri: documentURI, position: position)
            if paths.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform, progress: progress) {
                paths = try await session.slangInstancePaths(uri: documentURI, position: position)
            }
        } catch {
            waveformSourceLinkLogger.error("getInstances failed: \(String(describing: error), privacy: .public)")
            return String(
                localized: "waveformLink.serverFailed",
                defaultValue: "The language server did not answer. Try again in a moment."
            )
        }
        guard !Task.isCancelled else { return nil }
        guard !paths.isEmpty else {
            return String(
                localized: "waveformLink.notInDesign",
                defaultValue: "slang-server could not place this signal in the design. Set a top level or a build file in .slang/server.json if the waveform’s top module is not in this folder."
            )
        }
        let chosen = paths.count > 1 ? await chooseInstance(paths) : paths
        guard !chosen.isEmpty, !Task.isCancelled else { return nil }
        guard let key = await Self.mappingKey(rootKey: rootKey, waveform: waveform) else {
            return Task.isCancelled ? nil : Self.waveformLoadingMessage
        }
        var missing: [String] = []
        var notDumped: [String] = []
        var instances: [String] = []
        for designPath in chosen {
            guard !Task.isCancelled else { return nil }
            var dumpPaths: [String]
            switch await Self.resolveDumpPaths(designPath, session: session, waveform: waveform, key: key, progress: progress) {
            case .found(let found):
                dumpPaths = found
            case .notDumped(let scope):
                notDumped.append(String(
                    format: String(
                        localized: "waveformLink.notDumpedUnder",
                        defaultValue: "%1$@ (the waveform has %2$@ without it)"
                    ),
                    designPath,
                    scope
                ))
                continue
            case .instance:
                instances.append(designPath)
                continue
            case .notFound:
                missing.append(designPath)
                continue
            }
            // Several dumped instances of the design root and one instance asked for: ask which.
            if dumpPaths.count > 1, chosen.count == 1 {
                dumpPaths = await chooseInstance(dumpPaths)
            }
            guard !Task.isCancelled else { return nil }
            for dumpPath in dumpPaths {
                let added = await waveform.nativeViewSessions.waveform.callLink(
                    "addSignal",
                    argument: HierarchyPathMapping.segments(dumpPath)
                ) as? Bool == true
                if !added { missing.append(designPath) }
            }
        }
        lastWaveformPanel = waveform
        pairedEditors.setObject(editor, forKey: waveform)
        var messages: [String] = []
        if !instances.isEmpty {
            messages.append(String(
                format: String(
                    localized: "waveformLink.isInstance",
                    defaultValue: "%@ is an instance. Only signals can be added to the waveform."
                ),
                ListFormatter.localizedString(byJoining: instances)
            ))
        }
        if !notDumped.isEmpty {
            messages.append(String(
                format: String(
                    localized: "waveformLink.notDumped",
                    defaultValue: "Not dumped: %@. Check the simulator’s dump depth or whether it optimized the signal away."
                ),
                ListFormatter.localizedString(byJoining: notDumped)
            ))
        }
        if !missing.isEmpty {
            messages.append(String(
                format: String(
                    localized: "waveformLink.notInWaveform",
                    defaultValue: "%@ is not in this waveform. If the dump names the design differently, edit View > Waveform Path Mapping…"
                ),
                ListFormatter.localizedString(byJoining: missing)
            ))
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }

    private enum DumpResolution {
        case found([String])
        /// The design root's dump scope (named) is there, but not the signal.
        case notDumped(String)
        case instance
        case notFound
    }

    /// The dump paths of `designPath`: under the saved mapping, else under
    /// rules inferred from the two hierarchies (saved as inferred).
    private static func resolveDumpPaths(
        _ designPath: String,
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        key: String,
        progress: @MainActor @Sendable (String) -> Void
    ) async -> DumpResolution {
        let mapped = Self.mapping(forKey: key).dumpPaths(forDesignPath: designPath)
        var present: [String] = []
        for path in mapped {
            if await Self.hasSignal(HierarchyPathMapping.segments(path), in: waveform) { present.append(path) }
        }
        if !present.isEmpty { return .found(present) }
        let designSegments = HierarchyPathMapping.segments(designPath)
        guard let root = designSegments.first, let name = designSegments.last else { return .notFound }
        let parentItems = (try? await session.slangScopeChildren(HierarchyPathMapping.join(Array(designSegments.dropLast())))) ?? []
        if parentItems.first(where: { $0.name == name })?.isScope == true { return .instance }
        // The mapping already places the signal's scope in the dump: it was not dumped, don't look elsewhere.
        for path in mapped {
            let parent = Array(HierarchyPathMapping.segments(path).dropLast())
            if !parent.isEmpty, await Self.dumpChildren(parent, in: waveform) != nil {
                return .notDumped(HierarchyPathMapping.join(parent))
            }
        }
        let rootChildren = ((try? await session.slangScopeChildren(root)) ?? [])
            .map { HierarchyNode(name: $0.name, isScope: $0.isScope) }
        guard !rootChildren.isEmpty, !Task.isCancelled else { return .notFound }
        progress(String(localized: "waveformLink.searching", defaultValue: "Looking for the design in the waveform…"))
        let isFSDB = (waveform.filePath as NSString).pathExtension.lowercased() == "fsdb"
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: designPath,
            designRootChildren: rootChildren,
            dumpChildren: { path in await Self.dumpChildren(path, in: waveform) },
            // Each FSDB scope listing is a round trip to the SSH host.
            maxScopes: isFSDB ? 100 : 400
        )
        guard !Task.isCancelled else { return .notFound }
        let rest = Array(designSegments.dropFirst())
        switch result {
        case .found(let rules):
            Self.addInferredRules(rules, forKey: key)
            for rule in rules {
                waveformSourceLinkLogger.info("inferred path mapping \(rule.designPrefix, privacy: .public) = \(rule.dumpPrefix, privacy: .public)")
            }
            progress(String(
                format: String(
                    localized: "waveformLink.mappedNote",
                    defaultValue: "The waveform names %1$@ as %2$@. Change this in View > Waveform Path Mapping…"
                ),
                root,
                ListFormatter.localizedString(byJoining: rules.map(\.dumpPrefix))
            ))
            return .found(rules.map { HierarchyPathMapping.join(HierarchyPathMapping.segments($0.dumpPrefix) + rest) })
        case .notDumped(let rule):
            // Not saved: the rule only explains the miss, and a wrong one would stop later lookups from inferring again.
            return .notDumped(HierarchyPathMapping.join(HierarchyPathMapping.segments(rule.dumpPrefix) + rest.dropLast()))
        case .notFound:
            return .notFound
        }
    }

    private static func hasSignal(_ path: [String], in waveform: FilePreviewPanel) async -> Bool {
        await waveform.nativeViewSessions.waveform.callLink("hasSignal", argument: path) as? Bool == true
    }

    private static func dumpChildren(_ path: [String], in waveform: FilePreviewPanel) async -> [HierarchyNode]? {
        let result = await waveform.nativeViewSessions.waveform.callLink("scopeChildren", argument: path)
        guard let items = result as? [[String: Any]] else { return nil }
        return items.prefix(maxScopeChildren).compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty, name.utf16.count <= maxSegmentLength else { return nil }
            return HierarchyNode(name: name, isScope: item["isScope"] as? Bool ?? false)
        }
    }

    // MARK: Top level

    /// slang-server answers design queries only with a top level. When it has
    /// none, offer to elaborate with the module the waveform's top scope (or a
    /// scope just below a simulator wrapper such as `TOP`) is named after.
    /// One elaboration per server at a time; others wait for it. True when it set one.
    private static func elaborateDesign(
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let state = Self.topLevelState(for: session)
        if let running = state.elaboration { return await running.value }
        guard !state.declined else { return false }
        if let failedAt = state.failedAt, Date().timeIntervalSince(failedAt) < topLevelRetryInterval { return false }
        let task = Task { @MainActor in
            await Self.runElaboration(session: session, waveform: waveform, state: state, progress: progress)
        }
        state.elaboration = task
        let result = await task.value
        state.elaboration = nil
        return result
    }

    private static func runElaboration(
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        state: TopLevelState,
        progress: @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        guard let tops = try? await session.slangScopeChildren(""), tops.isEmpty else { return false }
        var candidate: (module: String, file: String)?
        search: for top in await Self.dumpChildren([], in: waveform) ?? [] where top.isScope {
            if let file = (try? await session.slangFilesContainingModule(top.name))?.first {
                candidate = (top.name, file)
                break
            }
            for child in await Self.dumpChildren([top.name], in: waveform) ?? [] where child.isScope {
                if let file = (try? await session.slangFilesContainingModule(child.name))?.first {
                    candidate = (child.name, file)
                    break search
                }
            }
        }
        guard let candidate else {
            state.failedAt = Date()
            return false
        }
        switch await Self.confirmElaboration(module: candidate.module) {
        case nil:
            return false
        case false?:
            state.declined = true
            return false
        case true?:
            break
        }
        progress(String(
            format: String(
                localized: "waveformLink.elaborating",
                defaultValue: "Elaborating the design with %@ as the top level…"
            ),
            candidate.module
        ))
        do {
            try await session.slangSetTopLevel(candidate.file)
            if let roots = try? await session.slangScopeChildren(""), !roots.isEmpty {
                waveformSourceLinkLogger.info("set slang top level to \(candidate.module, privacy: .public)")
                state.setByLink = true
                return true
            }
        } catch {
            waveformSourceLinkLogger.error("setTopLevel failed: \(String(describing: error), privacy: .public)")
        }
        // Nothing elaborated: put the server back in explore mode.
        try? await session.slangSetTopLevel("")
        state.failedAt = Date()
        return false
    }

    /// Asks before changing the server's top level, which every open editor of the folder shares.
    /// Nil when another link alert is already up.
    private static func confirmElaboration(module: String) async -> Bool? {
        let alert = NSAlert()
        alert.messageText = String(localized: "waveformLink.elaborate.title", defaultValue: "Elaborate the Design?")
        alert.informativeText = String(
            format: String(
                localized: "waveformLink.elaborate.detail",
                defaultValue: "slang-server has no top level for this folder, so it can’t place signals in the design. Elaborate it with %@ (the waveform’s top) as the top level? Diagnostics of this folder’s open files then follow that top level until you choose View > Reset Language Server Top Level."
            ),
            module
        )
        alert.addButton(withTitle: String(localized: "waveformLink.elaborate.confirm", defaultValue: "Elaborate"))
        alert.addButton(withTitle: String(localized: "waveformLink.mapping.cancel", defaultValue: "Cancel"))
        guard let response = await Self.runAlert(alert) else { return nil }
        return response == .alertFirstButtonReturn
    }

    /// Puts the language server of the focused (or last-used) editor back in explore mode, if the link set its top level.
    static func resetTopLevel() {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
              let session = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: workspace.id)?.linkSession?.session,
              let state = topLevelStates.first(where: { $0.session === session }), state.setByLink else {
            NSSound.beep()
            return
        }
        state.setByLink = false
        state.declined = true
        Task {
            try? await session.slangSetTopLevel("")
        }
    }

    // MARK: Waveform → editor

    /// Opens the selected waveform signal of `panel` in the editor. False when `panel` is not a waveform viewer.
    @discardableResult
    static func revealSelectedSignal(in panel: FilePreviewPanel?) -> Bool {
        guard let panel, panel.previewMode == .waveform else { return false }
        Task { @MainActor in
            guard let path = Self.dumpPath(fromPage: await panel.nativeViewSessions.waveform.callLink("selectedSignal")) else {
                NSSound.beep()
                return
            }
            Self.revealInSource(dumpPath: path, waveformPanel: panel)
        }
        return true
    }

    /// Opens `dumpPath`'s driver, or its declaration, in the SystemVerilog editor.
    /// Ignored while a reveal for the same viewer is still running.
    static func revealInSource(dumpPath: [String], waveformPanel: FilePreviewPanel) {
        let panelKey = ObjectIdentifier(waveformPanel)
        guard !revealingPanels.contains(panelKey) else { return }
        lastWaveformPanel = waveformPanel
        guard let editor = Self.linkedEditor(for: waveformPanel), let session = editor.linkSession?.session else {
            Self.showAlert(String(
                localized: "waveformLink.noEditor",
                defaultValue: "Open a SystemVerilog file of this design in the editor first, so cmux can ask slang-server where the signal is declared."
            ))
            return
        }
        revealingPanels.insert(panelKey)
        let rootKey = editor.linkRootKey
        let path = HierarchyPathMapping.join(dumpPath)
        Task { @MainActor in
            defer { revealingPanels.remove(panelKey) }
            guard let declaration = await Self.declaration(
                ofDumpPath: path,
                session: session,
                waveform: waveformPanel,
                rootKey: rootKey,
                progress: { [weak editor] message in editor?.showLinkMessage(message) }
            ) else {
                Self.showAlert(String(
                    format: String(
                        localized: "waveformLink.notFoundInDesign",
                        defaultValue: "%@ was not found in the design slang-server compiled. If the dump names the design differently, edit View > Waveform Path Mapping…"
                    ),
                    path
                ))
                return
            }
            pairedEditors.setObject(editor, forKey: waveformPanel)
            editor.navigate(to: declaration)
            await Self.showDrivers(of: declaration, session: session, near: editor)
        }
    }

    private static func declaration(
        ofDumpPath dumpPath: String,
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        rootKey: String,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> LSPLocation? {
        // Without a key (the viewer is reloading), try the paths as they are.
        let mapping = await Self.mappingKey(rootKey: rootKey, waveform: waveform).map(Self.mapping(forKey:)) ?? HierarchyPathMapping()
        if let location = await Self.location(ofDesignPath: mapping.designPath(forDumpPath: dumpPath), session: session) {
            return location
        }
        var roots = (try? await session.slangScopeChildren("")) ?? []
        if roots.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform, progress: progress) {
            roots = (try? await session.slangScopeChildren("")) ?? []
            if let location = await Self.location(ofDesignPath: mapping.designPath(forDumpPath: dumpPath), session: session) {
                return location
            }
        }
        var designRoots: [String: [HierarchyNode]] = [:]
        for root in roots where root.isScope {
            designRoots[root.name] = ((try? await session.slangScopeChildren(root.name)) ?? [])
                .map { HierarchyNode(name: $0.name, isScope: $0.isScope) }
        }
        guard let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: dumpPath,
            designRoots: designRoots,
            dumpChildren: { path in await Self.dumpChildren(path, in: waveform) }
        ) else { return nil }
        // Not saved: any dumped instance maps back to the same module, so this
        // rule says nothing about which instance the editor should add to.
        var lookup = mapping
        lookup.addInferredRule(designPrefix: rule.designPrefix, dumpPrefix: rule.dumpPrefix)
        return await Self.location(ofDesignPath: lookup.designPath(forDumpPath: dumpPath), session: session)
    }

    /// Declaration of the item at `designPath`, from its parent scope's listing.
    /// A bit-blasted name (`data[3]`) falls back to its vector (`data`).
    private static func location(ofDesignPath designPath: String, session: LanguageServerSession) async -> LSPLocation? {
        let segments = HierarchyPathMapping.segments(designPath)
        guard var name = segments.last else { return nil }
        let parent = HierarchyPathMapping.join(Array(segments.dropLast()))
        guard let items = try? await session.slangScopeChildren(parent) else { return nil }
        var item = items.first { $0.name == name }
        if item == nil, !name.hasPrefix("\\"), name.hasSuffix("]"), let bracket = name.firstIndex(of: "[") {
            name = String(name[..<bracket])
            item = items.first { $0.name == name }
        }
        guard var location = item?.location else { return nil }
        // Variables report the declarator; select just the name.
        if location.range.start.line == location.range.end.line {
            location.range.end.character = min(location.range.end.character, location.range.start.character + name.utf16.count)
        }
        return location
    }

    /// After the declaration opens: one assignment to the signal → select it;
    /// several → list them; none → say so. Only the declaration's file is
    /// searched, so drivers in other files and port connections are not traced.
    private static func showDrivers(of declaration: LSPLocation, session: LanguageServerSession, near editor: FilePreviewLanguageFeatures) async {
        guard let references = try? await session.references(
            uri: declaration.uri,
            position: declaration.range.start,
            includeDeclaration: false
        ) else { return }
        let declarationPath = declaration.uri.standardizedFileURL.path
        let sameFile = references.filter { $0.uri.standardizedFileURL.path == declarationPath }
        guard let target = await Self.editor(showing: declarationPath, like: editor), let text = target.linkText else { return }
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
        } else if !sameFile.isEmpty {
            target.showLinkMessage(String(
                localized: "waveformLink.noDriver",
                defaultValue: "No assignment to this signal in this file, so this is its declaration. Drivers in other files and through port connections are not traced."
            ))
        }
    }

    /// The editor that opened `path` on the same host and workspace as `editor`, once its text has loaded.
    private static func editor(showing path: String, like editor: FilePreviewLanguageFeatures) async -> FilePreviewLanguageFeatures? {
        for _ in 0..<100 {
            if let found = FilePreviewLanguageFeatures.linkable(showingDocumentPath: path, like: editor),
               found.linkText?.isEmpty == false {
                return found
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // MARK: Mapping editor

    /// Edits the path mapping between the design open in the focused (or last-used) SystemVerilog editor and its workspace's waveform.
    static func editMapping() {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
              let editor = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: workspace.id) else {
            Self.showAlert(String(
                localized: "waveformLink.noEditor",
                defaultValue: "Open a SystemVerilog file of this design in the editor first, so cmux can ask slang-server where the signal is declared."
            ))
            return
        }
        guard let waveform = Self.waveformPanel(near: editor.linkPanel) else {
            Self.showAlert(String(
                localized: "waveformLink.noWaveform",
                defaultValue: "Open a waveform (VCD, FST, GHW or FSDB) in this workspace first."
            ))
            return
        }
        let rootKey = editor.linkRootKey
        Task { @MainActor in
            guard let key = await Self.mappingKey(rootKey: rootKey, waveform: waveform) else {
                Self.showAlert(Self.waveformLoadingMessage)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "waveformLink.mapping.title", defaultValue: "Waveform Path Mapping")
            alert.informativeText = String(
                localized: "waveformLink.mapping.detail",
                defaultValue: "One rule per line: design prefix = waveform prefix, for example “cpu = top_tb.dut”. Several rules may share a design prefix, one per instance. cmux adds rules marked “# inferred” when it finds a signal under another prefix, and never changes yours. Leave it empty to use the same paths."
            )
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
            textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.string = Self.mapping(forKey: key).text
            let scrollView = NSScrollView(frame: textView.frame)
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            alert.accessoryView = scrollView
            alert.addButton(withTitle: String(localized: "waveformLink.mapping.save", defaultValue: "Save"))
            alert.addButton(withTitle: String(localized: "waveformLink.mapping.cancel", defaultValue: "Cancel"))
            alert.window.initialFirstResponder = textView
            guard await Self.runAlert(alert) == .alertFirstButtonReturn else { return }
            guard let mapping = HierarchyPathMapping(text: textView.string) else {
                Self.showAlert(String(
                    localized: "waveformLink.mapping.invalid",
                    defaultValue: "Each line must look like “design prefix = waveform prefix”. The mapping was not changed."
                ))
                return
            }
            Self.saveMapping(mapping, forKey: key)
        }
    }

    // MARK: Alerts

    /// Shows `alert` as a sheet on the key window. At most one link alert is up
    /// at a time; nil (and nothing shown) while another one is.
    private static func runAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse? {
        guard !isAlertShown else { return nil }
        isAlertShown = true
        defer { isAlertShown = false }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private static func showAlert(_ message: String) {
        guard !isAlertShown else {
            waveformSourceLinkLogger.info("dropped link alert while another is shown")
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "waveformLink.alertTitle", defaultValue: "Waveform Link")
        alert.informativeText = message
        Task { @MainActor in
            _ = await Self.runAlert(alert)
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
