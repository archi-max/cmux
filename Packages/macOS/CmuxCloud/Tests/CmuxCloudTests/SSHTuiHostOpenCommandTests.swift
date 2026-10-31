import CmuxCloud
import CmuxCore
import Foundation
import Testing

/// `cmux open` in a cmux-tui SSH terminal. Those terminals have no
/// cmuxd-remote relay and no `cmux` on PATH, so the app installs a small
/// host `cmux` from the terminal's launch command. It resolves the path on the
/// host, posts it as a session-wide marked `notification.create` on the
/// session's own daemon socket (no terminal marker), and waits for the Mac's
/// answer: an ack under a reserved `cmux-open:<outcome>` client id.
///
/// The script tests run the real script under real shells against a fake
/// cmux-tui that records its argv.
@Suite("cmux open in cmux-tui SSH terminals")
struct SSHTuiHostOpenCommandTests {
    static let terminalID = "term_0123456789abcdef0123456789abcdef"
    static let otherTerminalID = "term_fedcba9876543210fedcba9876543210"
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
        let expected = sandbox.installedPath(connection.hostOpenCommand)
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
        #expect(result.stdout.contains("cmux=missing"), "\(result.stdout)")
    }

    @Test("A failed install leaves no temporary file behind")
    func failedInstallRemovesTemporaryFile() throws {
        let sandbox = try Sandbox()
        let command = connection().hostOpenCommand
        // A non-searchable directory where the CLI goes: the install runs,
        // writes its temporary copy, and the final move fails.
        let directory = (sandbox.installedPath(command) as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory + "/cmux", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: directory + "/cmux")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory + "/cmux") }
        let result = try sandbox.run(connection().shellCommand, environment: sandbox.loginEnvironment)
        #expect(result.status == 0)
        #expect(result.stdout.contains("cmux=missing"), "\(result.stdout)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix(".cmux.") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test("The release and a tagged build keep separate CLIs, both outside ~/.cmux/bin")
    func installPathsAreIsolated() {
        let release = connection(bundleIdentifier: "com.cmuxterm.app").hostOpenCommand
        let tagged = connection().hostOpenCommand
        #expect(release.installDirectory.hasPrefix("$HOME/.local/share/cmux/ssh-cli/cmux/"))
        #expect(tagged.installDirectory.hasPrefix("$HOME/.local/share/cmux/ssh-cli/cmux-svedit/"))
        #expect(!tagged.installDirectory.contains(".cmux/bin"))
        #expect(tagged.script.contains("$HOME/.local/bin/cmux-tui-svedit}\""))
        #expect(release.script.contains("$HOME/.local/bin/cmux-tui}\""))
    }

    // MARK: Host script: request

    @Test("cmux open posts one session-wide row naming its terminal, and succeeds on the Mac's ok", arguments: shells)
    func openPostsSessionWideRow(shell: String) throws {
        let sandbox = try Sandbox()
        let file = try sandbox.makeFile("src/top.sv")
        let result = try sandbox.open(["src/top.sv:12"], shell: shell, cwd: sandbox.work)
        #expect(result.status == 0, "\(result.stderr)")
        let argv = try sandbox.createArgv()
        #expect(argv.starts(with: ["--json", "notification", "create"]))
        #expect(sandbox.value(after: "--title", in: argv) == SSHTuiHostOpenCommand.notificationTitle)
        #expect(sandbox.value(after: "--subtitle", in: argv) == "top.sv")
        // No --terminal: a terminal-scoped row would replace that terminal's
        // pending marker (an agent waiting for input, say).
        #expect(!argv.contains("--terminal"))
        let body = try #require(sandbox.value(after: "--body", in: argv))
        #expect(request(body: body) == .open(path: file, terminalID: Self.terminalID))
    }

    @Test("A name that itself ends in :N opens as written; :line:column is dropped", arguments: shells)
    func lineSuffixes(shell: String) throws {
        let sandbox = try Sandbox()
        let literal = try sandbox.makeFile("log:3")
        #expect(try sandbox.open(["log:3"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try sandbox.postedBody()) == .open(path: literal, terminalID: Self.terminalID))
        let plain = try sandbox.makeFile("a b.v")
        #expect(try sandbox.open(["a b.v:4:9"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try sandbox.postedBody()) == .open(path: plain, terminalID: Self.terminalID))
    }

    @Test("A symlink opens its target, the canonical host path", arguments: shells)
    func symlinkResolves(shell: String) throws {
        let sandbox = try Sandbox()
        let target = try sandbox.makeFile("real/wave.vcd")
        try FileManager.default.createSymbolicLink(atPath: sandbox.work + "/link.vcd", withDestinationPath: target)
        #expect(try sandbox.open(["link.vcd"], shell: shell, cwd: sandbox.work).status == 0)
        #expect(request(body: try sandbox.postedBody()) == .open(path: target, terminalID: Self.terminalID))
    }

    @Test("Refusals post nothing", arguments: shells)
    func refusals(shell: String) throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(atPath: sandbox.work + "/dir", withIntermediateDirectories: true)
        let big = try sandbox.makeFile("big.bin")
        try sandbox.truncate(big, to: 32 * 1024 * 1024 + 1)
        let unreadable = try sandbox.makeFile("secret.sv")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable) }
        // realpath and $(...) drop a trailing newline, which would name another file.
        _ = try sandbox.makeFile("nl\n")
        _ = try sandbox.makeFile("nl")
        let cases: [([String], String, Int32)] = [
            (["dir"], "is a directory", 1),
            (["missing.sv"], "no such file", 1),
            (["https://example.com/a"], "is not a file path", 1),
            (["big.bin"], "larger than 32 MB", 1),
            (["secret.sv"], "is not readable", 1),
            (["nl\n"], "line break", 1),
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

    @Test("Outside a cmux-tui terminal nothing is posted")
    func needsDaemonTerminal() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment.removeValue(forKey: "CMUX_TUI_TERMINAL_ID")
        let outside = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(outside.status == 1)
        #expect(outside.stderr.contains("CMUX_TUI_TERMINAL_ID"))
        #expect(!sandbox.posted)
    }

    @Test("Another verb runs the next cmux on PATH, or is refused when there is none")
    func otherVerbsPassThrough() throws {
        let sandbox = try Sandbox()
        let refused = try sandbox.run([sandbox.scriptPath, "notify", "--title", "x"], environment: sandbox.openEnvironment)
        #expect(refused.status == 2)
        #expect(refused.stderr.contains("only cmux open"))
        let other = sandbox.root + "/other-bin"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try sandbox.writeExecutable(other + "/cmux", "#!/bin/sh\nprintf 'other cmux:%s\\n' \"$*\"\n")
        var environment = sandbox.openEnvironment
        environment["PATH"] = sandbox.root + ":" + other + ":/usr/bin:/bin"
        let passed = try sandbox.run(["/bin/sh", "-c", "cmux notify --title x"], environment: environment)
        #expect(passed.status == 0, "\(passed.stderr)")
        #expect(passed.stdout == "other cmux:notify --title x\n")
        #expect(!sandbox.posted)
    }

    @Test("Under tmux the attaching client's terminal is used; without one, and under screen, nothing is posted")
    func tmuxAndScreen() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        let bin = sandbox.root + "/fake-tmux-bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try sandbox.writeExecutable(bin + "/tmux", "#!/bin/sh\nprintf '%s\\n' \"$FAKE_TMUX_ENV\"\n")
        var environment = sandbox.openEnvironment
        environment["PATH"] = bin + ":/usr/bin:/bin"
        environment["TMUX"] = "/tmp/tmux-1/default,1,0"
        environment["FAKE_TMUX_ENV"] = "CMUX_TUI_TERMINAL_ID=\(Self.otherTerminalID)"
        let attached = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(attached.status == 0, "\(attached.stderr)")
        guard case .open(_, let terminal) = request(body: try sandbox.postedBody()) else {
            Issue.record("no request posted")
            return
        }
        #expect(terminal == Self.otherTerminalID)

        try sandbox.forgetPost()
        environment["FAKE_TMUX_ENV"] = "-CMUX_TUI_TERMINAL_ID"
        let unknown = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(unknown.status == 1)
        #expect(unknown.stderr.contains("update-environment"), "\(unknown.stderr)")
        #expect(!sandbox.posted)

        var screen = sandbox.openEnvironment
        screen["STY"] = "1234.pts-0.host"
        let underScreen = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: screen, cwd: sandbox.work)
        #expect(underScreen.status == 1)
        #expect(underScreen.stderr.contains("screen"), "\(underScreen.stderr)")
        #expect(!sandbox.posted)
    }

    @Test("The usage text says :line is ignored and names the tmux limit")
    func usageText() throws {
        let sandbox = try Sandbox()
        let help = try sandbox.run(["/bin/sh", sandbox.scriptPath, "--help"], environment: sandbox.openEnvironment)
        #expect(help.status == 0)
        #expect(help.stdout.contains("Usage: cmux open <path>\n"), "\(help.stdout)")
        #expect(help.stdout.contains(":line"))
        #expect(help.stdout.contains("tmux"))
        // tmux's environment names the client that attached last.
        #expect(help.stdout.contains("attached last"), "\(help.stdout)")
        // Success means the Mac queued the preview, not that it is on screen.
        #expect(help.stdout.contains("queued"), "\(help.stdout)")
    }

    // MARK: Host script: the Mac's answer

    @Test("A Mac refusal is reported with its reason and a non-zero exit")
    func refusalIsReported() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        let reasons: [(SSHTuiHostOpenAnswer, String)] = [
            (.stale, "too old"),
            (.malformed, "could not read"),
            (.path, "refused this path"),
            (.previewsOff, "file previews are off"),
            (.unsupportedType, "Files panel"),
        ]
        for (answer, message) in reasons {
            var environment = sandbox.openEnvironment
            environment["FAKE_READ_BY"] = "\"mac-1\",\"\(answer.clientID)\""
            let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
            #expect(result.status == 1, "\(answer)")
            #expect(result.stderr.contains(message), "\(answer): \(result.stderr)")
        }
    }

    @Test("Only the Mac's ok is success: another client's read is not")
    func onlyMacOkIsSuccess() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = "\"phone-7\",\"mac-1\""
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(result.status == 1)
        #expect(result.stderr.contains("no cmux window took"), "\(result.stderr)")
        // Giving up withdraws the request, so the Mac cannot open it later.
        #expect(try sandbox.ackLog().contains("--client \(SSHTuiHostOpenAnswer.cancelledClientID)"))
    }

    @Test("Two copies of this cmux on PATH do not exec each other forever")
    func passthroughDoesNotLoop() throws {
        let sandbox = try Sandbox()
        let script = try String(contentsOfFile: sandbox.scriptPath, encoding: .utf8)
        let a = sandbox.root + "/a-bin", b = sandbox.root + "/b-bin"
        for dir in [a, b] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try sandbox.writeExecutable(dir + "/cmux", script)
        }
        var environment = sandbox.openEnvironment
        environment["PATH"] = b + ":" + a + ":/usr/bin:/bin"
        let looped = try sandbox.run(["/bin/sh", "-c", "cmux notify --title x"], environment: environment, timeout: 10)
        #expect(looped.status == 2, "\(looped.stderr)")
        #expect(looped.stderr.contains("only cmux open"), "\(looped.stderr)")

        // Every install directory is skipped, so a real cmux after them still runs.
        let installs = sandbox.home + "/.local/share/cmux/ssh-cli/cmux-svedit"
        let first = installs + "/1111", second = installs + "/2222"
        let other = sandbox.root + "/other-bin"
        for dir in [first, second, other] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try sandbox.writeExecutable(first + "/cmux", script)
        try sandbox.writeExecutable(second + "/cmux", script)
        try sandbox.writeExecutable(other + "/cmux", "#!/bin/sh\nprintf 'other cmux:%s\\n' \"$*\"\n")
        environment["PATH"] = [first, second, other, "/usr/bin", "/bin"].joined(separator: ":")
        let passed = try sandbox.run(["/bin/sh", "-c", "cmux notify --title x"], environment: environment, timeout: 10)
        #expect(passed.status == 0, "\(passed.stderr)")
        #expect(passed.stdout == "other cmux:notify --title x\n")

        // A passthrough that comes back to this script stops.
        environment["CMUX_SSH_CLI_PASSTHROUGH"] = "1"
        let again = try sandbox.run(["/bin/sh", "-c", "cmux notify --title x"], environment: environment, timeout: 10)
        #expect(again.status == 2, "\(again.stderr)")
        #expect(!again.stdout.contains("other cmux"))
    }

    @Test("A file named like an answer is not an answer: only read_by counts")
    func answerMatchedOnlyInReadBy() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("cmux-open:ok")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = ""
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "cmux-open:ok"], environment: environment,
                                     cwd: sandbox.work, timeout: 30)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stderr.contains("no cmux window took"), "\(result.stderr)")
    }

    @Test("The subtitle drops JSON punctuation, so a name cannot reshape the row the CLI reads")
    func subtitleIsSanitized() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a\"]}{[b\\.sv")
        let result = try sandbox.open(["a\"]}{[b\\.sv"], shell: "/bin/sh", cwd: sandbox.work)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(sandbox.value(after: "--subtitle", in: try sandbox.createArgv()) == "ab.sv")
    }

    @Test("not-open-here is one Mac's view: the CLI keeps waiting for another Mac's ok")
    func notOpenHereKeepsWaiting() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = "\"\(SSHTuiHostOpenAnswer.notOpenHere.clientID)\""
        environment["FAKE_SWITCH_AFTER"] = "3"
        environment["FAKE_READ_BY_LATER"] = "\"\(SSHTuiHostOpenAnswer.notOpenHere.clientID)\",\"cmux-open:ok\""
        let opened = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment,
                                     cwd: sandbox.work, timeout: 30)
        #expect(opened.status == 0, "\(opened.stderr)")

        // A hard refusal beside it still ends the wait at once.
        environment["FAKE_SWITCH_AFTER"] = nil
        environment["FAKE_READ_BY"] = "\"\(SSHTuiHostOpenAnswer.notOpenHere.clientID)\",\"\(SSHTuiHostOpenAnswer.unsupportedType.clientID)\""
        let hard = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment,
                                   cwd: sandbox.work, timeout: 30)
        #expect(hard.status == 1)
        #expect(hard.stderr.contains("Files panel"), "\(hard.stderr)")
        #expect(hard.elapsed < 5, "\(hard.elapsed)")
    }

    @Test("Only not-open-here until the deadline: the CLI waits it out, withdraws, and says why")
    func notOpenHereAloneTimesOut() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = "\"\(SSHTuiHostOpenAnswer.notOpenHere.clientID)\""
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment,
                                     cwd: sandbox.work, timeout: 30)
        #expect(result.status == 1)
        #expect(result.stderr.contains("not open in a cmux window"), "\(result.stderr)")
        #expect(result.elapsed >= Double(SSHTuiHostOpenCommand.answerWaitSeconds) - 2, "\(result.elapsed)")
        #expect(try sandbox.ackLog().contains("--client \(SSHTuiHostOpenAnswer.cancelledClientID)"))
    }

    @Test("An ok that lands shortly after the withdrawal still counts")
    func lateOkAfterCancelCounts() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_READ_BY"] = ""
        environment["FAKE_OK_AFTER_CANCEL"] = "2"
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment,
                                     cwd: sandbox.work, timeout: 30)
        #expect(result.status == 0, "\(result.stderr)")
    }

    @Test("Without fractional sleep the wait still ends at the same deadline")
    func wholeSecondSleepKeepsDeadline() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        let bin = sandbox.root + "/sleep-bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try sandbox.writeExecutable(bin + "/sleep", "#!/bin/sh\ncase $1 in *.*) exit 1 ;; esac\nexec /bin/sleep \"$@\"\n")
        var environment = sandbox.openEnvironment
        environment["PATH"] = bin + ":/usr/bin:/bin"
        environment["FAKE_READ_BY"] = ""
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment,
                                     cwd: sandbox.work, timeout: 60)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.elapsed < Double(SSHTuiHostOpenCommand.answerWaitSeconds) + 5, "\(result.elapsed)")
    }

    @Test("An unreadable daemon reply fails closed")
    func unparsableReplyFailsClosed() throws {
        let sandbox = try Sandbox()
        _ = try sandbox.makeFile("a.sv")
        var environment = sandbox.openEnvironment
        environment["FAKE_CREATE_REPLY"] = "{\"value\":{}}"
        let result = try sandbox.run(["/bin/sh", sandbox.scriptPath, "open", "a.sv"], environment: environment, cwd: sandbox.work)
        #expect(result.status == 1)
        #expect(result.stderr.contains("request id"), "\(result.stderr)")
    }

    // MARK: Mac-side decoding

    @Test("Only a well-formed body with a terminal and an acceptable path opens")
    func requestDecoding() {
        let body = SSHTuiHostOpenCommand.requestBody(path: "/home/u/top.sv", terminalID: Self.terminalID)
        func decide(_ body: String, accept: @escaping (String) -> Bool = { $0.hasPrefix("/") }) -> SSHTuiHostOpenRequest {
            SSHTuiHostOpenRequest(body: body, pathIsAcceptable: accept)
        }
        #expect(decide(body) == .open(path: "/home/u/top.sv", terminalID: Self.terminalID))
        #expect(decide("ok") == .notARequest)
        #expect(decide("cmux open me") == .notARequest)
        let prefix = SSHTuiHostOpenCommand.bodyPrefix
        let encodedPath = Data("/home/u/top.sv".utf8).base64EncodedString()
        let refusals: [(String, SSHTuiHostOpenAnswer)] = [
            (prefix + encodedPath, .malformed),
            (prefix + "term_bad:" + encodedPath, .malformed),
            (prefix + Self.terminalID + ":!!!", .malformed),
            (prefix + Self.terminalID + ":" + Data([0xFF, 0xFE]).base64EncodedString(), .malformed),
            (String(body.dropLast(4)) + "\u{2026}", .malformed),
            (prefix + Self.terminalID + ":" + Data(("/" + String(repeating: "a", count: 800)).utf8).base64EncodedString(), .malformed),
        ]
        for (refused, answer) in refusals {
            #expect(decide(refused) == .refused(answer), "\(refused)")
        }
        #expect(decide(body, accept: { _ in false }) == .refused(.path))
    }

    @Test("The longest accepted path still fits the body the Mac keeps")
    func longestPathFits() throws {
        let path = "/" + String(repeating: "p", count: SSHTuiHostOpenCommand.maximumPathBytes - 1)
        let body = SSHTuiHostOpenCommand.requestBody(path: path, terminalID: Self.terminalID)
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": Self.notificationID, "title": "cmux open", "body": body, "created_at_ms": "1", "read_by": [String](),
        ])
        let row = try #require(CloudVMNotificationRow.row(fromPayload: payload))
        #expect(SSHTuiHostOpenRequest(body: row.body, pathIsAcceptable: { _ in true }) == .open(path: path, terminalID: Self.terminalID))
    }

    @Test("A row as the Mac parses it from the daemon feed still decodes")
    func rowFromFeedDecodes() throws {
        let path = "/home/u/dir with space/ünï.sv"
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": Self.notificationID, "title": "cmux open", "subtitle": "ünï.sv",
            "body": SSHTuiHostOpenCommand.requestBody(path: path, terminalID: Self.terminalID),
            "created_at_ms": "1", "read_by": [String](),
        ])
        let row = try #require(CloudVMNotificationRow.row(fromPayload: payload))
        #expect(SSHTuiHostOpenRequest(body: row.body, pathIsAcceptable: { _ in true })
                == .open(path: path, terminalID: Self.terminalID))
    }

    // MARK: Helpers

    private func request(body: String) -> SSHTuiHostOpenRequest {
        SSHTuiHostOpenRequest(body: body, pathIsAcceptable: { $0.hasPrefix("/") })
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
    private var ackFile: String { root + "/ack-log" }
    private var subtitleFile: String { root + "/subtitle" }
    private var listCountFile: String { root + "/list-count" }
    private var afterCancelFile: String { root + "/after-cancel-count" }

    init() throws {
        root = Sandbox.canonical(NSTemporaryDirectory()) + "/cmux-open-\(UUID().uuidString.prefix(8))"
        let fm = FileManager.default
        for dir in [home, work] { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        // `exec "$SHELL" -l` lands here and reports what the terminal would get.
        try writeExecutable(root + "/login-shell", """
            #!/bin/sh
            printf 'cmux=%s\\n' "$(command -v cmux || echo missing)"
            printf 'args=%s\\n' "$*"
            """)
        let id = SSHTuiHostOpenCommandTests.notificationID
        try writeExecutable(fakeBinary, """
            #!/bin/sh
            case "$*" in
              *"notification create"*)
                : > "\(argvFile)"
                for a in "$@"; do printf '%s\\0' "$a" >> "\(argvFile)"; done
                prev=
                for a in "$@"; do [ "$prev" = --subtitle ] && printf '%s' "$a" > "\(subtitleFile)"; prev=$a; done
                printf '%s\\n' "${FAKE_CREATE_REPLY-{\\"value\\":{\\"body\\":\\"x\\",\\"id\\":\\"\(id)\\",\\"read_by\\":[]}}}" ;;
              *"notification list"*)
                # Keys sorted as serde_json writes them; the subtitle follows read_by.
                n=$(($(cat "\(listCountFile)" 2>/dev/null || echo 0) + 1)); echo "$n" > "\(listCountFile)"
                readers=${FAKE_READ_BY-\\"mac-1\\",\\"cmux-open:ok\\"}
                if [ -n "${FAKE_SWITCH_AFTER:-}" ] && [ "$n" -gt "$FAKE_SWITCH_AFTER" ]; then readers=$FAKE_READ_BY_LATER; fi
                if [ -n "${FAKE_OK_AFTER_CANCEL:-}" ] && grep -q cancelled "\(ackFile)" 2>/dev/null; then
                  c=$(($(cat "\(afterCancelFile)" 2>/dev/null || echo 0) + 1)); echo "$c" > "\(afterCancelFile)"
                  [ "$c" -ge "$FAKE_OK_AFTER_CANCEL" ] && readers='"cmux-open:cancelled","cmux-open:ok"'
                fi
                printf '[{"body":"x","id":"\(id)","read_by":[%s],"subtitle":"%s"}]\\n' "$readers" "$(cat "\(subtitleFile)" 2>/dev/null)" ;;
              *"notification ack"*)
                printf '%s\\n' "$*" >> "\(ackFile)" ;;
              *) exit 9 ;;
            esac
            """)
        let script = SSHTuiHostOpenCommand(session: "cmux-svedit", remoteBinary: "~/.local/bin/cmux-tui-svedit").script
        try writeExecutable(scriptPath, script)
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

    func forgetPost() throws { try FileManager.default.removeItem(atPath: argvFile) }

    func installedPath(_ command: SSHTuiHostOpenCommand) -> String {
        home + "/" + command.installDirectory.replacingOccurrences(of: "$HOME/", with: "") + "/cmux"
    }

    func open(_ arguments: [String], shell: String, cwd: String) throws -> ProcessResult {
        try? FileManager.default.removeItem(atPath: argvFile)
        return try run([shell, scriptPath, "open"] + arguments, environment: openEnvironment, cwd: cwd)
    }

    func createArgv() throws -> [String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: argvFile))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func postedBody() throws -> String {
        try #require(value(after: "--body", in: createArgv()))
    }

    func ackLog() throws -> String {
        (try? String(contentsOfFile: ackFile, encoding: .utf8)) ?? ""
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

    func run(_ argv: [String], environment: [String: String], cwd: String? = nil,
             timeout: TimeInterval = 60) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd ?? root)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let started = Date()
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
            if process.isRunning { process.terminate() }
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: stdout, as: UTF8.self),
                             stderr: String(decoding: stderr, as: UTF8.self),
                             elapsed: Date().timeIntervalSince(started))
    }

    func writeExecutable(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let elapsed: TimeInterval
}
