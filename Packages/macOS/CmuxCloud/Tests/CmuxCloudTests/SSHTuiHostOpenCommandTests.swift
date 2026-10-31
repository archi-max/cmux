import CmuxCloud
import CmuxCore
import Foundation
import Testing

/// `cmux open` in a cmux-tui SSH terminal. Those terminals have no
/// cmuxd-remote relay and no `cmux` on PATH, so the app installs a small
/// host `cmux` from the terminal's launch command. It resolves the path on the
/// host and posts it as a marked `notification.create` on the session's own
/// daemon socket; the Mac turns that row into a file preview.
///
/// The script tests run the real script under real shells against a fake
/// cmux-tui that records its argv.
@Suite("cmux open in cmux-tui SSH terminals")
struct SSHTuiHostOpenCommandTests {
    static let terminalID = "term_0123456789abcdef0123456789abcdef"
    static let notificationID = "notification_0123456789abcdef0123456789abcdef"
    static let shells = ["/bin/sh", "/bin/bash"]

    // MARK: Launch command

    @Test("The default shell installs the host cmux and puts it first on PATH")
    func defaultShellInstallsCLI() throws {
        let sandbox = try Sandbox()
        let connection = connection()
        let argv = connection.shellCommand
        #expect(argv.first == "/bin/sh")
        #expect(argv.last?.hasSuffix("exec \"${SHELL:-/bin/sh}\" -l") == true)
        let result = try sandbox.run(argv, environment: sandbox.loginEnvironment)
        #expect(result.status == 0, "\(result.stderr)")
        let expected = sandbox.home + "/" + connection.hostOpenCommand.installDirectory
            .replacingOccurrences(of: "$HOME/", with: "") + "/cmux"
        #expect(result.stdout.contains("cmux=\(expected)"), "\(result.stdout)")
        #expect(result.stdout.contains("args=-l"), "\(result.stdout)")
        let installed = try String(contentsOfFile: expected, encoding: .utf8)
        #expect(installed == connection.hostOpenCommand.script)
        #expect(FileManager.default.isExecutableFile(atPath: expected))

        // A second terminal reuses the install.
        let again = try sandbox.run(argv, environment: sandbox.loginEnvironment)
        #expect(again.stdout.contains("cmux=\(expected)"))
    }

