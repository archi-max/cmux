// Assembly-listing breakpoint checks (run.sh asm-listing): the real WaveformDebuggerAsmBreakpoints.swift
// (with CmuxSyntaxHighlighting's listing parser) on windowless NSTextViews, with stubbed viewers:
// a listing is found by its text, the gutter and F9 put a breakpoint on an instruction (a label line
// snaps to the next one), the page gets them as PC breakpoints and its list's toggles come back,
// conditions, marks follow their code when the listing is rebuilt (or are lost), the current commit
// is highlighted with an arrow, the listing is checked once against the dump's commits, Show
// Instruction in Listing, and the session.
// Usage: asm-listing <gnu-rv32-code.dis>
import AppKit

typealias AB = WaveformDebuggerAsmBreakpoints
var failures = 0
@MainActor func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

@MainActor func lineStart(_ line: Int, in text: String) -> Int { AB.lineStarts(of: text)[line] }

@MainActor func makeView(_ text: String, path: String, workspace: UUID) -> SavingTextView {
    let view = SavingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    view.string = text
    view.panel = FilePreviewPanel(workspaceId: workspace, filePath: path, previewMode: .text)
    AB.sync(view, filePath: path)
    return view
}

@MainActor func settle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

@MainActor func parsed(_ view: NSTextView) async -> Bool {
    for _ in 0..<100 { if AB.listing(in: view) != nil { return true }; await settle(20) }
    return false
}

@MainActor func pageItems(_ viewer: FilePreviewPanel) -> [[String: Any]]? {
    viewer.nativeViewSessions.waveform.calls.last { $0.function == "setPcBreakpoints" }?.argument["items"] as? [[String: Any]]
}

