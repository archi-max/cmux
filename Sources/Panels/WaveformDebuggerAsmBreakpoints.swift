import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// The waveform debugger's breakpoints in an assembly listing (objdump output, AsmListingParser):
/// F9 or a click in the listing's gutter puts one on an instruction; it hits when the dump's commit
/// stream commits that PC (the page's `pc` kind, cmux-debugger-commits.js, keyed by the mark's id).
/// Marks are kept by PC and symbol+offset (`AsmMark`), so they follow their code when the listing is
/// rebuilt. The listing also shows the current commit (an arrow in the gutter and a highlight), and
/// warns once when its encodings don't match what the dump committed.
@MainActor
enum WaveformDebuggerAsmBreakpoints {
    /// An open listing: its text view's parse, kept current 300 ms after an edit.
    final class Listing {
        weak var textView: NSTextView?
        let path: String
        var listing: AsmListing?
        /// UTF-16 offset of each line's start (the parser's 0-based lines).
        var lineStarts: [Int] = []
        var version = 0
        var parseTask: Task<Void, Never>?
        var observer: (any NSObjectProtocol)?
        /// The current commit's line, and the other commits of its cycle (highlighted lighter).
        var currentLine: Int?
        var otherLines: [Int] = []
        /// Ranges this listing highlighted (removed before the next).
        var highlighted: [NSRange] = []
        /// The dumps it was checked against (said once each).
        var checkedAgainst: Set<String> = []
        init(textView: NSTextView, path: String) {
            self.textView = textView
            self.path = path
        }
        deinit {
            parseTask?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        func lineStart(_ line: Int) -> Int? { line >= 0 && line < lineStarts.count ? lineStarts[line] : nil }
        func line(atOffset offset: Int) -> Int? {
            guard !lineStarts.isEmpty else { return nil }
            var lo = 0, hi = lineStarts.count
            while lo < hi { let mid = (lo + hi) / 2; if lineStarts[mid] <= offset { lo = mid + 1 } else { hi = mid } }
            return lo - 1
        }
    }

    private static let listings = NSMapTable<NSTextView, Listing>.weakToStrongObjects()

    /// Per workspace, in the order they were added.
    private(set) static var marks: [UUID: [AsmMark]] = [:]
    /// Marks whose condition the page could not parse (it says why): drawn as lost, never hit.
    private(set) static var badConditions: Set<UUID> = []

    /// The workspace a text view's file belongs to (the harness sets it).
    static var workspaceOf: @MainActor (NSTextView) -> UUID? = { (($0 as? SavingTextView)?.panel as? FilePreviewPanel)?.workspaceId }
    /// The waveform viewers of a workspace (the harness sets it).
    static var viewers: @MainActor (UUID) -> [FilePreviewPanel] = { workspace in
        AppDelegate.shared?.workspaceFor(tabId: workspace)?.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.previewMode == .waveform } ?? []
    }
    /// How long after an edit the listing is parsed again.
    static var reparseDelay: Duration = .milliseconds(300)
    /// Larger texts are not checked for being listings (the parser's cap is 4M lines).
    nonisolated static let maxListingBytes = 256 << 20

    // MARK: Attaching

