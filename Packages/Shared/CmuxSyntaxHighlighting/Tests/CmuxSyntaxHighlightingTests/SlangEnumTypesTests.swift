@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

private let slangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

/// Enum member names for waveform values: slang-server's types (getScope, hovers) and the display rules.
@Suite struct SlangEnumTypesTests {
    static let state = SlangEnumType(name: "fsm.state_t", width: 3, members: [
        .init(name: "IDLE", bits: "000"), .init(name: "FETCH", bits: "001"), .init(name: "DECODE", bits: "100"),
        .init(name: "EXEC", bits: "101"), .init(name: "DONE", bits: "111"),
    ])

    // MARK: Display

    @Test func aMembersValueShowsItsName() {
        #expect(Self.state.display("001") == .member("FETCH"))
        #expect(Self.state.display("001").text == "FETCH")
        #expect(Self.state.display("111").text == "DONE")
    }

    @Test func aValueNoMemberHasShowsTheValueAndAMarker() {
        #expect(Self.state.display("010") == .unknown("3'h2"))
        #expect(Self.state.display("010").text == "3'h2?")
        #expect(Self.state.display("110").text == "3'h6?")
    }

    @Test func xAndZShowAsXAndZ() {
        #expect(Self.state.display("xxx").text == "x")
        #expect(Self.state.display("ZZZ").text == "z")
        #expect(Self.state.display("0x1").text == "3'b0x1")
        #expect(Self.state.display("x").text == "x")
    }

    @Test func shortValuesAreExtendedAsVCDDoesAndLongOnesKeepTheirLowBits() {
        // VCD drops leading zeros (b1 for 3'b001), and extends a leading x or z.
        #expect(Self.state.display("1").text == "FETCH")
        #expect(Self.state.display("100").text == "DECODE")
        #expect(Self.state.display("z").text == "z")
        #expect(Self.state.display("0101").text == "EXEC")
    }

    @Test func theRawValueIsAHexLiteral() {
        #expect(SlangEnumValues.hexLiteral("001") == "3'h1")
        #expect(SlangEnumValues.hexLiteral("1") == "1'h1")
        #expect(SlangEnumValues.hexLiteral("1x0101") == "6'h?5")
        #expect(SlangEnumValues.hexLiteral(String(repeating: "1", count: 68)) == "68'hfffffffffffffffff")
    }

    // MARK: slang's text

    @Test func getScopeTypesNameTheEnumAndItsWidth() {
        #expect(SlangEnumValues.scopeType("Enum state_t (logic[2:0])") == .named(name: "state_t", width: 3))
        #expect(SlangEnumValues.scopeType("Enum op_t (logic[1:0])") == .named(name: "op_t", width: 2))
        #expect(SlangEnumValues.scopeType("Enum flag_t (logic)") == .named(name: "flag_t", width: 1))
        #expect(SlangEnumValues.scopeType("Enum s_t (bit[0:3])") == .named(name: "s_t", width: 4))
        #expect(SlangEnumValues.scopeType("input logic") == nil)
        #expect(SlangEnumValues.scopeType("PackedStruct uop_t (logic[5:0])") == nil)
    }

    @Test func anAnonymousEnumCarriesItsMembers() {
        let type = SlangEnumValues.scopeType("Enum enum{RED=32'sd0,GREEN=32'sd1,BLUE=32'sd2}e$3 (bit[31:0])")
        guard case .anonymous(let anonymous)? = type else {
            Issue.record("not anonymous: \(String(describing: type))")
            return
        }
        #expect(anonymous.width == 32)
        #expect(anonymous.members.map(\.name) == ["RED", "GREEN", "BLUE"])
        #expect(anonymous.members[2].bits == String(repeating: "0", count: 30) + "10")
        #expect(anonymous.name == "enum{RED,GREEN,BLUE}")
    }

    @Test func anArrayOfAnEnumNamesItsElementType() {
        #expect(SlangEnumValues.scopeType("state_t$[0:1]") == .array(elementType: "state_t"))
        #expect(SlangEnumValues.scopeType("cpu_pkg::op_t$[3:0]") == .array(elementType: "cpu_pkg::op_t"))
        #expect(SlangEnumValues.scopeType("logic$[3:0]") == .array(elementType: "logic"))
    }

    @Test func literalsBecomeBitsOfTheEnumsWidth() {
        #expect(SlangEnumValues.literalBits("3'b0", width: 3) == "000")
        #expect(SlangEnumValues.literalBits("3'b100", width: 3) == "100")
        #expect(SlangEnumValues.literalBits("4'b11", width: 4) == "0011")
        #expect(SlangEnumValues.literalBits("32'sd2", width: 32) == String(repeating: "0", count: 30) + "10")
        #expect(SlangEnumValues.literalBits("8'hA5", width: 8) == "10100101")
        #expect(SlangEnumValues.literalBits("'h1f", width: 8) == "00011111")
        #expect(SlangEnumValues.literalBits("3'o7", width: 3) == "111")
        #expect(SlangEnumValues.literalBits("12", width: 4) == "1100")
        #expect(SlangEnumValues.literalBits("4'd9", width: 4) == "1001")
        #expect(SlangEnumValues.literalBits("4'b1_0_1_0", width: 4) == "1010")
        #expect(SlangEnumValues.literalBits("W", width: 4) == nil)
        #expect(SlangEnumValues.literalBits("3'b1x", width: 3) == nil)
    }

