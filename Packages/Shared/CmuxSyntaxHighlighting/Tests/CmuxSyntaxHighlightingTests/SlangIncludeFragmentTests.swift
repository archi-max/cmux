#if os(macOS)
@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

/// The RTL link on a file that a module pulls in with `` `include `` (a
/// testbench body with no module of its own): slang-server's getInstances
/// returns [] there, so the link must place the symbol another way.
@Suite struct SlangIncludeFragmentTests {
    static let slangServer = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

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
    endmodule

    """

    /// A workspace with the fragment fixture and a build file for it; nil without slang-server.
    static func session() async throws -> (LanguageServerSession, URL)? {
        guard FileManager.default.isExecutableFile(atPath: slangServer) else { return nil }
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-frag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tb"), withIntermediateDirectories: true)
        try sub.write(to: root.appendingPathComponent("sub.sv"), atomically: true, encoding: .utf8)
        try wrapper.write(to: root.appendingPathComponent("tb_wrapper.sv"), atomically: true, encoding: .utf8)
        let fragmentURL = root.appendingPathComponent("tb/top_tb.sv")
        try fragment.write(to: fragmentURL, atomically: true, encoding: .utf8)
        let real = LanguageServerSession.realPath(root.path)
        let build = """
        --top tb_wrapper
        +define+TB_FILE=\\"\(real)/tb/top_tb.sv\\"
        \(real)/sub.sv
        \(real)/tb_wrapper.sv

        """
        try build.write(to: root.appendingPathComponent("build.f"), atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: slangServer, arguments: []), rootURI: root, languageId: "verilog")
        try await session.start()
        _ = try await session.executeCommand("slang.setBuildFile", argument: .string(real + "/build.f"), timeout: 60)
        await session.open(uri: fragmentURL, text: fragment, version: 1)
        return (session, fragmentURL)
    }

    @Test func aSignalTheIncluderDeclaresIsPlaced() async throws {
        guard let (session, fragmentURL) = try await Self.session() else { return }
        // `.clk (clk)`: the second clk, declared in tb_wrapper.
        let paths = try await session.slangDesignPaths(uri: fragmentURL, position: LSPPosition(line: 2, character: 15), identifier: "clk")
        await session.shutdown()
        #expect(paths == ["tb_wrapper.clk"])
    }

    @Test func aSignalTheFragmentDeclaresIsPlaced() async throws {
        guard let (session, fragmentURL) = try await Self.session() else { return }
        let paths = try await session.slangDesignPaths(uri: fragmentURL, position: LSPPosition(line: 0, character: 12), identifier: "frag_sig")
        await session.shutdown()
        #expect(paths == ["tb_wrapper.frag_sig"])
    }

    @Test func anInstanceTheFragmentDeclaresIsPlaced() async throws {
        guard let (session, fragmentURL) = try await Self.session() else { return }
        let paths = try await session.slangDesignPaths(uri: fragmentURL, position: LSPPosition(line: 1, character: 9), identifier: "dut")
        await session.shutdown()
        #expect(paths == ["tb_wrapper.dut"])
    }

    @Test func aModuleFileStillUsesGetInstances() async throws {
        guard let (session, fragmentURL) = try await Self.session() else { return }
        let wrapperURL = fragmentURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tb_wrapper.sv")
        let paths = try await session.slangDesignPaths(uri: wrapperURL, position: LSPPosition(line: 1, character: 9), identifier: "clk")
        await session.shutdown()
        #expect(paths == ["tb_wrapper.clk"])
    }
}
#endif
