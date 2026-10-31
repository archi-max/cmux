// Waveform debugger, editor side (run.sh debugger-editor): runs the real
// Sources/Panels/WaveformDebuggerEditorHighlights.swift on a windowless
// NSTextView (stubs.swift stands in for the viewer and slang-server) and checks
// what it draws: changed signals, their driver lines (a port connection
// through slang's driver cone too), the module's other lines dimmed, the rows
// lit in the waveform, and the selected row's lines, which outlive a cycle clear.
import AppKit

let source = """
module cpu(input logic clk, input logic rst);
  logic [31:0] pc, pc_next;
  logic stall, dmem_pending;
  ex_mem_t ex_mem;
  assign dmem_pending = |ex_mem.mem_rmask;
  always_ff @(posedge clk) begin
    if (rst) pc <= '0;
    else if (!stall)
      pc <= pc_next;
  end
  ex_stage ex_stg(
    .clk(clk),
    .ex_mem(ex_mem)
  );
endmodule
"""

nonisolated(unsafe) var failures = 0
func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

@MainActor func run() async {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    textView.string = source
    let text = source as NSString
    let lines = SystemVerilogInlineScan.lines(in: source, range: NSRange(location: 0, length: text.length))
    let lineRanges = lines.map(\.contentRange)
    let editor = FilePreviewLanguageFeatures(textView: textView, path: "/rtl/cpu.sv")
    FilePreviewLanguageFeatures.all = [editor]
    let waveform = FilePreviewPanel()
    WaveformSourceLink.waveform = waveform
    let page = waveform.nativeViewSessions.waveform
    page.previousTimes = [15: 5]
    editor.session.failing = ["tb.dut.pc_next"]
    editor.session.cones["tb.dut.ex_mem"] = [SlangConeEntry(path: "tb.dut.ex_stg.ex_mem", location: nil)]
    let scope = "TOP.tb.dut"
    func values(_ pairs: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.map { (scope + "." + $0.key, $0.value) })
    }
    let now = ["pc": "00000004", "pc_next": "00000008", "stall": "0", "dmem_pending": "1", "ex_mem": "ab", "clk": "1", "rst": "0"]
    WaveformSourceLink.values = [
        15: values(now),
        5: values(["pc": "00000000", "pc_next": "00000004", "stall": "0", "dmem_pending": "0", "ex_mem": "00", "clk": "1", "rst": "0"]),
    ]
    let layout = textView.layoutManager!
    func attribute(_ key: NSAttributedString.Key, line: Int, column: Int = 4) -> NSColor? {
        layout.temporaryAttribute(key, atCharacterIndex: lineRanges[line].location + column, effectiveRange: nil) as? NSColor
    }
    func isBlue(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return c.blueComponent > c.redComponent
    }
    func isWarm(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return false }
        return c.redComponent > c.blueComponent
    }
    func shown() -> WaveformDebuggerEditorHighlights.Shown {
        .init(editor: editor, textView: textView, lines: lines, waveform: waveform, time: 15,
              values: ["cpu": now], instances: ["cpu": .init(design: "tb.dut", dump: scope)])
    }
    func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    let driverLines = lineRanges.indices.filter { isWarm(attribute(.backgroundColor, line: $0)) && attribute(.foregroundColor, line: $0) == nil }
    expect(driverLines == [4, 6, 8, 12], "driver lines: the assign, both pc assignments, and ex_stg's .ex_mem connection: \(driverLines)")
    let dimmed = lineRanges.indices.filter { attribute(.foregroundColor, line: $0, column: 0) != nil }
    expect(dimmed == [0, 1, 2, 3, 5, 7, 9, 10, 11, 13, 14], "the module's other lines are dimmed: \(dimmed)")
    let pcAt = text.range(of: "pc", options: [], range: lineRanges[1]).location
    let stallAt = text.range(of: "stall", options: [], range: lineRanges[2]).location
    expect(isWarm(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: pcAt, effectiveRange: nil) as? NSColor), "a changed signal (pc) is tinted where it is declared")
    expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: stallAt, effectiveRange: nil) == nil, "an unchanged signal (stall) is not")
    expect(editor.session.asked == ["tb.dut.ex_mem", "tb.dut.pc_next"], "driver cones asked only for changed signals no line here assigns: \(editor.session.asked)")
    let rows = page.highlightCalls.last ?? []
    expect(rows == ["dmem_pending", "ex_mem", "pc", "pc_next"].map { ["TOP", "tb", "dut", $0] }, "the changed signals' rows light up in the waveform: \(rows)")

    // The same cycle again: the cone that failed (design not compiled yet) is asked again,
    // the one that answered comes from the cache; the rows are not sent again.
    let calls = page.highlightCalls.count
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked == ["tb.dut.ex_mem", "tb.dut.pc_next"] && page.highlightCalls.count == calls,
           "cones cached, a failed one for a while; unchanged rows not resent: \(editor.session.asked)")
    // A design change forgets them all; a failure is asked again once its wait is over.
    WaveformDebuggerEditorHighlights.forgetCones()
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.count == 4, "after a design change both are asked again: \(editor.session.asked)")
    WaveformDebuggerEditorHighlights.failedConeRetryInterval = 0.1
    try? await Task.sleep(nanoseconds: 200_000_000)
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.suffix(1) == ["tb.dut.pc_next"] && editor.session.asked.count == 5, "a failed cone is asked again after its wait: \(editor.session.asked)")
    WaveformDebuggerEditorHighlights.failedConeRetryInterval = 30

    // Typing above the highlights moves them with the text; clearing must still take them all away.
    textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// x\n")
    WaveformDebuggerEditorHighlights.clear(in: textView)
    let full = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
    var leftover = 0
    for index in 0..<full.length {
        for key in [NSAttributedString.Key.backgroundColor, .foregroundColor]
        where layout.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil) != nil {
            leftover += 1
        }
    }
    expect(leftover == 0, "no highlight is left behind after an edit: \(leftover)")
    textView.string = source

    // An edit that keeps the length still makes the drawn ranges stale: the selection is not drawn back.
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    let declLine = LSPLocation(uri: URL(fileURLWithPath: "/rtl/cpu.sv"), range: LSPRange(start: LSPPosition(line: 2, character: 15), end: LSPPosition(line: 2, character: 27)))
    WaveformDebuggerEditorHighlights.showSelection(declLine, drivers: [], near: editor)
    textView.textStorage?.replaceCharacters(in: NSRange(location: lineRanges[1].location + 2, length: 5), with: "LOGIC")
    WaveformDebuggerEditorHighlights.clear(in: textView)
    expect(attribute(.backgroundColor, line: 2) == nil, "a same-length edit: no selection drawn at stale ranges")
    WaveformDebuggerEditorHighlights.showSelection(nil, drivers: [], near: nil)
    textView.string = source

    // The text view swaps in another text storage (a reload): what was drawn on the old one is not drawn on it.
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    other.layoutManager!.replaceTextStorage(NSTextStorage(string: source))
    let otherEditor = FilePreviewLanguageFeatures(textView: other, path: "/rtl/other.sv")
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    let otherDecl = LSPLocation(uri: URL(fileURLWithPath: "/rtl/other.sv"), range: LSPRange(start: LSPPosition(line: 2, character: 15), end: LSPPosition(line: 2, character: 27)))
    // Edits on the old storage first, so the new one can catch up to the same count below.
    for _ in 0..<6 { other.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: (source as NSString).substring(to: 1)) }
    WaveformDebuggerEditorHighlights.showSelection(otherDecl, drivers: [], near: otherEditor)
    let before = other.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: lineRanges[2].location + 4, effectiveRange: nil)
    expect(before != nil, "the selection is drawn in the other editor before the swap")
    let drawnRevision = WaveformDebuggerEditorHighlights.revision(of: other)
    let swappedIn = NSTextStorage(string: source)
    other.layoutManager!.replaceTextStorage(swappedIn)
    // Make the new storage's edit count equal the old one's, so only its identity tells them apart.
    var guardCount = 0
    while WaveformDebuggerEditorHighlights.revision(of: other) < drawnRevision, guardCount < 20 {
        swappedIn.replaceCharacters(in: NSRange(location: 0, length: 1), with: (source as NSString).substring(to: 1))
        guardCount += 1
    }
    expect(WaveformDebuggerEditorHighlights.revision(of: other) == drawnRevision, "the swapped-in storage reaches the same edit count: \(WaveformDebuggerEditorHighlights.revision(of: other)) vs \(drawnRevision), \(guardCount) edits")
    WaveformDebuggerEditorHighlights.clear(in: other)
    let swapped = other.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: lineRanges[2].location + 4, effectiveRange: nil)
    expect(swapped == nil, "a swapped-in text storage gets nothing drawn from the old one")
    WaveformDebuggerEditorHighlights.showSelection(nil, drivers: [], near: nil)
    FilePreviewLanguageFeatures.all = [editor]

    // A newer refresh while an older one still waits for the page: the newer one draws.
    page.delay = 150_000_000
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    try? await Task.sleep(nanoseconds: 50_000_000)
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    try? await Task.sleep(nanoseconds: 400_000_000)
    page.delay = 0
    expect(isWarm(attribute(.backgroundColor, line: 4)), "a superseded refresh does not wipe the newer one")

    // The selected row's declaration and driver.
    let decl = LSPLocation(uri: URL(fileURLWithPath: "/rtl/cpu.sv"), range: LSPRange(start: LSPPosition(line: 2, character: 15), end: LSPPosition(line: 2, character: 27)))
    let driver = LSPLocation(uri: URL(fileURLWithPath: "/rtl/cpu.sv"), range: LSPRange(start: LSPPosition(line: 4, character: 9), end: LSPPosition(line: 4, character: 21)))
    WaveformDebuggerEditorHighlights.showSelection(decl, drivers: [driver], near: editor)
    expect(isBlue(attribute(.backgroundColor, line: 2)) && isBlue(attribute(.backgroundColor, line: 4)), "the selected row's declaration and driver lines light up")
    WaveformDebuggerEditorHighlights.clear(in: textView)
    expect(isBlue(attribute(.backgroundColor, line: 2)) && attribute(.backgroundColor, line: 6) == nil && attribute(.foregroundColor, line: 1, column: 0) == nil,
           "clearing the cycle keeps the selection's lines")
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    WaveformDebuggerEditorHighlights.showSelection(nil, drivers: [], near: nil)
    expect(attribute(.backgroundColor, line: 2) == nil && isWarm(attribute(.backgroundColor, line: 4)), "a new selection takes the old one's lines away and the cycle's come back")

    // Values read before the first cycle: nothing to compare with.
    page.previousTimes = [:]
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(lineRanges.indices.allSatisfy { attribute(.backgroundColor, line: $0) == nil }, "no cycle before: nothing drawn")

    // Not stepping: nothing drawn, the rows go out.
    page.previousTimes = [15: 5]
    WaveformDebugger.stepping = false
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(lineRanges.indices.allSatisfy { attribute(.backgroundColor, line: $0) == nil }, "not stepping: no highlights")
    expect(page.highlightCalls.last == [], "not stepping: the waveform's rows go out")

    // An edit while the values are read: nothing stale is drawn.
    WaveformDebugger.stepping = true
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    textView.string = source + "\n"
    await settle()
    expect(lineRanges.indices.allSatisfy { attribute(.backgroundColor, line: $0) == nil }, "an edit meanwhile: nothing drawn")

    print(failures == 0 ? "DEBUGGER EDITOR CHECKS PASSED" : "DEBUGGER EDITOR CHECKS FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

// No window and no Dock icon; the app only gives the text view its run loop.
NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
NSApplication.shared.run()
