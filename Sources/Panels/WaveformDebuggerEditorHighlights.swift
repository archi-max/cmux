import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// What the SystemVerilog editor shows while the waveform debugger steps
/// (FEATURES.md F.1): the signals that changed this cycle, the lines that drive
/// them (the module's other lines dimmed), the same signals' rows in the
/// waveform, and the declaration and drivers of the row selected there.
///
/// Drawn with the layout manager's temporary attributes, so the text, its
/// undo and its syntax colors are untouched.
@MainActor
enum WaveformDebuggerEditorHighlights {
    /// A module's instance in the design and in the dump.
    struct Instance: Equatable {
        var design: String
        var dump: String
    }

    /// One inline-value refresh of an editor: its visible lines and the values they showed.
    struct Shown {
        let editor: FilePreviewLanguageFeatures
        let textView: NSTextView
        let lines: [SystemVerilogInlineScan.Line]
        let waveform: FilePreviewPanel
        let time: Int64
        /// Per module: name → value at `time`.
        let values: [String: [String: String]]
        let instances: [String: Instance]
        /// Per module without values: why.
        var reasons: [String: WaveformDebuggerRTLStatus.Reason] = [:]
    }

    @MainActor private final class Drawn {
        var attributes: [(range: NSRange, key: NSAttributedString.Key, value: Any)] = []
        /// The text storage and its edit count when drawn: after an edit, or on another
        /// storage, the ranges no longer hold.
        weak var storage: NSTextStorage?
        let revision: Int

        init(_ textView: NSTextView) {
            storage = textView.textStorage
            revision = WaveformDebuggerEditorHighlights.revision(of: textView)
        }

        func holds(in textView: NSTextView) -> Bool {
            guard let storage, storage === textView.textStorage else { return false }
            return WaveformDebuggerEditorHighlights.revision(of: textView) == revision
        }
    }

    private final class Counter {
        var value = 0
    }

    /// Edits per text storage, so ranges drawn before an edit are never drawn again after it.
    /// Keyed by identity: text storages compare (and hash) by their text, which edits change.
    private static let revisions = NSMapTable<NSTextStorage, Counter>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private static var editObserver: NSObjectProtocol?

