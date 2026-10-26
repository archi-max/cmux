#if os(macOS)
@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

private let slangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")
private let veriblePath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/verible-verilog-format")
private let hasSlangServer = FileManager.default.isExecutableFile(atPath: slangServerPath)
private let hasVerible = FileManager.default.isExecutableFile(atPath: veriblePath)
private let runSSHTests = ProcessInfo.processInfo.environment["CMUX_LSP_SSH_TEST"] == "1"

private let subSource = """
module sub (
    input  logic [7:0] a,
    output logic [7:0] y
);
  assign y = a;
endmodule

"""

/// Line 6 references an undeclared identifier on purpose.
private let topSource = """
module top (
    input  logic [7:0] din,
    output logic [7:0] dout
);
  logic [7:0] mid;
  sub u_sub (.a(din), .y(mid));
  assign dout = mid + undeclared_sig;
endmodule

"""

/// Writes the two-file fixture workspace. `/tmp` is used deliberately because it is a symlink on macOS.
private func makeWorkspace() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-lsp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try subSource.write(to: root.appendingPathComponent("sub.sv"), atomically: true, encoding: .utf8)
    try topSource.write(to: root.appendingPathComponent("top.sv"), atomically: true, encoding: .utf8)
    return root
}

/// Returns the first diagnostics batch for `uri` that satisfies `predicate`, or nil after `timeout`.
private func waitForDiagnostics(
    _ stream: AsyncStream<(uri: URL, diagnostics: [LSPDiagnostic])>,
    uri: URL,
    timeout: TimeInterval = 20,
    where predicate: @escaping @Sendable ([LSPDiagnostic]) -> Bool
) async -> [LSPDiagnostic]? {
    await withTaskGroup(of: [LSPDiagnostic]?.self) { group in
        group.addTask {
            for await update in stream where update.uri == uri && predicate(update.diagnostics) {
                return update.diagnostics
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func exerciseSession(
    _ session: LanguageServerSession,
    root: URL,
    topText: String,
    checkCompletion: Bool = true
) async throws {
    let top = root.appendingPathComponent("top.sv")
    let sub = root.appendingPathComponent("sub.sv")
    let stream = await session.diagnosticsUpdates()
    try await session.start()
    #expect(await session.isRunning)
    await session.open(uri: top, text: topText, version: 1)

    let diagnostics = await waitForDiagnostics(stream, uri: top) { !$0.isEmpty }
    let undeclared = diagnostics?.first { $0.message.contains("undeclared_sig") }
    #expect(undeclared?.severity == .error)
    #expect(undeclared?.range.start == LSPPosition(line: 6, character: 22))

    // `mid` on line 4.
    let hover = try await session.hover(uri: top, position: LSPPosition(line: 4, character: 15))
    #expect(hover?.contains("mid") == true)

    // `sub` in the instantiation on line 5 resolves to the other file.
    let definition = try await session.definition(uri: top, position: LSPPosition(line: 5, character: 3))
    #expect(definition.first?.uri == sub)
    #expect(definition.first?.range.start == LSPPosition(line: 0, character: 7))

    let references = try await session.references(
        uri: top,
        position: LSPPosition(line: 4, character: 15),
        includeDeclaration: true
    )
    #expect(references.count >= 2)
    #expect(references.allSatisfy { $0.uri == top })

    if checkCompletion {
        let completion = try await session.completion(uri: top, position: LSPPosition(line: 6, character: 16))
        #expect(completion.contains { $0.label == "din" })
    }

    // Fixing the error clears the diagnostics.
    let fixed = topText.replacingOccurrences(of: " + undeclared_sig", with: "")
    await session.change(uri: top, text: fixed, version: 2)
    await session.save(uri: top, text: fixed)
    let cleared = await waitForDiagnostics(stream, uri: top) { diagnostics in
        !diagnostics.contains { $0.message.contains("undeclared_sig") }
    }
    #expect(cleared != nil)
    await session.close(uri: top)
}

@Suite("Language server session (slang-server)", .serialized, .enabled(if: hasSlangServer))
struct LanguageServerSessionIntegrationTests {
    @Test("Diagnostics, hover, definition, references, and completion across files")
    func crossFileFeatures() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let launch = LanguageToolLaunch.local(executablePath: slangServerPath, arguments: [])
        let session = LanguageServerSession(launch: launch, rootURI: root, languageId: "verilog")
        try await exerciseSession(session, root: root, topText: topSource)
        await session.shutdown()
        #expect(await session.isRunning == false)
    }

    @Test("Without a workspace root, definitions in other files are not found")
    func noRootNoCrossFile() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = root.appendingPathComponent("top.sv")
        let launch = LanguageToolLaunch.local(executablePath: slangServerPath, arguments: [])
        let session = LanguageServerSession(launch: launch, rootURI: nil, languageId: "verilog")
        try await session.start()
        await session.open(uri: top, text: topSource, version: 1)
        let definition = try await session.definition(uri: top, position: LSPPosition(line: 5, character: 3))
        #expect(definition.isEmpty)
        await session.shutdown()
    }

    @Test("Pool shares sessions and restarts them, re-opening documents")
    func poolRestart() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = root.appendingPathComponent("top.sv")
        let pool = LanguageServerPool()
        let launch = LanguageToolLaunch.local(executablePath: slangServerPath, arguments: [])
        let first = try await pool.session(launch: launch, rootURI: root, languageId: "verilog")
        let second = try await pool.session(launch: launch, rootURI: root, languageId: "verilog")
        #expect(first === second)

        await first.open(uri: top, text: topSource, version: 1)
        await first.simulateCrashForTesting()
        #expect(await first.isRunning == false)
        await #expect(throws: LanguageServerError.self) {
            _ = try await first.hover(uri: top, position: LSPPosition(line: 4, character: 15))
        }

        let stream = await first.diagnosticsUpdates()
        let restarted = try await pool.session(launch: launch, rootURI: root, languageId: "verilog")
        #expect(restarted === first)
        #expect(await restarted.isRunning)
        let diagnostics = await waitForDiagnostics(stream, uri: top) { diagnostics in
            diagnostics.contains { $0.message.contains("undeclared_sig") }
        }
        #expect(diagnostics != nil)
        await pool.shutdownAll()
        #expect(await first.isRunning == false)
    }
}