    @Test("A configured remote command gets the same CLI")
    func configuredCommandInstallsCLI() throws {
        let sandbox = try Sandbox()
        let argv = connection().commandArguments("echo hi")
        #expect(Array(argv.suffix(2)) == ["cmux-ssh", "echo hi"])
        let result = try sandbox.run(argv, environment: sandbox.loginEnvironment)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("/cmux-svedit/"), "\(result.stdout)")
        #expect(result.stdout.contains("args=-lc echo hi"), "\(result.stdout)")
    }

    @Test("A home that cannot be written still starts the shell")
    func unwritableHomeStillStartsShell() throws {
        let sandbox = try Sandbox()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sandbox.home)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sandbox.home) }
        let result = try sandbox.run(connection().shellCommand, environment: sandbox.loginEnvironment)
        #expect(result.status == 0)
        #expect(result.stdout.contains("args=-l"))
        #expect(result.stdout.contains("cmux=\n") || result.stdout.contains("cmux=missing"), "\(result.stdout)")
    }

    @Test("The release and a tagged build keep separate CLIs, both outside ~/.cmux/bin")
    func installPathsAreIsolated() {
        let release = connection(bundleIdentifier: "com.cmuxterm.app").hostOpenCommand
        let tagged = connection().hostOpenCommand
        #expect(release.installDirectory.hasPrefix("$HOME/.local/share/cmux/ssh-cli/cmux/"))
        #expect(tagged.installDirectory.hasPrefix("$HOME/.local/share/cmux/ssh-cli/cmux-svedit/"))
        #expect(!tagged.installDirectory.contains(".cmux/bin"))
        #expect(tagged.script.contains("$HOME/.local/bin/cmux-tui-svedit"))
        #expect(release.script.contains("$HOME/.local/bin/cmux-tui\""))
    }

    // MARK: Host script

    @Test("cmux open resolves the path on the host and posts one marked row for this terminal", arguments: shells)
    func openPostsMarkedRow(shell: String) throws {
        let sandbox = try Sandbox()
        let file = try sandbox.makeFile("src/top.sv")
        let result = try sandbox.open(["src/top.sv:12"], shell: shell, cwd: sandbox.work)
        #expect(result.status == 0, "\(result.stderr)")
        let argv = try sandbox.createArgv()
        #expect(argv.starts(with: ["--json", "notification", "create"]))
        #expect(sandbox.value(after: "--title", in: argv) == SSHTuiHostOpenCommand.notificationTitle)
        #expect(sandbox.value(after: "--subtitle", in: argv) == "top.sv")
        #expect(sandbox.value(after: "--terminal", in: argv) == Self.terminalID)
        let body = try #require(sandbox.value(after: "--body", in: argv))
        #expect(request(body: body) == .open(path: file, terminalID: Self.terminalID))
    }

    @Test("A name that itself ends in :N opens as written; :line:column is dropped", arguments: shells)
    func lineSuffixes(shell: String) throws {
        let sandbox = try Sandbox()
        let literal = try sandbox.makeFile("log:3")
        #expect(try sandbox.open(["log:3"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try #require(sandbox.value(after: "--body", in: sandbox.createArgv())))
                == .open(path: literal, terminalID: Self.terminalID))
        let plain = try sandbox.makeFile("a b.v")
        #expect(try sandbox.open(["a b.v:4:9"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try #require(sandbox.value(after: "--body", in: sandbox.createArgv())))
                == .open(path: plain, terminalID: Self.terminalID))
    }

    @Test("A symlink opens its target, the canonical host path", arguments: shells)
    func symlinkResolves(shell: String) throws {
        let sandbox = try Sandbox()
        let target = try sandbox.makeFile("real/wave.vcd")
        try FileManager.default.createSymbolicLink(atPath: sandbox.work + "/link.vcd", withDestinationPath: target)
        #expect(try sandbox.open(["link.vcd"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try #require(sandbox.value(after: "--body", in: sandbox.createArgv())))
                == .open(path: target, terminalID: Self.terminalID))
    }

    @Test("Refusals post nothing", arguments: shells)
    func refusals(shell: String) throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(atPath: sandbox.work + "/dir", withIntermediateDirectories: true)
        let big = try sandbox.makeFile("big.bin")
        try sandbox.truncate(big, to: 32 * 1024 * 1024 + 1)
        let cases: [([String], String, Int32)] = [
            (["dir"], "is a directory", 1),
            (["missing.sv"], "no such file", 1),
            (["https://example.com/a"], "is not a file path", 1),
            (["big.bin"], "larger than 32 MB", 1),
            ([], "Usage: cmux open", 2),
            (["a", "b"], "Usage: cmux open", 2),
            (["-x"], "Usage: cmux open", 2),
        ]
        for (arguments, message, status) in cases {
            let result = try sandbox.open(arguments, shell: shell, cwd: sandbox.work)
            #expect(result.status == status, "\(arguments)")
            #expect(result.stderr.contains(message), "\(arguments): \(result.stderr)")
            #expect(!sandbox.posted, "\(arguments)")
        }
        let long = String(repeating: "d", count: 200)
        let deep = try sandbox.makeFile("\(long)/\(long)/\(long)/\(long)/f")
        #expect(deep.utf8.count > SSHTuiHostOpenCommand.maximumPathBytes)
        let tooLong = try sandbox.open([deep], shell: shell, cwd: sandbox.work)
        #expect(tooLong.status == 1)
        #expect(tooLong.stderr.contains("too long"), "\(tooLong.stderr)")
        #expect(!sandbox.posted)
    }

    @Test("An FSDB dump has no size cap: the app reads it in place", arguments: shells)
    func fsdbHasNoCap(shell: String) throws {
        let sandbox = try Sandbox()
        let dump = try sandbox.makeFile("sim/run.FSDB")
        try sandbox.truncate(dump, to: 40 * 1024 * 1024)
        #expect(try sandbox.open(["sim/run.FSDB"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(sandbox.posted)
    }

    @Test("Outside a cmux-tui terminal, or for another verb, nothing is posted")
    func needsDaemonTerminal() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment.removeValue(forKey: "CMUX_TUI_TERMINAL_ID")
        let outside = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(outside.status == 1)
        #expect(outside.stderr.contains("CMUX_TUI_TERMINAL_ID"))
        let other = try sandbox.run(["/bin/sh", sandbox.scriptPath, "notify", "--title", "x"], environment: sandbox.openEnvironment)
        #expect(other.status == 2)
        #expect(other.stderr.contains("only cmux open"))
        #expect(!sandbox.posted)
    }

    @Test("No Mac taking the row within the wait is an error")
    func unacknowledgedIsAnError() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = ""
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(result.status == 1)
        #expect(result.stderr.contains("no cmux window took"), "\(result.stderr)")
        #expect(sandbox.posted)
    }

    // MARK: Mac-side decoding

    @Test("Only a fresh, terminal-scoped, well-formed row with an acceptable path opens")
    func requestDecoding() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
        let body = SSHTuiHostOpenCommand.bodyPrefix + Data("/home/u/top.sv".utf8).base64EncodedString()
        func decide(title: String = SSHTuiHostOpenCommand.notificationTitle, body: String = body,
                    terminal: String? = Self.terminalID, createdAtMs: UInt64 = nowMs,
                    accept: @escaping (String) -> Bool = { $0.hasPrefix("/") }) -> SSHTuiHostOpenRequest {
            SSHTuiHostOpenRequest(title: title, body: body, terminalID: terminal, createdAtMs: createdAtMs,
                                  now: now, pathIsAcceptable: accept)
        }
        #expect(decide() == .open(path: "/home/u/top.sv", terminalID: Self.terminalID))
        #expect(decide(title: "Build done", body: "ok") == .notARequest)
        #expect(decide(title: "Build done", body: "cmux open me") == .notARequest)
        let refusals: [SSHTuiHostOpenRequest] = [
            decide(terminal: nil),
            decide(terminal: "term_bad"),
            decide(createdAtMs: nowMs - 61_000),
            decide(createdAtMs: nowMs + 61_000),
            decide(body: SSHTuiHostOpenCommand.bodyPrefix + "!!!"),
            decide(body: SSHTuiHostOpenCommand.bodyPrefix + Data([0xFF, 0xFE]).base64EncodedString()),
            decide(body: String(body.dropLast(4)) + "\u{2026}"),
            decide(accept: { _ in false }),
            decide(body: SSHTuiHostOpenCommand.bodyPrefix
                   + Data(("/" + String(repeating: "a", count: 800)).utf8).base64EncodedString()),
        ]
        for refusal in refusals {
            guard case .refused = refusal else {
                Issue.record("expected a refusal, got \(refusal)")
                continue
            }
        }
    }

    @Test("A row as the Mac parses it from the daemon feed still decodes")
    func rowFromFeedDecodes() throws {
        let path = "/home/u/dir with space/ünï.sv"
        let body = SSHTuiHostOpenCommand.bodyPrefix + Data(path.utf8).base64EncodedString()
        let now = Date()
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": Self.notificationID, "title": "cmux open", "subtitle": "ünï.sv", "body": body,
            "created_at_ms": String(UInt64(now.timeIntervalSince1970 * 1000)), "terminal_id": Self.terminalID,
            "read_by": [String](),
        ])
        let row = try #require(CloudVMNotificationRow.row(fromPayload: payload))
        #expect(SSHTuiHostOpenRequest(row: row, now: now, pathIsAcceptable: { _ in true })
                == .open(path: path, terminalID: Self.terminalID))
    }

    // MARK: Helpers

    private func request(body: String) -> SSHTuiHostOpenRequest {
        SSHTuiHostOpenRequest(title: SSHTuiHostOpenCommand.notificationTitle, body: body, terminalID: Self.terminalID,
                              createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000), now: Date(),
                              pathIsAcceptable: { $0.hasPrefix("/") })
    }

    private func connection(bundleIdentifier: String = "com.cmuxterm.app.debug.svedit") -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil
        ), environment: [:], bundleIdentifier: bundleIdentifier)
    }
}