    static func revision(of textView: NSTextView) -> Int {
        if editObserver == nil {
            editObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main
            ) { notification in
                // Posted on the main thread, where text storages are edited.
                nonisolated(unsafe) let storage = notification.object as? NSTextStorage
                MainActor.assumeIsolated {
                    guard let storage, storage.editedMask.contains(.editedCharacters) else { return }
                    let counter = revisions.object(forKey: storage) ?? Counter()
                    counter.value += 1
                    revisions.setObject(counter, forKey: storage)
                }
            }
        }
        guard let storage = textView.textStorage else { return -1 }
        return revisions.object(forKey: storage)?.value ?? 0
    }

    private final class Work {
        var task: Task<Void, Never>?
    }

    private final class Paths {
        var paths: [[String]] = []
    }

    /// Most driver cones asked of slang-server per refresh, or per cycle while playing (each is cached).
    private static let maxConeRequests = 16

    private struct ConeBudget {
        let time: Int64
        let generation: Int
        var left: Int
    }

    /// While playing, per viewer: cone lookups left for the cycle shown (`maxConeRequests` per
    /// cycle across its editors).
    private static var coneBudgets: [ObjectIdentifier: ConeBudget] = [:]

    /// How long an editor waits after the marker moves before it reads values again: none
    /// while playing (the throttle still runs one refresh at a time), else enough to let quick moves settle.
    static func refreshDelay(playing: Bool) -> Duration {
        playing ? .zero : .milliseconds(120)
    }
    private static let maxCachedCones = 4000
    /// Most waveform rows lit per editor.
    private static let maxRows = 200

    private static let cycleDrawn = NSMapTable<NSTextView, Drawn>.weakToStrongObjects()
    private static let work = NSMapTable<NSTextView, Work>.weakToStrongObjects()
    /// Per editor: the dump paths of its changed signals, lit in its waveform.
    private static let rowPaths = NSMapTable<FilePreviewLanguageFeatures, Paths>.weakToStrongObjects()
    /// Per viewer: the rows last sent, so an unchanged set is not sent again.
    private static let sentRows = NSMapTable<FilePreviewPanel, Paths>.weakToStrongObjects()
    private struct ConeKey: Hashable {
        let server: ObjectIdentifier
        let path: String
    }

    /// slang's driver cone per server and signal path.
    private static var cones: [ConeKey: [SlangConeEntry]] = [:]
    /// When a cone lookup last failed, per server and signal path.
    private static var failedCones: [ConeKey: Date] = [:]
    /// Bumped whenever cones are forgotten, so a lookup in flight across it is not cached.
    private static var coneGeneration = 0
    /// Seconds before a failed cone lookup is tried again.
    static var failedConeRetryInterval: TimeInterval = 30
    /// The selected row's declaration and driver lines, per text view (drawn over the cycle highlights).
    private static let selectionLines = NSMapTable<NSTextView, Drawn>.weakToStrongObjects()

    // MARK: Cycle highlights

    /// An editor drew its values: while its waveform is stepped, compare them with the
    /// cycle before and highlight what changed and what drove it.
    static func valuesShown(_ shown: Shown) {
        WaveformDebugger.updateLocals(from: shown.editor)
        let textView = shown.textView
        let job = work.object(forKey: textView) ?? Work()
        work.setObject(job, forKey: textView)
        job.task?.cancel()
        guard WaveformDebugger.isStepping(shown.waveform) else {
            clear(in: textView)
            setRows([], from: shown.editor, in: shown.waveform)
            return
        }
        // The text the lines were scanned from: an edit before the task runs makes them stale too.
        let text = textView.string
        job.task = Task { @MainActor in
            let result = await cycleHighlights(shown, text: text)
            guard !Task.isCancelled else { return }
            if let result {
                apply(result.highlights, lines: shown.lines, in: textView)
                setRows(result.rows, from: shown.editor, in: shown.waveform)
            }
            WaveformDebuggerRTLStatus.editorDone(
                shown.editor, waveform: shown.waveform, time: shown.time,
                drew: shown.values.values.contains { !$0.isEmpty }, reasons: shown.reasons
            )
        }
    }

    private static func cycleHighlights(_ shown: Shown, text: String) async -> (highlights: WaveformCycleHighlights.Result, rows: [[String]])? {
        let page = shown.waveform.nativeViewSessions.waveform
        // The cycle these values were read in (the marker may have moved on since).
        let cycle = await page.callDebugger("cycleAt", argument: ["time": NSNumber(value: shown.time)]) as? [String: Any]
        // Superseded: the newer refresh draws (clearing here would cancel it).
        if Task.isCancelled { return nil }
        guard let previous = (cycle?["previousTime"] as? NSNumber)?.int64Value else {
            // (Not `clear`: that cancels this job, and the editor would never say it drew the cycle.)
            removeCycleHighlights(from: shown.textView)
            return nil
        }
        var changed: [String: Set<String>] = [:]
        for (module, now) in shown.values {
            guard let instance = shown.instances[module], !now.isEmpty else { continue }
            let names = now.keys.sorted()
            let values = await WaveformSourceLink.inlineValues(
                names: names, dumpInstance: instance.dump, waveform: shown.waveform, time: previous
            )
            guard !Task.isCancelled else { return nil }
            var before: [String: String] = [:]
            for (name, value) in zip(names, values) {
                if let value { before[name] = value }
            }
            changed[module] = WaveformCycleHighlights.changedNames(now: now, before: before)
        }
        let nsText = text as NSString
        var result = WaveformCycleHighlights.highlights(lines: shown.lines, text: nsText, changed: changed)
        await addPortDrivers(to: &result, changed: changed, shown: shown, text: nsText)
        // An edit since: the ranges are stale, and the edit's refresh follows.
        guard !Task.isCancelled, shown.textView.string == text else { return nil }
        var rows: [[String]] = []
        for (module, names) in changed {
            guard let instance = shown.instances[module] else { continue }
            let scope = HierarchyPathMapping.segments(instance.dump)
            rows += names.sorted().map { scope + [$0] }
        }
        return (result, Array(rows.prefix(maxRows)))
    }

    /// Changed signals no line here assigns may be driven by a child instance's
    /// output port (slang's driver cone says which): its connection line drives them.
    private static func addPortDrivers(
        to result: inout WaveformCycleHighlights.Result,
        changed: [String: Set<String>],
        shown: Shown,
        text: NSString
    ) async {
        guard let session = shown.editor.linkSession?.session else { return }
        let server = ObjectIdentifier(session)
        // While playing, one budget per cycle shown, shared by every editor (forgotten cones
        // start a new one); else each refresh (a scroll, an edit, a step) has its own.
        let playing = WaveformDebugger.state(of: shown.waveform).playing
        var ownBudget = maxConeRequests
        let viewer = ObjectIdentifier(shown.waveform)
        let budgetGeneration = coneGeneration
        func takeLookup() -> Bool {
            if playing {
                // This cycle's budget (a new cycle, or forgotten cones, start a new one).
                var budget = coneBudgets[viewer] ?? ConeBudget(time: shown.time, generation: budgetGeneration, left: maxConeRequests)
                if budget.time != shown.time || budget.generation != budgetGeneration {
                    budget = ConeBudget(time: shown.time, generation: budgetGeneration, left: maxConeRequests)
                }
                guard budget.left > 0 else { return false }
                budget.left -= 1
                if coneBudgets.count > 32, coneBudgets[viewer] == nil { coneBudgets.removeAll() }
                coneBudgets[viewer] = budget
                return true
            }
            guard ownBudget > 0 else { return false }
            ownBudget -= 1
            return true
        }
        var lines = Set(result.driverLines.map(\.location))
        for module in changed.keys.sorted() {
            guard let instance = shown.instances[module], !instance.design.isEmpty else { continue }
            for name in changed[module, default: []].sorted() where result.assigned[module]?.contains(name) != true {
                let path = instance.design + "." + name
                let key = ConeKey(server: server, path: path)
                var cone = cones[key]
                if cone == nil {
                    // A failure (often: the design isn't compiled yet) is asked again after a while.
                    if let failedAt = failedCones[key], Date().timeIntervalSince(failedAt) < failedConeRetryInterval { continue }
                    guard takeLookup() else { continue }
                    let generation = coneGeneration
                    guard let found = try? await session.slangDriverCone(path) else {
                        if generation == coneGeneration { failedCones[key] = Date() }
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    // An answer from before a recompile is used this once but not kept.
                    if generation == coneGeneration {
                        failedCones[key] = nil
                        if cones.count >= maxCachedCones { cones.removeAll() }
                        cones[key] = found
                    }
                    cone = found
                }
                for child in WaveformCycleHighlights.drivingChildInstances(cone: cone ?? [], designInstance: instance.design) {
                    guard let start = shown.lines.firstIndex(where: { line in
                        line.module == module && line.identifiers.contains { $0.name == child }
                    }) else { continue }
                    for range in WaveformCycleHighlights.connectionLines(of: name, instantiationAt: start, lines: shown.lines, text: text)
                    where lines.insert(range.location).inserted {
                        result.driverLines.append(range)
                    }
                }
            }
        }
    }

    private static func apply(_ result: WaveformCycleHighlights.Result, lines: [SystemVerilogInlineScan.Line], in textView: NSTextView) {
        // (Not `clear`: that cancels the job drawing these, before it says it drew the cycle.)
        removeCycleHighlights(from: textView)
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        let drawn = Drawn(textView)
        func add(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange) {
            guard range.length > 0, NSMaxRange(range) <= length else { return }
            layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
            drawn.attributes.append((range, key, value))
        }
        let driverStarts = Set(result.driverLines.map(\.location))
        let drivingModules = Set(lines.filter { driverStarts.contains($0.contentRange.location) }.compactMap(\.module))
        let dimmed = (textView.textColor ?? .textColor).withAlphaComponent(0.4)
        for line in lines where line.module.map(drivingModules.contains) == true && !driverStarts.contains(line.contentRange.location) {
            add(.foregroundColor, dimmed, line.contentRange)
        }
        for range in result.driverLines {
            add(.backgroundColor, NSColor.systemYellow.withAlphaComponent(0.16), range)
        }
        for range in result.changedIdentifiers {
            add(.backgroundColor, NSColor.systemOrange.withAlphaComponent(0.4), range)
        }
        cycleDrawn.setObject(drawn, forKey: textView)
        drawSelection(in: textView)
    }

    /// Removes the cycle highlights (not the selected row's) from `textView`.
    static func clear(in textView: NSTextView?) {
        guard let textView else { return }
        work.object(forKey: textView)?.task?.cancel()
        removeCycleHighlights(from: textView)
    }

    private static func removeCycleHighlights(from textView: NSTextView) {
        cycleDrawn.removeObject(forKey: textView)
        removeAll(from: textView)
        drawSelection(in: textView)
    }

    /// Temporary attributes move with edits, so the ranges drawn may be stale: these two
    /// keys (only the debugger draws them as temporary attributes) go from the whole text.
    private static func removeAll(from textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length, length > 0 else { return }
        let full = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }

    // MARK: Waveform rows

    private static func setRows(_ paths: [[String]], from editor: FilePreviewLanguageFeatures, in waveform: FilePreviewPanel) {
        let mine = rowPaths.object(forKey: editor) ?? Paths()
        mine.paths = paths
        rowPaths.setObject(mine, forKey: editor)
        var all: [[String]] = []
        for other in FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId) {
            guard WaveformSourceLink.waveformPanel(near: other.linkPanel) === waveform else { continue }
            for path in rowPaths.object(forKey: other)?.paths ?? [] where !all.contains(path) { all.append(path) }
        }
        let sent = sentRows.object(forKey: waveform) ?? Paths()
        guard sent.paths != all else { return }
        sent.paths = all
        sentRows.setObject(sent, forKey: waveform)
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("highlightRows", argument: ["paths": all])
        }
    }

    /// The viewer stopped stepping (the page dropped its highlights itself).
    static func forget(_ waveform: FilePreviewPanel) {
        sentRows.removeObject(forKey: waveform)
        showSelection(nil, drivers: [], near: nil)
        forgetCones()
    }

    /// The design changed (recompiled, another top level): the cached driver cones may not hold.
    static func forgetCones() {
        coneGeneration += 1
        cones.removeAll()
        failedCones.removeAll()
    }

    /// `session` compiled the design again (it published diagnostics): its cones may have changed.
    static func recompiled(_ session: LanguageServerSession) {
        let server = ObjectIdentifier(session)
        // Always: a lookup still out (nothing cached yet) must not be kept either.
        coneGeneration += 1
        if cones.keys.contains(where: { $0.server == server }) { cones = cones.filter { $0.key.server != server } }
        if failedCones.keys.contains(where: { $0.server == server }) { failedCones = failedCones.filter { $0.key.server != server } }
    }

    // MARK: Selected row → editor

    /// Lights the lines of `declaration` and `drivers` in the editor showing their file
    /// (nil: removes the last selection's lines).
    static func showSelection(_ declaration: LSPLocation?, drivers: [LSPLocation], near editor: FilePreviewLanguageFeatures?) {
        for textView in selectionLines.keyEnumerator().allObjects.compactMap({ $0 as? NSTextView }) {
            selectionLines.removeObject(forKey: textView)
            removeAll(from: textView)
            // The cycle highlights under the selection's lines come back.
            if let cycle = cycleDrawn.object(forKey: textView) { redraw(cycle, in: textView) }
        }
        guard let declaration, let editor,
              let target = FilePreviewLanguageFeatures.linkable(showingDocumentPath: declaration.uri.standardizedFileURL.path, like: editor),
              let textView = target.debuggerTextView else { return }
        let text = textView.string as NSString
        let lineIndex = FilePreviewLSPLineIndex(textView.string)
        let drawn = Drawn(textView)
        let color = NSColor.systemBlue.withAlphaComponent(0.24)
        for location in [declaration] + drivers {
            let start = lineIndex.offset(for: location.range.start)
            guard start <= text.length else { continue }
            var line = text.lineRange(for: NSRange(location: start, length: 0))
            while line.length > 0, let last = Unicode.Scalar(text.character(at: NSMaxRange(line) - 1)),
                  CharacterSet.newlines.contains(last) {
                line.length -= 1
            }
            if line.length > 0 { drawn.attributes.append((line, .backgroundColor, color)) }
        }
        selectionLines.setObject(drawn, forKey: textView)
        drawSelection(in: textView)
    }

    private static func drawSelection(in textView: NSTextView) {
        if let drawn = selectionLines.object(forKey: textView) { redraw(drawn, in: textView) }
    }

    private static func redraw(_ drawn: Drawn, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length,
              drawn.holds(in: textView) else { return }
        for (range, key, value) in drawn.attributes where range.length > 0 && NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
        }
    }
}
