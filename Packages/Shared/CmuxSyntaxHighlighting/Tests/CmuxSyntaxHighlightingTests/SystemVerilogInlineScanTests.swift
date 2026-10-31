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

    @Test func generateRegionsWithoutTheKeywordAreLocal() {
        let text = """
        module m;
          genvar i;
          for (i = 0; i < 4; i++) begin : g
            logic tmp;
          end
          if (P) begin : g_if
            logic loc;
          end else begin : g_else
            logic other;
          end
          case (W)
            1: begin : g_one
              logic one;
            end
          endcase
          always_ff @(posedge clk) if (rst) q <= 0; else q <= d;
          always_comb begin
            if (a) y = b;
          end
          assign out = tmp;
        endmodule
        """
        let lines = Self.names(text)
        #expect(lines[2].isEmpty && lines[3].isEmpty)
        #expect(lines[6].isEmpty && lines[8].isEmpty)
        #expect(lines[12].isEmpty)
        #expect(lines[15] == ["clk", "rst", "q", "q", "d"])
        #expect(lines[17] == ["a", "y", "b"])
        #expect(lines[19] == ["out", "tmp"])
    }

    @Test func nestedModulesIfdefHeadersMacromodulesAndClasses() {
        let text = """
        module outer;
          module inner;
            logic a;
          endmodule
          logic b;
        endmodule
        `ifdef SYN
        module dual_syn(input clk);
        `else
        module dual(input clk);
        `endif
          assign x = y;
        endmodule
        macromodule mm;
          class c;
            int member;
          endclass
          assign z = w;
        endmodule
        `define BLOCK begin \\
          logic hidden; \\
        end
        module after;
          assign p = q;
        endmodule
        """
        let lines = Self.scan(text)
        #expect(lines[2].module == "inner" && lines[4].module == "outer" && lines[4].identifiers.map(\.name) == ["b"])
        #expect(lines[7].module == "dual_syn" && lines[9].module == "dual" && lines[11].module == "dual")
        #expect(lines[11].identifiers.map(\.name) == ["x", "y"])
        #expect(lines[15].identifiers.isEmpty && lines[17].identifiers.map(\.name) == ["z", "w"] && lines[17].module == "mm")
        #expect(lines[20].identifiers.isEmpty)
        #expect(lines[23].module == "after" && lines[23].identifiers.map(\.name) == ["p", "q"])
    }

    @Test func checkpointsGiveTheSameAnswerAndAreFast() {
        // A large generated module: 60,000 lines, about 4 MB.
        var text = "module big;\n"
        for index in 0..<60_000 {
            text += "  assign sig_\(index) = in_\(index) ^ (other_\(index) & mask_value_long_name); // note \(index)\n"
        }
        text += "endmodule\n"
        let units = SystemVerilogInlineScan.units(of: text as NSString)
        let tail = NSRange(location: units.count - 3000, length: 1500)
        var cache = SystemVerilogInlineScan.Cache(units: units)
        let first = cache.lines(in: tail)
        #expect(first.allSatisfy { $0.module == "big" } && first.contains { !$0.identifiers.isEmpty })
        // An edit near the end keeps the checkpoints before it.
        let clock = ContinuousClock()
        var again: [SystemVerilogInlineScan.Line] = []
        let elapsed = clock.measure {
            cache.replaceUnits(units, editedFrom: units.count - 5000)
            again = cache.lines(in: tail)
        }
        #expect(again == first)
        #expect(again == SystemVerilogInlineScan.lines(in: text, range: tail))
        #expect(elapsed < .milliseconds(50), "rescan after an edit near the end took \(elapsed)")
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