@Suite("Language server session failures")
struct LanguageServerSessionFailureTests {
    @Test("A server that exits immediately fails start with its stderr")
    func exitsImmediately() async {
        let launch = LanguageToolLaunch.local(executablePath: "/bin/sh", arguments: ["-c", "echo boom >&2; exit 3"])
        let session = LanguageServerSession(launch: launch, rootURI: nil, languageId: "verilog")
        do {
            try await session.start()
            Issue.record("start() should have thrown")
        } catch let error as LanguageServerError {
            guard case .processExited(let status, let stderr) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            #expect(status == 3)
            #expect(stderr.contains("boom"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(await session.isRunning == false)
    }

    @Test("A server that never answers times out")
    func neverAnswers() async {
        let launch = LanguageToolLaunch.local(executablePath: "/bin/sleep", arguments: ["30"])
        let session = LanguageServerSession(launch: launch, rootURI: nil, languageId: "verilog", initializeTimeout: 0.5)
        let started = Date()
        await #expect(throws: LanguageServerError.timeout(method: "initialize")) {
            try await session.start()
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await session.isRunning == false)
    }

    @Test("A missing executable fails to launch")
    func missingExecutable() async {
        let launch = LanguageToolLaunch.local(executablePath: "/nonexistent/slang-server", arguments: [])
        let session = LanguageServerSession(launch: launch, rootURI: nil, languageId: "verilog")
        await #expect(throws: LanguageServerError.self) {
            try await session.start()
        }
    }

    @Test("A wedged server is killed after repeated timeouts")
    func wedgedServerIsKilled() async throws {
        // Reads the initialize header lines, answers it, then ignores everything.
        let script = #"read -r h; read -r b; printf 'Content-Length: 36\r\n\r\n{"jsonrpc":"2.0","id":1,"result":{}}'; exec sleep 30"#
        let launch = LanguageToolLaunch.local(executablePath: "/bin/sh", arguments: ["-c", script])
        let session = LanguageServerSession(launch: launch, rootURI: nil, languageId: "verilog", requestTimeout: 0.3)
        try await session.start()
        #expect(await session.isRunning)
        let uri = URL(fileURLWithPath: "/tmp/a.sv")
        for _ in 0..<2 {
            await #expect(throws: LanguageServerError.timeout(method: "textDocument/hover")) {
                _ = try await session.hover(uri: uri, position: LSPPosition(line: 0, character: 0))
            }
        }
        for _ in 0..<100 where await session.isRunning {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await session.isRunning == false)
    }

    @Test("Requests before start throw notRunning")
    func requestBeforeStart() async {
        let session = LanguageServerSession(launch: .local(executablePath: "/bin/cat", arguments: []), rootURI: nil, languageId: "verilog")
        await #expect(throws: LanguageServerError.notRunning) {
            _ = try await session.hover(uri: URL(fileURLWithPath: "/tmp/a.sv"), position: LSPPosition(line: 0, character: 0))
        }
    }
}

