// Line breakpoint checks (run.sh line-breakpoints): the real WaveformDebuggerLineBreakpoints.swift
// on windowless NSTextViews with stubbed editors and viewer: F9 and the gutter put a breakpoint on a
// line and take it off, it follows edits, the viewer gets the line's signals in the shown (or any)
// instance, the page's list removes or disables it, and a session brings it back on its line by text.
import AppKit

var failures = 0
@MainActor func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

let source = """
module core(input logic clk);
  logic [7:0] count, limit;
  logic done;
  always_ff @(posedge clk) count <= count + 1;
  assign done = count == limit;
  always_ff @(posedge clk) if (done) limit <= limit;
endmodule
"""

@MainActor func lineStart(_ line: Int, in text: String) -> Int {
    let starts = [0] + text.utf16.enumerated().filter { $0.element == 0x0A }.map { $0.offset + 1 }
    return starts[line]
}

@MainActor func run() async {
    typealias LB = WaveformDebuggerLineBreakpoints
    let workspace = UUID()
    let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.string = source
    let editor = FilePreviewLanguageFeatures(textView: view, path: "/rtl/core.sv", workspace: workspace)
    FilePreviewLanguageFeatures.all = [editor]
    editor.instances["core"] = (shown: "TOP.u_core", all: ["TOP.u_core", "TOP.u_core2"])
    let waveform = FilePreviewPanel(workspaceId: workspace)
    WaveformSourceLink.waveform = waveform
    AppDelegate.shared?.focused = view
    let page = waveform.nativeViewSessions.waveform

    func styles() -> [Int: FilePreviewLineNumberGutterView.BreakpointMark] { LB.styles(in: view) ?? [:] }
    func lastItems() -> [[String: Any]] { page.calls.last { $0.function == "setLineBreakpoints" }?.argument["items"] as? [[String: Any]] ?? [] }
    func describe(_ items: [[String: Any]]) -> [String] {
        items.map { item in
            let paths = (item["paths"] as? [[String]] ?? []).map { $0.joined(separator: ".") }.joined(separator: ",")
            return "\(item["label"] as? String ?? "?") [\(paths)] \(item["enabled"] as? Bool ?? false)"
        }
    }

    // F9 on the caret's line, and again to take it off.
    view.setSelectedRange(NSRange(location: lineStart(3, in: source) + 10, length: 0))
    expect(LB.toggleAtCaret(window: nil), "F9 in an SV editor is taken")
    expect(styles() == [lineStart(3, in: source): .enabled], "a dot on line 4: \(styles())")
    await LB.sync(waveform)
    expect(describe(lastItems()) == ["core.sv:4 [TOP.u_core.count] true"], "the viewer gets what line 4 assigns, in the shown instance: \(describe(lastItems()))")
    let calls = page.calls.count
    await LB.sync(waveform)
    expect(page.calls.count == calls, "nothing changed: not sent again")
    expect(LB.toggleAtCaret(window: nil) && styles().isEmpty, "F9 again takes it off: \(styles())")
    AppDelegate.shared?.focused = nil
    expect(!LB.toggleAtCaret(window: nil), "F9 elsewhere goes on")

    // The gutter: a click puts one on, its menu offers enable, any instance, remove.
    expect(LB.gutterClicked(view, lineStart: lineStart(5, in: source)), "a gutter click is taken")
    expect(LB.gutterClicked(view, lineStart: lineStart(4, in: source)), "and another")
    await LB.sync(waveform)
    expect(describe(lastItems()) == ["core.sv:6 [TOP.u_core.limit] true", "core.sv:5 [TOP.u_core.done] true"], "both sent: \(describe(lastItems()))")
    let menu = LB.gutterMenu(view, lineStart: lineStart(5, in: source))
    expect(menu?.items.map(\.title) == ["Disable Breakpoint", "Break in Any Instance", "Edit Condition…", "", "Remove Breakpoint"], "the dot's menu: \(String(describing: menu?.items.map(\.title)))")
    expect(LB.gutterMenu(view, lineStart: lineStart(1, in: source)) == nil, "no menu where there is no dot")
    if let any = menu?.items[1], let action = any.action { NSApp.sendAction(action, to: any.target, from: any) }
    if let disable = menu?.items[0], let action = disable.action { NSApp.sendAction(action, to: disable.target, from: disable) }
    await LB.sync(waveform)
    expect(describe(lastItems()).first == "core.sv:6 [TOP.u_core.limit,TOP.u_core2.limit] false",
           "any instance: both instances' limit; disabled: \(describe(lastItems()))")
    expect(styles()[lineStart(5, in: source)] == .disabled, "a disabled dot: \(styles())")

    // Edits above move them; the label follows.
    view.textStorage!.replaceCharacters(in: NSRange(location: lineStart(1, in: source), length: 0), with: "  // a comment\n")
    let edited = view.string
    expect(Set(styles().keys) == [lineStart(5, in: edited), lineStart(6, in: edited)], "dots moved down a line: \(styles()) \(lineStart(5, in: edited))")
    await LB.sync(waveform)
    expect(describe(lastItems()).map { String($0.prefix(10)) } == ["core.sv:7 ", "core.sv:6 "], "labels follow: \(describe(lastItems()))")
    // Deleting the line between them joins them onto one line: one stays.
    let five = lineStart(5, in: edited)
    view.textStorage!.replaceCharacters(in: NSRange(location: five, length: lineStart(6, in: edited) - five), with: "")
    expect(styles().count == 1, "a deleted line takes its breakpoint, one is left: \(styles())")

    // The page's list removes or disables (cmux owns line breakpoints).
    let key = (lastItems().first?["key"] as? String) ?? ""
    LB.pageReported(["key": key, "removed": true], waveform: waveform)
    await LB.sync(waveform)
    expect(lastItems().count == (LB.marks[workspace]?.count ?? -1), "removed from the page's list: \(describe(lastItems()))")

    // Conditions: the dot's menu asks for one (cmux's prompt), the dot shows it, the viewer gets it
    // with the line's instance; the page's list changes or clears it.
    _ = LB.gutterClicked(view, lineStart: lineStart(2, in: view.string))
    await LB.sync(waveform)
    let conditionKey = (lastItems().first?["key"] as? String) ?? ""
    let conditionId = UUID(uuidString: conditionKey)
    if let conditionId { LB.setEnabled(conditionId, true, in: workspace) }
    let conditionStart = styles().keys.first ?? -1
    WaveformDebuggerEvaluate.promptAnswer = "count == 3"
    let editMenu = LB.gutterMenu(view, lineStart: conditionStart)
    if let item = editMenu?.items.first(where: { $0.title == "Edit Condition…" }), let action = item.action {
        NSApp.sendAction(action, to: item.target, from: item)
    }
    expect(WaveformDebuggerEvaluate.prompted == [nil], "the prompt starts empty: \(WaveformDebuggerEvaluate.prompted)")
    expect(styles()[conditionStart] == .conditional, "a conditional dot: \(styles())")
    await LB.sync(waveform)
    let conditioned = lastItems().first { $0["key"] as? String == conditionKey }
    expect(conditioned?["condition"] as? String == "count == 3" && conditioned?["scope"] as? [String] == ["TOP", "u_core"],
           "sent with its condition and the line's instance: \(String(describing: conditioned))")
    let conditionMenu = LB.gutterMenu(view, lineStart: conditionStart)?.items.map(\.title) ?? []
    expect(conditionMenu.contains("Edit Condition…") && conditionMenu.contains("Remove Condition"), "a conditional dot's menu: \(conditionMenu)")
    // Asked again: the prompt shows the current one; cancel keeps it.
    WaveformDebuggerEvaluate.promptAnswer = nil
    if let item = LB.gutterMenu(view, lineStart: conditionStart)?.items.first(where: { $0.title == "Edit Condition…" }), let action = item.action {
        NSApp.sendAction(action, to: item.target, from: item)
    }
    expect(WaveformDebuggerEvaluate.prompted.last == "count == 3" && LB.marks[workspace]?.first { $0.id == conditionId }?.condition == "count == 3",
           "cancel keeps it: \(WaveformDebuggerEvaluate.prompted)")
    LB.pageReported(["key": conditionKey, "enabled": true, "condition": "limit != 0"], waveform: waveform)
    expect(LB.marks[workspace]?.first { $0.id == conditionId }?.condition == "limit != 0", "the page's list changes it")
    LB.pageReported(["key": conditionKey, "enabled": true, "condition": NSNull()], waveform: waveform)
    expect(LB.marks[workspace]?.first { $0.id == conditionId }?.condition == nil && styles()[conditionStart] == .enabled,
           "and clears it: \(styles())")
    if let item = LB.gutterMenu(view, lineStart: conditionStart)?.items.first(where: { $0.title == "Remove Condition" }) {
        expect(false, "no Remove Condition without one: \(item.title)")
    }

    // Signal breakpoints the page reports are kept, and a new page gets everything back.
    LB.signalsReported(["items": [["path": ["TOP", "u_core", "count"], "kind": "equals", "value": "'h3", "enabled": true, "condition": "limit > 2"]]],
                       waveform: waveform)
    expect(LB.signals[workspace]?.first?.condition == "limit > 2" && LB.signals[workspace]?.first?.pageItem["condition"] as? String == "limit > 2",
           "a signal breakpoint's condition is kept: \(String(describing: LB.signals[workspace]))")
    page.calls.removeAll()
    LB.pageLoaded(waveform)
    for _ in 0..<20 where page.calls.count < 2 { try? await Task.sleep(nanoseconds: 20_000_000) }
    expect(page.calls.map(\.function) == ["setLineBreakpoints", "restoreBreakpoints"], "a new page gets the lines and the signal breakpoints: \(page.calls.map(\.function))")
    let restoredItems = page.calls.last?.argument["items"] as? [[String: Any]]
    expect(restoredItems?.first?["value"] as? String == "'h3", "with their values: \(String(describing: restoredItems))")

    // A session: saved, restored into another workspace, placed by text in a file whose lines moved.
    for mark in LB.marks[workspace] ?? [] { LB.remove(mark.id, in: workspace) }
    view.string = source
    _ = LB.gutterClicked(view, lineStart: lineStart(4, in: source))
    _ = LB.gutterClicked(view, lineStart: lineStart(1, in: source))
    WaveformDebuggerEvaluate.watches[workspace] = ["count + 1", "limit"]
    if let first = LB.marks[workspace]?.first { LB.setCondition(first.id, "count == 3", in: workspace) }
    let saved = LB.snapshot(of: workspace)
    let data = try? JSONEncoder().encode(saved)
    let decoded = data.flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }
    expect(decoded == saved && decoded?.lines?.map(\.line) == [4, 1] && decoded?.signals?.count == 1,
           "the snapshot round-trips: \(String(describing: decoded))")
    expect(decoded?.lines?.first?.condition == "count == 3" && decoded?.signals?.first?.condition == "limit > 2",
           "conditions are in it: \(String(describing: decoded?.lines?.first))")
    let olderMark = try? JSONDecoder().decode(LB.Mark.self, from: Data(
        #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/a.sv","line":1,"text":"x","enabled":true,"anyInstance":false,"lost":false}"#.utf8))
    let olderSignal = try? JSONDecoder().decode(LB.SignalBreakpoint.self, from: Data(#"{"path":["a"],"kind":"change","enabled":true}"#.utf8))
    expect(olderMark != nil && olderMark?.condition == nil && olderSignal != nil, "older marks and signal breakpoints decode")
    expect(decoded?.watches == ["count + 1", "limit"], "the watches are in it: \(String(describing: decoded?.watches))")
    // An older manifest (no watches key) still decodes.
    let older = try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: Data(#"{"signals":[]}"#.utf8))
    expect(older != nil && older?.watches == nil, "a manifest without watches decodes: \(String(describing: older))")
    // Only watches: still saved.
    let watchOnly = UUID()
    WaveformDebuggerEvaluate.watches[watchOnly] = ["state"]
    expect(LB.snapshot(of: watchOnly)?.watches == ["state"], "a workspace with only watches saves them")
    let restored = UUID()
    LB.restore(decoded, in: restored)
    expect(WaveformDebuggerEvaluate.watches[restored] == ["count + 1", "limit"], "restored watches go back to the workspace")
    let reopened = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    // A header line above, and the declaration line changed.
    reopened.string = "// header\n" + source.replacingOccurrences(of: "  logic [7:0] count, limit;", with: "  logic [7:0] count, limit; // widths")
    let reopenedEditor = FilePreviewLanguageFeatures(textView: reopened, path: "/rtl/core.sv", workspace: restored)
    FilePreviewLanguageFeatures.all = [reopenedEditor]
    let placed = LB.styles(in: reopened) ?? [:]
    // (its condition comes back with it: a conditional dot)
    expect(placed == [lineStart(5, in: reopened.string): .conditional, lineStart(1, in: reopened.string): .lost],
           "the assign found again a line down; the changed line's kept there, lost: \(placed)")
    WaveformSourceLink.waveform = FilePreviewPanel(workspaceId: restored)
    await LB.sync(WaveformSourceLink.waveform!)
    let afterRestore = describe(WaveformSourceLink.waveform!.nativeViewSessions.waveform.calls.last?.argument["items"] as? [[String: Any]] ?? [])
    expect(afterRestore == ["core.sv:6 [] true", "core.sv:2 [] false"], "sent with no instance known yet, the lost one disabled: \(afterRestore)")
    expect(LB.snapshot(of: UUID()) == nil, "a workspace without breakpoints saves none")

    await runTrackingChecks()
    print(failures == 0 ? "LINE BREAKPOINT CHECKS PASSED" : "LINE BREAKPOINT CHECKS FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

/// Review H1, M1, M2: whole-buffer replaces (Format Document, a reload from disk, their undo), the
/// gutter drawing before the text loads, edits with no viewer, and lines with the same text.
@MainActor func runTrackingChecks() async {
    typealias LB = WaveformDebuggerLineBreakpoints
    WaveformSourceLink.waveform = nil
    func open(_ text: String, workspace: UUID) -> SavingTextView {
        let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = text
        let editor = FilePreviewLanguageFeatures(textView: view, path: "/rtl/core.sv", workspace: workspace)
        FilePreviewLanguageFeatures.all.append(editor)
        return view
    }
    func lines(_ view: NSTextView) -> [Int] {
        let text = view.string
        let starts = [0] + text.utf16.enumerated().filter { $0.element == 0x0A }.map { $0.offset + 1 }
        return (LB.styles(in: view) ?? [:]).keys.compactMap { starts.firstIndex(of: $0) }.sorted()
    }
    func state(_ workspace: UUID) -> [String] {
        (LB.marks[workspace] ?? []).map { "\($0.line) \($0.lost ? "lost" : "ok") \($0.enabled)" }.sorted()
    }

    // Format Document: the whole range replaced with re-indented text. All three stay on their lines.
    let formatted = UUID()
    let view = open(source, workspace: formatted)
    for line in [3, 4, 5] { _ = LB.gutterClicked(view, lineStart: lineStart(line, in: source)) }
    let reindented = source.replacingOccurrences(of: "\n  ", with: "\n    ")
    view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: view.textStorage!.length), with: reindented)
    expect(lines(view) == [3, 4, 5] && LB.marks[formatted]?.count == 3, "format keeps every breakpoint on its line: \(lines(view)) \(state(formatted))")
    // A reload from disk with the same text, and with a header line added.
    view.string = view.string
    expect(lines(view) == [3, 4, 5] && LB.marks[formatted]?.count == 3, "a reload with the same text: \(lines(view))")
    view.string = "// header\n" + view.string
    expect(lines(view) == [4, 5, 6] && LB.marks[formatted]?.count == 3, "a reload with a line added above: \(lines(view))")
    // A whole replace where one line's text changed: it stays at its line, not deleted, not lost.
    view.string = view.string.replacingOccurrences(of: "assign done = count == limit;", with: "assign done = (count == limit);")
    expect(lines(view) == [4, 5, 6] && LB.marks[formatted]?.count == 3 && !(LB.marks[formatted] ?? []).contains { $0.lost },
           "a changed line keeps its breakpoint: \(lines(view)) \(state(formatted))")
    // Undo of a format is another whole replace: back on the original lines.
    view.string = "// header\n" + source
    expect(lines(view) == [4, 5, 6] && LB.marks[formatted]?.count == 3, "undoing the format: \(lines(view))")

    // Deleting the line between two merges them; undoing the delete brings the other one back.
    let merged = UUID()
    let mergeView = open(source, workspace: merged)
    _ = LB.gutterClicked(mergeView, lineStart: lineStart(4, in: source))
    _ = LB.gutterClicked(mergeView, lineStart: lineStart(5, in: source))
    let four = lineStart(4, in: source)
    let deleted = (source as NSString).substring(with: NSRange(location: four, length: lineStart(5, in: source) - four))
    mergeView.textStorage!.replaceCharacters(in: NSRange(location: four, length: deleted.utf16.count), with: "")
    expect(lines(mergeView) == [4], "a deleted line takes its breakpoint: \(lines(mergeView))")
    LB.isUndoing = { _ in true }
    mergeView.textStorage!.replaceCharacters(in: NSRange(location: four, length: 0), with: deleted)
    LB.isUndoing = { _ in false }
    expect(lines(mergeView) == [4, 5] && LB.marks[merged]?.count == 2, "undo brings it back: \(lines(mergeView)) \(state(merged))")

    // The gutter draws before the text has loaded: nothing is lost; the marks are placed when it arrives.
    let early = UUID()
    LB.restore(SessionWaveformBreakpointsSnapshot(lines: [
        LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 3, text: "always_ff @(posedge clk) count <= count + 1;"),
        LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 4, text: "assign done = count == limit;"),
    ], signals: nil), in: early)
    let earlyView = open("", workspace: early)
    _ = LB.styles(in: earlyView)
    expect(state(early) == ["3 ok true", "4 ok true"], "drawn before the load: none lost: \(state(early))")
    earlyView.string = source
    expect(lines(earlyView) == [3, 4] && state(early) == ["3 ok true", "4 ok true"], "placed when the text arrives: \(lines(earlyView)) \(state(early))")

    // M1: an edit to a breakpoint's line with no viewer open is remembered (the file may close next).
    let unseen = UUID()
    let unseenView = open(source, workspace: unseen)
    _ = LB.gutterClicked(unseenView, lineStart: lineStart(4, in: source))
    let doneLine = lineStart(4, in: source)
    unseenView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// top\n")
    let lineEnd = doneLine + 7 + "  assign done = count == limit;".utf16.count
    unseenView.textStorage!.replaceCharacters(in: NSRange(location: lineEnd, length: 0), with: " // note")
    let wanted = "assign done = count == limit; // note"
    for _ in 0..<40 where LB.marks[unseen]?.first?.text != wanted { try? await Task.sleep(nanoseconds: 25_000_000) }
    expect(LB.marks[unseen]?.first?.line == 5 && LB.marks[unseen]?.first?.text == wanted,
           "line and text kept current without a viewer: \(String(describing: LB.marks[unseen]?.first))")

    // M2: two marks whose nearest matching line is the same one: each gets its own line; a third with
    // no line left is lost, disabled, and still has a dot.
    let twins = UUID()
    let block = "module m;\n  begin\n  end\n  begin\n  end\nendmodule\n"
    LB.restore(SessionWaveformBreakpointsSnapshot(lines: [
        LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 2, text: "end"),
        LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 3, text: "end"),
        LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 4, text: "end"),
    ], signals: nil), in: twins)
    let twinView = open("// added\n" + block, workspace: twins)
    let twinStyles = LB.styles(in: twinView) ?? [:]
    expect(lines(twinView) == [3, 4, 5] && twinStyles.values.filter { $0 == .lost }.count == 1,
           "duplicates take the free matching lines; the extra one is lost with a dot: \(lines(twinView)) \(state(twins))")
    expect(!(LB.marks[twins] ?? []).contains { !$0.lost && $0.enabled && !twinStyles.keys.contains(lineStart($0.line, in: twinView.string)) },
           "no enabled breakpoint without a dot: \(state(twins))")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
