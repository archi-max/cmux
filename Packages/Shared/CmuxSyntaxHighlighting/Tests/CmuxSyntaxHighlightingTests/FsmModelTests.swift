import Foundation
import Testing
@testable import CmuxSyntaxHighlighting

private let fsmSlangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

/// The state machine view's engines: Verdi's report, Yosys's $fsm cells, and the naming glue.
@Suite struct FsmModelTests {
    // MARK: Verdi (fsmAnalyzeFSM report)

    @Test func verdiReportGivesStatesTransitionsConditionsAndCounts() throws {
        let model = try #require(VerdiFsmReport.parse(FsmFixtures.verdiCtl))
        #expect(model.engine == .verdi)
        #expect(model.signal == "state")
        #expect(model.width == 3)
        #expect(model.states == [
            .init(bits: "000", name: "IDLE"), .init(bits: "001", name: "FETCH"), .init(bits: "100", name: "DECODE"),
            .init(bits: "101", name: "EXEC"), .init(bits: "111", name: "DONE"),
        ])
        #expect(model.reset == "000")
        #expect(model.resetSignal == "rst")
        #expect(model.controls == ["go", "stall"])
        #expect(Set(model.transitions) == [
            .init(from: "*", to: "000", condition: nil),
            .init(from: "111", to: "000", condition: nil),
            .init(from: "101", to: "001", condition: "go"),
            .init(from: "101", to: "111", condition: "!go"),
            .init(from: "100", to: "101", condition: "!stall"),
            .init(from: "001", to: "100", condition: nil),
            .init(from: "000", to: "001", condition: "go"),
        ])
        let counts = try #require(model.counts)
        #expect(counts.states["100"] == 26)
        #expect(counts.states["000"] == 11)
        #expect(counts.transitions.contains(.init(from: "100", to: "100", count: 15)))
        #expect(counts.transitions.contains(.init(from: "101", to: "001", count: 7)))
        #expect(!counts.transitions.contains { $0.from == "*" })
    }

    @Test func verdiReportOfALocalparamFSMNamesItsStatesFromTheLocalparams() throws {
        let model = try #require(VerdiFsmReport.parse(FsmFixtures.verdiLp))
        #expect(model.signal == "st")
        #expect(model.width == 2)
        #expect(model.states.map(\.name) == ["S_A", "S_B", "S_C"])
        #expect(model.transitions.contains(.init(from: "00", to: "01", condition: "a")))
        #expect(model.transitions.contains(.init(from: "00", to: "00", condition: "!a")))
        #expect(model.transitions.contains(.init(from: "01", to: "10", condition: "b")))
        #expect(model.counts?.states["00"] == 34)
    }

    @Test func notAReportIsNil() {
        #expect(VerdiFsmReport.parse("") == nil)
        #expect(VerdiFsmReport.parse("Finite State Machine (x) Report\nState Signal:\n") == nil)
    }

    @Test func theVerdiScriptsLinesSayWhatHappened() {
        let ok = "noise\ncmux-fsm: kdb /a/simv.daidir\ncmux-fsm: instance tb.u.ctl:FSM0:5:18:FSM\ncmux-fsm: report-begin\n"
            + FsmFixtures.verdiLp + "\ncmux-fsm: report-end\n"
        guard case .report(let text, let instance) = VerdiFsmEngine.outcome(ofOutput: ok) else {
            Issue.record("no report")
            return
        }
        #expect(instance == "tb.u.ctl:FSM0:5:18:FSM")
        #expect(VerdiFsmReport.parse(text)?.signal == "st")
        #expect(VerdiFsmEngine.outcome(ofOutput: "cmux-fsm: unavailable licence\n") == .unavailable(reason: "licence", detail: ""))
        #expect(VerdiFsmEngine.outcome(ofOutput: "cmux-fsm: kdb x\ncmux-fsm: unavailable no-fsm\n") == .unavailable(reason: "no-fsm", detail: ""))
        #expect(VerdiFsmEngine.outcome(ofOutput: "cmux-fsm: unavailable failed verdi Error: x y\n")
            == .unavailable(reason: "failed", detail: "verdi Error: x y"))
        #expect(VerdiFsmEngine.outcome(ofOutput: "bash: line 1: oops\n") == .unavailable(reason: "failed", detail: "bash: line 1: oops"))
        // A report cut off (no end marker) is not used.
        #expect(VerdiFsmEngine.outcome(ofOutput: "cmux-fsm: report-begin\nFinite State Machine (x) Report\n")
            == .unavailable(reason: "failed", detail: "the report was cut off"))
    }

    @Test func theVerdiCommandQuotesItsArgumentsForTheRemoteShell() {
        let command = VerdiFsmEngine.remoteCommand(fsdb: "/home/u/my run/x.fsdb", scope: "tb.dut", signal: "state")
        #expect(command == "bash -l -s -- '/home/u/my run/x.fsdb' 'tb.dut' 'state'")
        #expect(VerdiFsmEngine.remoteCommand(fsdb: "/a/it's.fsdb", scope: "t", signal: "s")
            == "bash -l -s -- '/a/it'\\''s.fsdb' 't' 's'")
    }

    // MARK: Yosys ($fsm cells after fsm_extract)

    @Test func yosysFsmCellGivesCodesAndConditionsWithoutTheReset() throws {
        let models = YosysFsm.models(json: Data(FsmFixtures.yosysLp.utf8))
        let model = try #require(models["st"])
        #expect(model.engine == .yosys)
        #expect(model.width == 2)
        #expect(Set(model.states.map(\.bits)) == ["00", "01", "10"])
        #expect(model.states.allSatisfy { $0.name == nil })
        #expect(model.reset == "00")
        #expect(model.resetSignal == "rst")
        #expect(model.controls == ["a", "b"])
        #expect(Set(model.transitions) == [
            .init(from: "00", to: "00", condition: "!a"),
            .init(from: "00", to: "01", condition: "a"),
            .init(from: "01", to: "00", condition: "!b"),
            .init(from: "01", to: "10", condition: "b"),
            .init(from: "10", to: "00", condition: nil),
        ])
    }

    @Test func yosysEnumFsmMatchesVerdisGraph() throws {
        let model = try #require(YosysFsm.models(json: Data(FsmFixtures.yosysCtl.utf8))["state"])
        let verdi = try #require(VerdiFsmReport.parse(FsmFixtures.verdiCtl))
        // Verdi leaves out self loops and adds Others; otherwise the same edges and conditions.
        let fromYosys = Set(model.transitions.filter { $0.from != $0.to })
        let fromVerdi = Set(verdi.transitions.filter { $0.from != "*" })
        #expect(fromYosys == fromVerdi)
        #expect(model.transitions.contains(.init(from: "000", to: "000", condition: "!go")))
        #expect(model.transitions.contains(.init(from: "100", to: "100", condition: "stall")))
    }

    @Test func aFlattenedDesignKeysItsFsmsByHierarchicalName() {
        let models = YosysFsm.models(json: Data(FsmFixtures.yosysTop.utf8))
        #expect(Set(models.keys) == ["u_ctl.state", "u_lp.st"])
        #expect(models["u_lp.st"]?.signal == "st")
    }

    @Test func notYosysJSONIsEmpty() {
        #expect(YosysFsm.models(json: Data("{}".utf8)).isEmpty)
        #expect(YosysFsm.models(json: Data("not json".utf8)).isEmpty)
    }

    @Test func theYosysScriptElaboratesTheModuleWithTheInstancesParameters() {
        let script = YosysFsm.script(
            files: ["/d/fsm_pkg.sv", "/d/dut.sv"], module: "ctl",
            parameters: [("W", "4"), ("S_A", "2'b0"), ("NAME", "\"x\""), ("T", "logic[1:0]")],
            signal: "state", force: true, slangFrontend: true, output: "/tmp/o.json"
        )
        // read_slang hands its arguments to slang as they are: quotes would be part of the name.
        #expect(script.contains(#"read_slang /d/fsm_pkg.sv /d/dut.sv --top ctl -G W=4 -G S_A=2'b0"#))
        // A path read_slang can't take (a space) goes through read_verilog instead.
        let spaced = YosysFsm.script(files: ["/d/my dut.sv"], module: "ctl", parameters: [], signal: "state", force: false,
                                     slangFrontend: true, output: "/tmp/o.json")
        #expect(spaced.contains(#"read_verilog -sv "/d/my dut.sv""#) && !spaced.contains("read_slang"))
        #expect(!script.contains("NAME"), "only literal values are passed")
        #expect(!script.contains("T=logic"))
        #expect(script.contains("opt -nodffe -nosdff"))
        #expect(script.contains(#"setattr -set fsm_encoding "\"auto\"" w:state"#))
        #expect(script.contains("fsm_detect\nfsm_extract\nwrite_json \"/tmp/o.json\""))
        let native = YosysFsm.script(
            files: ["/d/a.sv"], module: "lp", parameters: [("W", "4")], signal: "st", force: false,
            slangFrontend: false, output: "/tmp/o.json"
        )
        #expect(native.contains(#"read_verilog -sv "/d/a.sv""#))
        #expect(native.contains("hierarchy -top lp -chparam W 4"))
        #expect(!native.contains("setattr"))
    }

    // MARK: Names for codes

    @Test func localparamsOfTheStateWidthNameItsCodes() {
        let params: [FsmNaming.Param] = [
            .init(name: "S_A", type: "logic[1:0]", value: "2'b0"),
            .init(name: "S_B", type: "logic[1:0]", value: "2'b1"),
            .init(name: "S_C", type: "logic[1:0]", value: "2'b10"),
            .init(name: "WIDTH", type: "int", value: "32'sd2"),
            .init(name: "ALSO_B", type: "bit[1:0]", value: "2'd1"),
            .init(name: "X", type: "logic[2:0]", value: "3'b0"),
        ]
        let names = FsmNaming.names(params: params, width: 2)
        // S_B and ALSO_B share a value: that code isn't named, rather than named wrongly.
        #expect(names == ["00": "S_A", "10": "S_C"])
        var model = FsmModel(signal: "st", width: 2, states: [.init(bits: "00", name: nil), .init(bits: "01", name: nil), .init(bits: "10", name: nil)],
                             reset: "00", resetSignal: nil, controls: [], transitions: [], engine: .yosys, counts: nil)
        model = FsmNaming.named(model, names: names)
        #expect(model.states.map(\.name) == ["S_A", nil, "S_C"])
        #expect(model.name(of: "10") == "S_C")
        #expect(model.name(of: "01") == nil)
    }

    @Test func anEnumNamesEveryMemberAndAddsUnseenOnes() {
        let type = SlangEnumType(name: "fsm_pkg::state_t", width: 3, members: [
            .init(name: "IDLE", bits: "000"), .init(name: "FETCH", bits: "001"), .init(name: "SPARE", bits: "010"),
        ])
        let model = FsmModel(signal: "state", width: 3, states: [.init(bits: "001", name: nil), .init(bits: "000", name: nil)],
                             reset: "000", resetSignal: "rst", controls: [], transitions: [], engine: .yosys, counts: nil)
        let named = FsmNaming.named(model, enumType: type)
        #expect(named.states == [.init(bits: "001", name: "FETCH"), .init(bits: "000", name: "IDLE"), .init(bits: "010", name: "SPARE")])
    }

    @Test func theObservedModelHasTheEnumsMembersAndNoEdges() {
        let type = SlangEnumType(name: "t", width: 2, members: [.init(name: "A", bits: "00"), .init(name: "B", bits: "11")])
        let model = FsmModel.observed(signal: "s", enumType: type)
        #expect(model.engine == .observed)
        #expect(model.states == [.init(bits: "00", name: "A"), .init(bits: "11", name: "B")])
        #expect(model.transitions.isEmpty)
        let plain = FsmModel.observed(signal: "st", width: 2, names: ["00": "S_A"])
        #expect(plain.states == [.init(bits: "00", name: "S_A")])
    }

    @Test func aModelRoundTripsThroughJSONForThePage() throws {
        let model = try #require(VerdiFsmReport.parse(FsmFixtures.verdiLp))
        let object = model.pageObject()
        let data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(back?["signal"] as? String == "st")
        #expect(back?["engine"] as? String == "verdi")
        #expect((back?["states"] as? [[String: Any]])?.first?["name"] as? String == "S_A")
        #expect((back?["transitions"] as? [[String: Any]])?.contains { $0["condition"] as? String == "a" } == true)
    }

    // MARK: What the engines need from slang

    static let sources: [(String, String)] = [
        ("fsm_pkg.sv", #"""
package fsm_pkg;
  typedef enum logic [2:0] { IDLE, FETCH, DECODE = 3'd4, EXEC, DONE = 3'b111 } state_t;
endpackage
"""#),
        ("dut.sv", #"""
// Two FSMs: an enum two-process one (ctl) and a localparam one-process one (lp).
module ctl (input logic clk, input logic rst, input logic go, input logic stall, output logic busy);
  import fsm_pkg::*;
  state_t state, next_state;
  always_ff @(posedge clk)
    if (rst) state <= IDLE;
    else state <= next_state;
  always_comb begin
    next_state = state;
    unique case (state)
      IDLE: if (go) next_state = FETCH;
      FETCH: next_state = DECODE;
      DECODE: if (!stall) next_state = EXEC;
      EXEC: if (go) next_state = FETCH; else next_state = DONE;
      DONE: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end
  assign busy = state != IDLE;
endmodule
module lp (input logic clk, input logic rst, input logic a, input logic b, output logic y);
  localparam logic [1:0] S_A = 2'd0, S_B = 2'd1, S_C = 2'd2;
  logic [1:0] st;
  always_ff @(posedge clk)
    if (rst) st <= S_A;
    else case (st)
      S_A: st <= a ? S_B : S_A;
      S_B: st <= b ? S_C : S_A;
      S_C: st <= S_A;
      default: st <= S_A;
    endcase
  assign y = st == S_C;
endmodule
module top (input logic clk, input logic rst, input logic go, input logic stall, input logic a, input logic b,
            output logic busy, output logic y);
  ctl u_ctl (.clk, .rst, .go, .stall, .busy);
  lp u_lp (.clk, .rst, .a, .b, .y);
endmodule
"""#),
        ("tb.sv", #"""
module tb;
  logic clk = 0, rst = 1, go = 0, stall = 0, a = 0, b = 0, busy, y;
  top dut (.*);
  always #5 clk = ~clk;
  int unsigned seed = 7;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("fsm.fsdb"); $fsdbDumpvars(0, tb);
`else
    $dumpfile("fsm.vcd"); $dumpvars(0, tb);
`endif
    #12 rst = 0;
    repeat (60) begin
      @(negedge clk);
      go = ($random(seed) % 3) == 0; stall = ($random(seed) % 2) == 0;
      a = $random(seed) % 2; b = $random(seed) % 2;
    end
    $finish;
  end
endmodule
"""#),
    ]

    static func withServer(_ check: (LanguageServerSession, URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-fsm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in sources { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let real = LanguageServerSession.realPath(root.path)
        try "--top tb\n\(sources.map { "\(real)/\($0.0)" }.joined(separator: "\n"))\n"
            .write(to: root.appendingPathComponent("build.f"), atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: fsmSlangServerPath, arguments: []), rootURI: root, languageId: "verilog")
        do {
            try await session.start()
            _ = try await session.executeCommand("slang.setBuildFile", argument: .string(real + "/build.f"), timeout: 60)
            try await check(session, URL(fileURLWithPath: real))
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: fsmSlangServerPath), "needs slang-server"))
    func slangSaysTheInstancesModuleItsParametersAndTheFilesItNeeds() async throws {
        try await Self.withServer { session, root in
            let lp = try #require(try await session.slangFsmContext(instance: "tb.dut.u_lp", signal: "st"))
            #expect(lp.module == "lp")
            #expect(lp.width == 2)
            #expect(lp.enumType == nil)
            #expect(lp.parameters.map(\.name) == ["S_A", "S_B", "S_C"])
            #expect(FsmNaming.names(params: lp.parameters, width: 2) == ["00": "S_A", "01": "S_B", "10": "S_C"])
            // The module's own file and the packages, not the testbench (Yosys can't elaborate it).
            #expect(lp.files == [root.appendingPathComponent("fsm_pkg.sv").path, root.appendingPathComponent("dut.sv").path])
            let ctl = try #require(try await session.slangFsmContext(instance: "tb.dut.u_ctl", signal: "state"))
            #expect(ctl.module == "ctl")
            #expect(ctl.width == 3)
            #expect(ctl.enumType?.members.map(\.name) == ["IDLE", "FETCH", "DECODE", "EXEC", "DONE"])
            // A module with children brings their files too.
            let top = try #require(try await session.slangFsmContext(instance: "tb.dut", signal: "busy"))
            #expect(top.module == "top")
            #expect(top.files.contains(root.appendingPathComponent("dut.sv").path))
            #expect(!top.files.contains(root.appendingPathComponent("tb.sv").path))
            #expect(try await session.slangFsmContext(instance: "tb.dut.u_ctl", signal: "nope") == nil)
        }
    }

    // MARK: Running Yosys here

    static let localYosys = ["/opt/homebrew/bin/yosys", "/usr/local/bin/yosys"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(.enabled(if: localYosys != nil, "needs yosys"))
    func aLocalYosysRunGivesTheFsm() async throws {
        let yosys = try #require(Self.localYosys)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-fsm-yosys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dut = Self.sources[1].1
        let lpOnly = String(dut[dut.range(of: "module lp ")!.lowerBound..<dut.range(of: "module top ")!.lowerBound])
        let file = dir.appendingPathComponent("lp.sv")
        try lpOnly.write(to: file, atomically: true, encoding: .utf8)
        let frontend = await YosysFsm.hasSlangFrontend(yosys: yosys)
        let result = try await YosysFsm.runLocally(
            yosys: yosys, files: [file.path], module: "lp", parameters: [], signal: "st", force: false, slangFrontend: frontend
        )
        let model = try #require(result["st"])
        #expect(model.transitions.contains(.init(from: "00", to: "01", condition: "a")))
        await #expect(throws: YosysFsm.Failure.self) {
            _ = try await YosysFsm.runLocally(yosys: yosys, files: [file.path], module: "nope", parameters: [], signal: "st", force: false, slangFrontend: frontend)
        }
    }
    // MARK: Running Yosys where the sources are (Resources/vaporview/fsm/cmux-fsm-yosys.sh)

    @Test func theRemoteYosysRunnersLinesSayWhatHappened() {
        let json = FsmFixtures.yosysLp
        guard case .json(let text) = YosysFsm.remoteOutcome(ofOutput: "noise\ncmux-fsm: yosys /x/yosys slang\ncmux-fsm: json-begin\n\(json)\ncmux-fsm: json-end\n") else {
            Issue.record("no json")
            return
        }
        #expect(YosysFsm.models(json: Data(text.utf8))["st"] != nil)
        #expect(YosysFsm.remoteOutcome(ofOutput: "cmux-fsm: unavailable no-yosys\n") == .unavailable(reason: "no-yosys", detail: ""))
        #expect(YosysFsm.remoteOutcome(ofOutput: "cmux-fsm: unavailable failed ERROR: Module `nope' not found!\n")
            == .unavailable(reason: "failed", detail: "ERROR: Module `nope' not found!"))
        #expect(YosysFsm.remoteOutcome(ofOutput: "cmux-fsm: json-begin\n{") == .unavailable(reason: "failed", detail: "the output was cut off"))
        #expect(YosysFsm.remoteOutcome(ofOutput: "") == .unavailable(reason: "failed", detail: ""))
    }

    @Test func theRemoteYosysCommandCarriesBothScriptsEncoded() throws {
        let slang = "read_slang \"/a b.sv\" --top lp\n"
        let native = "read_verilog -sv \"/a b.sv\"\n"
        let command = YosysFsm.remoteCommand(slangScript: slang, nativeScript: native, yosys: "")
        #expect(command.hasPrefix("bash -l -s -- '"))
        let parts = command.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        #expect(parts.count == 3)
        #expect(Data(base64Encoded: parts[0]).map { String(decoding: $0, as: UTF8.self) } == slang)
        #expect(Data(base64Encoded: parts[1]).map { String(decoding: $0, as: UTF8.self) } == native)
        #expect(parts[2] == "")
    }

    static let yosysRunner = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/vaporview/fsm/cmux-fsm-yosys.sh")

    @Test(.enabled(if: localYosys != nil, "needs yosys"))
    func theRemoteYosysRunnerWorksAsAShellScriptHere() async throws {
        let yosys = try #require(Self.localYosys)
        #expect(FileManager.default.fileExists(atPath: Self.yosysRunner.path), "\(Self.yosysRunner.path)")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-fsm-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dut = Self.sources[1].1
        let file = dir.appendingPathComponent("lp.sv")
        try String(dut[dut.range(of: "module lp ")!.lowerBound..<dut.range(of: "module top ")!.lowerBound]).write(to: file, atomically: true, encoding: .utf8)
        let script = { (slang: Bool, module: String) in
            YosysFsm.script(files: [file.path], module: module, parameters: [], signal: "st", force: true, slangFrontend: slang, output: "fsm.json")
        }
        // As over ssh: the runner on stdin, `bash -l -s -- <args>` (here without -l: the user's login files aren't the test's).
        let run = { (module: String, yosysArgument: String) async throws -> YosysFsm.RemoteOutcome in
            let command = YosysFsm.remoteCommand(slangScript: script(true, module), nativeScript: script(false, module), yosys: yosysArgument)
            let result = try await FsmProcess.run("/bin/bash", ["-c", command.replacingOccurrences(of: "bash -l -s", with: "bash -s")],
                                                  input: try Data(contentsOf: Self.yosysRunner), timeout: 120)
            return YosysFsm.remoteOutcome(ofOutput: result.output)
        }
        guard case .json(let text) = try await run("lp", yosys) else {
            Issue.record("no json from the runner")
            return
        }
        #expect(YosysFsm.models(json: Data(text.utf8))["st"]?.transitions.contains(.init(from: "00", to: "01", condition: "a")) == true)
        guard case .unavailable(let reason, let detail) = try await run("nope", yosys) else {
            Issue.record("a missing module gave json")
            return
        }
        #expect(reason == "failed" && detail.contains("nope"), "\(reason) \(detail)")
        #expect(try await run("lp", "/nonexistent/yosys") == .unavailable(reason: "no-yosys", detail: "/nonexistent/yosys"))
    }

    // MARK: The engines in order

    static let lpContext = SlangFsmContext(module: "lp", width: 2, enumType: nil, parameters: [
        .init(name: "S_A", type: "logic[1:0]", value: "2'b0"), .init(name: "S_B", type: "logic[1:0]", value: "2'b1"),
        .init(name: "S_C", type: "logic[1:0]", value: "2'b10"),
    ], files: ["/d/dut.sv"])

    @Test func verdiFirstThenYosysThenTheDump() async throws {
        // Verdi's report wins.
        var result = await FsmPipeline.run(signal: "st", context: Self.lpContext,
                                           verdi: { .report(text: FsmFixtures.verdiLp, instance: "x") },
                                           yosys: { _ in Issue.record("yosys asked after Verdi answered"); return .failure(.notFound) })
        #expect(result.model.engine == .verdi && result.notes.isEmpty)
        // Verdi can't: Yosys, with the localparams' names.
        result = await FsmPipeline.run(signal: "st", context: Self.lpContext,
                                       verdi: { .unavailable(reason: "licence", detail: "") },
                                       yosys: { _ in .success(YosysFsm.models(json: Data(FsmFixtures.yosysLp.utf8))) })
        #expect(result.model.engine == .yosys)
        // (In Yosys's state table order.)
        #expect(Set(result.model.states.map { "\($0.bits)=\($0.name ?? "")" }) == ["00=S_A", "01=S_B", "10=S_C"])
        #expect(result.notes == [.verdi(reason: "licence", detail: "")])
        // A flattened run's FSM is found by its hierarchical name's last part.
        result = await FsmPipeline.run(signal: "st", context: Self.lpContext, verdi: nil,
                                       yosys: { _ in .success(YosysFsm.models(json: Data(FsmFixtures.yosysTop.utf8))) })
        #expect(result.model.engine == .yosys && result.model.signal == "st")
        // Neither: the dump, with the names slang has.
        result = await FsmPipeline.run(signal: "st", context: Self.lpContext,
                                       verdi: { .unavailable(reason: "no-fsm", detail: "") },
                                       yosys: { _ in .failure(.failed("ERROR: x")) })
        #expect(result.model.engine == .observed)
        #expect(result.model.width == 2 && result.model.states.map(\.name) == ["S_A", "S_B", "S_C"])
        #expect(result.notes == [.verdi(reason: "no-fsm", detail: ""), .yosys(.failed("ERROR: x"))])
        // An enum register: its members.
        let type = SlangEnumType(name: "state_t", width: 3, members: [.init(name: "IDLE", bits: "000"), .init(name: "GO", bits: "001")])
        let enumContext = SlangFsmContext(module: "ctl", width: 3, enumType: type, parameters: [], files: [])
        result = await FsmPipeline.run(signal: "state", context: enumContext, verdi: nil, yosys: { _ in .failure(.notFound) })
        #expect(result.model.engine == .observed && result.model.states.map(\.name) == ["IDLE", "GO"])
        // A Yosys model of an enum register is named by the enum, unseen members added.
        result = await FsmPipeline.run(signal: "state", context: enumContext, verdi: nil,
                                       yosys: { _ in .success(["state": FsmModel(signal: "state", width: 3, states: [.init(bits: "001", name: nil)], reset: nil,
                                                                               resetSignal: nil, controls: [], transitions: [], engine: .yosys, counts: nil)]) })
        #expect(result.model.states == [.init(bits: "001", name: "GO"), .init(bits: "000", name: "IDLE")])
        // Yosys's FSM of another register is not this one's.
        result = await FsmPipeline.run(signal: "state", context: enumContext, verdi: nil,
                                       yosys: { _ in .success(YosysFsm.models(json: Data(FsmFixtures.yosysLp.utf8))) })
        #expect(result.model.engine == .observed)
        // No slang: the dump alone, unnamed (the page takes the width from the dump).
        result = await FsmPipeline.run(signal: "q", context: nil, verdi: nil, yosys: nil)
        #expect(result.model.engine == .observed && result.model.states.isEmpty && result.model.width == 0)
    }
}
