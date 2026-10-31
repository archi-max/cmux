import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// The waveform debugger's line breakpoints: F9, or a click in a SystemVerilog editor's
/// line-number gutter, puts one on a line. It hits when a signal the line assigns changes
/// (`WaveformLineBreakpoint.watchedSignals`), in the instance the editor shows values for, or
/// in any instance of the module. The viewer page searches for hits (`setLineBreakpoints`);
/// this side keeps the breakpoints per workspace, on their lines while the file is edited, and
/// finds their lines again by text when the file is opened again.
@MainActor
enum WaveformDebuggerLineBreakpoints {
    struct Mark: Codable, Equatable, Sendable {
        var id: UUID
        /// The file's path (as the editor has it).
        var path: String
        /// 0-based, as last seen.
        var line: Int
        /// The line's text as last seen (`WaveformLineBreakpoint.lineText`).
        var text: String
        var enabled = true
        var anyInstance = false
        /// The line's text was not found when the file was opened again: kept disabled at its old line.
        var lost = false
        /// A SystemVerilog expression (cmux-expr.js) that must be true at the landing posedge; absent before B3.
        var condition: String? = nil
    }

    /// Per workspace, in the order they were added.
    private(set) static var marks: [UUID: [Mark]] = [:]

    /// Where the marks of an open file are, kept through the text view's edits.
    private final class Tracker {
        weak var storage: NSTextStorage?
        let workspace: UUID
        let path: String
        var offsets: [UUID: Int] = [:]
        var observer: (any NSObjectProtocol)?
        /// The text as of the last edit seen (to find what a whole-range replace really changed).
        var text: NSString = ""
        /// The marks were placed by text; not while the storage is still empty (the file loading).
        var placed = false
        /// Marks an edit merged into another's line, kept so an undo of that edit brings them back.
        var merged: [Mark] = []
        init(storage: NSTextStorage, workspace: UUID, path: String) {
            self.storage = storage
            self.workspace = workspace
            self.path = path
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private static let trackers = NSMapTable<NSTextView, Tracker>.weakToStrongObjects()

    /// Whether the text view's current edit is an undo or redo (the harness sets it).
    static var isUndoing: @MainActor (NSTextView) -> Bool = { textView in
        textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true
    }

    // MARK: Editing

    /// F9: a breakpoint on the caret's line, or none if it had one. False when the focused
    /// view is not a SystemVerilog editor (the key goes on).
    static func toggleAtCaret(window: NSWindow?) -> Bool {
        guard let textView = AppDelegate.shared?.shortcutFocusedSavingTextView(in: window),
              let editor = textView.languageFeatures else { return false }
        return toggle(in: editor, textView: textView, at: textView.selectedRange().location)
    }

    /// A breakpoint on the line holding UTF-16 offset `index`, or none if it had one.
    @discardableResult
    static func toggle(in editor: FilePreviewLanguageFeatures, textView: NSTextView, at index: Int) -> Bool {
        guard let workspace = editor.linkWorkspaceId, let tracker = tracker(for: textView, editor: editor),
              let storage = textView.textStorage else { return false }
        let text = storage.string as NSString
        let start = WaveformLineBreakpoint.lineStart(containing: index, in: text)
        if let existing = tracker.offsets.first(where: { $0.value == start })?.key {
            remove(existing, in: workspace)
            return true
        }
        let line = lineNumber(at: start, in: text)
        let mark = Mark(id: UUID(), path: editor.filePath, line: line, text: lineText(at: start, in: text))
        marks[workspace, default: []].append(mark)
        tracker.offsets[mark.id] = start
        changed(workspace)
        return true
    }

    static func remove(_ id: UUID, in workspace: UUID) {
        marks[workspace]?.removeAll { $0.id == id }
        for case let tracker as Tracker in trackers.objectEnumerator()?.allObjects ?? [] { tracker.offsets[id] = nil }
        changed(workspace)
    }

    static func setEnabled(_ id: UUID, _ enabled: Bool, in workspace: UUID) {
        update(id, in: workspace) { $0.enabled = enabled; if enabled { $0.lost = false } }
    }

    static func setAnyInstance(_ id: UUID, _ any: Bool, in workspace: UUID) {
        update(id, in: workspace) { $0.anyInstance = any }
    }

    /// The breakpoint's condition; nil or blank clears it. The page checks it parses (and says why not).
    static func setCondition(_ id: UUID, _ condition: String?, in workspace: UUID) {
        let trimmed = condition?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id, in: workspace) { $0.condition = trimmed?.isEmpty == false ? trimmed : nil }
    }

