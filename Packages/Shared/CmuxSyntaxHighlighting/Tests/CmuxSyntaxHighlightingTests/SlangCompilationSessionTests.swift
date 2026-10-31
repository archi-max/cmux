#if os(macOS)
@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

/// What a session compiles (slang.setTopLevel / slang.setBuildFile) against
/// the real slang-server: replay after a relaunch, the advertised commands,
/// the server's error messages and the diagnostics summary.
@Suite struct SlangCompilationSessionTests {
    static let slangServer = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

    /// A workspace with `leaf` instantiated twice by `top`, a file with no module, and
    /// a build file for `top`. Nil without slang-server.
    static func session(idleShutdownDelay: TimeInterval? = 60) async throws -> (session: LanguageServerSession, root: String)? {
        guard FileManager.default.isExecutableFile(atPath: slangServer) else { return nil }
        let rootURL = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-slangtop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = LanguageServerSession.realPath(rootURL.path)
        let design = """
        module leaf(input logic a, output logic b);
          assign b = a;
        endmodule
        module top;
          logic x, y;
          leaf u0(.a(x), .b(y));
          leaf u1(.a(y), .b(x));
          assign x = undeclared_sig;
        endmodule

        """
        try design.write(toFile: root + "/top.sv", atomically: true, encoding: .utf8)
        try "logic stray;\n".write(toFile: root + "/nomodule.sv", atomically: true, encoding: .utf8)
        try "--top top\n\(root)/top.sv\n".write(toFile: root + "/build.f", atomically: true, encoding: .utf8)
        let session = LanguageServerSession(launch: .local(executablePath: slangServer, arguments: []), rootURI: rootURL, languageId: "verilog", idleShutdownDelay: idleShutdownDelay)
        try await session.start()
        return (session, root)
    }

    static func tops(_ session: LanguageServerSession) async throws -> [String] {
        try await session.slangScopeChildren("").map(\.name)
    }

    @Test func aBuildFileIsSentAgainAfterARelaunch() async throws {
        guard let (session, root) = try await Self.session() else { return }
        #expect(try await Self.tops(session).isEmpty)
        try await session.slangSetBuildFile(root + "/build.f")
        #expect(try await Self.tops(session) == ["top"])
        #expect(try await session.slangInstanceCount() == 3)
        #expect(await session.slangCompilationTarget == .buildFile(root + "/build.f"))
        try await session.restart()
        #expect(try await Self.tops(session) == ["top"])
        try await session.restart(keepingCompilation: false)
        #expect(try await Self.tops(session).isEmpty)
        #expect(await session.slangCompilationTarget == nil)
        await session.shutdown()
    }

    @Test func aServerWithNoDocumentsStopsAndACommandRelaunchesIt() async throws {
        guard let (session, root) = try await Self.session(idleShutdownDelay: 0.5) else { return }
        let uri = URL(fileURLWithPath: root + "/top.sv")
        await session.open(uri: uri, text: try String(contentsOf: uri, encoding: .utf8), version: 1)
        try await session.slangSetBuildFile(root + "/build.f")
        try await Task.sleep(for: .milliseconds(900))
        #expect(await session.isRunning) // a document is open
        await session.close(uri: uri)
        for _ in 0..<40 where await session.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await !session.isRunning)
        // The build file chosen before comes back with the relaunch.
        #expect(try await Self.tops(session) == ["top"])
        #expect(await session.isRunning)
        await session.shutdown()
    }

    @Test func exploreModeOutlivesARestartButNotAConfigReload() async throws {
        guard let (session, root) = try await Self.session() else { return }
        try FileManager.default.createDirectory(atPath: root + "/.slang/local", withIntermediateDirectories: true)
        try "{\"build\": \"\(root)/build.f\"}\n".write(toFile: root + "/.slang/local/server.json", atomically: true, encoding: .utf8)
        try await session.restart(keepingCompilation: false)
        #expect(try await Self.tops(session) == ["top"])
        try await session.slangExplore()
        #expect(try await Self.tops(session).isEmpty)
        #expect(await session.slangCompilationTarget == nil)
        try await session.restart()
        #expect(try await Self.tops(session).isEmpty)
        try await session.restart(keepingCompilation: false)
        #expect(try await Self.tops(session) == ["top"])
        await session.shutdown()
    }

    @Test func aFailedSwitchOutOfExploreModeRestoresExploreMode() async throws {
        guard let (session, root) = try await Self.session() else { return }
        try FileManager.default.createDirectory(atPath: root + "/.slang/local", withIntermediateDirectories: true)
        try "{\"build\": \"\(root)/build.f\"}\n".write(toFile: root + "/.slang/local/server.json", atomically: true, encoding: .utf8)
        try await session.restart(keepingCompilation: false)
        try await session.slangExplore()
        let before = await session.slangCompilationState
        #expect(before.isExplore)
        // A switch whose design elaborates nothing, put back to what came before.
        try await session.slangSetTopLevel(root + "/nomodule.sv")
        try await session.slangRestore(before)
        #expect(await session.isInChosenExploreMode)
        try await session.restart()
        #expect(try await Self.tops(session).isEmpty) // not the config's build
        // A top level comes back as itself.
        try await session.slangSetTopLevel(root + "/top.sv")
        let top = await session.slangCompilationState
        try await session.slangExplore()
        try await session.slangRestore(top)
        #expect(await session.slangCompilationTarget == .topLevel(root + "/top.sv"))
        #expect(try await Self.tops(session) == ["top"])
        await session.shutdown()
    }

    @Test func theEmptyPathReturnsToExploreMode() async throws {
        guard let (session, root) = try await Self.session() else { return }
        try await session.slangSetTopLevel(root + "/top.sv")
        #expect(await session.slangCompilationTarget == .topLevel(root + "/top.sv"))
        #expect(try await Self.tops(session) == ["top"])
        try await session.slangSetTopLevel("")
        #expect(await session.slangCompilationTarget == nil)
        #expect(try await Self.tops(session).isEmpty)
        await session.shutdown()
    }

    @Test func advertisedCommandsAndServerErrors() async throws {
        guard let (session, root) = try await Self.session() else { return }
        #expect(await session.supportsCommand("slang.setBuildFile") == true)
        #expect(await session.supportsCommand("slang.noSuchCommand") == false)
        _ = await session.takeRecentErrorMessages()
        try await session.slangSetTopLevel(root + "/nomodule.sv")
        try await Task.sleep(for: .milliseconds(300))
        let messages = await session.takeRecentErrorMessages()
        #expect(messages.contains { $0.contains("No top modules") })
        #expect(await session.takeRecentErrorMessages().isEmpty)
        await session.shutdown()
    }

    @Test func theSummaryCountsTheCompilationsErrors() async throws {
        guard let (session, root) = try await Self.session() else { return }
        try await session.slangSetBuildFile(root + "/build.f")
        try await Task.sleep(for: .milliseconds(400))
        let summary = await session.diagnosticsSummary()
        #expect(summary.errorCount >= 1)
        #expect(summary.firstErrors.contains { $0.hasPrefix("top.sv:8:") && $0.contains("undeclared_sig") })
        await session.shutdown()
    }
}
#endif
