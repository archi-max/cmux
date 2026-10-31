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

    /// cpu's own children in the design.
    static let cpuChildren: [HierarchyNode] = [
        .init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "pc", isScope: false),
        .init(name: "pc_next", isScope: false), .init(name: "rf", isScope: true),
    ]

    static func children(_ path: [String]) async -> [HierarchyNode]? {
        dump[path.joined(separator: ".")]
    }

    static func children(of hierarchy: [String: [HierarchyNode]]) -> HierarchyPrefixInference.Children {
        { path in hierarchy[path.joined(separator: ".")] }
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

    @Test func textKeepsInferredMarksEqualsSignsAndEscapedNames() {
        let mapping = HierarchyPathMapping(rules: [
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut0"),
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut1", isInferred: true),
            .init(designPrefix: "alu", dumpPrefix: "tb.a=b"),
            .init(designPrefix: "core", dumpPrefix: "tb.\\u_core.x "),
        ])
        #expect(HierarchyPathMapping(text: mapping.text) == mapping)
    }

    @Test func rulesDecodeWithoutTheInferredFlag() throws {
        let data = Data(#"{"rules":[{"designPrefix":"cpu","dumpPrefix":"top_tb.dut"}]}"#.utf8)
        let mapping = try JSONDecoder().decode(HierarchyPathMapping.self, from: data)
        #expect(mapping.rules == [.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut")])
    }

    @Test func inferredRulesNeverReplaceUserRules() {
        var mapping = HierarchyPathMapping(rules: [.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut0")])
        mapping.addInferredRule(designPrefix: "cpu", dumpPrefix: "top_tb.dut1")
        mapping.addInferredRule(designPrefix: "cpu", dumpPrefix: "top_tb.dut0")
        #expect(mapping.rules == [
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut0"),
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut1", isInferred: true),
        ])
        // Both instances are candidates, the user's first.
        #expect(mapping.dumpPaths(forDesignPath: "cpu.pc") == ["top_tb.dut0.pc", "top_tb.dut1.pc"])
        #expect(mapping.dumpPath(forDesignPath: "cpu.pc") == "top_tb.dut0.pc")
        #expect(mapping.designPath(forDumpPath: "top_tb.dut1.pc") == "cpu.pc")
    }

    @Test func inferredRulesPerPrefixAreCapped() {
        var mapping = HierarchyPathMapping(rules: [.init(designPrefix: "cpu", dumpPrefix: "tb.user")])
        for index in 0..<(HierarchyPathMapping.maxInferredRulesPerPrefix + 3) {
            mapping.addInferredRule(designPrefix: "cpu", dumpPrefix: "tb.u\(index)")
        }
        #expect(mapping.rules.filter(\.isInferred).count == HierarchyPathMapping.maxInferredRulesPerPrefix)
        #expect(mapping.rules.first == .init(designPrefix: "cpu", dumpPrefix: "tb.user"))
        #expect(mapping.rules.last?.dumpPrefix == "tb.u\(HierarchyPathMapping.maxInferredRulesPerPrefix + 2)")
    }

    @Test func infersDumpScopeFromTheInstanceTree() async {
        // `pc` exists under both top_tb.mon and top_tb.dut; dut's children match cpu's.
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.pc",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children
        )
        #expect(result == .found([.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)]))
        let nested = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.rf.last",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children
        )
        #expect(nested == .found([.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)]))
    }

    @Test func aDumpNameWithItsRangeMatchesTheSignal() async {
        // FSDB names a 1-bit vector declared [N-1:0] with its range: `pc[0:0]`, `rst[0:0]`.
        var hierarchy = Self.dump
        hierarchy["top_tb.dut"] = [
            .init(name: "clk", isScope: false), .init(name: "rst[0:0]", isScope: false, width: 1), .init(name: "pc[0:0]", isScope: false, width: 1),
            .init(name: "pc_next", isScope: false), .init(name: "rf", isScope: true),
        ]
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.pc",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .found([.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)]))
        #expect(await HierarchyPrefixInference.exists(["top_tb", "dut", "pc"], dumpChildren: Self.children(of: hierarchy)))
        // A scope's index is part of its name: gen[0] is not gen.
        hierarchy["top_tb.dut"]!.append(.init(name: "gen[0]", isScope: true))
        #expect(await !HierarchyPrefixInference.exists(["top_tb", "dut", "gen"], dumpChildren: Self.children(of: hierarchy)))
        #expect(HierarchyPrefixInference.signalName(.init(name: "dfp_wdone[0:0]", isScope: false, width: 1)) == "dfp_wdone")
        // Only a range as wide as the signal is its declared range: an index or a part-select is
        // another signal (an array element, a bit), and without a width nothing can be told.
        #expect(HierarchyPrefixInference.signalName(.init(name: "data[3]", isScope: false, width: 1)) == "data[3]")
        #expect(HierarchyPrefixInference.signalName(.init(name: "x[3:0]", isScope: false, width: 4)) == "x")
        #expect(HierarchyPrefixInference.signalName(.init(name: "x[7:4]", isScope: false, width: 4)) == "x")
        #expect(HierarchyPrefixInference.signalName(.init(name: "x[3:0]", isScope: false, width: 1)) == "x[3:0]")
        #expect(HierarchyPrefixInference.signalName(.init(name: "x[0:0]", isScope: false)) == "x[0:0]")
        #expect(HierarchyPrefixInference.signalName(.init(name: "x[a:0]", isScope: false)) == "x[a:0]")
        #expect(HierarchyPrefixInference.signalName(.init(name: "gen[0]", isScope: true)) == "gen[0]")
    }

    @Test func onlyRangeNamedSignalsCanPlaceTheRoot() async {
        // A root of clk, rst and pc: the dut shares them only through their ranges, the testbench
        // shares clk and rst exactly but has no pc.
        let root: [HierarchyNode] = [.init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "pc", isScope: false)]
        let hierarchy: [String: [HierarchyNode]] = [
            "": [.init(name: "top_tb", isScope: true)],
            "top_tb": [.init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "dut", isScope: true)],
            "top_tb.dut": [.init(name: "clk", isScope: false), .init(name: "rst[0:0]", isScope: false, width: 1), .init(name: "pc[0:0]", isScope: false, width: 1)],
        ]
        let result = await HierarchyPrefixInference.dumpRules(forDesignPath: "cpu.pc", designRootChildren: root, dumpChildren: Self.children(of: hierarchy))
        #expect(result == .found([.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)]))
    }

    @Test func anArrayElementIsNotTheArray() async {
        // iverilog dumps mem[3] (an element), not mem: mem is not dumped.
        var hierarchy = Self.dump
        hierarchy["top_tb.dut"]!.append(.init(name: "mem[3]", isScope: false, width: 8))
        #expect(await !HierarchyPrefixInference.exists(["top_tb", "dut", "mem"], dumpChildren: Self.children(of: hierarchy)))
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.mem",
            designRootChildren: Self.cpuChildren + [.init(name: "mem", isScope: false)],
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .notDumped(.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)))
    }

    @Test func aDesignPathWithASelectStillMatchesExactly() async {
        // An element the dump lists by its index (`mem[3]`), asked for as such.
        var hierarchy = Self.dump
        hierarchy["top_tb.dut"]!.append(.init(name: "mem[3]", isScope: false))
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.mem[3]",
            designRootChildren: Self.cpuChildren + [.init(name: "mem", isScope: false)],
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .found([.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)]))
    }

    @Test func aRangeNamedDumpSignalFindsItsDesignRoot() async {
        var hierarchy = Self.dump
        hierarchy["top_tb.dut"] = [
            .init(name: "clk", isScope: false), .init(name: "rst", isScope: false), .init(name: "pc[0:0]", isScope: false, width: 1),
            .init(name: "pc_next", isScope: false), .init(name: "rf", isScope: true),
        ]
        let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: "top_tb.dut.pc[0:0]",
            designRoots: ["cpu": Self.cpuChildren],
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(rule == .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true))
    }

    @Test func aSignalTheDutDidNotDumpIsNotTakenFromAMonitor() async {
        // dut lost `pc` (optimised away); the monitor has a `pc` but shares only clk and pc with cpu.
        var hierarchy = Self.dump
        hierarchy["top_tb.dut"] = hierarchy["top_tb.dut"]!.filter { $0.name != "pc" }
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.pc",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .notDumped(.init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true)))
    }

    @Test func aWeakOverlapIsNoMatch() async {
        // Only the monitor holds `pc`, and two shared names of five are not enough.
        var hierarchy = Self.dump
        hierarchy["top_tb"] = hierarchy["top_tb"]!.filter { $0.name != "dut" }
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.pc",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .notFound)
    }

    @Test func aTestbenchSharingClockAndResetDoesNotHideASmallDut() async {
        // fifo_top has four children, so top_tb's clk and rst_n alone meet the threshold;
        // top_tb lacks req, and the real match is one level down.
        let hierarchy: [String: [HierarchyNode]] = [
            "": [.init(name: "top_tb", isScope: true)],
            "top_tb": [.init(name: "clk", isScope: false), .init(name: "rst_n", isScope: false), .init(name: "dut", isScope: true)],
            "top_tb.dut": [.init(name: "clk", isScope: false), .init(name: "rst_n", isScope: false), .init(name: "req", isScope: false),
                           .init(name: "u_fifo", isScope: true)],
            "top_tb.dut.u_fifo": [.init(name: "clk", isScope: false), .init(name: "count", isScope: false)],
        ]
        let rootChildren: [HierarchyNode] = [
            .init(name: "clk", isScope: false), .init(name: "rst_n", isScope: false), .init(name: "req", isScope: false),
            .init(name: "u_fifo", isScope: true),
        ]
        let rule = HierarchyPathMapping.Rule(designPrefix: "fifo_top", dumpPrefix: "top_tb.dut", isInferred: true)
        for path in ["fifo_top.req", "fifo_top.u_fifo.count"] {
            let result = await HierarchyPrefixInference.dumpRules(
                forDesignPath: path,
                designRootChildren: rootChildren,
                dumpChildren: Self.children(of: hierarchy)
            )
            #expect(result == .found([rule]))
        }
    }

    @Test func noMatchWithoutTheDesignRootsChildren() async {
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.clk",
            designRootChildren: [],
            dumpChildren: Self.children
        )
        #expect(result == .notFound)
    }

    @Test func twoEqualInstancesAreBothReturned() async {
        var hierarchy = Self.dump
        hierarchy["top_tb"] = [.init(name: "clk", isScope: false), .init(name: "dut0", isScope: true), .init(name: "dut1", isScope: true)]
        hierarchy["top_tb.dut0"] = Self.dump["top_tb.dut"]
        hierarchy["top_tb.dut1"] = Self.dump["top_tb.dut"]
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "cpu.pc",
            designRootChildren: Self.cpuChildren,
            dumpChildren: Self.children(of: hierarchy)
        )
        #expect(result == .found([
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut0", isInferred: true),
            .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut1", isInferred: true),
        ]))
    }

    @Test func noDumpRuleWhenThePathIsNowhere() async {
        let result = await HierarchyPrefixInference.dumpRules(
            forDesignPath: "lsu.missing",
            designRootChildren: [.init(name: "dcache", isScope: true), .init(name: "missing", isScope: false)],
            dumpChildren: Self.children
        )
        #expect(result == .notFound)
    }

    @Test func infersDesignRootForADumpPath() async {
        let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: "top_tb.dut.rf.data",
            designRoots: ["cpu": Self.cpuChildren],
            dumpChildren: Self.children
        )
        #expect(rule == .init(designPrefix: "cpu", dumpPrefix: "top_tb.dut", isInferred: true))
        // The monitor's two shared names are too few to call it a cpu.
        let monitor = await HierarchyPrefixInference.designRule(
            forDumpPath: "top_tb.mon.pc",
            designRoots: ["cpu": Self.cpuChildren],
            dumpChildren: Self.children
        )
        #expect(monitor == nil)
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
        #expect(target("    count += 1;", "count"))
        #expect(target("    acc <<= 2;", "acc"))
        #expect(target("    i++;", "i"))
        #expect(target("    {carry, sum} = a + b;", "carry"))
        #expect(target("    {carry, sum} = a + b;", "sum"))
        #expect(!target("  assign y = {a, b};", "a"))
        #expect(!target("    x = a + b;", "a"))
        #expect(!target("    if (a >= b) x = 1;", "a"))
    }
}