@Suite("Source formatter", .enabled(if: hasVerible))
struct SourceFormatterIntegrationTests {
    @Test("Formats SystemVerilog through verible-verilog-format")
    func formats() async throws {
        let launch = try #require(LanguageToolRegistry.formatter(forLanguage: "verilog", remoteDestination: nil))
        let ugly = "module m(input logic a,output logic y);assign y=a;endmodule\n"
        let formatted = try await SourceFormatter.format(ugly, using: launch)
        #expect(formatted != ugly)
        #expect(formatted.contains("assign y = a;"))
        #expect(formatted.hasSuffix("endmodule\n"))
    }

    @Test("Syntax errors throw")
    func syntaxError() async throws {
        let launch = try #require(LanguageToolRegistry.formatter(forLanguage: "verilog", remoteDestination: nil))
        await #expect(throws: SourceFormatterError.self) {
            _ = try await SourceFormatter.format("module m(; endmodule garbage ((\n", using: launch)
        }
    }
}

@Suite("Source formatter failures")
struct SourceFormatterFailureTests {
    @Test("Timeout kills the formatter")
    func timeout() async {
        let started = Date()
        await #expect(throws: SourceFormatterError.timedOut) {
            _ = try await SourceFormatter.format("x", using: .local(executablePath: "/bin/sleep", arguments: ["30"]), timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Empty output throws")
    func emptyOutput() async {
        await #expect(throws: SourceFormatterError.emptyOutput) {
            _ = try await SourceFormatter.format("x", using: .local(executablePath: "/usr/bin/true", arguments: []))
        }
    }

    @Test("Passes text through a stdin-to-stdout tool")
    func passthrough() async throws {
        let text = String(repeating: "logic [7:0] a; // é\n", count: 20_000)
        let output = try await SourceFormatter.format(text, using: .local(executablePath: "/bin/cat", arguments: []))
        #expect(output == text)
    }
}

@Suite("Remote language tools over ssh", .serialized, .enabled(if: runSSHTests))
struct RemoteLanguageToolTests {
    private let host = ProcessInfo.processInfo.environment["CMUX_LSP_SSH_HOST"] ?? "ews-01"

    private func ssh(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-T", host, command]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("slang-server over ssh resolves across remote files")
    func remoteSession() async throws {
        let remoteRoot = "/tmp/cmux-lsp-\(UUID().uuidString)"
        let script = """
        mkdir -p \(remoteRoot) && cat > \(remoteRoot)/sub.sv <<'EOF'
        \(subSource)EOF
        cat > \(remoteRoot)/top.sv <<'EOF'
        \(topSource)EOF
        """
        try ssh(script)
        defer { try? ssh("rm -rf \(remoteRoot)") }

        let launch = try #require(LanguageToolRegistry.languageServer(forLanguage: "verilog", remoteDestination: host))
        let root = URL(fileURLWithPath: remoteRoot)
        let session = LanguageServerSession(launch: launch, rootURI: root, languageId: "verilog")
        try await exerciseSession(session, root: root, topText: topSource, checkCompletion: false)

        // The slang-server 0.3.1+ build on ews-01 never answers completion
        // (it hangs inside the handler), so this only checks that the client
        // times out instead of hanging, and passes once the server is fixed.
        let top = root.appendingPathComponent("top.sv")
        await session.open(uri: top, text: topSource, version: 3)
        await withKnownIssue("Remote slang-server hangs on textDocument/completion", isIntermittent: true) {
            let completion = try await session.completion(uri: top, position: LSPPosition(line: 6, character: 16))
            #expect(completion.contains { $0.label == "din" })
        }
        await session.shutdown()
    }

    @Test("verible-verilog-format over ssh")
    func remoteFormat() async throws {
        let launch = try #require(LanguageToolRegistry.formatter(forLanguage: "verilog", remoteDestination: host))
        let formatted = try await SourceFormatter.format("module m;assign y=a;endmodule\n", using: launch, timeout: 20)
        #expect(formatted.contains("assign y = a;"))
    }
}
#endif
