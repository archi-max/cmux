import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct WaveformCycleHighlightsTests {
    static let cpu = """
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

    static func lines(_ text: String) -> [SystemVerilogInlineScan.Line] {
        SystemVerilogInlineScan.lines(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func lineNumbers(_ ranges: [NSRange], in text: String) -> [Int] {
        let all = lines(text)
        return ranges.compactMap { range in all.firstIndex { $0.contentRange == range } }
    }

    @Test func changedNamesNeedAnEarlierValue() {
        let changed = WaveformCycleHighlights.changedNames(
            now: ["pc": "0004", "stall": "0", "rd": "1f", "fresh": "1"],
            before: ["pc": "0000", "stall": "0", "rd": "1f"]
        )
        #expect(changed == ["pc"])
    }

    @Test func driverLinesAreTheAssignmentsOfChangedSignals() {
        let text = Self.cpu
        let result = WaveformCycleHighlights.highlights(
            lines: Self.lines(text), text: text as NSString, changed: ["cpu": ["pc", "dmem_pending"]]
        )
        // `if (rst) pc <= '0;` (6), `pc <= pc_next;` (8) and the assign (4); not the declarations.
        #expect(Self.lineNumbers(result.driverLines, in: text) == [4, 6, 8])
        #expect(result.assigned == ["cpu": ["pc", "dmem_pending"]])
        let words = result.changedIdentifiers.map { (text as NSString).substring(with: $0) }
        #expect(words == ["pc", "dmem_pending", "dmem_pending", "pc", "pc"])
    }

    @Test func aReadIsNotADriver() {
        let text = Self.cpu
        let result = WaveformCycleHighlights.highlights(
            lines: Self.lines(text), text: text as NSString, changed: ["cpu": ["pc_next", "ex_mem"]]
        )
        #expect(result.driverLines.isEmpty)
        #expect(result.changedIdentifiers.count == 5)
    }

    @Test func otherModulesNamesAreNotTheirs() {
        let text = "module a;\n  assign x = 1;\nendmodule\nmodule b;\n  assign x = 2;\nendmodule\n"
        let result = WaveformCycleHighlights.highlights(lines: Self.lines(text), text: text as NSString, changed: ["b": ["x"]])
        #expect(Self.lineNumbers(result.driverLines, in: text) == [4])
    }

    @Test func childInstancesFromTheDriverCone() {
        let cone = [
            SlangConeEntry(path: "tb.dut.ex_stg.ex_mem", location: nil),
            SlangConeEntry(path: "tb.dut.ex_stg.ex_mem", location: nil),
            SlangConeEntry(path: "tb.dut.alu_out", location: nil),
            SlangConeEntry(path: "tb.dut.mem.ctrl.state", location: nil),
            SlangConeEntry(path: "tb.other.x.y", location: nil),
        ]
        #expect(WaveformCycleHighlights.drivingChildInstances(cone: cone, designInstance: "tb.dut") == ["ex_stg"])
    }

    @Test func connectionLinesStopAtTheStatementEnd() {
        let text = Self.cpu
        let all = Self.lines(text)
        let start = all.firstIndex { (text as NSString).substring(with: $0.contentRange).contains("ex_stage ex_stg") }!
        let lines = WaveformCycleHighlights.connectionLines(of: "ex_mem", instantiationAt: start, lines: all, text: text as NSString)
        #expect(Self.lineNumbers(lines, in: text) == [12])
        #expect(WaveformCycleHighlights.connectionLines(of: "pc", instantiationAt: start, lines: all, text: text as NSString).isEmpty)
    }
}
