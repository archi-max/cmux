import Foundation
import Testing
@testable import CmuxSyntaxHighlighting

/// The waveform debugger's line breakpoints: which signals a line watches, and how a breakpoint
/// stays on its line through edits and finds it again by its text.
@Suite("Waveform line breakpoints")
struct WaveformLineBreakpointTests {
    private func line(_ number: Int, of source: String) -> (SystemVerilogInlineScan.Line, NSString) {
        let text = source as NSString
        let lines = SystemVerilogInlineScan.lines(in: source, range: NSRange(location: 0, length: text.length))
        return (lines[number], text)
    }

    private let source = """
    module core(input logic clk);
      logic [7:0] count, limit;
      logic done, busy, start;
      always_ff @(posedge clk) count <= count + 1;
      assign done = count == limit;
      always_comb begin
        if (start && !busy) {busy, done} = 2'b10;
        else busy = 0;
      end
      always_ff @(posedge clk) if (start && busy) limit <= limit;
      wire unused = busy;
    endmodule
    """

    @Test func watchesWhatTheLineAssigns() {
        func watched(_ number: Int) -> [String] {
            let (line, text) = line(number, of: source)
            return WaveformLineBreakpoint.watchedSignals(of: line, in: text)
        }
        #expect(watched(3) == ["count"])
        #expect(watched(4) == ["done"])
        #expect(watched(6) == ["busy", "done"])
        #expect(watched(7) == ["busy"])
        #expect(watched(9) == ["limit"])
        #expect(watched(10) == ["unused"])
    }

    @Test func aLineThatAssignsNothingWatchesWhatItReads() {
        let other = """
        module m(input logic clk);
          logic a, b, c;
          always_ff @(posedge clk) if (a && b) begin
          case (c)
          logic [3:0] d;
        endmodule
        """
        func watched(_ number: Int) -> [String] {
            let (line, text) = line(number, of: other)
            return WaveformLineBreakpoint.watchedSignals(of: line, in: text)
        }
        #expect(watched(2) == ["clk", "a", "b"])
        #expect(watched(3) == ["c"])
        #expect(watched(4) == ["d"])
        #expect(watched(5) == [])
    }

    @Test func aBreakpointMovesWithEditsAboveIt() {
        let before = "a\nb\nc\nd\n" as NSString
        let atC = 4
        // Insert a line above it.
        let inserted = NSMutableString(string: before)
        inserted.insert("x\n", at: 2)
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 2, length: 2), changeInLength: 2, in: inserted) == 6)
        // Delete the line above it.
        let deleted = NSMutableString(string: before)
        deleted.deleteCharacters(in: NSRange(location: 2, length: 2))
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 2, length: 0), changeInLength: -2, in: deleted) == 2)
        // Typing on its own line, after its start: it stays at the line's start.
        let typed = NSMutableString(string: before)
        typed.insert("zz", at: 5)
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 5, length: 2), changeInLength: 2, in: typed) == 4)
        // An edit below it: unchanged.
        let below = NSMutableString(string: before)
        below.insert("y", at: 6)
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 6, length: 1), changeInLength: 1, in: below) == 4)
        // Its line deleted with the one before (b and c joined away): it goes to the line now there.
        let joined = NSMutableString(string: before)
        joined.deleteCharacters(in: NSRange(location: 2, length: 4))
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 2, length: 0), changeInLength: -4, in: joined) == 2)
        // Text typed at the very start of its line pushes the line's start? No: the line still starts there.
        let atStart = NSMutableString(string: before)
        atStart.insert("q", at: 4)
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 4, length: 1), changeInLength: 1, in: atStart) == 4)
        // A new line typed at the start of its line moves it down with its text.
        let newline = NSMutableString(string: before)
        newline.insert("\n", at: 4)
        #expect(WaveformLineBreakpoint.offset(atC, afterEditing: NSRange(location: 4, length: 1), changeInLength: 1, in: newline) == 5)
    }

    @Test func findsItsLineAgainByText() {
        let text = "module m;\n  a <= b;\n  c <= d;\n  a <= b;\nendmodule\n" as NSString
        #expect(WaveformLineBreakpoint.line(matching: "c <= d;", near: 2, in: text) == 2)
        #expect(WaveformLineBreakpoint.line(matching: "c <= d;", near: 0, in: text) == 2)
        // Two lines with that text: the one nearest where it was.
        #expect(WaveformLineBreakpoint.line(matching: "a <= b;", near: 3, in: text) == 3)
        #expect(WaveformLineBreakpoint.line(matching: "a <= b;", near: 0, in: text) == 1)
        // Spacing does not matter; a changed line is not found.
        #expect(WaveformLineBreakpoint.line(matching: "c  <=   d;", near: 2, in: text) == 2)
        #expect(WaveformLineBreakpoint.line(matching: "c <= e;", near: 2, in: text) == nil)
        #expect(WaveformLineBreakpoint.lineText(" \t c <=   d; ") == "c <= d;")
    }
}