/// A temporary HOME, a working directory, a fake login shell and a fake cmux-tui.
private final class Sandbox {
    let root: String
    var home: String { root + "/home" }
    var work: String { root + "/work" }
    var scriptPath: String { root + "/cmux" }
    private var fakeBinary: String { root + "/fake-cmux-tui" }
    private var argvFile: String { root + "/create-argv" }

    init() throws {
        root = Sandbox.canonical(NSTemporaryDirectory()) + "/cmux-open-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for dir in [home, work] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        // `exec "$SHELL" -l` lands here and reports what the terminal would get.
        try write(root + "/login-shell", """
            #!/bin/sh
            printf 'cmux=%s\\n' "$(command -v cmux || echo missing)"
            printf 'args=%s\\n' "$*"
            """)
        try write(fakeBinary, """
            #!/bin/sh
            case "$*" in
              *"notification create"*)
                : > "\(argvFile)"
                for a in "$@"; do printf '%s\\0' "$a" >> "\(argvFile)"; done
                printf '{"value":{"body":"x","id":"\(SSHTuiHostOpenCommandTests.notificationID)","read_by":[]}}\\n' ;;
              *"notification list"*)
                printf '[{"body":"x","id":"\(SSHTuiHostOpenCommandTests.notificationID)","read_by":[%s]}]\\n' "${FAKE_READ_BY-\\"mac\\"}" ;;
              *) exit 9 ;;
            esac
            """)
        let script = SSHTuiHostOpenCommand(session: "cmux-svedit", remoteBinary: "~/.local/bin/cmux-tui-svedit").script
        try write(scriptPath, script)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    var loginEnvironment: [String: String] {
        ["HOME": home, "SHELL": root + "/login-shell", "PATH": "/usr/bin:/bin"]
    }

    var openEnvironment: [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin", "CMUX_TUI_BIN": fakeBinary,
         "CMUX_TUI_SOCKET": root + "/mux.sock", "CMUX_TUI_TERMINAL_ID": SSHTuiHostOpenCommandTests.terminalID]
    }

    var posted: Bool { FileManager.default.fileExists(atPath: argvFile) }

    func open(_ arguments: [String], shell: String, cwd: String) throws -> ProcessResult {
        try? FileManager.default.removeItem(atPath: argvFile)
        return try run([shell, scriptPath, "open"] + arguments, environment: openEnvironment, cwd: cwd)
    }

    func createArgv() throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: argvFile))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    /// Creates a file under `work` and returns its canonical path.
    func makeFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: work + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: url)
        return Sandbox.canonical(url.path)
    }

    /// realpath(3): Foundation's resolvingSymlinksInPath drops `/private`.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func truncate(_ path: String, to size: UInt64) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: size)
        try handle.close()
    }

    func run(_ argv: [String], environment: [String: String], cwd: String? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd ?? root)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: stdout, as: UTF8.self),
                             stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
