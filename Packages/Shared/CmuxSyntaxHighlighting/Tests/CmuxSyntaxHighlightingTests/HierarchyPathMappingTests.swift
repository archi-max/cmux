import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct HierarchyPathMappingTests {
    /// top_tb (testbench) instantiates cpu as dut; cpu has rf (regfile) and pc.
    static let dump: [String: [HierarchyNode]] = [
        "": [.init(name: "top_tb", isScope: true)],
        "top_tb": [.init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "dut", isScope: true),
                   .init(name: "mon", isScope: true)],
        "top_tb.mon": [.init(name: "clk", isScope: false), .init(name: "pc", isScope: false)],
        "top_tb.dut": [.init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "pc", isScope: false),
                       .init(name: "pc_next", isScope: false), .init(name: "rf", isScope: true)],
        "top_tb.dut.rf": [.init(name: "clk", isScope: false), .init(name: "data", isScope: false), .init(name: "last", isScope: false)],
    ]

    static func children(_ path: [String]) async -> [HierarchyNode]? {
        dump[path.joined(separator: ".")]
    }

    @Test func identityWithoutRules() {
        let mapping = HierarchyPathMapping()
        #expect(mapping.dumpPath(forDesignPath: "top_tb.dut.pc") == "top_tb.dut.pc")
        #expect(mapping.designPath(forDumpPath: "top_tb.dut.pc") == "top_tb.dut.pc")
    }

    @Test func longestSegmentAlignedRuleWins() {
        let mapping = HierarchyPathMapping(rules: [
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut"),
            .init(designPrefix: "cpu.rf", dumpPrefix: "top_tb.dut.regs"),
        ])
        #expect(mapping.dumpPath(forDesignPath: "cpu.pc") == "top_tb.dut.pc")
        #expect(mapping.dumpPath(forDesignPath: "cpu.rf.data") == "top_tb.dut.regs.data")
        // `cpux` only shares characters with `cpu`, not a segment.
        #expect(mapping.dumpPath(forDesignPath: "cpux.pc") == "cpux.pc")
        #expect(mapping.designPath(forDumpPath: "top_tb.dut.regs.last") == "cpu.rf.last")
        #expect(mapping.designPath(forDumpPath: "top_tb.dut.pc") == "cpu.pc")
        #expect(mapping.designPath(forDumpPath: "top_tb.clk") == "top_tb.clk")
    }

    @Test func emptyDesignPrefixPrependsAWrapper() {
        let mapping = HierarchyPathMapping(rules: [.init(designPrefix: "", dumpPrefix: "TOP")])
        #expect(mapping.dumpPath(forDesignPath: "top_tb.dut.pc") == "TOP.top_tb.dut.pc")
        #expect(mapping.designPath(forDumpPath: "TOP.top_tb.dut.pc") == "top_tb.dut.pc")
    }

    @Test func segmentsKeepSelectsAndEscapedNames() {
        #expect(HierarchyPathMapping.segments("top.gen[0].u.x") == ["top", "gen[0]", "u", "x"])
        #expect(HierarchyPathMapping.segments("top.m[a.b].x") == ["top", "m[a.b]", "x"])
        #expect(HierarchyPathMapping.segments("top.\\a.b .x") == ["top", "\\a.b ", "x"])
        #expect(HierarchyPathMapping.segments("") == [])
    }

    @Test func textRoundTrips() {
        let mapping = HierarchyPathMapping(rules: [.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut")])
        #expect(HierarchyPathMapping(text: mapping.text) == mapping)
        #expect(HierarchyPathMapping(text: "# comment\n\n cpu = top_tb.dut \n") == mapping)
        #expect(HierarchyPathMapping(text: "cpu top_tb.dut") == nil)
    }

    @Test func infersDumpScopeFromTheInstanceTree() async {
        // `pc` exists under both top_tb.mon and top_tb.dut; dut's children match cpu's.
        let rule = await HierarchyPrefixInference.dumpRule(
            forDesignPath: "cpu.pc",
            designRootChildren: ["clk", "rst", "pc", "pc_next", "rf"],
            dumpChildren: Self.children
        )
        #expect(rule == .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut"))
        let nested = await HierarchyPrefixInference.dumpRule(
            forDesignPath: "cpu.rf.last",
            designRootChildren: ["clk", "rst", "pc", "pc_next", "rf"],
            dumpChildren: Self.children
        )
        #expect(nested == .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut"))
    }

    @Test func noDumpRuleWhenThePathIsNowhere() async {
        let rule = await HierarchyPrefixInference.dumpRule(
            forDesignPath: "cpu.missing",
            designRootChildren: ["pc"],
            dumpChildren: Self.children
        )
        #expect(rule == nil)
    }

    @Test func infersDesignRootForADumpPath() async {
        let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: "top_tb.dut.rf.data",
            designRoots: ["cpu": ["clk", "rst", "pc", "pc_next", "rf"]],
            dumpChildren: Self.children
        )
        #expect(rule == .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut"))
    }

    @Test func assignmentTargets() {
        func target(_ line: String, _ name: String) -> Bool {
            let column = (line as NSString).range(of: name).location
            return SystemVerilogAssignmentScanner.isAssignmentTarget(line: line, column: column, length: name.utf16.count)
        }
        #expect(target("  assign pc_next = pc + 4;", "pc_next"))
        #expect(target("    if (rst) pc <= '0;", "pc"))
        #expect(target("    else pc <= pc_next;", "pc"))
        #expect(target("    data[waddr] <= wdata;", "data"))
        #expect(target("    s.valid = 1'b1;", "s"))
        #expect(target("    IDLE: state_next = FETCH;", "state_next"))
        #expect(target("  always_comb x = y;", "x"))
        #expect(!target("  assign pc_next = pc + 4;", "pc"))
        #expect(!target("    if (pc == 4) begin", "pc"))
        #expect(!target("    foo(pc <= 3);", "pc"))
        #expect(!target("  logic [31:0] pc;", "pc"))
        #expect(!target("    x <= (a <= b);", "a"))
        #expect(!target("  .clk(clk),", "clk"))
    }
}