    @Test func membersAreReadFromTheTypedefWithTheirOffsets() {
        let text = "typedef enum logic [W-1:0] { IDLE, FETCH, DECODE = 3'd4, EXEC, DONE = 3'b111 } state_t;"
        let members = SlangEnumValues.declaredMembers(in: text)
        #expect(members?.map(\.name) == ["IDLE", "FETCH", "DECODE", "EXEC", "DONE"])
        #expect(members?.map(\.explicitValue) == [nil, nil, "3'd4", nil, "3'b111"])
        let offset = members?[2].offset ?? -1
        #expect((text as NSString).substring(with: NSRange(location: offset, length: 6)) == "DECODE")
    }

    @Test func membersSkipCommentsAndExpandRanges() {
        let text = """
        typedef enum logic [3:0] {
            // comment, with a comma
            A_ST,   /* block, comma */ B_ST = 4'h3,
          C_ST = {2'b1, 2'b0},
            D_ST[2],
            E_ST[5:6] = 4'd9
        } multi_t;
        """
        let members = SlangEnumValues.declaredMembers(in: text)
        #expect(members?.map(\.name) == ["A_ST", "B_ST", "C_ST", "D_ST", "E_ST"])
        #expect(members?[2].explicitValue == "{2'b1, 2'b0}")
        #expect(members?[3].range == SlangEnumValues.MemberRange(first: 0, last: 1))
        #expect(members?[4].range == SlangEnumValues.MemberRange(first: 5, last: 6))
        #expect(members?[4].explicitValue == "4'd9")
        #expect(SlangEnumValues.declaredMembers(in: "typedef struct packed { logic a; } s_t;") == nil)
    }

    @Test func membersOfAnEnumWithoutTypedefAndWithAPackageBase() {
        let members = SlangEnumValues.declaredMembers(in: "enum bit [1:0] {A, B} e;")
        #expect(members?.map(\.name) == ["A", "B"])
        #expect(SlangEnumValues.declaredMembers(in: "typedef enum pkg::base_t {X = pkg::K, Y} t;")?.map(\.name) == ["X", "Y"])
    }

    @Test func aMembersValuesComeFromItsHoverOnePerInstance() {
        let hover = """
        **EnumValue** `IDLE` in `fsm.state_t`  \nValue: `3'b0`  \n\n\n---\n\n````systemverilog\ntypedef enum logic [W-1:0] { IDLE } state_t;\n````\n\n---\n\n**EnumValue** `IDLE` in `fsm.state_t`  \nValue: `4'b0`  \n\n\n---\n\n````systemverilog\ntypedef enum logic [W-1:0] { IDLE } state_t;\n````
        """
        let values = SlangEnumValues.hoverMemberValues(hover)
        #expect(values.map(\.name) == ["IDLE", "IDLE"])
        #expect(values.map(\.literal) == ["3'b0", "4'b0"])
        #expect(values.first?.scope == "fsm.state_t")
    }

    @Test func aTypeLinkIsReadFromADeclarationsHover() {
        let hover = "**Variable** `state` in `fsm`  \nType: [`Enum state_t (logic[2:0])`](<file:///private/tmp/d/fsm.sv#L3,82>)  \nWidth: `3`  \n\n\n---\n\n````systemverilog\nstate_t state, next_state;\n````"
        let link = SlangEnumValues.enumTypeLink(inHover: hover)
        #expect(link?.uri == URL(fileURLWithPath: "/private/tmp/d/fsm.sv"))
        #expect(link?.position == LSPPosition(line: 2, character: 81))
        let alias = "**TypeAlias** `state_t` in `fsm`  \nResolved Type: [`Enum state_t (logic[2:0])`](<file:///f.sv#L3,82>)  \nResolved Width: `3`  \n"
        #expect(SlangEnumValues.enumTypeLink(inHover: alias)?.position == LSPPosition(line: 2, character: 81))
        #expect(SlangEnumValues.enumTypeLink(inHover: "**Variable** `x`  \nType: `logic[3:0]`  \n") == nil)
    }

    @Test func aHoversDeclarationIsItsFirstCodeBlock() {
        let hover = "**TypeAlias** `t`  \n\n---\n\n````systemverilog\ntypedef enum {\n  A\n} t;\n````\n\n---\n\nmore\n````systemverilog\nother\n````"
        #expect(SlangEnumValues.firstCodeBlock(inHover: hover) == "typedef enum {\n  A\n} t;")
    }