    /// Keeps the text view's listing matched to its file: attached when the text is objdump output.
    static func sync(_ textView: NSTextView, filePath: String) {
        if let existing = listings.object(forKey: textView) {
            if existing.path == filePath { return }
            detach(textView)
        }
        guard let storage = textView.textStorage else { return }
        let state = Listing(textView: textView, path: filePath)
        listings.setObject(state, forKey: textView)
        state.observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak textView] _ in
            MainActor.assumeIsolated {
                guard let textView, let state = listings.object(forKey: textView),
                      textView.textStorage?.editedMask.contains(.editedCharacters) == true else { return }
                scheduleParse(state, delay: reparseDelay)
            }
        }
        scheduleParse(state, delay: .zero)
    }

    static func detach(_ textView: NSTextView) {
        guard let state = listings.object(forKey: textView) else { return }
        clearHighlight(state)
        listings.removeObject(forKey: textView)
    }

    /// The parsed listing of a text view, if it shows one.
    static func listing(in textView: NSTextView) -> Listing? {
        guard let state = listings.object(forKey: textView), state.listing != nil else { return nil }
        return state
    }

    /// Whether an open text view shows `path` as a listing (the debugger's commands then act on the workspace's viewer).
    static func showsListing(path: String) -> Bool {
        (listings.objectEnumerator()?.allObjects ?? []).contains { ($0 as? Listing).map { $0.path == path && $0.listing != nil } == true }
    }

    private static func scheduleParse(_ state: Listing, delay: Duration) {
        state.parseTask?.cancel()
        state.version += 1
        let version = state.version
        guard let text = state.textView?.string else { return }
        state.parseTask = Task { @MainActor [weak state] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let parsed = await Task.detached(priority: .userInitiated) { () -> (AsmListing, [Int])? in
                guard text.utf8.count <= maxListingBytes, AsmListingDetector.isListing(text) else { return nil }
                return (AsmListingParser.parse(text), lineStarts(of: text))
            }.value
            guard let state, state.version == version, !Task.isCancelled else { return }
            parsedListing(state, parsed)
        }
    }

    /// UTF-16 offsets of the line starts (after each LF).
    nonisolated static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    private static func parsedListing(_ state: Listing, _ parsed: (AsmListing, [Int])?) {
        state.listing = parsed?.0
        state.lineStarts = parsed?.1 ?? []
        if let listing = state.listing, let workspace = state.textView.flatMap(workspaceOf) {
            resolveMarks(of: state.path, in: listing, workspace: workspace)
            for waveform in viewers(workspace) { checkMatch(state, waveform: waveform) }
        }
        redraw(state)
    }

    /// The marks of `path` re-placed in its new parse (they follow their code; see AsmMark.resolved).
    private static func resolveMarks(of path: String, in listing: AsmListing, workspace: UUID) {
        guard var list = marks[workspace], list.contains(where: { $0.listingPath == path }) else { return }
        var changedAny = false
        for i in list.indices where list[i].listingPath == path {
            let placed = list[i].resolved(in: listing).mark
            if placed != list[i] { list[i] = placed; changedAny = true }
        }
        marks[workspace] = list
        if changedAny { changed(workspace) } else { redrawGutters() }
    }

    // MARK: Editing

    /// The mark on `line` of the listing (an instruction's line), if any.
    private static func mark(atLine line: Int, in state: Listing, workspace: UUID) -> AsmMark? {
        guard let listing = state.listing else { return nil }
        return (marks[workspace] ?? []).first { $0.listingPath == state.path && !$0.lost && listing.line(forPC: $0.pc) == line }
    }

    /// F9 in a listing: a breakpoint on the caret's instruction, or none if it had one. False when
    /// the focused view is not a listing (the key goes on).
    static func toggleAtCaret(window: NSWindow?) -> Bool {
        guard let textView = AppDelegate.shared?.shortcutFocusedSavingTextView(in: window) else { return false }
        return toggle(in: textView, at: textView.selectedRange().location)
    }

    /// A breakpoint on the instruction of the line holding UTF-16 offset `index` (a label or blank
    /// line: the next instruction), or none if it had one. False when the view shows no listing.
    @discardableResult
    static func toggle(in textView: NSTextView, at index: Int) -> Bool {
        guard let state = listing(in: textView), let listing = state.listing, let workspace = workspaceOf(textView),
              let line = state.line(atOffset: index) else { return false }
        guard let target = listing.instructionLine(atOrAfter: line), let inst = listing.instruction(atLine: target) else {
            NSSound.beep()
            return true
        }
        if let existing = mark(atLine: target, in: state, workspace: workspace) {
            remove(existing.id, in: workspace)
            return true
        }
        marks[workspace, default: []].append(AsmMark(listing: listing, instruction: inst, listingPath: state.path))
        changed(workspace)
        return true
    }

    static func remove(_ id: UUID, in workspace: UUID) {
        marks[workspace]?.removeAll { $0.id == id }
        badConditions.remove(id)
        changed(workspace)
    }

    static func setEnabled(_ id: UUID, _ enabled: Bool, in workspace: UUID) {
        update(id, in: workspace) { $0.enabled = enabled }
    }

    /// The breakpoint's condition; nil or blank clears it. The page checks it parses (and says why not).
    static func setCondition(_ id: UUID, _ condition: String?, in workspace: UUID) {
        let trimmed = condition?.trimmingCharacters(in: .whitespacesAndNewlines)
        badConditions.remove(id)
        update(id, in: workspace) { $0.condition = trimmed?.isEmpty == false ? trimmed : nil }
    }

    private static func update(_ id: UUID, in workspace: UUID, _ change: (inout AsmMark) -> Void) {
        guard let index = marks[workspace]?.firstIndex(where: { $0.id == id }) else { return }
        change(&marks[workspace]![index])
        changed(workspace)
    }

    /// The page's list toggled, removed or re-conditioned one: `{ event: 'pcBreakpoint', key, enabled?,
    /// removed?, condition?, conditionError? }`.
    static func pageReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        guard let key = body["key"] as? String, let id = UUID(uuidString: key) else { return }
        let workspace = waveform.workspaceId
        if body["removed"] as? Bool == true {
            remove(id, in: workspace)
            return
        }
        if let enabled = body["enabled"] as? Bool, marks[workspace]?.first(where: { $0.id == id })?.enabled != enabled {
            setEnabled(id, enabled, in: workspace)
        }
        if body.keys.contains("condition") { setCondition(id, body["condition"] as? String, in: workspace) }
        if let bad = body["conditionError"] as? Bool, bad != badConditions.contains(id) {
            if bad { badConditions.insert(id) } else { badConditions.remove(id) }
            redrawGutters()
        }
    }

    private static func changed(_ workspace: UUID) {
        redrawGutters()
        scheduleSync(workspace)
    }

    // MARK: Gutter

    /// The gutter's dots in a listing: line start offset → style. Nil for a view that shows no listing.
    static func styles(in textView: NSTextView) -> [Int: FilePreviewLineNumberGutterView.BreakpointMark]? {
        guard let state = listing(in: textView), let listing = state.listing, let workspace = workspaceOf(textView) else { return nil }
        var styles: [Int: FilePreviewLineNumberGutterView.BreakpointMark] = [:]
        for mark in marks[workspace] ?? [] where mark.listingPath == state.path {
            guard !mark.lost, let line = listing.line(forPC: mark.pc), let start = state.lineStart(line) else { continue }
            styles[start] = mark.enabled && badConditions.contains(mark.id) ? .lost
                : (mark.enabled ? (mark.condition == nil ? .enabled : .conditional) : .disabled)
        }
        return styles
    }

    /// The current commit's line start in a listing (the gutter's arrow), or nil.
    static func currentLineStart(in textView: NSTextView) -> Int? {
        guard let state = listing(in: textView), let line = state.currentLine else { return nil }
        return state.lineStart(line)
    }

    static func gutterClicked(_ textView: NSTextView, lineStart start: Int) -> Bool {
        guard listing(in: textView) != nil else { return false }
        return toggle(in: textView, at: start)
    }

    /// The menu of an instruction line: run the viewer to its next or previous commit; on a breakpoint's
    /// dot also enable, condition, remove. Nil on a line that is no instruction.
    static func gutterMenu(_ textView: NSTextView, lineStart start: Int) -> NSMenu? {
        guard let state = listing(in: textView), let workspace = workspaceOf(textView), let line = state.line(atOffset: start),
              let pc = state.listing?.pc(forLine: line) else { return nil }
        let menu = NSMenu()
        menu.addItem(MenuItem(
            title: String(localized: "waveformDebugger.asm.runToNext", defaultValue: "Run to Next Commit Here")
        ) { runTo(pc: pc, dir: 1, inWorkspace: workspace) })
        menu.addItem(MenuItem(
            title: String(localized: "waveformDebugger.asm.runToPrevious", defaultValue: "Run to Previous Commit Here")
        ) { runTo(pc: pc, dir: -1, inWorkspace: workspace) })
        guard let mark = mark(atLine: line, in: state, workspace: workspace) else { return menu }
        let id = mark.id
        menu.addItem(.separator())
        menu.addItem(MenuItem(
            title: mark.enabled
                ? String(localized: "waveformDebugger.lineBreakpoint.disable", defaultValue: "Disable Breakpoint")
                : String(localized: "waveformDebugger.lineBreakpoint.enable", defaultValue: "Enable Breakpoint")
        ) { setEnabled(id, !mark.enabled, in: workspace) })
        let label = self.label(of: mark)
        menu.addItem(MenuItem(
            title: String(localized: "waveformDebugger.lineBreakpoint.editCondition", defaultValue: "Edit Condition…")
        ) { [weak textView] in
            guard let answer = WaveformDebuggerEvaluate.promptCondition(current: mark.condition, for: label, window: textView?.window)
            else { return }
            setCondition(id, answer, in: workspace)
        })
        if mark.condition != nil {
            menu.addItem(MenuItem(
                title: String(localized: "waveformDebugger.lineBreakpoint.removeCondition", defaultValue: "Remove Condition")
            ) { setCondition(id, nil, in: workspace) })
        }
        menu.addItem(.separator())
        menu.addItem(MenuItem(
            title: String(localized: "waveformDebugger.removeBreakpoint", defaultValue: "Remove Breakpoint")
        ) { remove(id, in: workspace) })
        return menu
    }

    /// The workspace's viewer runs to `pc`'s next (1) or previous (-1) commit (no breakpoint is added).
    static func runTo(pc: UInt64, dir: Int, inWorkspace workspace: UUID) {
        guard let waveform = viewers(workspace).first else { NSSound.beep(); return }
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("runToPc", argument: ["pcs": [hex(pc)], "dir": dir])
        }
    }

    @MainActor private final class MenuItem: NSMenuItem {
        private let run: @MainActor () -> Void
        init(title: String, run: @escaping @MainActor () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(runItem), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func runItem() { run() }
    }

    private static func redrawGutters() {
        for case let textView as NSTextView in listings.keyEnumerator().allObjects {
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    private static func redraw(_ state: Listing) {
        state.textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: The page

    static func hex(_ pc: UInt64) -> String { "0x" + String(pc, radix: 16) }

    /// `sum.dis: main+0x8`, or the PC when the instruction has no symbol.
    static func label(of mark: AsmMark) -> String {
        let file = (mark.listingPath as NSString).lastPathComponent
        let at = mark.symbol.map { mark.offset == 0 ? $0 : "\($0)+0x\(String(mark.offset, radix: 16))" } ?? hex(mark.pc)
        return "\(file): \(at)"
    }

    /// The page's items: `{ key, listingLabel, pcs, channel?, enabled, condition? }`; a lost mark is off.
    static func items(inWorkspace workspace: UUID) -> [[String: Any]] {
        (marks[workspace] ?? []).map { mark in
            var item: [String: Any] = ["key": mark.id.uuidString, "listingLabel": label(of: mark), "pcs": [hex(mark.pc)],
                                       "enabled": mark.enabled && !mark.lost]
            if let condition = mark.condition { item["condition"] = condition }
            if let channel = mark.channel { item["channel"] = channel }
            return item
        }
    }

    private static var syncTasks: [UUID: Task<Void, Never>] = [:]
    private static let sent = NSMapTable<FilePreviewPanel, NSString>.weakToStrongObjects()

    private static func scheduleSync(_ workspace: UUID) {
        syncTasks[workspace]?.cancel()
        syncTasks[workspace] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            syncTasks[workspace] = nil
            for waveform in viewers(workspace) { await sync(waveform) }
        }
    }

    /// Sends `waveform` the workspace's listing breakpoints when they differ from what it has.
    static func sync(_ waveform: FilePreviewPanel) async {
        let items = self.items(inWorkspace: waveform.workspaceId)
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]),
              let json = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else { return }
        if sent.object(forKey: waveform) as String? == json as String { return }
        sent.setObject(json, forKey: waveform)
        _ = await waveform.nativeViewSessions.waveform.callDebugger("setPcBreakpoints", argument: ["items": items])
    }

    /// A new page has none: it gets them again, and each open listing is checked against its dump.
    static func pageLoaded(_ waveform: FilePreviewPanel) {
        sent.removeObject(forKey: waveform)
        for case let state as Listing in listings.objectEnumerator()?.allObjects ?? [] {
            state.checkedAgainst.remove(waveform.filePath)
        }
        Task { @MainActor in await sync(waveform) }
    }

    /// The commit stream is ready in `waveform` (`{ event: 'commitsReady' }`): the listings are checked against it.
    static func commitsReady(_ waveform: FilePreviewPanel) {
        for case let state as Listing in listings.objectEnumerator()?.allObjects ?? [] {
            guard let textView = state.textView, workspaceOf(textView) == waveform.workspaceId else { continue }
            checkMatch(state, waveform: waveform)
        }
    }

    /// Says once per listing and dump when the listing's encodings are not what the dump committed.
    private static func checkMatch(_ state: Listing, waveform: FilePreviewPanel) {
        guard state.listing != nil, !state.checkedAgainst.contains(waveform.filePath) else { return }
        Task { @MainActor [weak state] in
            let sample = await waveform.nativeViewSessions.waveform.callDebugger("commitSample", argument: ["limit": 1000])
            guard let state, let listing = state.listing, let rows = sample as? [[String: Any]], !rows.isEmpty,
                  !state.checkedAgainst.contains(waveform.filePath) else { return }
            state.checkedAgainst.insert(waveform.filePath)
            let committed: [(pc: UInt64, insn: UInt64)] = rows.compactMap { row in
                guard let pc = (row["pc"] as? String).flatMap(parseHex), let insn = (row["insn"] as? NSNumber)?.uint64Value else { return nil }
                return (pc, insn)
            }
            let match = listing.match(committed: committed)
            guard let text = mismatchText(match, listingPath: state.path) else { return }
            _ = await waveform.nativeViewSessions.waveform.callDebugger("say", argument: ["text": text, "level": "warning"])
        }
    }

    /// The warning for a listing that doesn't match the dump, or nil when it does (or nothing was compared).
    static func mismatchText(_ match: AsmListingMatch, listingPath: String) -> String? {
        let file = (listingPath as NSString).lastPathComponent
        if match.checked == 0 {
            guard match.notInListing > 0 else { return nil }
            return String(
                format: String(
                    localized: "waveformDebugger.asm.noPCsInListing",
                    defaultValue: "%1$@ doesn't match this dump: none of the %2$@ committed PCs checked are in it."
                ),
                file, String(match.notInListing)
            )
        }
        guard !match.agrees, let first = match.firstMismatch else { return nil }
        return String(
            format: String(
                localized: "waveformDebugger.asm.mismatch",
                defaultValue: "%1$@ doesn't match this dump: %2$@ of %3$@ committed instructions differ (first at %4$@: committed %5$@, listing %6$@)."
            ),
            file, String(match.checked - match.matched), String(match.checked), hex(first.pc), hex(first.committed), hex(first.listing)
        )
    }

    static func parseHex(_ text: String) -> UInt64? {
        let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt64(digits, radix: 16)
    }

    // MARK: The current commit

    /// The page's commits at the marker: `{ event: 'commitPcs', pcs: [hex], current: hex | null }` (empty on Stop).
    static func currentReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let current = (body["current"] as? String).flatMap(parseHex)
        let pcs = (body["pcs"] as? [String] ?? []).compactMap(parseHex)
        for case let state as Listing in listings.objectEnumerator()?.allObjects ?? [] {
            guard let textView = state.textView, workspaceOf(textView) == waveform.workspaceId, let listing = state.listing else { continue }
            let line = current.flatMap { listing.line(forPC: $0) }
            let others = pcs.filter { $0 != current }.compactMap { listing.line(forPC: $0) }
            guard line != state.currentLine || others != state.otherLines else { continue }
            state.currentLine = line
            state.otherLines = others
            highlight(state)
            if let line { reveal(line: line, in: state, onlyIfHidden: true) }
        }
    }

    private static func lineRange(_ line: Int, in state: Listing) -> NSRange? {
        guard let start = state.lineStart(line), let length = state.textView?.textStorage?.length, start <= length else { return nil }
        let end = state.lineStart(line + 1).map { min($0, length) } ?? length
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func clearHighlight(_ state: Listing) {
        guard let layout = state.textView?.layoutManager else { state.highlighted = []; return }
        let length = state.textView?.textStorage?.length ?? 0
        for range in state.highlighted where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        state.highlighted = []
    }

    private static func highlight(_ state: Listing) {
        clearHighlight(state)
        guard let layout = state.textView?.layoutManager else { redraw(state); return }
        for other in state.otherLines {
            guard let range = lineRange(other, in: state) else { continue }
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.12), forCharacterRange: range)
            state.highlighted.append(range)
        }
        if let line = state.currentLine, let range = lineRange(line, in: state) {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.25), forCharacterRange: range)
            state.highlighted.append(range)
        }
        redraw(state)
    }

    /// The line scrolled into view (only when it is off-screen, with `onlyIfHidden`).
    private static func reveal(line: Int, in state: Listing, onlyIfHidden: Bool) {
        guard let textView = state.textView, let range = lineRange(line, in: state) else { return }
        if onlyIfHidden, let layout = textView.layoutManager, let container = textView.textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let visible = textView.visibleRect
            if rect.minY >= visible.minY && rect.maxY <= visible.maxY { return }
        }
        textView.scrollRangeToVisible(range)
        if !onlyIfHidden { textView.setSelectedRange(NSRange(location: range.location, length: 0)) }
    }

    /// Show Instruction in Listing: the current commit's PC in an open listing of the workspace. False
    /// when no listing open has it.
    static func revealCurrent(of waveform: FilePreviewPanel) async -> Bool {
        let answer = await waveform.nativeViewSessions.waveform.callDebugger("currentCommitPc")
        guard let pc = (answer as? String).flatMap(parseHex) else { return false }
        return reveal(pc: pc, inWorkspace: waveform.workspaceId)
    }

    @discardableResult
    static func reveal(pc: UInt64, inWorkspace workspace: UUID) -> Bool {
        for case let state as Listing in listings.objectEnumerator()?.allObjects ?? [] {
            guard let textView = state.textView, workspaceOf(textView) == workspace,
                  let line = state.listing?.line(forPC: pc) else { continue }
            reveal(line: line, in: state, onlyIfHidden: false)
            textView.window?.makeFirstResponder(textView)
            return true
        }
        return false
    }

    // MARK: Session

    static func sessionMarks(of workspace: UUID) -> [AsmMark]? {
        let list = marks[workspace] ?? []
        return list.isEmpty ? nil : list
    }

    static func restore(_ list: [AsmMark]?, in workspace: UUID) {
        guard let list, !list.isEmpty else { return }
        marks[workspace] = list
        for case let state as Listing in listings.objectEnumerator()?.allObjects ?? [] {
            guard let textView = state.textView, workspaceOf(textView) == workspace, let listing = state.listing else { continue }
            resolveMarks(of: state.path, in: listing, workspace: workspace)
        }
        changed(workspace)
    }

    #if DEBUG
    /// For the harness: forget everything.
    static func resetForChecks() {
        marks = [:]
        badConditions = []
        for case let textView as NSTextView in listings.keyEnumerator().allObjects { detach(textView) }
    }
    #endif
}
