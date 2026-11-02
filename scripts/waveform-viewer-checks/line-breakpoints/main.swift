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
    // verify-bp N4: and each instance's own paths and scope, for a condition tested in each one.
    let groups = (lastItems().first?["groups"] as? [[String: Any]] ?? []).map {
        ($0["scope"] as? [String] ?? []).joined(separator: ".") + ":" + ($0["paths"] as? [[String]] ?? []).map { $0.joined(separator: ".") }.joined(separator: ",")
    }
    expect(groups == ["TOP.u_core:TOP.u_core.limit", "TOP.u_core2:TOP.u_core2.limit"], "any instance: per-instance groups: \(groups)")
    // review-bp L10: why a line has no paths: it watches nothing (endmodule), or its file is too large to scan.
    _ = LB.gutterClicked(view, lineStart: lineStart(6, in: source))
    await LB.sync(waveform)
    let nothing = lastItems().first { $0["label"] as? String == "core.sv:7" }
    editor.tooLargeToScan = true
    LB.instancesLearned(by: editor)
    await LB.sync(waveform)
    let unscanned = lastItems().first { $0["label"] as? String == "core.sv:7" }
    editor.tooLargeToScan = false
    expect(nothing?["unwatched"] as? String == "nothing" && unscanned?["unwatched"] as? String == "tooLarge",
           "a line with no paths says why: \(String(describing: nothing?["unwatched"])) \(String(describing: unscanned?["unwatched"]))")
    _ = LB.gutterClicked(view, lineStart: lineStart(6, in: source))
    await LB.sync(waveform)
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
    // verify-bp N5: a condition the page can't parse is drawn as an error (the lost style) until fixed.
    LB.pageReported(["key": conditionKey, "conditionError": true], waveform: waveform)
    expect(styles()[conditionStart] == .lost, "a condition that does not parse: drawn as an error: \(styles())")
    LB.pageReported(["key": conditionKey, "conditionError": false], waveform: waveform)
    expect(styles()[conditionStart] == .conditional, "fixed: a conditional dot again: \(styles())")
    // verify-bp2 R4: cmux's own change of the condition clears the error (the page says again if the
    // new one is bad too), also with no page open to say so.
    LB.pageReported(["key": conditionKey, "conditionError": true], waveform: waveform)
    if let conditionId { LB.setCondition(conditionId, "limit != 1", in: workspace) }
    expect(styles()[conditionStart] == .conditional, "a condition changed in cmux is not drawn as the old one's error: \(styles())")
    LB.pageReported(["key": conditionKey, "conditionError": true], waveform: waveform)
    if let conditionId { LB.setCondition(conditionId, nil, in: workspace) }
    expect(styles()[conditionStart] == .enabled, "nor once it is removed: \(styles())")
    if let conditionId { LB.setCondition(conditionId, "limit != 0", in: workspace) }
    LB.pageReported(["key": conditionKey, "enabled": true, "condition": NSNull()], waveform: waveform)
    expect(LB.marks[workspace]?.first { $0.id == conditionId }?.condition == nil && styles()[conditionStart] == .enabled,
           "and clears it: \(styles())")
    if let item = LB.gutterMenu(view, lineStart: conditionStart)?.items.first(where: { $0.title == "Remove Condition" }) {
        expect(false, "no Remove Condition without one: \(item.title)")
    }

    // Signal breakpoints the page reports are kept, and a new page gets everything back.
    LB.signalsReported(["items": [["path": ["TOP", "u_core", "count"], "kind": "equals", "value": "'h3", "enabled": true, "condition": "limit > 2"]]],
                       waveform: waveform)
    expect(LB.signals(for: waveform).first?.condition == "limit > 2" && LB.signals(for: waveform).first?.pageItem["condition"] as? String == "limit > 2",
           "a signal breakpoint's condition is kept: \(LB.signals(for: waveform))")
    // Review M3: a second viewer in the workspace (another dump) keeps its own.
    let other = FilePreviewPanel(workspaceId: workspace, filePath: "/w/b.vcd")
    LB.signalsReported(["items": [["path": ["TOP", "y"], "kind": "change", "enabled": true]]], waveform: other)
    LB.watchesReported(["items": ["y + 1"]], waveform: other)
    LB.watchesReported(["items": ["count"]], waveform: waveform)
    expect(LB.signals(for: waveform).map(\.path) == [["TOP", "u_core", "count"]] && LB.signals(for: other).map(\.path) == [["TOP", "y"]],
           "signal breakpoints are kept per viewer's dump: \(LB.signals(for: waveform).map(\.path)) \(LB.signals(for: other).map(\.path))")
    expect(LB.watches(for: waveform) == ["count"] && LB.watches(for: other) == ["y + 1"], "and watches")
    other.nativeViewSessions.waveform.calls.removeAll()
    LB.pageLoaded(other)
    for _ in 0..<20 where other.nativeViewSessions.waveform.calls.count < 3 { try? await Task.sleep(nanoseconds: 20_000_000) }
    let otherRestore = other.nativeViewSessions.waveform.calls.first { $0.function == "restoreBreakpoints" }?.argument["items"] as? [[String: Any]]
    let otherWatches = other.nativeViewSessions.waveform.calls.first { $0.function == "restoreWatches" }?.argument["items"] as? [String]
    expect(otherRestore?.compactMap { $0["path"] as? [String] } == [["TOP", "y"]] && otherWatches == ["y + 1"],
           "the other viewer's page gets its own back: \(String(describing: otherRestore)) \(String(describing: otherWatches))")
    LB.watchesReported(["items": []], waveform: waveform)
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
    LB.watchesReported(["items": ["count + 1", "limit"]], waveform: waveform)
    if let first = LB.marks[workspace]?.first { LB.setCondition(first.id, "count == 3", in: workspace) }
    let saved = LB.snapshot(of: workspace)
    let data = try? JSONEncoder().encode(saved)
    let decoded = data.flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }
    expect(decoded == saved && decoded?.lines?.map(\.line) == [4, 1] && decoded?.signalsByDump?["/w/a.vcd"]?.count == 1
           && decoded?.signalsByDump?["/w/b.vcd"]?.count == 1,
           "the snapshot round-trips: \(String(describing: decoded))")
    expect(decoded?.lines?.first?.condition == "count == 3" && decoded?.signalsByDump?["/w/a.vcd"]?.first?.condition == "limit > 2",
           "conditions are in it: \(String(describing: decoded?.lines?.first))")
    let olderMark = try? JSONDecoder().decode(LB.Mark.self, from: Data(
        #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/a.sv","line":1,"text":"x","enabled":true,"anyInstance":false,"lost":false}"#.utf8))
    let olderSignal = try? JSONDecoder().decode(LB.SignalBreakpoint.self, from: Data(#"{"path":["a"],"kind":"change","enabled":true}"#.utf8))
    expect(olderMark != nil && olderMark?.condition == nil && olderSignal != nil, "older marks and signal breakpoints decode")
    // Text breakpoints (Break When Text Matches…): their fields are kept, saved and given back; one
    // without a pattern is not kept; an older build's list (no text field) still decodes.
    let textWorkspace = UUID()
    let textViewer = FilePreviewPanel(workspaceId: textWorkspace, filePath: "/w/t.vcd")
    LB.signalsReported(["items": [
      ["path": ["TOP", "inst"], "kind": "text", "format": "riscv", "pattern": "jal ra", "caseSensitive": false, "anyRegisterNames": true,
       "enabled": true, "condition": "valid"],
      ["path": ["TOP", "inst"], "kind": "text", "format": "riscv", "enabled": true],
      ["path": ["TOP", "inst"], "kind": "text", "format": "riscv", "pattern": String(repeating: "a", count: 4097), "enabled": true],
    ]], waveform: textViewer)
    let kept = LB.signals(for: textViewer)
    expect(kept.count == 1 && kept.first?.text == WaveformDebuggerTextBreakpoint(format: "riscv", pattern: "jal ra", caseSensitive: false, anyRegisterNames: true),
           "a text breakpoint's fields are kept, bad ones dropped: \(kept)")
    let textItem = kept.first?.pageItem
    expect(textItem?["format"] as? String == "riscv" && textItem?["pattern"] as? String == "jal ra" && textItem?["kind"] as? String == "text"
           && textItem?["anyRegisterNames"] as? Bool == true && textItem?["condition"] as? String == "valid",
           "and go back to the page as it sent them: \(String(describing: textItem))")
    let textSaved = LB.snapshot(of: textWorkspace)
    let textDecoded = (try? JSONEncoder().encode(textSaved)).flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }
    expect(textDecoded == textSaved && textDecoded?.signalsByDump?["/w/t.vcd"]?.first?.text?.pattern == "jal ra",
           "a session keeps them: \(String(describing: textDecoded))")
    let textOlder = try? JSONDecoder().decode(LB.SignalBreakpoint.self, from: Data(
        #"{"path":["a"],"kind":"text","enabled":true,"text":{"format":"ascii","pattern":"ok"}}"#.utf8))
    expect(textOlder?.text?.caseSensitive == nil && textOlder?.pageItem["caseSensitive"] == nil && textOlder?.pageItem["pattern"] as? String == "ok",
           "optional fields stay optional: \(String(describing: textOlder))")
    // Commit breakpoints (Break at Address…, Break When Next Instruction Matches…, Break When Written…):
    // no path; their fields are kept, saved and given back; one the page could not have made is dropped.
    LB.signalsReported(["items": [
      ["path": [String](), "kind": "pc", "pcs": ["0x80000004", "0x80000010"], "channel": 1, "enabled": true, "condition": "$a0 == 0"],
      ["path": [String](), "kind": "commitText", "pattern": "csrw mtvec", "caseSensitive": true, "anyRegisterNames": false, "enabled": false],
      ["path": [String](), "kind": "write", "loc": "mem:0x80001000/4", "enabled": true],
      ["path": [String](), "kind": "write", "loc": "csr:mtvec", "enabled": true],
      ["path": [String](), "kind": "sequence", "query": "{lw} as L ##1 rs1 == L.rd", "land": "start", "enabled": true],
      ["path": [String](), "kind": "sequence", "query": "{sw}", "land": "end", "enabled": true],
      ["path": [String](), "kind": "sequence", "query": "", "enabled": true],
      ["path": [String](), "kind": "sequence", "query": "{sw}", "land": "middle", "enabled": true],
      ["path": [String](), "kind": "sequence", "query": String(repeating: "a", count: 4097), "enabled": true],
      ["path": [String](), "kind": "pc", "pcs": [String](), "enabled": true],
      ["path": [String](), "kind": "pc", "pcs": ["main"], "enabled": true],
      ["path": [String](), "kind": "write", "loc": "", "enabled": true],
      ["path": [String](), "kind": "commitText", "pattern": "", "enabled": true],
      ["path": [String](), "kind": "commitText", "pattern": String(repeating: "a", count: 4097), "enabled": true],
      ["path": [String](), "kind": "change", "enabled": true],
    ]], waveform: textViewer)
    let commitKept = LB.signals(for: textViewer)
    expect(commitKept.map(\.kind) == ["pc", "commitText", "write", "write", "sequence", "sequence"]
           && commitKept[4].commit == WaveformDebuggerCommitBreakpoint(query: "{lw} as L ##1 rs1 == L.rd", land: "start")
           && commitKept[4].pageItem["query"] as? String == "{lw} as L ##1 rs1 == L.rd" && commitKept[4].pageItem["land"] as? String == "start"
           && commitKept[5].commit == WaveformDebuggerCommitBreakpoint(query: "{sw}", land: "end")
           && commitKept[0].commit == WaveformDebuggerCommitBreakpoint(pcs: ["0x80000004", "0x80000010"], channel: 1)
           && commitKept[1].commit == WaveformDebuggerCommitBreakpoint(pattern: "csrw mtvec", caseSensitive: true, anyRegisterNames: false)
           && commitKept[2].commit == WaveformDebuggerCommitBreakpoint(loc: "mem:0x80001000/4"),
           "commit breakpoints' fields are kept, bad ones dropped: \(commitKept)")
    let pcItem = commitKept.first?.pageItem
    expect(pcItem?["kind"] as? String == "pc" && pcItem?["pcs"] as? [String] == ["0x80000004", "0x80000010"] && pcItem?["channel"] as? Int == 1
           && pcItem?["condition"] as? String == "$a0 == 0" && (pcItem?["path"] as? [String])?.isEmpty == true
           && commitKept[1].pageItem["enabled"] as? Bool == false && commitKept[1].pageItem["anyRegisterNames"] as? Bool == false
           && commitKept[2].pageItem["loc"] as? String == "mem:0x80001000/4",
           "and go back to the page as it sent them: \(String(describing: pcItem))")
    let commitSaved = LB.snapshot(of: textWorkspace)
    let commitDecoded = (try? JSONEncoder().encode(commitSaved)).flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }
    expect(commitDecoded == commitSaved && commitDecoded?.signalsByDump?["/w/t.vcd"]?[3].commit?.loc == "csr:mtvec",
           "a session keeps them: \(String(describing: commitDecoded))")
    LB.signalsReported(["items": []], waveform: textViewer)
    expect(decoded?.watchesByDump?["/w/a.vcd"] == ["count + 1", "limit"] && decoded?.watchesByDump?["/w/b.vcd"] == ["y + 1"],
           "the watches are in it, per dump: \(String(describing: decoded?.watchesByDump))")
    // An older manifest (one list for the workspace) still decodes, and any viewer gets that list.
    let older = try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: Data(
        #"{"signals":[{"path":["TOP","z"],"kind":"change","enabled":true}],"watches":["z"]}"#.utf8))
    let olderWorkspace = UUID()
    LB.restore(older, in: olderWorkspace)
    let olderViewer = FilePreviewPanel(workspaceId: olderWorkspace, filePath: "/w/c.vcd")
    expect(LB.signals(for: olderViewer).map(\.path) == [["TOP", "z"]] && LB.watches(for: olderViewer) == ["z"],
           "an older manifest's lists go to its viewers: \(String(describing: older))")
    // Listing breakpoints (WaveformDebuggerAsmBreakpoints, stubbed here) are saved with the rest, alone too.
    let asmOnly = UUID()
    let asmMark = AsmMark(listingPath: "/w/prog.dis", pc: 0x8000_0004, symbol: "_start", offset: 4, encoding: 0x4501, text: "li a0,0")
    WaveformDebuggerAsmBreakpoints.saved[asmOnly] = [asmMark]
    let asmSnapshot = LB.snapshot(of: asmOnly)
    expect(asmSnapshot?.pcMarks == [asmMark], "a workspace with only listing breakpoints saves them: \(String(describing: asmSnapshot))")
    let asmDecoded = (try? JSONEncoder().encode(asmSnapshot)).flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }
    expect(asmDecoded == asmSnapshot, "and they decode")
    let asmRestored = UUID()
    LB.restore(asmDecoded, in: asmRestored)
    expect(WaveformDebuggerAsmBreakpoints.restored.last?.workspace == asmRestored && WaveformDebuggerAsmBreakpoints.restored.last?.marks == [asmMark],
           "a restore gives them back: \(WaveformDebuggerAsmBreakpoints.restored)")
    expect((older?.pcMarks) == nil, "an older manifest has none")
    // Only watches: still saved.
    let watchOnly = UUID()
    LB.watchesReported(["items": ["state"]], waveform: FilePreviewPanel(workspaceId: watchOnly))
    expect(LB.snapshot(of: watchOnly)?.watchesByDump?["/w/a.vcd"] == ["state"], "a workspace with only watches saves them")
    let restored = UUID()
    LB.restore(decoded, in: restored)
    expect(LB.watches(for: FilePreviewPanel(workspaceId: restored)) == ["count + 1", "limit"]
           && LB.watches(for: FilePreviewPanel(workspaceId: restored, filePath: "/w/b.vcd")) == ["y + 1"], "restored watches go back per dump")
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
    await runVerifyChecks()
    await runVerify2Checks()
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

// verify-bp-b03a64a: typing cost (N1), the diff narrowing (duplicate `end`), reloads and formats
// that change a mark's line (N2, N3), undo (N6), joined lines (N7), an empty new file (N12).
@MainActor func runVerifyChecks() async {
    typealias LB = WaveformDebuggerLineBreakpoints
    WaveformSourceLink.waveform = nil
    func open(_ text: String, workspace: UUID, path: String = "/rtl/core.sv") -> SavingTextView {
        let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = text
        let editor = FilePreviewLanguageFeatures(textView: view, path: path, workspace: workspace)
        FilePreviewLanguageFeatures.all.append(editor)
        return view
    }
    func starts(_ text: String) -> [Int] { [0] + text.utf16.enumerated().filter { $0.element == 0x0A }.map { $0.offset + 1 } }
    func lines(_ view: NSTextView) -> [Int] {
        let s = starts(view.string)
        return (LB.styles(in: view) ?? [:]).keys.map { s.firstIndex(of: $0) ?? -1 }.sorted()
    }
    func state(_ workspace: UUID) -> [String] {
        (LB.marks[workspace] ?? []).map { "\($0.line) \($0.lost ? "lost" : "ok") \($0.enabled) \($0.text)" }.sorted()
    }
    func click(_ view: NSTextView, _ line: Int) { _ = LB.gutterClicked(view, lineStart: starts(view.string)[line]) }
    func edit(_ view: NSTextView, _ range: NSRange, _ text: String) { view.textStorage!.replaceCharacters(in: range, with: text) }

    // N1: typing in a 100k-line file costs about what it costs with no breakpoint code: no copy of
    // the text and no line table per keystroke, with no breakpoints and with one.
    var big = "module big(input logic clk);\n"
    for i in 0..<100_000 { big += "  always_ff @(posedge clk) r\(i) <= r\(i) + 1; // filler\n" }
    big += "endmodule\n"
    for withMark in [false, true] {
        let view = open(big, workspace: UUID(), path: "/rtl/big.sv")
        _ = LB.styles(in: view)
        let ns = view.string as NSString
        if withMark { _ = LB.gutterClicked(view, lineStart: ns.range(of: "  always_ff @(posedge clk) r50000 <=").location) }
        let at = ns.range(of: "r10 <=").location
        let started = Date()
        for i in 0..<200 { edit(view, NSRange(location: at + i, length: 0), "x") }
        let perKey = Date().timeIntervalSince(started) * 1000 / 200
        expect(perKey < 1.0, "typing in a 100k-line file \(withMark ? "with a breakpoint" : "without breakpoints"): \(String(format: "%.3f", perKey)) ms per key (under 1)")
        if withMark {
            expect(lines(view) == [50_001], "the breakpoint stays on its line while typing above it: \(lines(view))")
        }
    }

    // The diff: a reload that adds 3 lines on top keeps a mark on the middle of three `end`s on its
    // own `end` (the raw edited range would send it to the nearest `end` by line number).
    let dup = UUID()
    let block = "module m;\n  begin\n  end\n  begin\n    x = 1;\n  end\n  begin\n  end\nendmodule\n"
    let dupView = open(block, workspace: dup)
    click(dupView, 5)
    dupView.string = "// a\n// b\n// c\n" + block
    expect(lines(dupView) == [8], "a reload with lines added above keeps the mark on its own `end`: \(lines(dupView))")
    // With no line that is there once (nothing to line up by), only the narrowed span keeps it.
    let alike = UUID()
    let pairs = String(repeating: "begin\nend\n", count: 3)
    let alikeView = open(pairs, workspace: alike)
    click(alikeView, 3)
    alikeView.string = "end\n" + pairs
    expect(lines(alikeView) == [4], "a reload adding an `end` above lines that all repeat keeps the mark on its `end`: \(lines(alikeView))")

    // N2: a reload that removes a line above and changes a mark's own line keeps all three.
    let reload = UUID()
    let reloadView = open(source, workspace: reload)
    for line in [3, 4, 5] { click(reloadView, line) }
    reloadView.string = source.replacingOccurrences(of: "assign done = count == limit;", with: "assign done = count >= limit;")
    reloadView.string = source.replacingOccurrences(of: "  logic done;\n", with: "")
    expect(lines(reloadView) == [2, 3, 4] && LB.marks[reload]?.count == 3, "a reload removing a line above and changing a marked line keeps every mark: \(lines(reloadView)) \(state(reload))")
    reloadView.string = source
    expect(lines(reloadView) == [3, 4, 5] && LB.marks[reload]?.count == 3, "and a reload back puts them back: \(lines(reloadView))")

    // N3: Format Document that splits a line above and re-spaces the marked one keeps it on its statement.
    let format = UUID()
    let formatView = open(source, workspace: format)
    click(formatView, 4)
    let formatted = source.replacingOccurrences(of: "logic [7:0] count, limit;", with: "logic [7:0] count;\n  logic [7:0] limit;")
        .replacingOccurrences(of: "assign done = count == limit;", with: "assign done = (count == limit);")
    edit(formatView, NSRange(location: 0, length: (formatView.string as NSString).length), formatted)
    expect(lines(formatView) == [5], "a format that re-spaces the line and adds one above keeps the statement: \(lines(formatView))")
    for _ in 0..<20 { try? await Task.sleep(nanoseconds: 25_000_000) }
    expect(LB.marks[format]?.first?.text.contains("assign done") == true, "its saved text is still its statement: \(state(format))")
    let respaced = UUID()
    let respacedView = open(source, workspace: respaced)
    click(respacedView, 4)
    edit(respacedView, NSRange(location: 0, length: (respacedView.string as NSString).length),
         "// header\n" + source.replacingOccurrences(of: "assign done = count == limit;", with: "assign done = count==limit;"))
    expect(lines(respacedView) == [5], "only spacing changed in its line, a line added above: \(lines(respacedView))")

    // N6: an undo that does not put back the deleted line brings no merged mark back.
    let undo = UUID()
    let undoView = open(source, workspace: undo)
    click(undoView, 4); click(undoView, 5)
    let s = starts(undoView.string)
    edit(undoView, NSRange(location: s[4], length: s[5] - s[4]), "")
    edit(undoView, NSRange(location: starts(undoView.string)[2], length: 0), "  assign done = count == limit;\n")
    edit(undoView, NSRange(location: 0, length: 0), "x")
    LB.isUndoing = { _ in true }
    edit(undoView, NSRange(location: 0, length: 1), "")
    LB.isUndoing = { _ in false }
    expect(lines(undoView) == [5], "an unrelated undo brings no deleted breakpoint back: \(lines(undoView)) \(state(undo))")

    // N7: joining a line into the one above keeps the upper mark and its condition.
    let join = UUID()
    let joinView = open(source, workspace: join)
    click(joinView, 4); click(joinView, 5)
    let upper = LB.marks[join]!.first { $0.line == 4 }!.id
    LB.setCondition(upper, "count == 3", in: join)
    edit(joinView, NSRange(location: starts(joinView.string)[5] - 1, length: 1), "")
    expect(lines(joinView) == [4] && LB.marks[join]?.map(\.id) == [upper] && LB.marks[join]?.first?.condition == "count == 3",
           "joining lines keeps the upper breakpoint and its condition: \(lines(joinView)) \(String(describing: LB.marks[join]?.map(\.condition)))")

    // N12: F9 in a new empty file, then typing: the breakpoint stays (not lost, still enabled).
    let empty = UUID()
    let emptyView = open("", workspace: empty)
    _ = LB.styles(in: emptyView)
    _ = LB.toggle(in: emptyView.languageFeatures!, textView: emptyView, at: 0)
    edit(emptyView, NSRange(location: 0, length: 0), "a")
    expect(lines(emptyView) == [0] && state(empty).first?.contains("ok true") == true, "a new empty file's breakpoint survives typing: \(lines(emptyView)) \(state(empty))")

    // review-bp L9: a session restored after the file's gutter drew already (its tracker made with no
    // marks) still places them; a snapshot taken off the main thread keeps the last one, and a
    // restore there is applied on the main thread, not dropped.
    let early = UUID()
    let earlyView = open(source, workspace: early)
    _ = LB.styles(in: earlyView)
    LB.restore(SessionWaveformBreakpointsSnapshot(lines: [LB.Mark(id: UUID(), path: "/rtl/core.sv", line: 4, text: "assign done = count == limit;")],
                                                  signals: nil), in: early)
    expect(lines(earlyView) == [4], "restored into a file already drawn: placed: \(lines(earlyView)) \(state(early))")
    let onMain = LB.sessionSnapshot(of: early)
    let offMain = await Task.detached { LB.sessionSnapshot(of: early) }.value
    expect(onMain?.lines?.count == 1 && offMain == onMain, "a snapshot off the main thread keeps the last one: \(String(describing: offMain))")
    let later = UUID()
    let restoreSnapshot = onMain
    await Task.detached { LB.sessionRestore(restoreSnapshot, in: later) }.value
    for _ in 0..<40 where LB.marks[later] == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
    expect(LB.marks[later]?.count == 1, "a restore off the main thread is applied: \(state(later))")

    // L10: lines split as the gutter splits them (U+2028, U+2029, U+0085 too), so a mark's saved line
    // is the line its dot is on.
    let separators = UUID()
    let separated = "// a\u{2028}b\u{85}c\n" + source
    let separatedView = open(separated, workspace: separators)
    let separatedStarts = (separated as NSString).lineStarts()
    _ = LB.gutterClicked(separatedView, lineStart: separatedStarts[7])
    _ = LB.sessionSnapshot(of: separators)
    expect(LB.marks[separators]?.first?.line == 7 && LB.marks[separators]?.first?.text == "assign done = count == limit;",
           "line numbers count every line break the gutter does: \(state(separators))")

    // L10: placing many marks in a big file is one pass, not one per mark. Timed against 200 marks in the
    // same file, so a loaded Mac slows both: one pass costs about the same for both, a pass per mark 10x.
    var manyText = "module many(input logic clk);\n"
    for i in 0..<50_000 { manyText += "  assign w\(i) = r\(i);\n" }
    manyText += "endmodule\n"
    func place(_ count: Int) -> (ms: Double, placed: Bool) {
        let space = UUID()
        let step = 50_000 / count
        LB.restore(SessionWaveformBreakpointsSnapshot(lines: (0..<count).map {
            LB.Mark(id: UUID(), path: "/rtl/many.sv", line: 1 + $0 * step, text: "assign w\($0 * step) = r\($0 * step);")
        }, signals: nil), in: space)
        let view = open(manyText, workspace: space, path: "/rtl/many.sv")
        let started = Date()
        _ = LB.styles(in: view)
        let ms = Date().timeIntervalSince(started) * 1000
        return (ms, (LB.marks[space] ?? []).count == count && (LB.marks[space] ?? []).allSatisfy { !$0.lost })
    }
    let few = place(200)
    let lots = place(2000)
    let fewAgain = place(200)
    let baseline = min(few.ms, fewAgain.ms)
    expect(lots.placed && (lots.ms < 500 || lots.ms < 4 * max(baseline, 1)),
           "2000 marks in a 50k-line file placed in \(Int(lots.ms)) ms (under 500, or under 4x the \(Int(baseline)) ms of 200 marks)")

    // N8: an older manifest's list goes to the first viewer that reports; cleared there, it does not
    // come back after a relaunch, nor go to an unrelated viewer.
    let legacy = UUID()
    LB.restore(try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: Data(
        #"{"signals":[{"path":["TOP","x"],"kind":"change","enabled":true}],"watches":["x"]}"#.utf8)), in: legacy)
    let legacyViewer = FilePreviewPanel(workspaceId: legacy, filePath: "/w/a.vcd")
    let given = LB.signals(for: legacyViewer).map(\.path)
    LB.signalsReported(["items": []], waveform: legacyViewer)
    LB.watchesReported(["items": []], waveform: legacyViewer)
    let relaunched = UUID()
    let legacyData = try? JSONEncoder().encode(LB.snapshot(of: legacy))
    LB.restore(legacyData.flatMap { try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: $0) }, in: relaunched)
    let again = FilePreviewPanel(workspaceId: relaunched, filePath: "/w/a.vcd")
    let unrelated = FilePreviewPanel(workspaceId: relaunched, filePath: "/w/unrelated.fst")
    expect(given == [["TOP", "x"]] && LB.signals(for: again).isEmpty && LB.signals(for: unrelated).isEmpty
           && LB.watches(for: again).isEmpty && LB.watches(for: unrelated).isEmpty,
           "a cleared older-manifest list stays cleared: \(given) \(LB.signals(for: again).map(\.path)) \(LB.signals(for: unrelated).map(\.path)) \(LB.watches(for: unrelated))")
}

/// The app's editor stack: TextKit 1 (FilePreviewTextEditor), typed through insertText/insertTab/
/// deleteBackward with a real UndoManager. AppKit widens editedRange by didProcessEditing here
/// (attribute fixing), which raw replaceCharacters on a plain storage does not show.
@MainActor final class UndoHost: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

// verify-bp-39828a5 R1: typing through the real path keeps the marks and costs O(edit); R3: a page
// that reports its (empty) list while handling setLineBreakpoints does not wipe the saved one.
@MainActor func runVerify2Checks() async {
    typealias LB = WaveformDebuggerLineBreakpoints
    WaveformSourceLink.waveform = nil
    LB.isUndoing = { $0.undoManager?.isUndoing == true || $0.undoManager?.isRedoing == true }
    let host = UndoHost()
    host.manager.groupsByEvent = false
    func tk1(_ text: String, workspace: UUID) -> SavingTextView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = host
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.string = text
        let editor = FilePreviewLanguageFeatures(textView: view, path: "/rtl/core.sv", workspace: workspace)
        FilePreviewLanguageFeatures.all.append(editor)
        _ = LB.styles(in: view)
        return view
    }
    func starts(_ view: NSTextView) -> [Int] { (view.string as NSString).lineStarts() }
    func dots(_ view: NSTextView) -> [Int] { let s = starts(view); return (LB.styles(in: view) ?? [:]).keys.map { s.firstIndex(of: $0) ?? -1 }.sorted() }
    func caret(_ view: NSTextView, _ line: Int, _ column: Int) { view.setSelectedRange(NSRange(location: starts(view)[line] + column, length: 0)) }
    func key(_ view: NSTextView, _ action: () -> Void) { host.manager.beginUndoGrouping(); action(); host.manager.endUndoGrouping() }
    func type(_ view: NSTextView, _ text: String) { key(view) { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) } }
    func fresh(_ lines: [Int]) -> (SavingTextView, UUID) {
        let workspace = UUID()
        let view = tk1(source, workspace: workspace)
        for line in lines { _ = LB.gutterClicked(view, lineStart: starts(view)[line]) }
        return (view, workspace)
    }

    do {
        let (view, workspace) = fresh([4])
        caret(view, 4, 0); type(view, " ")
        expect(dots(view) == [4] && LB.marks[workspace]?.count == 1, "TK1: a space at column 0 of a marked line keeps it: \(dots(view))")
        host.manager.undo()
        expect(dots(view) == [4] && LB.marks[workspace]?.count == 1, "TK1: and its undo: \(dots(view))")
    }
    do {
        let (view, workspace) = fresh([4])
        caret(view, 4, 0); key(view) { view.insertTab(nil) }
        expect(dots(view) == [4] && LB.marks[workspace]?.count == 1, "TK1: a Tab at column 0 keeps it: \(dots(view))")
    }
    do {
        let (view, workspace) = fresh([4])
        view.setSelectedRange(NSRange(location: starts(view)[4], length: 6)); type(view, "assign")
        expect(dots(view) == [4] && LB.marks[workspace]?.count == 1, "TK1: select from column 0 and retype keeps it: \(dots(view))")
    }
    do {
        let (view, _) = fresh([4])
        caret(view, 3, 10); type(view, "x")
        caret(view, 4, 0); key(view) { view.insertNewline(nil) }
        caret(view, 5, 2); key(view) { view.deleteBackward(nil) }
        expect(dots(view) == [5], "TK1: typing above, Enter at column 0, backspace in the indentation: \(dots(view))")
    }
    // The first key in a file over ~1,500 lines (AppKit widens it to the whole paragraph).
    var mid = "module big(input logic clk);\n"
    for i in 0..<3000 { mid += "  always_ff @(posedge clk) r\(i) <= r\(i) + 1; // filler\n" }
    mid += "endmodule\n"
    do {
        let workspace = UUID()
        let view = tk1(mid, workspace: workspace)
        _ = LB.gutterClicked(view, lineStart: starts(view)[1500])
        caret(view, 1500, 30); type(view, "x")
        expect(dots(view) == [1500] && LB.marks[workspace]?.count == 1, "TK1: the first key in a 3,000-line file, on the marked line: \(dots(view))")
    }
    // N1 on the real path: typing on the line above a mark in a 100k-line file costs what typing
    // with no mark does (AppKit's own cost is several ms per key here).
    var big = "module big(input logic clk);\n"
    for i in 0..<100_000 { big += "  always_ff @(posedge clk) r\(i) <= r\(i) + 1; // filler\n" }
    big += "endmodule\n"
    do {
        let workspace = UUID()
        let view = tk1(big, workspace: workspace)
        func time(_ keys: Int) -> Double {
            caret(view, 50_000, 30)
            let started = Date()
            for _ in 0..<keys { type(view, "x") }
            return Date().timeIntervalSince(started) * 1000 / Double(keys)
        }
        _ = time(20)
        let without = time(200)
        _ = LB.gutterClicked(view, lineStart: starts(view)[50_001])
        let with = time(200)
        expect(with < without + 2 && dots(view) == [50_001],
               "TK1: typing on the line above a mark at 100k lines: \(String(format: "%.2f", with)) ms/key, \(String(format: "%.2f", without)) without (within 2): \(dots(view))")
    }
    LB.isUndoing = { _ in false }

    // R2 and the older silent moves (verify-bp2's adversarial set): a reload or Format Document puts
    // a mark on its statement, or says it is lost; never silently on another statement.
    enum Want { case line(Int), lineOrLost(Int), lost }
    func moved(_ name: String, _ text: String, mark: Int, _ newText: String, _ want: Want, format: Bool = false) {
        let workspace = UUID()
        let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = text
        FilePreviewLanguageFeatures.all.append(FilePreviewLanguageFeatures(textView: view, path: "/rtl/x.sv", workspace: workspace))
        _ = LB.styles(in: view)
        _ = LB.gutterClicked(view, lineStart: (text as NSString).lineStarts()[mark])
        if format { view.textStorage!.replaceCharacters(in: NSRange(location: 0, length: view.textStorage!.length), with: newText) } else { view.string = newText }
        let starts = (view.string as NSString).lineStarts()
        let dot = (LB.styles(in: view) ?? [:]).keys.compactMap { starts.firstIndex(of: $0) }.first
        let mark = LB.marks[workspace]?.first
        let ok: Bool
        switch want {
        case .line(let line): ok = mark?.lost == false && dot == line
        case .lineOrLost(let line): ok = mark != nil && dot != nil && (mark?.lost == true || dot == line)
        case .lost: ok = mark?.lost == true && dot != nil
        }
        expect(ok, "\(name): dot \(String(describing: dot)) lost \(String(describing: mark?.lost)) (want \(want))")
    }
    let twoModules = "module a(input logic clk);\n  logic [7:0] count, limit;\n  logic done;\n  assign done = count == limit;\nendmodule\nmodule b(input logic clk);\n  logic [7:0] count, limit;\n  logic done;\n  assign done = count == limit;\nendmodule\n"
    let twoModulesNew = twoModules.replacingOccurrences(of: "module b(input logic clk);\n  logic [7:0] count, limit;\n  logic done;\n  assign done = count == limit;",
                                                        with: "module b(input logic clk);\n  logic [7:0] count, limit;\n  logic done, busy;\n  logic go;\n  assign done = count >= limit;")
    moved("module b's line changed, a line added above: not module a's", twoModules, mark: 8, twoModulesNew, .lineOrLost(9))
    moved("the same as a format", twoModules, mark: 8, twoModulesNew, .lineOrLost(9), format: true)
    let twins = "module c(input logic clk);\n  always_ff @(posedge clk) begin\n    q <= d;\n    q <= d;\n  end\n  assign y = q;\nendmodule\n"
    moved("the second of two same lines, a line added above and a change below", twins, mark: 3,
          twins.replacingOccurrences(of: "begin\n", with: "begin\n    r <= 1;\n").replacingOccurrences(of: "assign y = q;", with: "assign y = ~q;"), .line(4))
    let nested = "module e(input logic clk);\n  always_ff @(posedge clk) begin\n    if (go) begin\n      q <= d;\n    end\n  end\n  assign y = q;\nendmodule\n"
    moved("the outer end of end/end, a line added inside", nested, mark: 5,
          nested.replacingOccurrences(of: "      q <= d;\n", with: "      q <= d;\n      r <= d;\n").replacingOccurrences(of: "assign y = q;", with: "assign y = ~q;"), .line(6))
    let swapped = "module s(input logic clk);\n  always_ff @(posedge clk) begin\n    x <= x + 1;\n    y <= 0;\n  end\n  always_ff @(posedge clk) begin\n    z <= z + 1;\n    w <= 0;\n  end\nendmodule\n"
    let swappedNew = "module s(input logic clk);\n  always_ff @(posedge clk) begin\n    z <= z + 1;\n    w <= 0;\n  end\n  always_ff @(posedge clk) begin\n    x <= x + 1;\n    y <= 0;\n  end\nendmodule\n"
    moved("always blocks swapped, the mark's line unchanged", swapped, mark: 2, swappedNew, .line(6))
    moved("swapped, the mark's line changed", swapped, mark: 3, swappedNew.replacingOccurrences(of: "y <= 0;", with: "y <= 1;"), .lineOrLost(7))
    // verify-bp2 R4c: the line diff pairs the mark's line with the other block's copy, which stayed;
    // its block moved (the nearest line once in each file above it moved), so it goes with it.
    let swappedTwin = swapped.replacingOccurrences(of: "w <= 0;", with: "y <= 0;")
    moved("swapped, the mark's line changed, its old text elsewhere", swappedTwin, mark: 3,
          swappedNew.replacingOccurrences(of: "w <= 0;", with: "y <= 0;").replacingOccurrences(of: "    x <= x + 1;\n    y <= 0;", with: "    x <= x + 1;\n    y <= 2;"), .lineOrLost(7))
    moved("the same, the mark's line unchanged", swappedTwin, mark: 3, swappedNew.replacingOccurrences(of: "w <= 0;", with: "y <= 0;"), .line(7))
    // A mark in a block that stayed does not follow another line that moved.
    let stayed = swappedTwin.replacingOccurrences(of: "endmodule\n", with: "  assign o = x;\nendmodule\n")
    moved("a line once in each file moved away below a mark in a block that stayed", stayed, mark: 3,
          stayed.replacingOccurrences(of: "  assign o = x;\n", with: "").replacingOccurrences(of: "module s(input logic clk);\n", with: "module s(input logic clk);\n  assign o = x;\n"), .line(4))
    let functions = "module f(input logic [7:0] a, output logic [7:0] o);\n  function automatic logic [7:0] inc(input logic [7:0] v);\n    return v + 1;\n  endfunction\n  assign o = inc(a);\n  function automatic logic [7:0] dec(input logic [7:0] v);\n    return v - 1;\n  endfunction\nendmodule\n"
    let functionsNew = "module f(input logic [7:0] a, output logic [7:0] o);\n  function automatic logic [7:0] dec(input logic [7:0] v);\n    return v - 1;\n  endfunction\n  assign o = inc(a);\n  function automatic logic [7:0] inc(input logic [7:0] v);\n    return v + 1;\n  endfunction\nendmodule\n"
    moved("functions swapped", functions, mark: 2, functionsNew, .line(6))
    moved("a format joining begin onto the marked always line", "module k(input logic clk);\n  always_ff @(posedge clk)\n  begin\n    q <= d;\n  end\n  logic z;\nendmodule\n", mark: 1,
          "module k(input logic clk);\n  always_ff @(posedge clk) begin\n    q <= d;\n  end\n  logic z;\nendmodule\n", .line(1), format: true)
    let arms = "module m(input logic clk, input logic [1:0] s);\n  always_comb begin\n    case (s)\n      2'd0: q = 0;\n      2'd1: begin\n        q = 1;\n      end\n      2'd2: begin\n        q = 1;\n      end\n    endcase\n  end\nendmodule\n"
    moved("a case arm's body changed, another arm has its old text", arms, mark: 8,
          arms.replacingOccurrences(of: "      2'd2: begin\n        q = 1;", with: "      2'd3: q = 3;\n      2'd2: begin\n        q = 2;"), .lineOrLost(9))
    let hunks = "module p(input logic clk);\n  logic [7:0] count, limit;\n  logic done;\n  assign done = count == limit;\n  always_ff @(posedge clk) count <= count + 1;\n  assign busy = !done;\nendmodule\n"
    let hunksNew = hunks.replacingOccurrences(of: "  assign done = count == limit;", with: "  logic busy;\n  assign done = count == limit;").replacingOccurrences(of: "assign busy = !done;", with: "assign busy = ~done;")
    moved("two hunks: a line added right above the mark, a change below", hunks, mark: 3, hunksNew, .line(4))
    moved("the same as a format", hunks, mark: 3, hunksNew, .line(4), format: true)
    // N2's lost branch: the marked line and its neighbours replaced by other lines (not one for one).
    moved("the marked line replaced by unrelated lines", source, mark: 4,
          source.replacingOccurrences(of: "  logic done;\n  always_ff @(posedge clk) count <= count + 1;\n  assign done = count == limit;\n",
                                      with: "  wire a;\n  wire b;\n  wire c;\n  wire d;\n"), .lost)
    // The two whitespace tiers, where its text is twice in its gap (so the line diff pairs neither):
    // the same words spaced alike win over a nearer copy spaced differently; spacing aside, the same
    // text wins over a nearer line that only starts like it.
    moved("its text spaced alike wins over a nearer one spaced differently", source, mark: 4,
          source.replacingOccurrences(of: "  assign done = count == limit;\n", with: "  wire w;\n  assign done = count==limit;\n  wire v;\n  assign  done  =  count == limit;\n  wire u;\n"), .line(7))
    moved("spacing aside, the same text wins over a nearer line it was joined into", source, mark: 4,
          source.replacingOccurrences(of: "  assign done = count == limit;\n", with: "  wire w;\n  assign done = count == limit; assign go = 1;\n  assign done = count==limit;\n  wire v;\n  assign done = count ==limit;\n  wire u;\n"), .line(6))

    // R3: the page posts its (empty) signal list while it handles setLineBreakpoints, before the
    // reply (a real WKWebView does: see breakpoints' ordering check). The saved list still goes back.
    for legacy in [false, true] {
        let workspace = UUID()
        let manifest = legacy ? #"{"signals":[{"path":["TOP","x"],"kind":"change","enabled":true}],"watches":["x + 1"]}"#
            : #"{"signalsByDump":{"/w/a.vcd":[{"path":["TOP","x"],"kind":"change","enabled":true}]},"watchesByDump":{"/w/a.vcd":["x + 1"]}}"#
        LB.restore(try? JSONDecoder().decode(SessionWaveformBreakpointsSnapshot.self, from: Data(manifest.utf8)), in: workspace)
        let viewer = FilePreviewPanel(workspaceId: workspace)
        let page = viewer.nativeViewSessions.waveform
        page.onCall = { function in
            if function == "setLineBreakpoints" {
                LB.signalsReported(["items": []], waveform: viewer)
                LB.watchesReported(["items": []], waveform: viewer)
            }
        }
        LB.pageLoaded(viewer)
        for _ in 0..<40 where !page.calls.contains(where: { $0.function == "restoreWatches" }) { try? await Task.sleep(nanoseconds: 20_000_000) }
        let restored = (page.calls.first { $0.function == "restoreBreakpoints" }?.argument["items"] as? [[String: Any]])?.compactMap { $0["path"] as? [String] }
        let watched = page.calls.first { $0.function == "restoreWatches" }?.argument["items"] as? [String]
        expect(restored == [["TOP", "x"]] && watched == ["x + 1"] && LB.signals(for: viewer).map(\.path) == [["TOP", "x"]],
               "a page that reports its empty list while loading still gets the saved one\(legacy ? " (older manifest)" : ""): \(page.calls.map(\.function)) \(String(describing: restored)) \(String(describing: watched)) kept \(LB.signals(for: viewer).map(\.path))")
        page.onCall = nil
    }
}

extension NSString {
    /// Line starts as the gutter splits lines (.byLines).
    func lineStarts() -> [Int] {
        var starts: [Int] = []
        enumerateSubstrings(in: NSRange(location: 0, length: length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in starts.append(range.location) }
        return starts
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("timeout"); exit(1) }
app.run()
