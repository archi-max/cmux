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
    /// Marks whose condition the page could not parse (it says why): drawn as lost, never hit.
    private(set) static var badConditions: Set<UUID> = []

    /// Where the marks of an open file are, kept through the text view's edits.
    private final class Tracker {
        weak var storage: NSTextStorage?
        let workspace: UUID
        let path: String
        var offsets: [UUID: Int] = [:]
        /// Each mark's line as it is now (raw, without its line break), kept per edit in O(line).
        var lineTexts: [UUID: String] = [:]
        var observer: (any NSObjectProtocol)?
        var willObserver: (any NSObjectProtocol)?
        /// The edit as it was made (willProcessEditing): by didProcessEditing AppKit's attribute
        /// fixing has widened editedRange (to the next line start, or the whole paragraph).
        var exactEdit: (range: NSRange, delta: Int)?
        /// The text before the edits since: a copy taken when marks appear, and the edits made since
        /// as (range in the text then, its new characters). Only a large edit (a Format Document or
        /// a reload) or one that moves a mark's line start needs the old text; typing only logs.
        /// Nil while the file has no marks: then an edit costs nothing.
        var snapshot: NSString?
        var log: [(range: NSRange, text: String)] = []
        /// The marks were placed by text; not while the storage is still empty (the file loading).
        var placed = false
        /// Marks an edit merged into another's line, with the text that edit took out: the undo that
        /// puts that text back brings them back (and no other undo does).
        var merged: [(mark: Mark, removed: String)] = []
        var hasMarks: Bool { !offsets.isEmpty || !merged.isEmpty }
        init(storage: NSTextStorage, workspace: UUID, path: String) {
            self.storage = storage
            self.workspace = workspace
            self.path = path
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let willObserver { NotificationCenter.default.removeObserver(willObserver) }
        }
        /// The text before the current edit.
        func oldText() -> NSString {
            guard let snapshot else { return "" }
            guard !log.isEmpty else { return snapshot }
            let text = NSMutableString(string: snapshot)
            for edit in log { text.replaceCharacters(in: edit.range, with: edit.text) }
            return text
        }
        /// The current text is the old text from here on (an O(file) copy: not per keystroke).
        func takeSnapshot() {
            if hasMarks, let storage { snapshot = NSString(string: storage.string) } else { snapshot = nil }
            log = []
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
        let first = !tracker.hasMarks
        tracker.offsets[mark.id] = start
        tracker.lineTexts[mark.id] = rawLine(at: start, in: text)
        // A mark made here is where it is (an empty new file is not one still loading).
        tracker.placed = true
        if first { tracker.takeSnapshot() }
        changed(workspace)
        return true
    }

    static func remove(_ id: UUID, in workspace: UUID) {
        marks[workspace]?.removeAll { $0.id == id }
        for case let tracker as Tracker in trackers.objectEnumerator()?.allObjects ?? [] {
            tracker.offsets[id] = nil
            tracker.lineTexts[id] = nil
            tracker.merged.removeAll { $0.mark.id == id }
        }
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
        if let bad = body["conditionError"] as? Bool, bad != badConditions.contains(id) {
            if bad { badConditions.insert(id) } else { badConditions.remove(id) }
            redrawGutters()
        }
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
            styles[offset] = mark.lost || (mark.enabled && badConditions.contains(id)) ? .lost
                : (mark.enabled ? (mark.condition == nil ? .enabled : .conditional) : .disabled)
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
        tracker.takeSnapshot()
        tracker.willObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.willProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                guard let textView, let tracker = trackers.object(forKey: textView), let storage = tracker.storage else { return }
                tracker.exactEdit = storage.editedMask.contains(.editedCharacters) ? (storage.editedRange, storage.changeInLength) : nil
            }
        }
        tracker.observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak textView] _ in
            // Posted on the main thread (queue nil): the observed storage, which the tracker holds.
            MainActor.assumeIsolated {
                guard let textView, let tracker = trackers.object(forKey: textView), let storage = tracker.storage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                let exact = tracker.exactEdit
                tracker.exactEdit = nil
                if !tracker.placed {
                    guard storage.length > 0 else { return }
                    place(tracker, in: storage)
                    tracker.takeSnapshot()
                    changed(tracker.workspace)
                    return
                }
                // No breakpoints in this file: nothing to keep up per keystroke.
                guard tracker.hasMarks else {
                    tracker.snapshot = nil
                    tracker.log = []
                    return
                }
                edited(tracker, storage: storage, edit: exact ?? (storage.editedRange, storage.changeInLength), undoing: isUndoing(textView))
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
        let table = lineTable(of: text)
        let starts = table.starts
        var taken: Set<Int> = []
        guard var list = marks[tracker.workspace] else { return }
        // Every line by the text marks compare, read once (not one pass over the file per mark).
        var byText: [String: [Int]] = [:]
        if list.contains(where: { $0.path == tracker.path }) {
            for (number, line) in table.texts.enumerated() { byText[WaveformLineBreakpoint.lineText(line), default: []].append(number) }
        }
        for index in list.indices where list[index].path == tracker.path {
            var mark = list[index]
            let wanted = WaveformLineBreakpoint.lineText(mark.text)
            let near = mark.line
            // The nearest free line with its text (the earlier on a tie).
            let match = wanted.isEmpty ? nil : (byText[wanted] ?? []).filter { !taken.contains($0) }
                .min { (abs($0 - near), $0) < (abs($1 - near), $1) }
            if let line = match {
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
            tracker.lineTexts[mark.id] = rawLine(at: starts[mark.line], in: text)
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

    /// Moves the file's breakpoints with an edit. Typing (an edit that takes out no mark's line
    /// start) costs O(edit + marks): offsets after it shift, a mark before it stays (also when its
    /// line is split or another is joined into it), and the edited line's text is re-read.
    /// Anything else goes to `relocate`, which looks at the old text.
    private static func edited(_ tracker: Tracker, storage: NSTextStorage, edit: (range: NSRange, delta: Int), undoing: Bool) {
        let text = storage.string as NSString
        // The edit as made, not as widened by attribute fixing (Tracker.exactEdit).
        let edited = edit.range
        let delta = edit.delta
        // A whole-range replace (Format Document, a reload) or a large paste: compare with the old text.
        if edited.length > 1024 || (undoing && !tracker.merged.isEmpty) {
            relocate(tracker, text: text, edited: edited, undoing: undoing)
            return
        }
        let start = edited.location, newEnd = NSMaxRange(edited), oldEnd = newEnd - delta
        let inserted = text.substring(with: edited)
        let editLine = WaveformLineBreakpoint.lineStart(containing: start, in: text)
        // A mark's line start taken out or replaced: compare with the old text.
        if oldEnd > start, tracker.offsets.values.contains(where: { $0 >= start && $0 <= oldEnd }) {
            relocate(tracker, text: text, edited: edited, undoing: undoing)
            return
        }
        let splits = inserted.rangeOfCharacter(from: .newlines) != nil
        var moved: [UUID: Int] = [:]
        var dropped: [UUID] = []
        // In offset order: of two that meet on one line, the one already at its start stays.
        for (id, offset) in tracker.offsets.sorted(by: { $0.value < $1.value }) {
            var new = offset > oldEnd ? offset + delta
                : (offset == oldEnd && offset >= start ? WaveformLineBreakpoint.lineStart(containing: offset + delta, in: text) : offset)
            // Its line split: it goes with its statement (Enter in the indentation moves it down).
            if splits && offset == editLine && offset < start, let old = tracker.lineTexts[id] {
                new = splitLine(old: old, head: offset, tail: WaveformLineBreakpoint.lineStart(containing: newEnd, in: text), in: text)
            }
            if moved.values.contains(new) { dropped.append(id); continue }
            moved[id] = new
        }
        tracker.offsets = moved
        for (id, offset) in moved where offset >= editLine && offset <= newEnd { tracker.lineTexts[id] = rawLine(at: offset, in: text) }
        merge(dropped, in: tracker, removed: "")
        tracker.log.append((NSRange(location: start, length: oldEnd - start), inserted))
        if tracker.log.count > 4096 { tracker.takeSnapshot() }
        changed(tracker.workspace, redraw: true)
    }

    /// Moves the marks with an edit by comparing the old text with the new (O(file)). The span
    /// that really changed is, for a whole or large replace, the edited range narrowed to where
    /// the texts differ (a reload replaces everything but changes less). A mark before the span stays; one after it moves by
    /// the change in length; one whose line the span touched goes to the line its old line now
    /// lines up with (by the unchanged lines around it), else to its text (exact, then ignoring
    /// whitespace) nearest that line. A reload or Format Document never drops one: when its line
    /// is taken it goes to the nearest free line, lost and disabled. A user's edit that puts two on
    /// one line keeps one, the other kept aside for the undo that puts its text back.
    private static func relocate(_ tracker: Tracker, text: NSString, edited: NSRange, undoing: Bool) {
        let old = tracker.oldText()
        let whole = edited.location == 0 && edited.length == text.length
        let delta = text.length - old.length
        // A user's edit changed exactly its range (narrowing it could move a deleted line's start
        // into the next line); a whole or large replace changed only where the texts differ.
        let span = whole || edited.length > 1024
            ? changedSpan(old: old, new: text, edited: edited)
            : (start: edited.location, oldEnd: NSMaxRange(edited) - delta)
        let newSpanEnd = span.oldEnd + delta
        let oldTable = lineTable(of: old), newTable = lineTable(of: text)
        let oldLineOf = { (offset: Int) in lineIndex(of: offset, in: oldTable.starts) }
        let newLineOf = { (offset: Int) in lineIndex(of: offset, in: newTable.starts) }
        let byId = Dictionary((marks[tracker.workspace] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var taken: [Int: UUID] = [:]
        var inside: [(id: UUID, line: Int, text: String)] = []
        var dropped: [UUID] = []
        let joinsOrSplits = old.substring(with: NSRange(location: span.start, length: span.oldEnd - span.start)).rangeOfCharacter(from: .newlines) != nil
            || text.substring(with: NSRange(location: span.start, length: newSpanEnd - span.start)).rangeOfCharacter(from: .newlines) != nil
        for (id, offset) in tracker.offsets.sorted(by: { $0.value < $1.value }) {
            // Its line start was in the changed span (a line start before it is still one, on the
            // same line: a mark there stays, also when lines are joined into or split off its line).
            let touched = joinsOrSplits && offset >= span.start && offset < span.oldEnd
            if touched {
                let line = oldLineOf(offset)
                inside.append((id, line, oldTable.texts[line]))
                continue
            }
            var start = WaveformLineBreakpoint.lineStart(containing: offset >= span.oldEnd ? offset + delta : offset, in: text)
            // Its line split by the edit: it goes with its statement.
            if joinsOrSplits && offset < span.start && span.start <= NSMaxRange(old.lineRange(for: NSRange(location: offset, length: 0))) {
                let tail = WaveformLineBreakpoint.lineStart(containing: newSpanEnd, in: text)
                if taken[newLineOf(tail)] == nil { start = splitLine(old: oldTable.texts[oldLineOf(offset)], head: start, tail: tail, in: text) }
            }
            let line = newLineOf(start)
            if taken[line] != nil { dropped.append(id); continue }
            taken[line] = id
        }
        var lost: Set<UUID> = []
        if !inside.isEmpty {
            // Old line → new line through the span's lines that are the same, once each, in both.
            let firstOld = oldLineOf(span.start), lastOld = oldLineOf(max(span.start, span.oldEnd))
            let lastNew = newLineOf(max(span.start, newSpanEnd))
            let anchors = alignment(old: Array(oldTable.texts[firstOld...lastOld]), new: Array(newTable.texts[firstOld...lastNew]))
                .map { (old: $0.old + firstOld, new: $0.new + firstOld) }
            // Where an old line lines up, and whether the lines between its neighbours are one for one
            // (so a changed line there is the same statement changed).
            let aligned = { (line: Int) -> (line: Int, oneForOne: Bool) in
                let above = anchors.last { $0.old <= line } ?? (old: firstOld - 1, new: firstOld - 1)
                let below = anchors.first { $0.old > line } ?? (old: lastOld + 1, new: lastNew + 1)
                let target = max(0, min(newTable.starts.count - 1, min(above.new + (line - above.old), below.new - 1 < above.new + 1 ? above.new + 1 : below.new - 1)))
                return (target, below.old - above.old == below.new - above.new)
            }
            for mark in inside {
                // A user's edit that took out the whole line takes its breakpoint (kept for the undo).
                let oldRange = old.lineRange(for: NSRange(location: oldTable.starts[mark.line], length: 0))
                if !whole && oldRange.location >= span.start && NSMaxRange(oldRange) <= span.oldEnd {
                    dropped.append(mark.id)
                    continue
                }
                let (target, oneForOne) = aligned(mark.line)
                let wanted = WaveformLineBreakpoint.lineText(mark.text)
                let bare = squeezed(mark.text)
                var line: Int?
                if taken[target] == nil, WaveformLineBreakpoint.lineText(newTable.texts[target]) == wanted || squeezed(newTable.texts[target]) == bare {
                    line = target
                } else if let match = nearest(in: newTable.texts, near: target, where: { taken[$0] == nil }, matching: { WaveformLineBreakpoint.lineText($0) == wanted })
                            ?? nearest(in: newTable.texts, near: target, where: { taken[$0] == nil }, matching: { squeezed($0) == bare }) {
                    line = match
                } else if taken[target] == nil && oneForOne {
                    // Its line was changed where it stands (the lines around it line it up one for one).
                    line = target
                } else if whole {
                    // Not found: never moved silently onto another statement, never dropped by a reload.
                    line = taken[target] == nil ? target : nearestFree(to: target, count: newTable.starts.count, taken: Set(taken.keys))
                    lost.insert(mark.id)
                } else if taken[target] == nil {
                    line = target
                }
                guard let line else { dropped.append(mark.id); continue }
                taken[line] = mark.id
            }
        }
        // An undo that puts back the text of an edit that merged marks: those come back.
        var restored: [Mark] = []
        if undoing, !tracker.merged.isEmpty {
            let putBack = text.substring(with: NSRange(location: span.start, length: newSpanEnd - span.start))
            tracker.merged.removeAll { entry in
                guard !entry.removed.isEmpty, putBack.contains(entry.removed) else { return false }
                let wanted = WaveformLineBreakpoint.lineText(entry.mark.text)
                guard let line = nearest(in: newTable.texts, near: entry.mark.line, where: { taken[$0] == nil },
                                         matching: { WaveformLineBreakpoint.lineText($0) == wanted }) else { return false }
                var back = entry.mark
                back.line = line
                taken[line] = back.id
                restored.append(back)
                return true
            }
        }
        tracker.offsets = Dictionary(uniqueKeysWithValues: taken.map { ($0.value, newTable.starts[$0.key]) })
        tracker.lineTexts = Dictionary(uniqueKeysWithValues: taken.map { ($0.value, newTable.texts[$0.key]) })
        if !lost.isEmpty {
            for index in marks[tracker.workspace]?.indices ?? 0..<0 where lost.contains(marks[tracker.workspace]![index].id) {
                marks[tracker.workspace]![index].lost = true
                marks[tracker.workspace]![index].enabled = false
            }
        }
        // What the edit took out, for the undo that puts it back.
        let removed = old.substring(with: NSRange(location: span.start, length: span.oldEnd - span.start))
        merge(dropped.map { id in (id, inside.first { $0.id == id }) }, in: tracker, removed: removed, byId: byId)
        if !restored.isEmpty { marks[tracker.workspace, default: []].append(contentsOf: restored) }
        tracker.takeSnapshot()
        changed(tracker.workspace, redraw: true)
    }

    /// A line `old` split in two (its head stays at `head`, the rest starts at `tail`): where its
    /// statement went. The head unless only the tail still reads as the old line.
    private static func splitLine(old: String, head: Int, tail: Int, in text: NSString) -> Int {
        guard tail != head else { return head }
        let wanted = squeezed(old)
        if squeezed(rawLine(at: head, in: text)) == wanted { return head }
        return squeezed(rawLine(at: tail, in: text)) == wanted ? tail : head
    }

    /// Marks an edit put on another's line: out of the list, kept for the undo of that edit.
    private static func merge(_ dropped: [UUID], in tracker: Tracker, removed: String) {
        let byId = Dictionary((marks[tracker.workspace] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        merge(dropped.map { ($0, nil) }, in: tracker, removed: removed, byId: byId)
    }

    private static func merge(_ dropped: [(id: UUID, at: (id: UUID, line: Int, text: String)?)], in tracker: Tracker,
                              removed: String, byId: [UUID: Mark]) {
        guard !dropped.isEmpty else { return }
        for entry in dropped {
            guard var mark = byId[entry.id] else { continue }
            if let at = entry.at {
                mark.line = at.line
                mark.text = WaveformLineBreakpoint.lineText(at.text)
            } else if let raw = tracker.lineTexts[entry.id] {
                mark.text = WaveformLineBreakpoint.lineText(raw)
            }
            tracker.merged.append((mark, removed))
            tracker.lineTexts[entry.id] = nil
        }
        if tracker.merged.count > 64 { tracker.merged.removeFirst(tracker.merged.count - 64) }
        let ids = Set(dropped.map(\.id))
        marks[tracker.workspace]?.removeAll { ids.contains($0.id) }
    }

    /// Pairs (old index, new index) of lines that are the same (ignoring whitespace) and appear
    /// once in each, kept in order in both (the longest such run, as patience diff does).
    private static func alignment(old: [String], new: [String]) -> [(old: Int, new: Int)] {
        var oldCount: [String: (count: Int, index: Int)] = [:], newCount: [String: (count: Int, index: Int)] = [:]
        for (index, line) in old.enumerated() { let key = squeezed(line); guard !key.isEmpty else { continue }; oldCount[key] = ((oldCount[key]?.count ?? 0) + 1, index) }
        for (index, line) in new.enumerated() { let key = squeezed(line); guard !key.isEmpty else { continue }; newCount[key] = ((newCount[key]?.count ?? 0) + 1, index) }
        let pairs = oldCount.compactMap { key, value -> (old: Int, new: Int)? in
            guard value.count == 1, let other = newCount[key], other.count == 1 else { return nil }
            return (value.index, other.index)
        }.sorted { $0.old < $1.old }
        // Longest increasing run of new indices.
        var tails: [Int] = [], previous = [Int](repeating: -1, count: pairs.count), tailIndex: [Int] = []
        for (k, pair) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if tails[mid] < pair.new { lo = mid + 1 } else { hi = mid } }
            if lo > 0 { previous[k] = tailIndex[lo - 1] }
            if lo == tails.count { tails.append(pair.new); tailIndex.append(k) } else { tails[lo] = pair.new; tailIndex[lo] = k }
        }
        var run: [(old: Int, new: Int)] = []
        var k = tailIndex.last ?? -1
        while k >= 0 { run.append(pairs[k]); k = previous[k] }
        return run.reversed()
    }

    /// The line of `texts` nearest `line` (the earlier on a tie) that `free` and `matching` accept.
    private static func nearest(in texts: [String], near line: Int, where free: (Int) -> Bool, matching: (String) -> Bool) -> Int? {
        guard !texts.isEmpty else { return nil }
        let start = max(0, min(line, texts.count - 1))
        for distance in 0..<texts.count {
            for candidate in [start - distance, start + distance] where candidate >= 0 && candidate < texts.count && free(candidate) && matching(texts[candidate]) {
                return candidate
            }
        }
        return nil
    }

    /// A line's text with no whitespace at all (Format Document may re-space inside a line).
    private static func squeezed(_ line: String) -> String {
        String(line.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
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

    /// The marks' line numbers and texts from where their open files have them (one pass per file
    /// with marks), and their trackers' old text brought up to date.
    private static func refreshPositions(in workspace: UUID) {
        guard var list = marks[workspace] else { return }
        for case let tracker as Tracker in trackers.objectEnumerator()?.allObjects ?? [] where tracker.workspace == workspace && tracker.hasMarks {
            guard let storage = tracker.storage else { continue }
            let text = storage.string as NSString
            let sorted = tracker.offsets.sorted { $0.value < $1.value }
            let lines = lineNumbers(at: sorted.map(\.value), in: text)
            for ((id, offset), line) in zip(sorted, lines) {
                guard let at = list.firstIndex(where: { $0.id == id }) else { continue }
                list[at].line = line
                list[at].text = WaveformLineBreakpoint.lineText(tracker.lineTexts[id] ?? rawLine(at: offset, in: text))
            }
            if !tracker.log.isEmpty { tracker.takeSnapshot() }
        }
        marks[workspace] = list
    }

    /// Every line's start and text (without its break): where texts are compared (placing, the old text).
    private static func lineTable(of text: NSString) -> (starts: [Int], texts: [String]) {
        var starts: [Int] = [], texts: [String] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
            starts.append(range.location)
            texts.append(line ?? "")
        }
        if starts.isEmpty || (text.length > 0 && isBreak(text.character(at: text.length - 1))) {
            starts.append(text.length)
            texts.append("")
        }
        return (starts, texts)
    }

    /// A line break as .byLines (the gutter) splits lines: \n, \r, U+0085, U+2028, U+2029.
    private static func isBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029 }

    private static func lineIndex(of offset: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= offset { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// The 0-based lines of ascending `offsets`, counted in one pass over the text up to the last.
    private static func lineNumbers(at offsets: [Int], in text: NSString) -> [Int] {
        var result: [Int] = []
        var line = 0, index = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        var previousCR = false
        for offset in offsets {
            let end = min(offset, text.length)
            while index < end {
                let count = min(buffer.count, end - index)
                text.getCharacters(&buffer, range: NSRange(location: index, length: count))
                for k in 0..<count {
                    let unit = buffer[k]
                    // \r\n is one break; a lone \r or \n is one, and so are U+0085, U+2028, U+2029 (as .byLines).
                    if unit == 0x0A { if !previousCR { line += 1 } } else if isBreak(unit) { line += 1 }
                    previousCR = unit == 0x0D
                }
                index += count
            }
            result.append(line)
        }
        return result
    }

    private static func lineNumber(at offset: Int, in text: NSString) -> Int {
        lineNumbers(at: [offset], in: text)[0]
    }

    /// The line at `start` as it is, without its break.
    private static func rawLine(at start: Int, in text: NSString) -> String {
        text.substring(with: text.lineRange(for: NSRange(location: min(start, text.length), length: 0))).trimmingCharacters(in: .newlines)
    }

    private static func lineText(at start: Int, in text: NSString) -> String {
        WaveformLineBreakpoint.lineText(rawLine(at: start, in: text))
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

    /// A new page has no breakpoints: it gets the lines, and its dump's signal breakpoints and watches.
    /// Viewers whose new page has not had its saved signal breakpoints (or watches) back yet: what
    /// such a page reports (its empty list, posted while it handles setLineBreakpoints) is not saved.
    private static let restoringSignals = NSHashTable<FilePreviewPanel>.weakObjects()
    private static let restoringWatches = NSHashTable<FilePreviewPanel>.weakObjects()

    static func pageLoaded(_ waveform: FilePreviewPanel) {
        sent.removeObject(forKey: waveform)
        // Read before any await: the page reports its own (empty) lists while it loads.
        let list = signals(for: waveform)
        let expressions = watches(for: waveform)
        if !list.isEmpty { restoringSignals.add(waveform) }
        if !expressions.isEmpty { restoringWatches.add(waveform) }
        Task { @MainActor in
            await sync(waveform)
            if !list.isEmpty {
                restoringSignals.remove(waveform)
                _ = await waveform.nativeViewSessions.waveform.callDebugger(
                    "restoreBreakpoints", argument: ["items": list.map(\.pageItem)]
                )
            }
            if !expressions.isEmpty {
                restoringWatches.remove(waveform)
                _ = await waveform.nativeViewSessions.waveform.callDebugger("restoreWatches", argument: ["items": expressions])
            }
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
            var groups: [[String: Any]] = []
            // Why a line has no paths, for the page's list: it watches nothing, or its file is too large to scan.
            var unwatched: String?
            scan: if let editor = editors.first(where: { $0.filePath == mark.path }), let textView = editor.debuggerTextView,
               let offset = trackers.object(forKey: textView)?.offsets[mark.id], let storage = textView.textStorage {
                guard let line = editor.breakpointLine(at: offset) else { unwatched = "tooLarge"; break scan }
                let signals = line.module == nil ? [] : WaveformLineBreakpoint.watchedSignals(of: line, in: storage.string as NSString)
                guard let module = line.module, !signals.isEmpty else { unwatched = "nothing"; break scan }
                let instances = editor.breakpointInstances(ofModule: module)
                let dumps = mark.anyInstance ? instances.all : instances.shown.map { [$0] } ?? []
                // A condition's names are looked up in the instance the line is watched in; in each
                // one's own when it breaks in any (groups: each instance's scope and paths).
                scope = dumps.first.map { HierarchyPathMapping.segments($0) }
                for dump in dumps {
                    let scope = HierarchyPathMapping.segments(dump)
                    let own = signals.map { scope + [$0] }
                    paths += own
                    if dumps.count > 1 { groups.append(["scope": scope, "paths": own]) }
                }
            }
            var item: [String: Any] = ["key": mark.id.uuidString, "label": label, "paths": paths, "enabled": mark.enabled && !mark.lost]
            if let condition = mark.condition { item["condition"] = condition }
            if let scope { item["scope"] = scope }
            if !groups.isEmpty { item["groups"] = groups }
            if let unwatched { item["unwatched"] = unwatched }
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

    /// Per workspace, per viewer's dump (its file path; "" for an older session's single list, which
    /// any viewer without its own gets): the signal breakpoints and the watch expressions its page last had.
    private(set) static var signals: [UUID: [String: [SignalBreakpoint]]] = [:]
    private(set) static var watches: [UUID: [String: [String]]] = [:]

    /// The page's limit on an expression's length (cmux-expr.js MAX_TEXT).
    static let maxExpressionLength = 1000

    static func signals(for waveform: FilePreviewPanel) -> [SignalBreakpoint] {
        let byDump = signals[waveform.workspaceId] ?? [:]
        return byDump[waveform.filePath] ?? byDump[""] ?? []
    }

    static func watches(for waveform: FilePreviewPanel) -> [String] {
        let byDump = watches[waveform.workspaceId] ?? [:]
        return byDump[waveform.filePath] ?? byDump[""] ?? []
    }

    /// `{ event: 'breakpoints', items: [{ path, kind, value, enabled, condition }] }` from the page.
    static func signalsReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let items = body["items"] as? [[String: Any]] ?? []
        // A new page's own list before it has the saved one back: not what the user has.
        if restoringSignals.contains(waveform) { return }
        // A viewer that was given an older session's list makes it its own: the list is not
        // given again to it (after it cleared it) or to other viewers.
        if signals[waveform.workspaceId]?[waveform.filePath] == nil { signals[waveform.workspaceId]?[""] = nil }
        signals[waveform.workspaceId, default: [:]][waveform.filePath] = items.compactMap { item in
            guard let path = item["path"] as? [String], !path.isEmpty, let kind = item["kind"] as? String,
                  kind == "change" || kind == "equals" else { return nil }
            let condition = (item["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SignalBreakpoint(
                path: path, kind: kind, value: item["value"] as? String, enabled: item["enabled"] as? Bool ?? true, condition: condition
            )
        }
    }

    /// `{ event: 'watches', items: [expr, ...] }` from the page.
    static func watchesReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let items = (body["items"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxExpressionLength }
        if restoringWatches.contains(waveform) { return }
        if watches[waveform.workspaceId]?[waveform.filePath] == nil { watches[waveform.workspaceId]?[""] = nil }
        watches[waveform.workspaceId, default: [:]][waveform.filePath] = items
    }

    // MARK: Session

    /// The workspace's breakpoints and watches, for its session snapshot; nil when it has none.
    static func snapshot(of workspace: UUID) -> SessionWaveformBreakpointsSnapshot? {
        refreshPositions(in: workspace)
        let lines = marks[workspace] ?? []
        let signalsByDump = (signals[workspace] ?? [:]).filter { !$0.value.isEmpty }
        let watchesByDump = (watches[workspace] ?? [:]).filter { !$0.value.isEmpty }
        guard !lines.isEmpty || !signalsByDump.isEmpty || !watchesByDump.isEmpty else { return nil }
        return SessionWaveformBreakpointsSnapshot(
            lines: lines.isEmpty ? nil : lines, signals: nil, watches: nil,
            signalsByDump: signalsByDump.isEmpty ? nil : signalsByDump,
            watchesByDump: watchesByDump.isEmpty ? nil : watchesByDump
        )
    }

    /// The last snapshot taken on the main thread, per workspace: what a session snapshot taken
    /// elsewhere saves (rather than nothing, which would erase the saved breakpoints).
    nonisolated(unsafe) private static var lastSnapshots: [UUID: SessionWaveformBreakpointsSnapshot] = [:]
    private nonisolated static let lastSnapshotsLock = NSLock()

    /// The workspace's breakpoints for its session snapshot, from any thread.
    nonisolated static func sessionSnapshot(of workspace: UUID) -> SessionWaveformBreakpointsSnapshot? {
        guard Thread.isMainThread else { return lastSnapshotsLock.withLock { lastSnapshots[workspace] } }
        let current = MainActor.assumeIsolated { snapshot(of: workspace) }
        lastSnapshotsLock.withLock { lastSnapshots[workspace] = current }
        return current
    }

    /// A session's breakpoints restored, from any thread (on the main thread, where they live).
    nonisolated static func sessionRestore(_ snapshot: SessionWaveformBreakpointsSnapshot?, in workspace: UUID) {
        guard let snapshot else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { restore(snapshot, in: workspace) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { restore(snapshot, in: workspace) } }
        }
    }

    /// Breakpoints from a restored session: lines are placed by text when their files open,
    /// signal breakpoints and watches go to their dumps' viewers when the pages load.
    static func restore(_ snapshot: SessionWaveformBreakpointsSnapshot?, in workspace: UUID) {
        guard let snapshot else { return }
        if let lines = snapshot.lines, !lines.isEmpty {
            marks[workspace] = lines
            // A file whose gutter drew before the restore has a tracker already: placed again now.
            for case let tracker as Tracker in trackers.objectEnumerator()?.allObjects ?? [] where tracker.workspace == workspace {
                guard let storage = tracker.storage, storage.length > 0 else { continue }
                tracker.offsets = [:]
                tracker.lineTexts = [:]
                tracker.merged = []
                place(tracker, in: storage)
                tracker.takeSnapshot()
            }
            changed(workspace)
        }
        var signalsByDump = snapshot.signalsByDump ?? [:]
        if let legacy = snapshot.signals, !legacy.isEmpty, signalsByDump[""] == nil { signalsByDump[""] = legacy }
        if !signalsByDump.isEmpty { signals[workspace] = signalsByDump }
        var watchesByDump = snapshot.watchesByDump ?? [:]
        if let legacy = snapshot.watches, !legacy.isEmpty, watchesByDump[""] == nil { watchesByDump[""] = legacy }
        if !watchesByDump.isEmpty { watches[workspace] = watchesByDump }
    }
}

/// A workspace's waveform debugger breakpoints (and watch expressions) in its session; absent in
/// older manifests and for workspaces without any.
struct SessionWaveformBreakpointsSnapshot: Codable, Sendable, Equatable {
    var lines: [WaveformDebuggerLineBreakpoints.Mark]?
    /// Before per-dump keys: one list for the workspace (read, not written).
    var signals: [WaveformDebuggerLineBreakpoints.SignalBreakpoint]?
    var watches: [String]? = nil
    /// Per viewer's dump (file path).
    var signalsByDump: [String: [WaveformDebuggerLineBreakpoints.SignalBreakpoint]]? = nil
    var watchesByDump: [String: [String]]? = nil
}