    private static func update(_ id: UUID, in workspace: UUID, _ change: (inout Mark) -> Void) {
        guard let index = marks[workspace]?.firstIndex(where: { $0.id == id }) else { return }
        change(&marks[workspace]![index])
        changed(workspace)
    }

    /// The page's list toggled, removed or edited the condition of one:
    /// `{ event: 'lineBreakpoint', key, enabled, removed, condition? }` (condition null: cleared).
    static func pageReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        guard let key = body["key"] as? String, let id = UUID(uuidString: key) else { return }
        let workspace = waveform.workspaceId
        if body["removed"] as? Bool == true {
            remove(id, in: workspace)
            return
        }
        if let enabled = body["enabled"] as? Bool { setEnabled(id, enabled, in: workspace) }
        if body.keys.contains("condition") { setCondition(id, body["condition"] as? String, in: workspace) }
    }

    // MARK: Gutter

    /// The gutter's dots: line start offset → style. Nil for a view that takes no breakpoints.
    static func styles(in textView: NSTextView) -> [Int: FilePreviewLineNumberGutterView.BreakpointMark]? {
        guard let editor = (textView as? SavingTextView)?.languageFeatures,
              let tracker = tracker(for: textView, editor: editor) else { return nil }
        let byId = Dictionary((marks[tracker.workspace] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var styles: [Int: FilePreviewLineNumberGutterView.BreakpointMark] = [:]
        for (id, offset) in tracker.offsets {
            guard let mark = byId[id] else { continue }
            styles[offset] = mark.lost ? .lost : (mark.enabled ? (mark.condition == nil ? .enabled : .conditional) : .disabled)
        }
        return styles
    }

    /// A click on the gutter at line start `start`: toggles the line's breakpoint.
    static func gutterClicked(_ textView: NSTextView, lineStart start: Int) -> Bool {
        guard let editor = (textView as? SavingTextView)?.languageFeatures else { return false }
        return toggle(in: editor, textView: textView, at: start)
    }

    /// The menu of a breakpoint's dot: enable, any instance, remove. Nil without one on the line.
    static func gutterMenu(_ textView: NSTextView, lineStart start: Int) -> NSMenu? {
        guard let editor = (textView as? SavingTextView)?.languageFeatures,
              let tracker = tracker(for: textView, editor: editor),
              let id = tracker.offsets.first(where: { $0.value == start })?.key,
              let mark = marks[tracker.workspace]?.first(where: { $0.id == id }) else { return nil }
        let workspace = tracker.workspace
        let menu = NSMenu()
        menu.addItem(GutterMenuItem(
            title: mark.enabled
                ? String(localized: "waveformDebugger.lineBreakpoint.disable", defaultValue: "Disable Breakpoint")
                : String(localized: "waveformDebugger.lineBreakpoint.enable", defaultValue: "Enable Breakpoint")
        ) { setEnabled(id, !mark.enabled, in: workspace) })
        let any = GutterMenuItem(
            title: String(localized: "waveformDebugger.lineBreakpoint.anyInstance", defaultValue: "Break in Any Instance")
        ) { setAnyInstance(id, !mark.anyInstance, in: workspace) }
        any.state = mark.anyInstance ? .on : .off
        menu.addItem(any)
        let label = "\((mark.path as NSString).lastPathComponent):\(mark.line + 1)"
        menu.addItem(GutterMenuItem(
            title: String(localized: "waveformDebugger.lineBreakpoint.editCondition", defaultValue: "Edit Condition…")
        ) { [weak textView] in
            guard let answer = WaveformDebuggerEvaluate.promptCondition(current: mark.condition, for: label, window: textView?.window)
            else { return }
            setCondition(id, answer, in: workspace)
        })
        if mark.condition != nil {
            menu.addItem(GutterMenuItem(
                title: String(localized: "waveformDebugger.lineBreakpoint.removeCondition", defaultValue: "Remove Condition")
            ) { setCondition(id, nil, in: workspace) })
        }
        menu.addItem(.separator())
        menu.addItem(GutterMenuItem(
            title: String(localized: "waveformDebugger.removeBreakpoint", defaultValue: "Remove Breakpoint")
        ) { remove(id, in: workspace) })
        return menu
    }

    @MainActor private final class GutterMenuItem: NSMenuItem {
        private let run: @MainActor () -> Void
        init(title: String, run: @escaping @MainActor () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(runItem), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func runItem() { run() }
    }

    // MARK: Tracking an open file

    /// The text view's tracker, made (and its file's breakpoints placed by text) on first use or
    /// after the view swaps in another text storage (a reload).
    private static func tracker(for textView: NSTextView, editor: FilePreviewLanguageFeatures) -> Tracker? {
        guard let workspace = editor.linkWorkspaceId, let storage = textView.textStorage,
              FilePreviewLanguageFeatures.isSupported(filePath: editor.filePath) else { return nil }
        if let tracker = trackers.object(forKey: textView), tracker.storage === storage,
           tracker.workspace == workspace, tracker.path == editor.filePath {
            return tracker
        }
        let tracker = Tracker(storage: storage, workspace: workspace, path: editor.filePath)
        // An empty storage is a file still loading (its text comes as one replace): placed then.
        if storage.length > 0 { place(tracker, in: storage) }
        tracker.text = NSString(string: storage.string)
        tracker.observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak textView] _ in
            // Posted on the main thread (queue nil): the observed storage, which the tracker holds.
            MainActor.assumeIsolated {
                guard let textView, let tracker = trackers.object(forKey: textView), let storage = tracker.storage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                if tracker.placed {
                    edited(tracker, storage: storage, undoing: isUndoing(textView))
                } else if storage.length > 0 {
                    place(tracker, in: storage)
                    changed(tracker.workspace)
                }
                tracker.text = NSString(string: storage.string)
                scheduleRefresh(tracker.workspace)
            }
        }
        trackers.setObject(tracker, forKey: textView)
        return tracker
    }

    /// The file's breakpoints on their lines: by their text (the nearest free such line), else kept
    /// near their old line, disabled and marked lost. Every mark gets a line of its own while the
    /// file has lines enough; one that gets none is lost and disabled, never enabled without a dot.
    private static func place(_ tracker: Tracker, in storage: NSTextStorage) {
        tracker.placed = true
        let text = storage.string as NSString
        let starts = lineStarts(of: text)
        var taken: Set<Int> = []
        guard var list = marks[tracker.workspace] else { return }
        for index in list.indices where list[index].path == tracker.path {
            var mark = list[index]
            if let line = WaveformLineBreakpoint.lines(matching: mark.text, near: mark.line, in: text).first(where: { !taken.contains($0) }) {
                mark.line = line
                mark.lost = false
            } else {
                if !mark.lost {
                    mark.lost = true
                    mark.enabled = false
                }
                mark.line = nearestFree(to: min(mark.line, starts.count - 1), count: starts.count, taken: taken) ?? mark.line
            }
            list[index] = mark
            guard mark.line < starts.count, taken.insert(mark.line).inserted else { continue }
            tracker.offsets[mark.id] = starts[mark.line]
        }
        marks[tracker.workspace] = list
    }

    /// The free line nearest `line` (0..<count), the earlier on a tie; nil when every line is taken.
    private static func nearestFree(to line: Int, count: Int, taken: Set<Int>) -> Int? {
        guard count > 0 else { return nil }
        let start = max(0, min(line, count - 1))
        for distance in 0..<count {
            for candidate in [start - distance, start + distance] where candidate >= 0 && candidate < count && !taken.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Moves the file's breakpoints with an edit. What changed is found by comparing the text before
    /// and after (a Format Document or a reload replaces the whole range but changes less): a mark
    /// before it stays, one after it moves by the change in length, and one whose line start was in
    /// it goes to its text again (the nearest free line with it), else keeps its line number. Two
    /// that meet on one line become one, kept aside so an undo of that edit brings it back.
    private static func edited(_ tracker: Tracker, storage: NSTextStorage, undoing: Bool) {
        let old = tracker.text
        let text = storage.string as NSString
        let span = changedSpan(old: old, new: text, edited: storage.editedRange)
        let delta = text.length - old.length
        let starts = lineStarts(of: text)
        let lineOf: (Int) -> Int = { offset in
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= offset { lo = mid } else { hi = mid - 1 } }
            return lo
        }
        let byId = Dictionary((marks[tracker.workspace] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var taken: [Int: UUID] = [:]
        var inside: [(id: UUID, line: Int, text: String)] = []
        var dropped: [UUID] = []
        // An edit within lines (no line break taken out or put in) moves no line: no text to look for.
        let newlines = CharacterSet.newlines
        let joinsOrSplits = old.substring(with: NSRange(location: span.start, length: span.oldEnd - span.start)).rangeOfCharacter(from: newlines) != nil
            || text.substring(with: NSRange(location: span.start, length: span.oldEnd + delta - span.start)).rangeOfCharacter(from: newlines) != nil
        for (id, offset) in tracker.offsets.sorted(by: { $0.value < $1.value }) {
            let oldRange = old.lineRange(for: NSRange(location: min(offset, old.length), length: 0))
            // Its line was changed, or had lines put inside it (after its start).
            let touched = joinsOrSplits && (span.oldEnd > span.start
                ? oldRange.location < span.oldEnd && NSMaxRange(oldRange) > span.start
                : oldRange.location < span.start && span.start < NSMaxRange(oldRange))
            if touched {
                // Its line before the edit: what to look for.
                let oldLine = old.substring(with: oldRange).trimmingCharacters(in: .newlines)
                inside.append((id, lineNumber(at: offset, in: old), WaveformLineBreakpoint.lineText(oldLine)))
                continue
            }
            let line = lineOf(WaveformLineBreakpoint.lineStart(containing: offset >= span.oldEnd ? offset + delta : offset, in: text))
            if taken[line] != nil { dropped.append(id); continue }
            taken[line] = id
        }
        // Those whose text is still there first, then the rest at their line numbers.
        var unmatched: [(id: UUID, line: Int, text: String)] = []
        for mark in inside {
            if let line = WaveformLineBreakpoint.lines(matching: mark.text, near: mark.line, in: text).first(where: { taken[$0] == nil }) {
                taken[line] = mark.id
            } else {
                unmatched.append(mark)
            }
        }
        for mark in unmatched {
            let line = min(mark.line, starts.count - 1)
            if taken[line] != nil { dropped.append(mark.id); continue }
            taken[line] = mark.id
        }
        // An undo of an edit that merged marks: those whose text is back on a free line return.
        var restored: [Mark] = []
        if undoing {
            tracker.merged.removeAll { mark in
                guard let line = WaveformLineBreakpoint.lines(matching: mark.text, near: mark.line, in: text)
                    .first(where: { taken[$0] == nil }) else { return false }
                var back = mark
                back.line = line
                taken[line] = back.id
                restored.append(back)
                return true
            }
        }
        tracker.offsets = Dictionary(uniqueKeysWithValues: taken.map { ($0.value, starts[$0.key]) })
        if !dropped.isEmpty {
            for id in dropped {
                guard var mark = byId[id] else { continue }
                if let at = inside.first(where: { $0.id == id }) {
                    mark.line = at.line
                    mark.text = at.text
                }
                tracker.merged.append(mark)
            }
            if tracker.merged.count > 64 { tracker.merged.removeFirst(tracker.merged.count - 64) }
            marks[tracker.workspace]?.removeAll { dropped.contains($0.id) }
        }
        if !restored.isEmpty { marks[tracker.workspace, default: []].append(contentsOf: restored) }
        changed(tracker.workspace, redraw: true)
    }

    /// The span an edit really changed: `start` (the common prefix's end) and the old text's end of
    /// it (`oldEnd`), from the edited range widened only where the texts differ.
    private static func changedSpan(old: NSString, new: NSString, edited: NSRange) -> (start: Int, oldEnd: Int) {
        let oldLength = old.length, newLength = new.length
        // Outside the edited range the texts agree; inside it, compare.
        let limit = min(oldLength, newLength)
        var prefix = max(0, min(edited.location, limit))
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = max(0, min(newLength - NSMaxRange(edited), limit - prefix))
        while suffix < limit - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        return (prefix, oldLength - suffix)
    }

    /// The marks' line numbers and texts from where their open files have them (one pass per file).
    private static func refreshPositions(in workspace: UUID) {
        guard var list = marks[workspace] else { return }
        for case let tracker as Tracker in trackers.objectEnumerator()?.allObjects ?? [] where tracker.workspace == workspace {
            guard let storage = tracker.storage else { continue }
            let text = storage.string as NSString
            let sorted = tracker.offsets.sorted { $0.value < $1.value }
            var line = 0
            var index = 0
            for (id, offset) in sorted {
                let end = min(offset, text.length)
                while index < end {
                    let unit = text.character(at: index)
                    if unit == 0x0A || (unit == 0x0D && (index + 1 >= text.length || text.character(at: index + 1) != 0x0A)) { line += 1 }
                    index += 1
                }
                guard let at = list.firstIndex(where: { $0.id == id }) else { continue }
                list[at].line = line
                list[at].text = lineText(at: offset, in: text)
            }
        }
        marks[workspace] = list
    }

    private static func lineStarts(of text: NSString) -> [Int] {
        var starts: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.location)
        }
        return starts.isEmpty ? [0] : starts
    }

    private static func lineNumber(at offset: Int, in text: NSString) -> Int {
        var line = 0
        var index = 0
        let end = min(offset, text.length)
        while index < end {
            let unit = text.character(at: index)
            if unit == 0x0A || (unit == 0x0D && (index + 1 >= text.length || text.character(at: index + 1) != 0x0A)) { line += 1 }
            index += 1
        }
        return line
    }

    private static func lineText(at start: Int, in text: NSString) -> String {
        WaveformLineBreakpoint.lineText(text.substring(with: text.lineRange(for: NSRange(location: start, length: 0)))
            .trimmingCharacters(in: .newlines))
    }

    // MARK: To the viewer

    private static var syncTasks: [UUID: Task<Void, Never>] = [:]
    private static let sent = NSMapTable<FilePreviewPanel, NSString>.weakToStrongObjects()

    /// Breakpoints changed: the gutters redraw, the viewers hear soon.
    private static func changed(_ workspace: UUID, redraw: Bool = true) {
        if redraw { redrawGutters() }
        scheduleSync(workspace)
    }

    /// An editor learned (or changed) the instances it shows: the viewers may need other paths.
    static func instancesLearned(by editor: FilePreviewLanguageFeatures) {
        guard let workspace = editor.linkWorkspaceId, marks[workspace]?.contains(where: { $0.path == editor.filePath }) == true else { return }
        scheduleSync(workspace)
    }

    private static var refreshTasks: [UUID: Task<Void, Never>] = [:]

    /// Brings the marks' line numbers and texts up to date soon after an edit, so a file closed
    /// before the next sync or snapshot is found again by its current text.
    private static func scheduleRefresh(_ workspace: UUID) {
        refreshTasks[workspace]?.cancel()
        refreshTasks[workspace] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refreshTasks[workspace] = nil
            refreshPositions(in: workspace)
        }
    }

    private static func scheduleSync(_ workspace: UUID) {
        syncTasks[workspace]?.cancel()
        syncTasks[workspace] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            for waveform in viewers(inWorkspace: workspace) { await sync(waveform) }
        }
    }

