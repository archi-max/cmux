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
    /// Has a macro include of its own (not of a fragment): its ports are not the fragment's.
    static let sub = """
    module sub (input logic clk, output logic q);
      always_ff @(posedge clk) q <= ~q;
      `include `SUB_DEFS
    endmodule

    /// A port whose width depends on a parameter: one declaration for every instance's width.
    module psub #(parameter W = 1) (input logic [W-1:0] d);
    endmodule

    """

    /// Included by tb_wrapper through a define, like a TB_FILE testbench body.
    static let fragment = """
        logic frag_sig;
        sub dut (
            .clk (clk),
            .q   (frag_sig)
        );
        `include `DEFS_FILE

    """

    static let wrapper = """
    module tb_wrapper;
        bit clk = 1'b0;
        always #1 clk = ~clk;
        `include `TB_FILE
        logic [3:0] count;
        `include `BODY_FILE
        logic [1:0] spare;
        sub w (.clk (clk), .q (spare[1]));
        logic [3:0] wide;
        sub nw (.clk (wide[0]), .q (wide));
        logic pd1;
        logic [1:0] pd2;
        psub #(.W(2)) p2 (.d (pd2));
        psub p1 (.d (pd1));
        logic gq;
        for (genvar i = 0; i < 1; i++) begin : g
            sub u (.clk (clk), .q (gq));
        end
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
        var defs: URL { root.appendingPathComponent("tb/defs.svh") }
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
        try "// defines\n".write(to: root.appendingPathComponent("tb/defs.svh"), atomically: true, encoding: .utf8)
        // The body's macro names it through a symlinked folder: matched by its real path.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("tblink").path, withDestinationPath: "tb")
        let real = LanguageServerSession.realPath(root.path)
        let build = """
        --top tb_wrapper
        +define+TB_FILE=\\"\(real)/tb/top_tb.sv\\"
        +define+BODY_FILE=\\"\(real)/tblink/body.sv\\"
        +define+DEFS_FILE=\\"\(real)/tb/defs.svh\\"
        +define+SUB_DEFS=\\"\(real)/tb/defs.svh\\"
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

    @Test func includeDirectivesKeepSlashesInQuotesAndSkipBlockComments() {
        let text = "`include \"a//b.sv\" // `include \"no.sv\"\n/* `include \"no2.sv\"\n `include `NO3 */ `include \"yes.sv\"\n/* one line */`include `YES\n"
        #expect(LanguageServerSession.includeDirectives(in: text) == ["a//b.sv", "yes.sv", "`YES"])
    }

    @Test func includeDirectivePositionsAreUTF16LinesAndColumns() {
        // 😀 is two UTF-16 units; a macro's position is inside its name.
        let text = "/* x\n */ `include \"a.sv\"\n  \"😀\" `include `M\n"
        let found = LanguageServerSession.includeDirectiveLocations(in: text)
        #expect(found.map(\.target) == ["a.sv", "`M"])
        #expect(found.map(\.position) == [LSPPosition(line: 1, character: 14), LSPPosition(line: 2, character: 17)])
    }

    @Test func anUnclosedCommentEndsTheScanAndAnUnclosedStringItsLine() {
        #expect(LanguageServerSession.includeDirectives(in: "`include \"a.sv\"\n/* `include \"b.sv\"") == ["a.sv"])
        #expect(LanguageServerSession.includeDirectives(in: "x = \"open\n`include \"c.sv\"") == ["c.sv"])
        #expect(LanguageServerSession.includeDirectives(in: "`include").isEmpty)
        #expect(LanguageServerSession.includeDirectives(in: "`include   ").isEmpty)
        #expect(LanguageServerSession.includeDirectives(in: "`includes \"no.sv\"").isEmpty)
    }

    @Test func includeTargetsMatchTheFullPath() {
        typealias S = LanguageServerSession
        // Next to the includer.
        #expect(S.includeMatch(target: "body.sv", declaringFile: "/w/a/top.sv", file: "/w/a/body.sv", fileExists: { _ in true }) == .exact)
        #expect(S.includeMatch(target: "/w/b/body.sv", declaringFile: "/w/a/top.sv", file: "/w/b/body.sv", fileExists: nil) == .exact)
        // a/body.sv is not b/body.sv.
        #expect(S.includeMatch(target: "body.sv", declaringFile: "/w/a/top.sv", file: "/w/b/body.sv", fileExists: { $0 == "/w/a/body.sv" }) == nil)
        #expect(S.includeMatch(target: "/w/a/body.sv", declaringFile: "/w/a/top.sv", file: "/w/b/body.sv", fileExists: nil) == nil)
        // Found through an include directory (not next to the includer, or can't tell on an SSH host).
        #expect(S.includeMatch(target: "body.sv", declaringFile: "/w/a/top.sv", file: "/w/b/body.sv", fileExists: { _ in false }) == .suffix)
        #expect(S.includeMatch(target: "b/body.sv", declaringFile: "/w/top.sv", file: "/w/x/b/body.sv", fileExists: nil) == .suffix)
        #expect(S.includeMatch(target: "x/body.sv", declaringFile: "/w/a/top.sv", file: "/w/b/body.sv", fileExists: nil) == nil)
    }

    @Test func aMacroExpansionIsReadFromTheHover() {
        let hover = "DefineDirective TB_FILE  \nFrom `ws/build.f`  \n\n\n---\n\nExpands to   \n````systemverilog\n\"/w/tb/top_tb.sv\"\n````"
        #expect(LanguageServerSession.macroIncludeTarget(fromHover: hover) == "/w/tb/top_tb.sv")
        #expect(LanguageServerSession.macroIncludeTarget(fromHover: "Expands to\n```systemverilog\n<x.svh>\n```") == "x.svh")
        #expect(LanguageServerSession.macroIncludeTarget(fromHover: "logic clk") == nil)
    }

    @Test func aFragmentWithItsOwnMacroIncludeIsStillPlaced() async throws {
        try await Self.withFixture { fixture in
            // `.q (frag_sig)`: declared at the top of this fragment, which has a macro include of its own.
            let paths = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 3, character: 16), identifier: "frag_sig")
            #expect(paths == ["tb_wrapper.frag_sig"])
        }
    }

    @Test func aPortNameInAFragmentIsTheChildInstancesPort() async throws {
        try await Self.withFixture { fixture in
            // `.clk` of `.clk (clk)` in the fragment: dut's port, not the includer's clk.
            let port = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 2, character: 10), identifier: "clk")
            #expect(port == ["tb_wrapper.dut.clk"])
            // `.q` of `.q   (frag_sig)`: no signal of that name outside dut.
            let q = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 3, character: 9), identifier: "q")
            #expect(q == ["tb_wrapper.dut.q"])
            // The expression in the parentheses stays the local signal.
            let local = try await fixture.session.slangDesignPaths(uri: fixture.fragment, position: LSPPosition(line: 2, character: 15), identifier: "clk")
            #expect(local == ["tb_wrapper.clk"])
        }
    }

    @Test func aPortNameInAModuleIsTheChildInstancesPort() async throws {
        try await Self.withFixture { fixture in
            // `sub w (.clk (clk), .q (spare[1]));` in tb_wrapper.
            let port = try await fixture.session.slangDesignPaths(uri: fixture.wrapper, position: LSPPosition(line: 7, character: 12), identifier: "clk")
            #expect(port == ["tb_wrapper.w.clk"])
            let local = try await fixture.session.slangDesignPaths(uri: fixture.wrapper, position: LSPPosition(line: 7, character: 18), identifier: "clk")
            #expect(local == ["tb_wrapper.clk"])
        }
    }

    @Test func portConnectionsAreFoundInText() {
        typealias S = LanguageServerSession
        let text = "sub #(.W(2)) u0 (\n  .a (x), // .z (no)\n  .b(y[1]),\n  .c\n);\nfoo(.a(1));\n"
        let units = Array(text.utf16)
        func offset(of needle: String, plus: Int = 1) -> Int {
            units.count - Array(text[text.range(of: needle)!.lowerBound...].utf16).count + plus
        }
        #expect(S.portConnection(in: text, at: offset(of: ".a (x)"))?.port == "a")
        #expect(S.portConnection(in: text, at: offset(of: ".a (x)"))?.instance == "u0")
        #expect(S.portConnection(in: text, at: offset(of: ".b(y[1])"))?.port == "b")
        #expect(S.portConnection(in: text, at: offset(of: ".c\n"))?.port == "c")
        // The expression, a parameter override and a function's named argument are not port names.
        #expect(S.portConnection(in: text, at: offset(of: "(x)", plus: 1)) == nil)
        #expect(S.portConnection(in: text, at: offset(of: ".W(2)")) == nil)
        #expect(S.portConnection(in: text, at: offset(of: ".a(1)")) == nil)
        let connections = S.portConnections(inInstanceText: "u0 (\n  .a (x), // .z (no)\n  .b(y[1]),\n  .c, .*\n)")
        #expect(connections.map(\.port) == ["a", "b", "c"])
        #expect(connections.map(\.signal) == ["x", nil, "c"])
        // A positional connection's member select is not a named port.
        #expect(S.portConnections(inInstanceText: "u (top.sig, s.f, q)").isEmpty)
        #expect(S.portConnections(inInstanceText: "u (.a (s.f), .b)").map(\.port) == ["a", "b"])
    }

    @Test func aTaskCallsNamedArgumentIsNotAPortName() {
        typealias S = LanguageServerSession
        for text in ["initial begin foo(.a(x)); end\n", "always @(posedge clk) if (c) foo(.a(x));\n", "function f; return foo(.a(x)); endfunction\n", "initial #5 foo(.a(x));\n"] {
            let units = Array(text.utf16)
            let offset = units.count - Array(text[text.range(of: ".a(x)")!.lowerBound...].utf16).count + 1
            #expect(S.portConnection(in: text, at: offset) == nil)
        }
        // An instance after a parameter list, and the second instance of one statement, still are.
        let text = "sub #(W) u (.a(x)), v (.b(y));\n"
        let units = Array(text.utf16)
        func offset(of needle: String) -> Int { units.count - Array(text[text.range(of: needle)!.lowerBound...].utf16).count + 1 }
        #expect(S.portConnection(in: text, at: offset(of: ".a(x)"))?.instance == "u")
        #expect(S.portConnection(in: text, at: offset(of: ".b(y)"))?.instance == "v")
    }

    @Test func aMacroIncludeOfAnotherFileIsNotTheIncluder() async throws {
        try await Self.withFixture { fixture in
            // sub `include`s `SUB_DEFS (defs.svh), not the fragment; tb_wrapper includes body.sv through `BODY_FILE.
            let sub = fixture.root.appendingPathComponent("sub.sv")
            #expect(try await fixture.session.includeMatch(of: fixture.fragment, inDeclaringFile: sub) == nil)
            #expect(try await fixture.session.includeMatch(of: fixture.body, inDeclaringFile: fixture.wrapper) == .exact)
        }
    }

    @Test func aNetsPortAliasesArePlainWholeNetConnections() async throws {
        try await Self.withFixture { fixture in
            // Down: the instance ports a signal is connected to.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.frag_sig") == ["tb_wrapper.dut.q"])
            #expect(Set(try await fixture.session.slangPortAliases(of: "tb_wrapper.clk")) == ["tb_wrapper.dut.clk", "tb_wrapper.w.clk"])
            // Up: what the parent connects a port to.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.dut.q") == ["tb_wrapper.frag_sig"])
            // A slice is not the same net.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.w.q").isEmpty)
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.spare").isEmpty)
            // A connection between different widths is not the same net.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.wide").isEmpty)
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.nw.q").isEmpty)
            // A width that depends on a parameter can't be checked from the declaration: skipped.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.pd1").isEmpty)
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.pd2").isEmpty)
            // Inside a generate block the parent's signal is declared further up: not guessed.
            #expect(try await fixture.session.slangPortAliases(of: "tb_wrapper.g[0].u.q").isEmpty)
        }
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