    // MARK: Against slang-server

    static let pkg = """
    package cpu_pkg;
      typedef enum logic [1:0] { OP_ADD = 2'd0, OP_SUB = 2'd1, OP_AND = 2'd3 } op_t;
        typedef enum logic [3:0] {
            // comment
            A_ST,   /* block */ B_ST = 4'h3,
          C_ST,
            D_ST[2],
            E_ST[5:6]
        } multi_t;
      localparam logic [2:0] K = 3'd6;
    endpackage

    """

    static let fsm = """
    module fsm #(parameter int W = 3) (input logic clk, input logic rst, input logic go, output logic busy);
      import cpu_pkg::*;
      typedef enum logic [W-1:0] { IDLE, FETCH, DECODE = 3'd4, EXEC, DONE = 3'b111 } state_t;
      typedef enum logic [2:0] { P0 = cpu_pkg::K, P1 } param_t;
      state_t state, next_state;
      op_t op_q;
      cpu_pkg::multi_t mm;
      param_t pp;
      state_t hist [2];
      enum { RED, GREEN, BLUE } color;
      logic [2:0] plain;
      always_ff @(posedge clk) state <= rst ? IDLE : next_state;
      always_comb next_state = state == IDLE && go ? FETCH : state;
      assign busy = state != IDLE;
    endmodule
    module top;
      logic clk, rst, go, busy, busy4;
      fsm u_fsm (.*);
      fsm #(.W(4)) u_fsm4 (.clk, .rst, .go, .busy(busy4));
    endmodule

    """

    static func withServer(_ check: (LanguageServerSession, SlangEnumTypeCache) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-enum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pkg.write(to: root.appendingPathComponent("pkg.sv"), atomically: true, encoding: .utf8)
        try fsm.write(to: root.appendingPathComponent("fsm.sv"), atomically: true, encoding: .utf8)
        let real = LanguageServerSession.realPath(root.path)
        try "--top top\n\(real)/pkg.sv\n\(real)/fsm.sv\n".write(to: root.appendingPathComponent("build.f"), atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: slangServerPath, arguments: []), rootURI: root, languageId: "verilog")
        do {
            try await session.start()
            _ = try await session.executeCommand("slang.setBuildFile", argument: .string(real + "/build.f"), timeout: 60)
            try await check(session, SlangEnumTypeCache())
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func aScopesEnumSignalsComeWithTheirMembers() async throws {
        try await Self.withServer { session, cache in
            let signals = try await session.slangEnumSignals(inScope: "top.u_fsm", cache: cache)
            #expect(Set(signals.keys) == ["state", "next_state", "op_q", "mm", "pp", "hist", "color"])
            #expect(signals["state"]?.type == Self.state)
            #expect(signals["state"]?.isArray == false)
            #expect(signals["next_state"]?.type == Self.state)
            #expect(signals["op_q"]?.type.name == "cpu_pkg::op_t")
            #expect(signals["op_q"]?.type.members.map(\.name) == ["OP_ADD", "OP_SUB", "OP_AND"])
            #expect(signals["op_q"]?.type.members.map(\.bits) == ["00", "01", "11"])
            #expect(signals["hist"]?.isArray == true)
            #expect(signals["hist"]?.type == Self.state)
            #expect(signals["color"]?.type.members.map(\.name) == ["RED", "GREEN", "BLUE"])
            #expect(signals["plain"] == nil)
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func multiLineTypedefsRangesAndParameterValues() async throws {
        try await Self.withServer { session, cache in
            let signals = try await session.slangEnumSignals(inScope: "top.u_fsm", cache: cache)
            let multi = signals["mm"]?.type
            #expect(multi?.name == "cpu_pkg::multi_t")
            #expect(multi?.members.map(\.name) == ["A_ST", "B_ST", "C_ST", "D_ST0", "D_ST1", "E_ST5", "E_ST6"])
            #expect(multi?.members.map(\.bits) == ["0000", "0011", "0100", "0101", "0110", "0111", "1000"])
            // A value from a package parameter: slang's hover says what it is.
            #expect(signals["pp"]?.type.members.map(\.bits) == ["110", "111"])
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func aParameterizedEnumHasEachInstancesWidth() async throws {
        try await Self.withServer { session, cache in
            let narrow = try await session.slangEnumSignals(inScope: "top.u_fsm", cache: cache)
            let wide = try await session.slangEnumSignals(inScope: "top.u_fsm4", cache: cache)
            #expect(narrow["state"]?.type.width == 3)
            #expect(wide["state"]?.type.width == 4)
            #expect(wide["state"]?.type.members.map(\.bits) == ["0000", "0001", "0100", "0101", "0111"])
            #expect(wide["state"]?.type.members.map(\.name) == Self.state.members.map(\.name))
            #expect(try await session.slangEnumSignals(inScope: "top.nope", cache: cache).isEmpty)
        }
    }
}