@MainActor func run(_ listingPath: String) async {
    guard let text = try? String(contentsOfFile: listingPath, encoding: .utf8) else { print("cannot read", listingPath); exit(2) }
    AB.reparseDelay = .milliseconds(20)
    let workspace = UUID()
    let viewer = FilePreviewPanel(workspaceId: workspace, filePath: "/w/run.vcd")
    AB.viewers = { $0 == workspace ? [viewer] : [] }

    // Found by its text (not its name); a text that isn't a listing takes no breakpoints.
    let view = makeView(text, path: "/w/prog.txt", workspace: workspace)
    let plain = makeView("just some notes\nnot objdump output\n", path: "/w/notes.dis", workspace: workspace)
    expect(await parsed(view), "objdump output is a listing, whatever its name")
    await settle(100)
    expect(AB.styles(in: plain) == nil && !AB.gutterClicked(plain, lineStart: 0), "a text that isn't one takes no breakpoints")
    expect(AB.styles(in: view)?.isEmpty == true, "no breakpoints yet")

    // The gutter: a label line snaps to its first instruction (line 6 `<_start>:`, line 7 lui).
    expect(AB.gutterClicked(view, lineStart: lineStart(6, in: text)), "a click on the label line is taken")
    var styles = AB.styles(in: view) ?? [:]
    expect(styles == [lineStart(7, in: text): .enabled], "the breakpoint is on the next instruction: \(styles)")
    _ = AB.gutterClicked(view, lineStart: lineStart(8, in: text))
    let mark = AB.marks[workspace]?.last
    expect(mark?.pc == 0x8000_0004 && mark?.symbol == "_start" && mark?.offset == 4 && mark?.text == "li a0,0",
           "kept by PC and symbol+offset: \(String(describing: mark))")
    _ = AB.gutterClicked(view, lineStart: lineStart(8, in: text) + 3)
    expect(AB.marks[workspace]?.count == 1, "a second click removes it")

    // F9 at the caret.
    AppDelegate.shared?.focused = view
    view.setSelectedRange(NSRange(location: lineStart(10, in: text) + 5, length: 0))
    expect(AB.toggleAtCaret(window: nil), "F9 in a listing is taken")
    AppDelegate.shared?.focused = plain
    expect(!AB.toggleAtCaret(window: nil), "and not in another text")
    expect(AB.marks[workspace]?.map(\.pc) == [0x8000_0000, 0x8000_0008], "F9 put one on its line: \(AB.marks[workspace]?.map(\.pc) ?? [])")

    // The page gets them as PC breakpoints keyed by the mark (one call for a burst of edits).
    await settle()
    var items = pageItems(viewer)
    expect(items?.map { $0["pcs"] as? [String] ?? [] } == [["0x80000000"], ["0x80000008"]]
           && items?.map { $0["listingLabel"] as? String ?? "" } == ["prog.txt: _start", "prog.txt: _start+0x8"]
           && items?.allSatisfy { $0["enabled"] as? Bool == true && ($0["key"] as? String).flatMap(UUID.init(uuidString:)) != nil } == true,
           "the page's items: \(String(describing: items))")
    expect(viewer.nativeViewSessions.waveform.calls.filter { $0.function == "setPcBreakpoints" }.count == 1, "sent once")
    await AB.sync(viewer)
    expect(viewer.nativeViewSessions.waveform.calls.filter { $0.function == "setPcBreakpoints" }.count == 1, "not again while unchanged")

    // The page's list toggles, conditions and removes them.
    let first = AB.marks[workspace]![0].id, second = AB.marks[workspace]![1].id
    AB.pageReported(["key": first.uuidString, "enabled": false], waveform: viewer)
    styles = AB.styles(in: view) ?? [:]
    expect(styles[lineStart(7, in: text)] == .disabled, "disabled from the list: \(styles)")
    AB.pageReported(["key": first.uuidString, "conditionError": true], waveform: viewer)
    AB.setEnabled(first, true, in: workspace)
    expect(AB.styles(in: view)?[lineStart(7, in: text)] == .lost, "a condition that does not parse is drawn as an error")
    AB.pageReported(["key": first.uuidString, "conditionError": false], waveform: viewer)
    WaveformDebuggerEvaluate.promptAnswer = "$a0 == 3"
    let menu = AB.gutterMenu(view, lineStart: lineStart(7, in: text))
    expect(menu?.items.map(\.title) == ["Disable Breakpoint", "Edit Condition…", "", "Remove Breakpoint"], "the dot's menu: \(menu?.items.map(\.title) ?? [])")
    if let edit = menu?.items.first(where: { $0.title == "Edit Condition…" }) { _ = edit.target?.perform(edit.action, with: edit) }
    expect(AB.marks[workspace]?.first?.condition == "$a0 == 3" && AB.styles(in: view)?[lineStart(7, in: text)] == .conditional,
           "Edit Condition… sets it")
    expect(AB.gutterMenu(view, lineStart: lineStart(7, in: text))?.items.map(\.title).contains("Remove Condition") == true, "and offers to remove it")
    expect(AB.gutterMenu(view, lineStart: lineStart(9, in: text)) == nil, "no menu where there is no breakpoint")
    AB.pageReported(["key": second.uuidString, "removed": true], waveform: viewer)
    expect(AB.marks[workspace]?.map(\.id) == [first], "removed from the list")
    await settle()
    items = pageItems(viewer)
    expect(items?.count == 1 && items?.first?["condition"] as? String == "$a0 == 3", "the page has the condition: \(String(describing: items))")

    // A rebuild that moved the code: two instructions more before `bnez` (line 12, _start+0xc).
    _ = AB.gutterClicked(view, lineStart: lineStart(12, in: text))
    let bnez = AB.marks[workspace]!.last!.id
    let moved = text.replacingOccurrences(of: "8000000a:\t12fd                \taddi\tt0,t0,-1\n",
                                          with: "8000000a:\t12fd                \taddi\tt0,t0,-1\n8000000c:\t0001                \tnop\n8000000e:\t0001                \tnop\n")
        .replacingOccurrences(of: "8000000c:\tfe029ee3          \tbnez\tt0,80000008 <_start+0x8>",
                              with: "80000010:\tfe029ce3          \tbnez\tt0,80000008 <_start+0x8>")
    expect(moved != text, "the rebuilt listing differs")
    view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (view.string as NSString).length), with: moved)
    await settle(300)
    let followed = AB.marks[workspace]?.first { $0.id == bnez }
    expect(followed?.pc == 0x8000_0010 && followed?.offset == 0x10 && followed?.lost == false, "bnez's breakpoint followed its code: \(String(describing: followed))")
    expect(AB.styles(in: view)?[lineStart(14, in: moved)] == .enabled, "drawn on its new line")
    await settle()
    expect(pageItems(viewer)?.contains { $0["pcs"] as? [String] == ["0x80000010"] } == true, "the page has its new PC")

    // A listing without its symbol or its PC: the mark is lost (kept, off). (A listing that still has
    // the PC keeps it there, whatever the instruction: design Q8.)
    let other = text.replacingOccurrences(of: "<_start>", with: "<start2>")
        .components(separatedBy: "\n").filter { !$0.hasPrefix("8000000c:") && !$0.hasPrefix("80000010:") }.joined(separator: "\n")
    view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (view.string as NSString).length), with: other)
    await settle(300)
    let lost = AB.marks[workspace]?.first { $0.id == bnez }
    expect(lost?.lost == true, "a breakpoint whose code is gone is lost: \(String(describing: lost))")
    await settle()
    expect(pageItems(viewer)?.first { ($0["pcs"] as? [String]) == ["0x80000010"] }?["enabled"] as? Bool == false, "and off in the page")
    view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (view.string as NSString).length), with: text)
    await settle(300)
    expect(AB.marks[workspace]?.first { $0.id == bnez }.map { !$0.lost && $0.pc == 0x8000_000c } == true, "back on bnez when the code is: \(String(describing: AB.marks[workspace]?.first { $0.id == bnez }))")

    // The current commit: an arrow and a highlight on its line, the cycle's others lighter; Stop clears it.
    AB.currentReported(["pcs": ["0x80000004", "0x80000006"], "current": "0x80000006"], waveform: viewer)
    expect(AB.currentLineStart(in: view) == lineStart(9, in: text), "the arrow is on the current commit's line")
    let lm = view.layoutManager!
    let strong = lm.temporaryAttribute(.backgroundColor, atCharacterIndex: lineStart(9, in: text) + 2, effectiveRange: nil) as? NSColor
    let light = lm.temporaryAttribute(.backgroundColor, atCharacterIndex: lineStart(8, in: text) + 2, effectiveRange: nil) as? NSColor
    expect(strong != nil && light != nil && (strong?.alphaComponent ?? 0) > (light?.alphaComponent ?? 1), "highlighted, the other commit lighter")
    AB.currentReported(["pcs": [String](), "current": NSNull()], waveform: viewer)
    expect(AB.currentLineStart(in: view) == nil
           && lm.temporaryAttribute(.backgroundColor, atCharacterIndex: lineStart(9, in: text) + 2, effectiveRange: nil) == nil, "cleared on Stop")
    let otherWorkspace = FilePreviewPanel(workspaceId: UUID(), filePath: "/w/x.vcd")
    AB.currentReported(["pcs": ["0x80000004"], "current": "0x80000004"], waveform: otherWorkspace)
    expect(AB.currentLineStart(in: view) == nil, "another workspace's viewer doesn't move it")

    // Show Instruction in Listing.
    viewer.nativeViewSessions.waveform.answers["currentCommitPc"] = "0x8000005a"
    let shown = await AB.revealCurrent(of: viewer)
    expect(shown && view.selectedRange().location == lineStart(text.components(separatedBy: "\n").firstIndex { $0.hasPrefix("8000005a:") }!, in: text),
           "reveals the current commit's line")
    viewer.nativeViewSessions.waveform.answers["currentCommitPc"] = "0x90000000"
    let notShown = await AB.revealCurrent(of: viewer)
    expect(!notShown, "false when no open listing has it")

    // The listing checked against the dump's commits once (per listing and dump).
    let checker = FilePreviewPanel(workspaceId: workspace, filePath: "/w/bad.vcd")
    checker.nativeViewSessions.waveform.answers["commitSample"] = [["pc": "0x80000000", "insn": 0x8000_4137], ["pc": "0x80000004", "insn": 0x4511],
                                                                  ["pc": "0x80000012", "insn": 0x0000_1317]]
    AB.viewers = { $0 == workspace ? [viewer, checker] : [] }
    AB.commitsReady(checker)
    await settle(100)
    let said = checker.nativeViewSessions.waveform.calls.filter { $0.function == "say" }.map { $0.argument["text"] as? String ?? "" }
    expect(said == ["prog.txt doesn't match this dump: 1 of 3 committed instructions differ (first at 0x80000004: committed 0x4511, listing 0x4501)."],
           "a mismatch is said: \(said)")
    AB.commitsReady(checker)
    await settle(100)
    expect(checker.nativeViewSessions.waveform.calls.filter { $0.function == "say" }.count == 1, "once")
    viewer.nativeViewSessions.waveform.answers["commitSample"] = [["pc": "0x80000004", "insn": 0x4501], ["pc": "0x8000000c", "insn": 0xfe02_9ee3]]
    AB.commitsReady(viewer)
    await settle(100)
    expect(!viewer.nativeViewSessions.waveform.calls.contains { $0.function == "say" }, "nothing said when it matches")
    var none = AsmListingMatch()
    none.notInListing = 5
    expect(AB.mismatchText(none, listingPath: "/w/a.dis") == "a.dis doesn't match this dump: none of the 5 committed PCs checked are in it.",
           "none of the PCs in it: said")
    expect(AB.mismatchText(AsmListingMatch(), listingPath: "/w/a.dis") == nil, "nothing compared: nothing said")

    // The session: saved, restored into another workspace, placed when its listing opens.
    let saved = AB.sessionMarks(of: workspace)
    let decoded = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode([AsmMark].self, from: $0) }
    expect(decoded == saved && decoded?.count == 2, "the marks encode: \(decoded?.count ?? -1)")
    let restored = UUID()
    AB.restore(decoded, in: restored)
    let again = makeView(text, path: "/w/prog.txt", workspace: restored)
    expect(await parsed(again), "the listing opens in the restored workspace")
    await settle(100)
    expect(AB.styles(in: again)?.count == 2, "and its breakpoints are drawn: \(AB.styles(in: again) ?? [:])")
    expect(AB.sessionMarks(of: UUID()) == nil, "a workspace without any saves none")

    print(failures == 0 ? "ASM LISTING CHECKS PASSED" : "ASM LISTING CHECKS FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let listingPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
Task { @MainActor in await run(listingPath) }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
