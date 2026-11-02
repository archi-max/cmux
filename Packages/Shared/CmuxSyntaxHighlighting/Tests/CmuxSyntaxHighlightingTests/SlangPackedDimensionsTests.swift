import Foundation
import Testing
@testable import CmuxSyntaxHighlighting

private let slangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

/// Packed dimensions of a signal, from slang-server's getScope type (the waveform viewer's
/// Split > By Declared Dimensions).
struct SlangPackedDimensionsTests {
    private func dims(_ text: String) -> [[Int]]? {
        SlangPackedDimensions.parse(text)?.map { [$0.left, $0.right] }
    }

    @Test func multiDimensionalVectorsGiveEveryDimension() {
        #expect(dims("logic[1:0][31:0]") == [[1, 0], [31, 0]])
        #expect(dims("output logic[1:0][31:0]") == [[1, 0], [31, 0]])
        #expect(dims("input logic[3:0][7:0]") == [[3, 0], [7, 0]])
        #expect(dims("logic[1:0][2:0][3:0]") == [[1, 0], [2, 0], [3, 0]])
        #expect(dims("logic[0:1][15:0]") == [[0, 1], [15, 0]])
        #expect(dims("bit[2:1][3:0]") == [[2, 1], [3, 0]])
        #expect(dims("reg[1:0][3:0]") == [[1, 0], [3, 0]])
        #expect(dims("logic signed[1:0][7:0]") == [[1, 0], [7, 0]])
        #expect(SlangPackedDimensions.parse("logic[1:0][2:0][3:0]")?.map(\.count) == [2, 3, 4])
    }

    @Test func otherTypesHaveNone() {
        // One dimension: nothing to split by.
        #expect(dims("logic[7:0]") == nil)
        #expect(dims("logic") == nil)
        #expect(dims("input logic") == nil)
        // An element type slang doesn't spell out (a struct, an enum): its width isn't in the text.
        #expect(dims("pair_t[1:0]") == nil)
        #expect(dims("Enum state_t (logic[2:0])") == nil)
        #expect(dims("PackedStruct uop_t (logic[5:0])") == nil)
        // An unpacked array: the dump has its elements as separate signals.
        #expect(dims("logic[1:0][7:0]$[0:3]") == nil)
        #expect(dims("int") == nil)
        #expect(dims("logic[N-1:0][7:0]") == nil)
        #expect(dims("logic[1:0][7:0] extra") == nil)
        #expect(dims("") == nil)
    }

    @Test func aWidthIsTheProductOfItsDimensions() {
        #expect(SlangPackedDimensions.width(SlangPackedDimensions.parse("logic[1:0][2:0][3:0]") ?? []) == 24)
        #expect(SlangPackedDimensions.width(SlangPackedDimensions.parse("logic[0:1][15:0]") ?? []) == 32)
    }

    static let design = """
    typedef logic [7:0] byte_t;
    typedef struct packed { logic [3:0] a; logic [3:0] b; } pair_t;
    module dut #(parameter int NUM_PORTS = 2) (input logic clk, output logic [NUM_PORTS-1:0][31:0] dfp_addr);
      logic [1:0][2:0][3:0] cube;
      logic [0:1][15:0] up;
      byte_t [3:0] tb4;
      pair_t [1:0] pairs;
      logic [7:0] flat;
      logic [1:0][7:0] mem [4];
      wire [1:0][7:0] w2;
    endmodule
    module top; logic clk; logic [1:0][31:0] dfp_addr; dut u (.clk, .dfp_addr); endmodule

    """

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func aScopesPackedSignalsComeWithTheirDimensions() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-packed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.design.write(to: root.appendingPathComponent("d.sv"), atomically: true, encoding: .utf8)
        let real = LanguageServerSession.realPath(root.path)
        try "--top top\n\(real)/d.sv\n".write(to: root.appendingPathComponent("build.f"), atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: slangServerPath, arguments: []), rootURI: root, languageId: "verilog")
        do {
            try await session.start()
            _ = try await session.executeCommand("slang.setBuildFile", argument: .string(real + "/build.f"), timeout: 60)
            let signals = try await session.slangPackedSignals(inScope: "top.u")
            // Parameters resolved, typedef'd vectors spelled out; structs, 1-D and unpacked left out.
            #expect(Set(signals.keys) == ["dfp_addr", "cube", "up", "tb4", "w2"])
            #expect(signals["dfp_addr"]?.map { [$0.left, $0.right] } == [[1, 0], [31, 0]])
            #expect(signals["cube"]?.map { [$0.left, $0.right] } == [[1, 0], [2, 0], [3, 0]])
            #expect(signals["up"]?.map { [$0.left, $0.right] } == [[0, 1], [15, 0]])
            #expect(signals["tb4"]?.map { [$0.left, $0.right] } == [[3, 0], [7, 0]])
            let top = try await session.slangPackedSignals(inScope: "top")
            #expect(top["dfp_addr"]?.map { [$0.left, $0.right] } == [[1, 0], [31, 0]])
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }
}
