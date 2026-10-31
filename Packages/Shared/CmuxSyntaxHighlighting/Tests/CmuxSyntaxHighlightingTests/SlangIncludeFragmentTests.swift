#if os(macOS)
@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

private let slangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

/// The RTL link on a file that a module pulls in with `` `include `` (a
/// testbench body with no module of its own): slang-server's getInstances
/// returns [] there, so the link must place the symbol another way. In a
/// module file it must not: a module that is not under the top is not in
/// the design, whatever its ports connect to.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server at ~/.local/bin/slang-server"))
struct SlangIncludeFragmentTests {
    static let sub = """
    module sub (input logic clk, output logic q);
      always_ff @(posedge clk) q <= ~q;
    endmodule

    """

    /// Included by tb_wrapper through a define, like a TB_FILE testbench body.
    static let fragment = """
        logic frag_sig;
        sub dut (
            .clk (clk),
            .q   (frag_sig)
        );

    """

    static let wrapper = """
    module tb_wrapper;
        bit clk = 1'b0;
        always #1 clk = ~clk;
        `include `TB_FILE
        logic [3:0] count;
        `include `BODY_FILE
    endmodule

    """

    /// A fragment that declares nothing: it only drives the includer's signals.
    static let body = """
        always @(posedge clk) count <= count + 4'd1;

    """

    /// Compiled with the design but instantiated nowhere under the top.
    static let unused = """
    module unused;
        logic x, y;
        sub u (.clk (x), .q (y));
    endmodule

    """

    struct Fixture {
        let session: LanguageServerSession
        let root: URL
        var fragment: URL { root.appendingPathComponent("tb/top_tb.sv") }
        var wrapper: URL { root.appendingPathComponent("tb_wrapper.sv") }
        var unused: URL { root.appendingPathComponent("unused.sv") }
        var body: URL { root.appendingPathComponent("tb/body.sv") }
    }

    /// Runs `check` on a workspace with the fixture and a build file for it, then stops the server
    /// and removes the folder, also when `check` throws.
    static func withFixture(_ check: (Fixture) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-frag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tb"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try sub.write(to: root.appendingPathComponent("sub.sv"), atomically: true, encoding: .utf8)
        try wrapper.write(to: root.appendingPathComponent("tb_wrapper.sv"), atomically: true, encoding: .utf8)
        try unused.write(to: root.appendingPathComponent("unused.sv"), atomically: true, encoding: .utf8)
        try fragment.write(to: root.appendingPathComponent("tb/top_tb.sv"), atomically: true, encoding: .utf8)
        try body.write(to: root.appendingPathComponent("tb/body.sv"), atomically: true, encoding: .utf8)
        let real = LanguageServerSession.realPath(root.path)
        let build = """
        --top tb_wrapper
        +define+TB_FILE=\\"\(real)/tb/top_tb.sv\\"
        +define+BODY_FILE=\\"\(real)/tb/body.sv\\"
        \(real)/sub.sv
        \(real)/tb_wrapper.sv
        \(real)/unused.sv

        """
        try build.write(to: root.appendingPathComponent("build.f"), atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: slangServerPath, arguments: []), rootURI: root, languageId: "verilog")
        let fixture = Fixture(session: session, root: root)
        do {
            try await session.start()
            _ = try await session.executeCommand("slang.setBuildFile", argument: .string(real + "/build.f"), timeout: 60)
            await session.open(uri: fixture.fragment, text: fragment, version: 1)
            await session.open(uri: fixture.unused, text: unused, version: 1)
            await session.open(uri: fixture.wrapper, text: wrapper, version: 1)
            await session.open(uri: fixture.body, text: body, version: 1)
            try await check(fixture)
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    @Test func aSignalTheIncluderDeclaresIsPlaced() async throws {
        try await Self.withFixture { fixture in
            // `.clk (clk)`: the second clk, declared in tb_wrapper.
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 2, character: 15), identifier: "clk")
            #expect(paths == ["tb_wrapper.clk"])
        }
    }

    @Test func aSignalTheFragmentDeclaresIsPlaced() async throws {
        try await Self.withFixture { fixture in
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 0, character: 12), identifier: "frag_sig")
            #expect(paths == ["tb_wrapper.frag_sig"])
        }
    }

    @Test func anInstanceTheFragmentDeclaresIsPlaced() async throws {
        try await Self.withFixture { fixture in
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 1, character: 9), identifier: "dut")
            #expect(paths == ["tb_wrapper.dut"])
        }
    }

    @Test func aFragmentThatDeclaresNothingIsPlacedThroughItsIncluder() async throws {
        try await Self.withFixture { fixture in
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.body, position: LSPPosition(line: 0, character: 26), identifier: "count")
            #expect(paths == ["tb_wrapper.count"])
        }
    }

    @Test func includeDirectivesAreRead() {
        let text = "`include \"a/b.svh\"\n  `include <c.sv> // `include \"commented.sv\"\n`include `TB_FILE\n// `include \"no.sv\"\n"
        #expect(LanguageServerSession.includeDirectives(in: text) == ["a/b.svh", "c.sv", "`TB_FILE"])
    }

    @Test func aModuleFileStillUsesGetInstances() async throws {
        try await Self.withFixture { fixture in
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.wrapper, position: LSPPosition(line: 1, character: 9), identifier: "clk")
            #expect(paths == ["tb_wrapper.clk"])
        }
    }

    @Test func aModuleNotUnderTheTopIsNotPlacedThroughItsPorts() async throws {
        try await Self.withFixture { fixture in
            // `.clk` and `sub` in `sub u (.clk (x), ...)` of the uninstantiated module: their
            // declarations (sub's port, sub itself) are in the design, but this use is not.
            let port = try await fixture.session.slangDesignPaths(uri: fixture.unused, position: LSPPosition(line: 2, character: 12), identifier: "clk")
            #expect(port.isEmpty)
            let type = try await fixture.session.slangDesignPaths(uri: fixture.unused, position: LSPPosition(line: 2, character: 5), identifier: "sub")
            #expect(type.isEmpty)
            let local = try await fixture.session.slangDesignPaths(uri: fixture.unused, position: LSPPosition(line: 1, character: 10), identifier: "x")
            #expect(local.isEmpty)
        }
    }

    @Test func aStoppedServerIsAnErrorNotAnEmptyAnswer() async throws {
        try await Self.withFixture { fixture in
            await fixture.session.shutdown()
            await #expect(throws: LanguageServerError.self) {
                _ = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 0, character: 12), identifier: "frag_sig")
            }
        }
    }
}
#endif