    /// Sends `waveform` the workspace's line breakpoints when they differ from what it has
    /// (before a continue from cmux, so it searches the current ones).
    static func sync(_ waveform: FilePreviewPanel) async {
        let items = self.items(inWorkspace: waveform.workspaceId)
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]),
              let json = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else { return }
        // A new page has none: pageLoaded forgets what was sent.
        if sent.object(forKey: waveform) as String? == json as String { return }
        sent.setObject(json, forKey: waveform)
        _ = await waveform.nativeViewSessions.waveform.callDebugger("setLineBreakpoints", argument: ["items": items])
    }

    /// A new page has no breakpoints: it gets the lines and the workspace's signal breakpoints.
    static func pageLoaded(_ waveform: FilePreviewPanel) {
        sent.removeObject(forKey: waveform)
        Task { @MainActor in
            await sync(waveform)
            guard let list = signals[waveform.workspaceId], !list.isEmpty else { return }
            _ = await waveform.nativeViewSessions.waveform.callDebugger(
                "restoreBreakpoints", argument: ["items": list.map(\.pageItem)]
            )
        }
    }

    private static func viewers(inWorkspace workspace: UUID) -> [FilePreviewPanel] {
        var out: [FilePreviewPanel] = []
        for editor in FilePreviewLanguageFeatures.linkables(inWorkspace: workspace) {
            if let waveform = WaveformSourceLink.waveformPanel(near: editor.linkPanel), !out.contains(where: { $0 === waveform }) {
                out.append(waveform)
            }
        }
        return out
    }

    /// The page's items: `{ key, label, paths, enabled }`; a line whose file is closed, or whose
    /// module has no instance in the waveform yet, has no paths.
    static func items(inWorkspace workspace: UUID) -> [[String: Any]] {
        refreshPositions(in: workspace)
        let editors = FilePreviewLanguageFeatures.linkables(inWorkspace: workspace)
        return (marks[workspace] ?? []).map { mark in
            let label = "\((mark.path as NSString).lastPathComponent):\(mark.line + 1)"
            var paths: [[String]] = []
            var scope: [String]?
            if let editor = editors.first(where: { $0.filePath == mark.path }), let textView = editor.debuggerTextView,
               let offset = trackers.object(forKey: textView)?.offsets[mark.id], let storage = textView.textStorage,
               let line = editor.breakpointLine(at: offset), let module = line.module {
                let signals = WaveformLineBreakpoint.watchedSignals(of: line, in: storage.string as NSString)
                let instances = editor.breakpointInstances(ofModule: module)
                let dumps = mark.anyInstance ? instances.all : instances.shown.map { [$0] } ?? []
                // A condition's names are looked up in the (first) instance the line is watched in.
                scope = dumps.first.map { HierarchyPathMapping.segments($0) }
                for dump in dumps {
                    let scope = HierarchyPathMapping.segments(dump)
                    paths += signals.map { scope + [$0] }
                }
            }
            var item: [String: Any] = ["key": mark.id.uuidString, "label": label, "paths": paths, "enabled": mark.enabled && !mark.lost]
            if let condition = mark.condition { item["condition"] = condition }
            if let scope { item["scope"] = scope }
            return item
        }
    }

    private static func redrawGutters() {
        for case let textView as NSTextView in trackers.keyEnumerator().allObjects {
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    // MARK: Signal breakpoints

    /// A breakpoint the page made on a waveform signal (Break When Changes / Equals…).
    struct SignalBreakpoint: Codable, Equatable, Sendable {
        var path: [String]
        var kind: String
        var value: String?
        var enabled: Bool
        var condition: String? = nil

        var pageItem: [String: Any] {
            var item: [String: Any] = ["path": path, "kind": kind, "enabled": enabled]
            if let value { item["value"] = value }
            if let condition { item["condition"] = condition }
            return item
        }
    }

    /// The signal breakpoints a viewer of the workspace last had (a new page gets them back).
    private(set) static var signals: [UUID: [SignalBreakpoint]] = [:]

    /// `{ event: 'breakpoints', items: [{ path, kind, value, enabled }] }` from the page.
    static func signalsReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let items = body["items"] as? [[String: Any]] ?? []
        signals[waveform.workspaceId] = items.compactMap { item in
            guard let path = item["path"] as? [String], !path.isEmpty, let kind = item["kind"] as? String,
                  kind == "change" || kind == "equals" else { return nil }
            let condition = (item["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SignalBreakpoint(
                path: path, kind: kind, value: item["value"] as? String, enabled: item["enabled"] as? Bool ?? true, condition: condition
            )
        }
    }

    // MARK: Session

    /// The workspace's breakpoints, for its session snapshot; nil when it has none.
    static func snapshot(of workspace: UUID) -> SessionWaveformBreakpointsSnapshot? {
        refreshPositions(in: workspace)
        let lines = marks[workspace] ?? []
        let signals = self.signals[workspace] ?? []
        let watches = WaveformDebuggerEvaluate.snapshot(of: workspace)
        guard !lines.isEmpty || !signals.isEmpty || watches != nil else { return nil }
        return SessionWaveformBreakpointsSnapshot(
            lines: lines.isEmpty ? nil : lines, signals: signals.isEmpty ? nil : signals, watches: watches
        )
    }

    /// Breakpoints from a restored session: lines are placed by text when their files open,
    /// signal breakpoints go to the workspace's viewers when their pages load.
    static func restore(_ snapshot: SessionWaveformBreakpointsSnapshot?, in workspace: UUID) {
        guard let snapshot else { return }
        if let lines = snapshot.lines, !lines.isEmpty {
            marks[workspace] = lines
            changed(workspace)
        }
        if let restored = snapshot.signals, !restored.isEmpty { signals[workspace] = restored }
        WaveformDebuggerEvaluate.restore(snapshot.watches, in: workspace)
    }
}

/// A workspace's waveform debugger breakpoints (and watch expressions) in its session; absent in
/// older manifests and for workspaces without any.
struct SessionWaveformBreakpointsSnapshot: Codable, Sendable, Equatable {
    var lines: [WaveformDebuggerLineBreakpoints.Mark]?
    var signals: [WaveformDebuggerLineBreakpoints.SignalBreakpoint]?
    var watches: [String]? = nil
}
