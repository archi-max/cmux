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
    // Another server's recompile keeps them; this server's recompile (new diagnostics) forgets them.
    WaveformDebuggerEditorHighlights.recompiled(LanguageServerSession())
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.count == 2, "another server's recompile keeps the cones: \(editor.session.asked)")
    WaveformDebuggerEditorHighlights.recompiled(editor.session)
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.count == 4, "a recompile asks both again: \(editor.session.asked)")
    // A design change forgets them all; a failure is asked again once its wait is over.
    WaveformDebuggerEditorHighlights.forgetCones()
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.count == 6, "after a design change both are asked again: \(editor.session.asked)")
    WaveformDebuggerEditorHighlights.failedConeRetryInterval = 0.1
    try? await Task.sleep(nanoseconds: 200_000_000)
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    expect(editor.session.asked.suffix(1) == ["tb.dut.pc_next"] && editor.session.asked.count == 7, "a failed cone is asked again after its wait: \(editor.session.asked)")
    WaveformDebuggerEditorHighlights.failedConeRetryInterval = 30
    // Lookups still out when the server recompiles (nothing cached for it yet): their answers aren't kept.
    WaveformDebuggerEditorHighlights.forgetCones()
    editor.session.delay = 400_000_000
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    try? await Task.sleep(nanoseconds: 100_000_000)
    WaveformDebuggerEditorHighlights.recompiled(editor.session)
    try? await Task.sleep(nanoseconds: 700_000_000)
    editor.session.delay = 0
    let askedBefore = editor.session.asked.count
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    // Lookups run one after another: only the first (ex_mem) was out across the recompile; pc_next's
    // failure came after it and is kept for its wait.
    expect(editor.session.asked.suffix(from: askedBefore) == ["tb.dut.ex_mem"], "an answer from before a recompile isn't cached: \(editor.session.asked.suffix(from: askedBefore))")

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

    // An `include`d testbench fragment (design_b's adapter_tb.sv, included into tb_wrapper): its
    // lines belong to the file's pseudo-module, placed at tb_wrapper. slang's answers are recorded
    // from slang-server 0.3.1 on that design: tb_wrapper.dfp_ready is driven by the dut's port.
    let fragmentSource = """
    logic [NUM_PORTS-1:0] dfp_read = 1'b0;
    logic [NUM_PORTS-1:0] dfp_ready;
    int errors = 0;
    cache_adapter #(
        .NUM_PORTS(NUM_PORTS)
    ) dut (
        .clk           (clk),
        .dfp_read      (dfp_read),
        .dfp_ready     (dfp_ready)
    );
    """
    WaveformDebugger.stepping = true
    textView.string = source
    WaveformDebuggerEditorHighlights.clear(in: textView)
    let fragmentView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    fragmentView.string = fragmentSource
    var fragmentScan = SystemVerilogInlineScan.Cache(units: SystemVerilogInlineScan.units(of: fragmentSource as NSString))
    fragmentScan.fragmentModule = "adapter_tb.sv"
    let fragmentLines = fragmentScan.lines(in: NSRange(location: 0, length: (fragmentSource as NSString).length))
    let fragmentEditor = FilePreviewLanguageFeatures(textView: fragmentView, path: "/tb/adapter_tb/adapter_tb.sv")
    FilePreviewLanguageFeatures.all = [fragmentEditor]
    fragmentEditor.session.cones["tb_wrapper.dfp_ready"] = [SlangConeEntry(path: "tb_wrapper.dut.dfp_ready", location: nil)]
    WaveformSourceLink.values = [
        15: ["tb_wrapper.dfp_read": "0", "tb_wrapper.dfp_ready": "1", "tb_wrapper.errors": "00000000", "tb_wrapper.clk": "1"],
        5: ["tb_wrapper.dfp_read": "0", "tb_wrapper.dfp_ready": "0", "tb_wrapper.errors": "00000000", "tb_wrapper.clk": "1"],
    ]
    page.previousTimes = [15: 5]
    let fragmentNow = ["dfp_read": "0", "dfp_ready": "1", "errors": "00000000", "clk": "1"]
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: fragmentEditor, textView: fragmentView, lines: fragmentLines, waveform: waveform, time: 15,
        values: ["adapter_tb.sv": fragmentNow], instances: ["adapter_tb.sv": .init(design: "tb_wrapper", dump: "tb_wrapper")]
    ))
    await settle()
    let fragmentLayout = fragmentView.layoutManager!
    let fragmentText = fragmentSource as NSString
    func fragmentAttribute(_ key: NSAttributedString.Key, line: Int, column: Int = 4) -> NSColor? {
        fragmentLayout.temporaryAttribute(key, atCharacterIndex: fragmentLines[line].contentRange.location + column, effectiveRange: nil) as? NSColor
    }
    let readyAt = fragmentText.range(of: "dfp_ready", options: [], range: fragmentLines[1].contentRange).location
    expect(isWarm(fragmentLayout.temporaryAttribute(.backgroundColor, atCharacterIndex: readyAt, effectiveRange: nil) as? NSColor),
           "the fragment's changed signal (dfp_ready) is tinted where it is declared")
    expect(isWarm(fragmentAttribute(.backgroundColor, line: 8)) && fragmentAttribute(.foregroundColor, line: 8) == nil,
           "its driver, the dut's .dfp_ready connection, is a driver line")
    expect(fragmentEditor.session.asked == ["tb_wrapper.dfp_ready"], "the cone asked at the fragment's place: \(fragmentEditor.session.asked)")
    expect(page.highlightCalls.last == [["tb_wrapper", "dfp_ready"]], "its row lights up: \(String(describing: page.highlightCalls.last))")

    // The RTL item in the debugger's strip: what the editors did with this cycle, or why not.
    page.rtlStatuses.removeAll()
    page.rtlShownTimes.removeAll()
    FilePreviewLanguageFeatures.all = []
    WaveformDebuggerRTLStatus.report(waveform)
    await settle()
    let none = page.rtlStatuses.last
    expect(none?["ok"] as? Bool == false && none?["wait"] as? Bool == false && (none?["text"] as? String)?.contains("SystemVerilog") == true,
           "no editor: says to open one, and play does not wait: \(String(describing: none))")
    FilePreviewLanguageFeatures.all = [editor]
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: editor, textView: textView, lines: lines, waveform: waveform, time: 15,
        values: [:], instances: [:], reasons: ["cpu": .notPlaced]
    ))
    await settle()
    let unplaced = page.rtlStatuses.last
    expect(unplaced?["ok"] as? Bool == false && unplaced?["wait"] as? Bool == true
           && (unplaced?["text"] as? String)?.contains("cpu.sv") == true && (unplaced?["text"] as? String)?.contains("placed") == true,
           "a file slang can't place: says so and how to fix it: \(String(describing: unplaced))")
    expect((unplaced?["tooltip"] as? String)?.contains("cpu.sv: cpu.sv") == false, "the tooltip names the file once: \(String(describing: unplaced))")
    expect(page.rtlShownTimes == [15], "and the cycle counts as shown (nothing to draw): \(page.rtlShownTimes)")
    WaveformDebuggerEditorHighlights.valuesShown(shown())
    await settle()
    let drawn = page.rtlStatuses.last
    expect(drawn?["ok"] as? Bool == true && drawn?["text"] as? String == "RTL: cpu.sv", "highlights drawn: names the file: \(String(describing: drawn))")
    // Two editors: the cycle is shown once both drew it; the one that can't is in the tooltip.
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    page.rtlShownTimes.removeAll()
    page.previousTimes = [25: 15]
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: editor, textView: textView, lines: lines, waveform: waveform, time: 25, values: [:], instances: [:]
    ))
    await settle()
    expect(page.rtlShownTimes.isEmpty, "one of two editors drew cycle 25: not shown yet: \(page.rtlShownTimes)")
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: otherEditor, textView: other, lines: lines, waveform: waveform, time: 25,
        values: [:], instances: [:], reasons: ["cpu": .severalInstances(module: "cpu")]
    ))
    await settle()
    let both = page.rtlStatuses.last
    expect(page.rtlShownTimes == [25], "both drew it: shown: \(page.rtlShownTimes)")
    expect((both?["tooltip"] as? String)?.contains("other.sv") == true, "the other editor's reason is in the tooltip: \(String(describing: both))")

    // Cone lookups are capped per cycle across all editors, not per editor: two editors with
    // 12 unassigned changed signals each ask 16 in all for one cycle.
    let wideNames = (0..<12).map { "w\($0)" }
    let wideSource = "module wide;\n" + wideNames.map { "  logic \($0);\n" }.joined() + "endmodule\n"
    let wideLines = SystemVerilogInlineScan.lines(in: wideSource, range: NSRange(location: 0, length: (wideSource as NSString).length))
    func wideEditor(_ path: String) -> (FilePreviewLanguageFeatures, NSTextView) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.string = wideSource
        return (FilePreviewLanguageFeatures(textView: view, path: path), view)
    }
    let (wideA, viewA) = wideEditor("/rtl/wide_a.sv")
    let (wideB, viewB) = wideEditor("/rtl/wide_b.sv")
    FilePreviewLanguageFeatures.all = [wideA, wideB]
    page.previousTimes = [45: 35]
    var wideNow: [String: String] = [:]
    var wideValues: [Int64: [String: String]] = [45: [:], 35: [:]]
    for name in wideNames {
        wideNow[name] = "1"
        for scope in ["tb.a", "tb.b"] {
            wideValues[45]![scope + "." + name] = "1"
            wideValues[35]![scope + "." + name] = "0"
        }
    }
    WaveformSourceLink.values = wideValues
    WaveformDebugger.playing = true
    for (editor, view, scope) in [(wideA, viewA, "tb.a"), (wideB, viewB, "tb.b")] {
        WaveformDebuggerEditorHighlights.valuesShown(.init(
            editor: editor, textView: view, lines: wideLines, waveform: waveform, time: 45,
            values: ["wide": wideNow], instances: ["wide": .init(design: scope, dump: scope)]
        ))
    }
    await settle()
    let wideAsked = wideA.session.asked.count + wideB.session.asked.count
    expect(wideAsked == 16, "cone lookups for one cycle: 16 across both editors (interleaved): \(wideA.session.asked.count) + \(wideB.session.asked.count)")
    // Playing: an editor refreshes as soon as the marker moves (the throttle still coalesces).
    expect(WaveformDebuggerEditorHighlights.refreshDelay(playing: true) == .zero
           && WaveformDebuggerEditorHighlights.refreshDelay(playing: false) == .milliseconds(120),
           "no refresh delay while playing, 120 ms otherwise")
    // Paused, a second look at the same cycle (a scroll, a second editor) has its own 16.
    WaveformDebugger.playing = false
    let askedPlaying = wideA.session.asked.count
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: wideA, textView: viewA, lines: wideLines, waveform: waveform, time: 45,
        values: ["wide": wideNow], instances: ["wide": .init(design: "tb.a", dump: "tb.a")]
    ))
    await settle()
    expect(wideA.session.asked.count == 12, "paused: a refresh at the same cycle asks A's other cones: \(askedPlaying) then \(wideA.session.asked.count)")

    // Two viewers playing at once: each viewer's editors have their own 16 per cycle.
    let viewerC = FilePreviewPanel()
    let (wideC, viewC) = wideEditor("/rtl/wide_c.sv")
    let (wideD, viewD) = wideEditor("/rtl/wide_d.sv")
    let nearC = FilePreviewPanel()
    nearC.near = viewerC
    wideD.linkPanel = nearC
    viewerC.nativeViewSessions.waveform.previousTimes = [45: 35]
    WaveformDebugger.playing = true
    WaveformDebuggerEditorHighlights.forgetCones()
    for (each, view, scope, viewer) in [(wideC, viewC, "tb.a", waveform), (wideD, viewD, "tb.b", viewerC)] {
        WaveformDebuggerEditorHighlights.valuesShown(.init(
            editor: each, textView: view, lines: wideLines, waveform: viewer, time: 45,
            values: ["wide": wideNow], instances: ["wide": .init(design: scope, dump: scope)]
        ))
    }
    await settle()
    expect(wideC.session.asked.count == 12 && wideD.session.asked.count == 12,
           "two viewers: each its own budget: \(wideC.session.asked.count) + \(wideD.session.asked.count)")
    WaveformDebugger.playing = false

    // An editor next to another viewer neither holds up this one's play nor shows in its strip.
    let elsewhere = FilePreviewPanel()
    elsewhere.near = FilePreviewPanel()
    otherEditor.linkPanel = elsewhere
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    page.rtlShownTimes.removeAll()
    page.previousTimes[55] = 45
    WaveformDebuggerEditorHighlights.valuesShown(.init(
        editor: editor, textView: textView, lines: lines, waveform: waveform, time: 55, values: [:], instances: [:]
    ))
    await settle()
    expect(page.rtlShownTimes == [55], "the other viewer's editor isn't waited for: \(page.rtlShownTimes)")
    expect((page.rtlStatuses.last?["tooltip"] as? String)?.contains("other.sv") == false,
           "nor in the strip: \(String(describing: page.rtlStatuses.last))")
    otherEditor.linkPanel = nil

    func draw(_ each: FilePreviewLanguageFeatures, _ view: NSTextView, at time: Int64) async {
        WaveformDebuggerEditorHighlights.valuesShown(.init(
            editor: each, textView: view, lines: lines, waveform: waveform, time: time, values: [:], instances: [:]
        ))
        await settle()
    }
    func lastStatus() -> [String: Any] { page.rtlStatuses.last ?? [:] }

    // Before any editor ever reported, the strip says it waits for them.
    let fresh = FilePreviewLanguageFeatures(textView: NSTextView(frame: .zero), path: "/rtl/fresh.sv")
    FilePreviewLanguageFeatures.all = [fresh]
    WaveformDebuggerRTLStatus.report(waveform)
    await settle()
    expect((lastStatus()["text"] as? String)?.contains("waiting") == true, "never reported: waiting: \(lastStatus())")
    FilePreviewLanguageFeatures.all = [editor, otherEditor]

    // Play starts again: reports from before don't count for the wait, but the strip keeps them.
    for t in [65, 75, 85, 95, 105] as [Int64] { page.previousTimes[t] = t - 10 }
    await draw(editor, textView, at: 65)
    await draw(otherEditor, other, at: 65)
    WaveformDebuggerRTLStatus.playStarted(waveform)
    await settle()
    expect((lastStatus()["text"] as? String)?.contains("waiting") == false,
           "play starting doesn't blank the strip: \(lastStatus())")
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 65)
    expect(page.rtlShownTimes.isEmpty, "the other editor's report from before play doesn't count: \(page.rtlShownTimes)")

    // The page moved on without an editor (it timed out on the cycle): that editor isn't
    // waited for until it reports the page's cycle again, late reports for cycles left included.
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 75, left: nil, missed: false)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 75)
    expect(page.rtlShownTimes.isEmpty, "at first the other editor is waited for: \(page.rtlShownTimes)")
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 85, left: 75, missed: true)
    await draw(editor, textView, at: 85)
    expect(page.rtlShownTimes == [85], "it missed 75: it no longer holds play: \(page.rtlShownTimes)")
    await draw(otherEditor, other, at: 75)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 95, left: 85, missed: false)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 95)
    expect(page.rtlShownTimes == [95], "a late report for a cycle the page left doesn't bring it back: \(page.rtlShownTimes)")
    await draw(otherEditor, other, at: 95)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 105, left: 95, missed: false)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 105)
    expect(page.rtlShownTimes.isEmpty, "it reported the page's cycle: waited for again: \(page.rtlShownTimes)")

    // One editor, stalled: after the first cycle it missed, the page doesn't wait at all.
    FilePreviewLanguageFeatures.all = [otherEditor]
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 75, left: nil, missed: false)
    await settle()
    expect(lastStatus()["wait"] as? Bool == true, "play waits for it at first: \(lastStatus())")
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 85, left: 75, missed: true)
    await settle()
    expect(lastStatus()["wait"] as? Bool == false, "it missed 75: play runs at its rate: \(lastStatus())")
    await draw(otherEditor, other, at: 85)
    expect(lastStatus()["wait"] as? Bool == true, "it caught up: play waits again: \(lastStatus())")

    for t in [115, 125, 135, 145] as [Int64] { page.previousTimes[t] = t - 10 }
    // Play starts from a cycle the editors drew before: the first move doesn't count as missed.
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    await draw(editor, textView, at: 65)
    await draw(otherEditor, other, at: 65)
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 75, left: 65, missed: false)
    await settle()
    expect(lastStatus()["wait"] as? Bool == true, "the start cycle isn't a missed one: play waits: \(lastStatus())")
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 75)
    await draw(otherEditor, other, at: 75)
    expect(page.rtlShownTimes == [75], "both drew the first played cycle: shown: \(page.rtlShownTimes)")

    // Behind isn't for the whole play: an editor that draws a played cycle within the 250 ms wait
    // of its move is waited for again; one slower than that isn't.
    let t0 = Date()
    WaveformDebuggerRTLStatus.now = { t0 }
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 75, left: 65, missed: false)
    await draw(editor, textView, at: 75)
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.3) }
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 85, left: 75, missed: true)
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.35) }
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 95, left: 85, missed: false)
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.75) }
    await draw(otherEditor, other, at: 85)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 95)
    expect(page.rtlShownTimes == [95], "the other drew 85 450 ms after its move: still behind: \(page.rtlShownTimes)")
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.8) }
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 105, left: 95, missed: false)
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.85) }
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 115, left: 105, missed: false)
    WaveformDebuggerRTLStatus.now = { t0.addingTimeInterval(0.9) }
    await draw(otherEditor, other, at: 105)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 125, left: 115, missed: false)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 125)
    expect(page.rtlShownTimes.isEmpty, "it drew 105 within 100 ms of its move: waited for again: \(page.rtlShownTimes)")
    WaveformDebuggerRTLStatus.now = { Date() }

    // The setting turned on mid-play: every editor is waited for again.
    FilePreviewLanguageFeatures.all = [otherEditor]
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 75, left: 65, missed: false)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 85, left: 75, missed: true)
    await settle()
    expect(lastStatus()["wait"] as? Bool == false, "(behind: no wait) \(lastStatus())")
    WaveformDebuggerRTLStatus.waitSettingChanged(waveform)
    await settle()
    expect(lastStatus()["wait"] as? Bool == true, "the setting changed: it is waited for again: \(lastStatus())")

    // The first cycle (none before it to compare with) is drawn too: it counts as shown.
    FilePreviewLanguageFeatures.all = [editor]
    WaveformDebuggerRTLStatus.playStarted(waveform)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 5)
    expect(page.rtlShownTimes == [5], "a cycle with none before it: shown: \(page.rtlShownTimes)")

    // The page already moved to a cycle every editor drew: the ack comes at once.
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    WaveformDebuggerRTLStatus.playStarted(waveform)
    await draw(editor, textView, at: 135)
    await draw(otherEditor, other, at: 135)
    page.rtlShownTimes.removeAll()
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 135, left: 125, missed: false)
    await settle()
    expect(page.rtlShownTimes == [135], "moved to a cycle both drew: shown: \(page.rtlShownTimes)")

    // A new page (stepping stopped) starts its plays afresh: a report from an earlier one doesn't count.
    WaveformDebuggerRTLStatus.forget(waveform)
    WaveformDebuggerRTLStatus.playStarted(waveform)
    page.rtlShownTimes.removeAll()
    await draw(otherEditor, other, at: 145)
    WaveformDebuggerRTLStatus.forget(waveform)
    WaveformDebuggerRTLStatus.playStarted(waveform)
    WaveformDebuggerRTLStatus.pageMoved(waveform, to: 145, left: 135, missed: false)
    page.rtlShownTimes.removeAll()
    await draw(editor, textView, at: 145)
    expect(page.rtlShownTimes.isEmpty, "the other's report from before the page forgot doesn't count: \(page.rtlShownTimes)")

    // (Both editors; this one at 65 since play started, the other not, for the checks below.)
    FilePreviewLanguageFeatures.all = [editor, otherEditor]
    WaveformDebuggerRTLStatus.playStarted(waveform)
    await draw(editor, textView, at: 65)
    page.rtlShownTimes.removeAll()

    // An editor closes: play no longer waits for it, and the strip says so.
    FilePreviewLanguageFeatures.all = [editor]
    WaveformDebuggerRTLStatus.editorGone(otherEditor)
    await settle()
    expect(page.rtlShownTimes == [65], "the editor play waited for closed: the cycle is shown: \(page.rtlShownTimes)")
    expect((page.rtlStatuses.last?["tooltip"] as? String)?.contains("other.sv") == false
           && (page.rtlStatuses.last?["text"] as? String)?.contains("waiting") == false,
           "the strip no longer waits for it: \(String(describing: page.rtlStatuses.last))")
    FilePreviewLanguageFeatures.all = []
    WaveformDebuggerRTLStatus.editorGone(editor)
    await settle()
    expect(page.rtlStatuses.last?["wait"] as? Bool == false && page.rtlStatuses.last?["ok"] as? Bool == false,
           "the last one closed: play doesn't wait: \(String(describing: page.rtlStatuses.last))")

    print(failures == 0 ? "DEBUGGER EDITOR CHECKS PASSED" : "DEBUGGER EDITOR CHECKS FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

// No window and no Dock icon; the app only gives the text view its run loop.
NSApplication.shared.setActivationPolicy(.prohibited)
Task { @MainActor in await run() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
NSApplication.shared.run()
