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
        symbol: LinkSymbol,
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
        let chosen: [String]
        switch await Self.chosenDesignPaths(
            session: session,
            documentURI: documentURI,
            position: position,
            symbol: symbol,
            waveform: waveform,
            chooseInstance: chooseInstance,
            progress: progress
        ) {
        case .message(let message):
            return message
        case .paths(let paths):
            chosen = paths
        }
        guard !chosen.isEmpty, !Task.isCancelled else { return nil }
        guard let key = await Self.mappingKey(rootKey: rootKey, waveform: waveform) else {
            return Task.isCancelled ? nil : Self.waveformLoadingMessage
        }
        var missing: [String] = []
        var notDumped: [String] = []
        var instances: [String] = []
        var aliasNotes: [String] = []
        for designPath in chosen {
            guard !Task.isCancelled else { return nil }
            var dumpPaths: [String]
            // The design path whose dump is added (an alias when the simulator kept only that name).
            var linkedPath = designPath
            switch await Self.resolveDumpPaths(designPath, session: session, waveform: waveform, key: key, progress: progress) {
            case .found(let found):
                dumpPaths = found
            case .notDumped(let scope):
                if let alias = await Self.dumpedAlias(of: designPath, session: session, waveform: waveform, key: key, progress: progress) {
                    dumpPaths = alias.dumpPaths
                    linkedPath = alias.path
                    aliasNotes.append(String(
                        format: String(
                            localized: "waveformLink.showingAlias",
                            defaultValue: "%1$@ isn’t dumped; showing %2$@, the same net through a port connection."
                        ),
                        designPath,
                        alias.path
                    ))
                    break
                }
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
                let segments = HierarchyPathMapping.segments(dumpPath)
                let added = await waveform.nativeViewSessions.waveform.callLink("addSignal", argument: segments) as? Bool == true
                guard added else {
                    missing.append(designPath)
                    continue
                }
                // Inline values follow the instance last added from.
                editor.recordLinkedInstance(
                    design: HierarchyPathMapping.join(Array(HierarchyPathMapping.segments(linkedPath).dropLast())),
                    dump: HierarchyPathMapping.join(Array(segments.dropLast()))
                )
            }
        }
        lastWaveformPanel = waveform
        pairedEditors.setObject(editor, forKey: waveform)
        var messages = aliasNotes
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

    /// The identifier the link acts on, and whether its line is inside a module
    /// (false in an `include`d fragment).
    struct LinkSymbol {
        let name: String
        let isInModule: Bool
    }

    private enum DesignPaths {
        case paths([String])
        case message(String)
    }

    /// The design paths of the symbol at `position`, for the instances the user picks when
    /// the module has several (empty when the menu is dismissed). Offers to elaborate in explore mode.
    private static func chosenDesignPaths(
        session: LanguageServerSession,
        documentURI: URL,
        position: LSPPosition,
        symbol: LinkSymbol,
        waveform: FilePreviewPanel,
        chooseInstance: ([String]) async -> [String],
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> DesignPaths {
        var paths: [String]
        // An included fragment is placed by walking the design, which can take a while over SSH.
        let searchNote = String(
            format: String(
                localized: "waveformLink.searchingFragment",
                defaultValue: "Looking for %@ in the design this file is included into…"
            ),
            symbol.name
        )
        let willSearch: @Sendable () async -> Void = { await progress(searchNote) }
        do {
            paths = try await session.slangDesignPaths(
                uri: documentURI,
                position: position,
                identifier: symbol.name,
                isInModule: symbol.isInModule,
                willSearch: willSearch
            )
            // Asked again only when the design was empty and the link just elaborated it
            // (an empty design has nothing to walk, so the walk runs at most once).
            if paths.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform, progress: progress) {
                paths = try await session.slangDesignPaths(
                    uri: documentURI,
                    position: position,
                    identifier: symbol.name,
                    isInModule: symbol.isInModule,
                    willSearch: willSearch
                )
            }
        } catch is CancellationError {
            return .paths([])
        } catch {
            waveformSourceLinkLogger.error("getInstances failed: \(String(describing: error), privacy: .public)")
            return .message(String(
                localized: "waveformLink.serverFailed",
                defaultValue: "The language server did not answer. Try again in a moment."
            ))
        }
        guard !Task.isCancelled else { return .paths([]) }
        guard !paths.isEmpty else {
            // getScope("") also lists packages; only instances are tops.
            let hasTops = ((try? await session.slangScopeChildren("")) ?? []).contains { $0.kind != "Package" }
            guard !Task.isCancelled else { return .paths([]) }
            if !hasTops {
                return .message(String(
                    localized: "waveformLink.notInDesign",
                    defaultValue: "slang-server could not place this signal in the design. Set a top level or a build file in .slang/server.json if the waveform’s top module is not in this folder."
                ))
            }
            if !symbol.isInModule {
                return .message(String(
                    format: String(
                        localized: "waveformLink.notInDesign.fragment",
                        defaultValue: "This file has no module of its own; it is `include’d into another file. slang-server found no %@ in the design it is included into."
                    ),
                    symbol.name
                ))
            }
            return .message(String(
                format: String(
                    localized: "waveformLink.notInDesign.elaborated",
                    defaultValue: "slang-server found no %@ in the elaborated design. Its module may not be instantiated under the current top level."
                ),
                symbol.name
            ))
        }
        return .paths(paths.count > 1 ? await chooseInstance(paths) : paths)
    }

    /// Adds every signal of the instance at `position` (an instance name), or of the
    /// instance the signal at `position` is in, using VaporView's Add All in Scope.
    static func addScope(
        session: LanguageServerSession,
        documentURI: URL,
        position: LSPPosition,
        symbol: LinkSymbol,
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
        let chosen: [String]
        switch await Self.chosenDesignPaths(
            session: session,
            documentURI: documentURI,
            position: position,
            symbol: symbol,
            waveform: waveform,
            chooseInstance: chooseInstance,
            progress: progress
        ) {
        case .message(let message):
            return message
        case .paths(let paths):
            chosen = paths
        }
        guard !chosen.isEmpty, !Task.isCancelled else { return nil }
        guard let key = await Self.mappingKey(rootKey: rootKey, waveform: waveform) else {
            return Task.isCancelled ? nil : Self.waveformLoadingMessage
        }
        var missing: [String] = []
        var truncated: [String] = []
        var busy = false
        for designPath in chosen {
            guard !Task.isCancelled else { return nil }
            let segments = HierarchyPathMapping.segments(designPath)
            let parent = HierarchyPathMapping.join(Array(segments.dropLast()))
            let parentItems = (try? await session.slangScopeChildren(parent)) ?? []
            let isInstance = parentItems.first { $0.name == segments.last }?.isScope == true
            let scope = isInstance ? designPath : parent
            guard !scope.isEmpty else {
                missing.append(designPath)
                continue
            }
            // The dump scope is found through one of its signals, like Add to Waveform.
            guard let probe = ((try? await session.slangScopeChildren(scope)) ?? []).first(where: { !$0.isScope }) else {
                missing.append(scope)
                continue
            }
            var dumpScopes: [String]
            switch await Self.resolveDumpPaths(scope + "." + probe.name, session: session, waveform: waveform, key: key, progress: progress) {
            case .found(let dumpPaths):
                dumpScopes = dumpPaths.map { HierarchyPathMapping.join(Array(HierarchyPathMapping.segments($0).dropLast())) }
            case .notDumped(let dumpScope):
                dumpScopes = [dumpScope]
            case .instance, .notFound:
                missing.append(scope)
                continue
            }
            if dumpScopes.count > 1, chosen.count == 1 {
                dumpScopes = await chooseInstance(dumpScopes)
            }
            for dumpScope in dumpScopes {
                guard !Task.isCancelled else { return nil }
                switch await Self.addScopeSignals(dumpScope, in: waveform) {
                case .notInViewer:
                    missing.append(scope)
                case .declined:
                    continue
                case .busy:
                    busy = true
                case let .added(added, total):
                    if added < total {
                        truncated.append(String(
                            format: String(
                                localized: "waveformLink.addScope.truncated",
                                defaultValue: "Added %1$@ of the %2$@ signals in %3$@ not shown yet. Choose Add All Signals in Scope again for the next ones."
                            ),
                            NumberFormatter.localizedString(from: NSNumber(value: added), number: .decimal),
                            NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal),
                            dumpScope
                        ))
                    }
                    editor.recordLinkedInstance(design: scope, dump: dumpScope)
                }
            }
        }
        lastWaveformPanel = waveform
        pairedEditors.setObject(editor, forKey: waveform)
        var messages = truncated
        if busy {
            messages.append(String(
                localized: "waveformLink.addScope.busy",
                defaultValue: "Nothing was added: another Waveform Link dialog is open. Close it and choose Add All Signals in Scope again."
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

    private enum ScopeAddResult {
        case notInViewer
        /// The user cancelled the confirm.
        case declined
        /// Another link dialog was up, so nothing was asked.
        case busy
        /// How many were added of how many not shown yet.
        case added(Int, total: Int)
    }

    /// Adds the signals of dump scope `dumpScope` not shown yet, asking first when there are many.
    private static func addScopeSignals(_ dumpScope: String, in waveform: FilePreviewPanel) async -> ScopeAddResult {
        let path = HierarchyPathMapping.segments(dumpScope)
        let session = waveform.nativeViewSessions.waveform
        guard var result = await session.callLink("addScope", argument: ["path": path]) as? [String: Any] else { return .notInViewer }
        if result["needsConfirm"] as? Bool == true {
            let count = (result["count"] as? NSNumber)?.intValue ?? 0
            let total = (result["total"] as? NSNumber)?.intValue ?? count
            let alert = NSAlert()
            alert.messageText = String(localized: "waveformLink.addScope.confirm.title", defaultValue: "Add All Signals in Scope?")
            alert.informativeText = String(
                format: String(
                    localized: "waveformLink.addScope.confirm.detail",
                    defaultValue: "This adds %1$@ signals of %2$@ to the waveform."
                ),
                NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                dumpScope
            )
            alert.addButton(withTitle: String(localized: "waveformLink.addScope.confirm.add", defaultValue: "Add"))
            alert.addButton(withTitle: String(localized: "waveformLink.mapping.cancel", defaultValue: "Cancel"))
            _ = total
            guard let response = await Self.runAlert(alert) else { return .busy }
            guard response == .alertFirstButtonReturn, !Task.isCancelled else { return .declined }
            guard let confirmed = await session.callLink("addScope", argument: ["path": path, "confirmed": true]) as? [String: Any] else {
                return .notInViewer
            }
            result = confirmed
        }
        let added = (result["added"] as? NSNumber)?.intValue ?? 0
        return .added(added, total: (result["total"] as? NSNumber)?.intValue ?? added)
    }

    /// Aliases tried at most for a path that isn't dumped (one dump lookup each).
    private static let aliasLimit = 8

    /// For a design path the dump lacks: the first of its plain port-connection aliases
    /// (`slangPortAliases`) that is dumped, with its dump paths. Simulators often keep only one
    /// name of a net, such as the instance port a testbench wire is connected to.
    private static func dumpedAlias(
        of designPath: String,
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        key: String,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> (path: String, dumpPaths: [String])? {
        guard let aliases = try? await session.slangPortAliases(of: designPath) else { return nil }
        for alias in aliases.prefix(aliasLimit) {
            guard !Task.isCancelled else { return nil }
            if case .found(let dumpPaths) = await resolveDumpPaths(alias, session: session, waveform: waveform, key: key, progress: progress),
               !dumpPaths.isEmpty {
                return (alias, dumpPaths)
            }
        }
        return nil
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
        // A top level or build file being set by hand wins.
        guard !state.declined, !SlangCompilationActions.isBusy(session) else { return false }
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
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        // getScope("") also lists packages; only instances are tops.
        guard let tops = try? await session.slangScopeChildren(""), tops.allSatisfy({ $0.kind == "Package" }) else { return false }
        // A profile made for this waveform's testbench comes before guessing a top level.
        if await autoPickProfile(session: session, waveform: waveform, progress: progress) {
            state.setByLink = false
            return true
        }
        // A profile build (or the user's own choice) is running: don't guess a top level over it.
        guard !SlangCompilationActions.isBusy(session) else { return false }
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
            if let roots = try? await session.slangScopeChildren(""), roots.contains(where: { $0.kind != "Package" }) {
                waveformSourceLinkLogger.info("set slang top level to \(candidate.module, privacy: .public)")
                state.setByLink = true
                SlangCompilationActions.recordTarget(.topLevel(candidate.file), for: session)
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
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

    /// Builds from the profile whose `--top` names the waveform's top scope (or the scope below it).
    private static func autoPickProfile(
        session: LanguageServerSession,
        waveform: FilePreviewPanel,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let tops = (await Self.dumpChildren([], in: waveform) ?? []).filter(\.isScope).map(\.name)
        guard !tops.isEmpty else { return false }
        var children: [String: [String]] = [:]
        for top in tops.prefix(8) {
            children[top] = (await Self.dumpChildren([top], in: waveform) ?? []).filter(\.isScope).map(\.name)
        }
        return await SlangCompilationActions.autoPickProfile(session: session, dumpTops: tops, dumpChildren: children, progress: progress)
    }

    /// When a waveform opens, its workspace's servers with no top level build from the matching profile.
    private static func autoPickProfiles(for waveform: FilePreviewPanel) async {
        var seen = Set<ObjectIdentifier>()
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId) {
            guard let session = editor.linkSession?.session, seen.insert(ObjectIdentifier(session)).inserted,
                  Self.topLevelState(for: session).elaboration == nil,
                  let tops = try? await session.slangScopeChildren(""), tops.allSatisfy({ $0.kind == "Package" }) else { continue }
            _ = await autoPickProfile(session: session, waveform: waveform) { _ in }
        }
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

    /// Puts the language server of the focused (or last-used) editor back in explore mode,
    /// if the link or Set as SystemVerilog Top Level set its top level.
    static func resetTopLevel() {
        guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
              let session = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: workspace.id)?.linkSession?.session,
              canResetTopLevel(session: session), !SlangCompilationActions.isBusy(session) else {
            NSSound.beep()
            return
        }
        resetTopLevel(session: session)
    }

    /// Whether cmux set `session`'s top level (so Reset Top Level has something to undo).
    static func canResetTopLevel(session: LanguageServerSession) -> Bool {
        switch SlangCompilationActions.target(of: session) {
        case .topLevel?: return true
        case .buildFile?: return false
        case nil: return topLevelStates.first(where: { $0.session === session })?.setByLink == true
        }
    }

    /// Back to explore mode; the link stops offering to elaborate for this session.
    static func resetTopLevel(session: LanguageServerSession) {
        let state = Self.topLevelState(for: session)
        state.setByLink = false
        state.declined = true
        Task { @MainActor in
            await SlangCompilationActions.returnToConfiguredCompilation(session)
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        }
    }

    /// The user chose a top level themselves: the link's own choice no longer applies.
    static func topLevelWasChosen(session: LanguageServerSession) {
        let state = Self.topLevelState(for: session)
        state.setByLink = false
        state.failedAt = nil
    }

    // MARK: Waveform → editor

    /// Opens the selected waveform signal of `panel` in the editor. False when `panel` is not a
    /// waveform viewer or one of its text fields has focus.
    @discardableResult
    static func revealSelectedSignal(in panel: FilePreviewPanel?) -> Bool {
        // In the viewer's search or value field the key is typing (Opt+Shift+D is `Î`).
        guard let panel, panel.previewMode == .waveform,
              !panel.nativeViewSessions.waveform.isEditableElementFocused else { return false }
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
                progress: { [weak editor] message in editor?.showLinkMessage(message, isProgress: true) }
            ) else {
                editor.closeLinkProgress()
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
            editor.closeLinkProgress()
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
        var roots = ((try? await session.slangScopeChildren("")) ?? []).filter { $0.kind != "Package" }
        if roots.isEmpty, await Self.elaborateDesign(session: session, waveform: waveform, progress: progress) {
            roots = ((try? await session.slangScopeChildren("")) ?? []).filter { $0.kind != "Package" }
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

    // MARK: Inline values

    /// Each waveform viewer's marker time, while it has one.
    private static let markerTimes = NSMapTable<FilePreviewPanel, NSNumber>.weakToStrongObjects()
    /// Most values shown per refresh, and the longest value string kept.
    private static let maxInlineValues = 300
    private static let maxInlineValueLength = 64

    static func markerTime(of waveform: FilePreviewPanel) -> Int64? {
        markerTimes.object(forKey: waveform)?.int64Value
    }

    /// The viewer's marker moved (nil: removed). The workspace's SV editors redraw their values.
    static func markerMoved(in waveform: FilePreviewPanel, time: Int64?) {
        if let time {
            markerTimes.setObject(NSNumber(value: time), forKey: waveform)
        } else {
            markerTimes.removeObject(forKey: waveform)
        }
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId) {
            editor.waveformMarkerDidMove()
        }
    }

    /// The viewer is closing: its editors' values go away with it.
    static func waveformClosed(_ waveform: FilePreviewPanel) {
        markerTimes.removeObject(forKey: waveform)
        if lastWaveformPanel === waveform { lastWaveformPanel = nil }
        Self.waveformValuesChanged(in: waveform.workspaceId)
    }

    /// The viewer is loading its file again (a reload or a new page): the old values and marker no longer hold.
    static func waveformReloading(_ waveform: FilePreviewPanel) {
        markerTimes.removeObject(forKey: waveform)
        Self.waveformValuesChanged(in: waveform.workspaceId)
    }

    /// The viewer received signal data (FSDB): values of newly shown signals can be read now.
    static func waveformDataArrived(_ waveform: FilePreviewPanel) {
        guard Self.markerTime(of: waveform) != nil else { return }
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId) {
            editor.waveformMarkerDidMove()
        }
    }

    /// The viewer opened its file: picks up the marker a restored session put back.
    static func waveformOpened(_ waveform: FilePreviewPanel) {
        Task { @MainActor in
            await Self.autoPickProfiles(for: waveform)
        }
        Task { @MainActor in
            guard let time = await waveform.nativeViewSessions.waveform.callLink("markerTime") as? NSNumber else { return }
            Self.markerMoved(in: waveform, time: time.int64Value)
        }
    }

    /// The inline values' preference changed: every editor fetches its values again.
    static func inlineValueSettingsChanged() {
        for workspaceId in Set(FilePreviewLanguageFeatures.allLinkables.compactMap(\.linkWorkspaceId)) {
            Self.waveformValuesChanged(in: workspaceId)
        }
    }

    private static func waveformValuesChanged(in workspaceId: UUID) {
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: workspaceId) {
            editor.waveformValuesDidChange()
        }
    }

    /// The design instances a module is elaborated as, from slang's paths of
    /// signals declared in it (`probes`: names and where they appear). Never changes the top level.
    static func instancePaths(
        session: LanguageServerSession,
        documentURI: URL,
        probes: [(name: String, position: LSPPosition)]
    ) async -> [String] {
        for probe in probes.prefix(6) {
            guard let paths = try? await session.slangInstancePaths(uri: documentURI, position: probe.position) else { return [] }
            var instances: [String] = []
            for path in paths {
                let segments = HierarchyPathMapping.segments(path)
                guard segments.count >= 2, segments.last == probe.name else { continue }
                let instance = HierarchyPathMapping.join(Array(segments.dropLast()))
                if !instances.contains(instance) { instances.append(instance) }
            }
            if !instances.isEmpty { return instances }
        }
        return []
    }

    /// The dump scopes design instance `designInstance` maps to under the saved
    /// mapping (several when it maps one design root to several dumped instances).
    /// Nil while the viewer has no hierarchy.
    static func dumpInstances(ofDesignInstance designInstance: String, rootKey: String, waveform: FilePreviewPanel) async -> [String]? {
        guard let key = await Self.mappingKey(rootKey: rootKey, waveform: waveform) else { return nil }
        return Self.mapping(forKey: key).dumpPaths(forDesignPath: designInstance)
    }

    /// Whether inline values may ask the viewer for signals it does not show.
    /// FSDB has to walk such a signal's changes on the dump's host, so that is opt-in there.
    static func showsUnshownValues(in waveform: FilePreviewPanel) -> Bool {
        guard (waveform.filePath as NSString).pathExtension.lowercased() == "fsdb" else { return true }
        return UserDefaults.standard.bool(forKey: WaveformInlineValueSettings.unshownFSDBValuesKey)
    }

    /// Values at `time` in `waveform` of the signals `names` of dump scope
    /// `dumpInstance`; nil where the dump has no such signal (or, see
    /// `showsUnshownValues`, the viewer does not show it).
    static func inlineValues(names: [String], dumpInstance: String, waveform: FilePreviewPanel, time: Int64) async -> [String?] {
        let names = Array(names.prefix(maxInlineValues))
        let scope = HierarchyPathMapping.segments(dumpInstance)
        let result = await waveform.nativeViewSessions.waveform.callLink(
            "valuesAt",
            argument: [
                "time": NSNumber(value: time),
                "paths": names.map { scope + [$0] },
                "unshown": Self.showsUnshownValues(in: waveform),
            ] as [String: Any]
        ) as? [Any] ?? []
        return names.indices.map { index in
            guard index < result.count, let value = result[index] as? String else { return nil }
            return Self.displayableValue(value)
        }
    }

    /// A value from the page as drawn: no control or bidirectional formatting
    /// characters (which could garble or reorder the line), at most `maxInlineValueLength`.
    static func displayableValue(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !bidiControls.contains(scalar.value)
        }
        let cleaned = String(String.UnicodeScalarView(scalars).prefix(maxInlineValueLength))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]

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
            Self.waveformValuesChanged(in: waveform.workspaceId)
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
        // The message can be selected and copied.
        alert.layout()
        for case let field as NSTextField in alert.window.contentView?.subviews ?? [] where field.stringValue == message {
            field.isSelectable = true
        }
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

/// The inline values' preference (View > Show FSDB Values for Signals Not in the Waveform).
enum WaveformInlineValueSettings {
    static let unshownFSDBValuesKey = "waveformSourceLink.inlineValues.unshownFSDB"
}

// MARK: Waveform debugger

extension WaveformSourceLink {
    /// Where dump signal `dumpPath` is declared, and the editor whose language
    /// server found it. Never elaborates a design or asks anything: nil while
    /// the server has no design, or when the design has no such signal.
    static func debuggerDeclaration(
        ofDumpPath dumpPath: [String],
        waveform: FilePreviewPanel
    ) async -> (location: LSPLocation, editor: FilePreviewLanguageFeatures)? {
        guard let editor = Self.linkedEditor(for: waveform), let session = editor.linkSession?.session,
              let roots = try? await session.slangScopeChildren(""), !roots.isEmpty,
              let location = await Self.declaration(
                  ofDumpPath: HierarchyPathMapping.join(dumpPath),
                  session: session,
                  waveform: waveform,
                  rootKey: editor.linkRootKey,
                  progress: { _ in }
              ) else { return nil }
        return (location, editor)
    }
}
