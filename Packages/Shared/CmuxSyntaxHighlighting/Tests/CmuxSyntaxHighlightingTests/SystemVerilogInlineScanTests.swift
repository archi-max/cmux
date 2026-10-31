import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct SystemVerilogInlineScanTests {
    static func names(_ text: String, lines range: ClosedRange<Int>? = nil) -> [[String]] {
        scan(text, lines: range).map { $0.identifiers.map(\.name) }
    }

    static func scan(_ text: String, lines range: ClosedRange<Int>? = nil) -> [SystemVerilogInlineScan.Line] {
        let all = text.components(separatedBy: "\n")
        let range = range ?? 0...(all.count - 1)
        let start = all[..<range.lowerBound].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let length = all[range].reduce(0) { $0 + ($1 as NSString).length + 1 } - 1
        return SystemVerilogInlineScan.lines(in: text, range: NSRange(location: start, length: max(0, length)))
    }

    @Test func skipsCommentsStringsKeywordsAndMembers() {
        let text = """
        module cpu(input logic clk);
          assign pc_next = pc + 4'h4; // next pc
          initial $display("pc %h", pc);
          assign y = bus.data | `WIDTH;
        endmodule
        """
        #expect(Self.names(text) == [["clk"], ["pc_next", "pc"], ["pc"], ["y", "bus"], []])
    }

    @Test func aBlockCommentOpenedAboveTheLinesIsKnown() {
        let text = """
        module m;
        /* first
           assign hidden = 1;
        */
          assign shown = a;
        endmodule
        """
        #expect(Self.names(text, lines: 2...4) == [[], [], ["shown", "a"]])
    }

    @Test func linesKnowTheirModule() {
        let text = """
        module fifo(input clk);
          logic full;
        endmodule
        module fifo_ctrl;
          logic full;
        endmodule
        """
        let lines = Self.scan(text)
        #expect(lines.map(\.module) == ["fifo", "fifo", "fifo", "fifo_ctrl", "fifo_ctrl", "fifo_ctrl"])
        #expect(lines[1].identifiers == [.init(name: "full", offset: (text as NSString).range(of: "full").location)])
    }

    @Test func functionTaskAndGenerateLocalsAreLeftOut() {
        let text = """
        module m;
          function automatic logic f(logic x);
            return x;
          endfunction
          import "DPI-C" function void dpi(int a);
          for (genvar i = 0; i < 4; i++) begin : g_lane
            logic x;
            if (i > 0) begin
              assign x = y;
            end
          end
          generate
            assign z = w;
          endgenerate
          assign out = x;
        endmodule
        """
        let lines = Self.names(text)
        #expect(lines[1].isEmpty && lines[2].isEmpty)
        #expect(lines[4] == [])
        #expect(lines[6].isEmpty && lines[8].isEmpty)
        #expect(lines[12].isEmpty)
        #expect(lines[14] == ["out", "x"])
    }

    @Test func outsideModulesThereAreNoIdentifiers() {
        let text = """
        package p;
          localparam int W = 8;
        endpackage
        """
        #expect(Self.names(text) == [[], [], []])
    }

    @Test func escapedIdentifiersAndBasedNumbersAreSkipped() {
        let text = """
        module m;
          assign \\a.b  = 8'hff + 1_000 + c;
        endmodule
        """
        #expect(Self.names(text, lines: 1...1) == [["c"]])
    }

    @Test func historyStepsBackAndForward() {
        var history = BackForwardHistory<Int>(limit: 3)
        for entry in [1, 2, 2, 3, 4] {
            history.record(entry, isSame: ==)
        }
        #expect(history.back == [2, 3, 4])
        #expect(history.step(.back, current: 5, isUsable: { _ in true }) == 4)
        #expect(history.forward == [5])
        #expect(history.step(.forward, current: 4, isUsable: { _ in true }) == 5)
        #expect(history.back == [2, 3, 4])
        // Entries nothing can open are dropped on the way.
        #expect(history.step(.back, current: 5, isUsable: { $0 != 4 && $0 != 3 }) == 2)
        #expect(history.back.isEmpty && history.forward == [5])
        #expect(history.step(.back, current: 2, isUsable: { _ in true }) == nil)
        // A new jump drops what Go Forward could redo.
        history.record(7, isSame: ==)
        #expect(history.forward.isEmpty && history.back == [7])
    }
}
