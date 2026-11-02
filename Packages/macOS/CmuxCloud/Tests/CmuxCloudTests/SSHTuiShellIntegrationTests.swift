import CmuxCloud
import CmuxCore
import Foundation
import Testing

/// The Files panel of a cmux-tui SSH workspace follows the terminal's `cd`
/// through the daemon's graph `cwd`, which the daemon takes from OSC 7. The
/// daemon injects its own shell integration (and so OSC 7) only into the
/// default shell; an SSH terminal starts the app's launch command instead, so
/// the launch command has to make the login shell report its directory.
///
/// The tests run the real launch command under the real shells. The login
/// shell is a wrapper named after the shell that adds `-i`, so the shell is
/// interactive (prompt hooks run) while it reads commands from a pipe.
@Suite("cmux-tui SSH terminals report the shell's directory")
struct SSHTuiShellIntegrationTests {
    /// A bash that honors ENV in POSIX mode. Apple's /bin/bash 3.2 does not,
    /// so on macOS this needs a separately installed bash.
    static let gnuBash: String? = {
        let environment = ProcessInfo.processInfo.environment["CMUX_TEST_GNU_BASH"]
        var candidates = [environment, "/opt/homebrew/bin/bash", "/usr/local/bin/bash"].compactMap { $0 }
        #if os(Linux)
        candidates.append("/bin/bash")
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @Test("A zsh login shell reports its directory after cd")
    func zshReportsDirectory() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let target = try sandbox.makeDirectory("proj/sub dir")
        let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho marker-done\n")
        #expect(result.stdout.contains("marker-done"), "\(result.stderr)")
        #expect(result.reportedDirectories.contains(sandbox.work), "\(result.stdout.debugDescription)")
        #expect(result.reportedDirectories.last == target, "\(result.stdout.debugDescription)")
    }

    @Test("zsh still runs each of the user's startup files once, with ZDOTDIR restored")
    func zshStartupFilesUnchanged() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        try sandbox.writeStartupFiles([".zshenv", ".zprofile", ".zshrc", ".zlogin"], in: sandbox.home)
        try sandbox.append(#"print -r -- "zdotdir=[${ZDOTDIR-unset}] posix=[${CMUX_SSH_ZDOTDIR-unset}]""#,
                           to: sandbox.home + "/.zshrc")
        let result = try sandbox.runLoginShell(input: "echo marker-done\n")
        #expect(result.stdout.contains("marker-done"), "\(result.stderr)")
        #expect(try sandbox.startupLog() == [".zshenv", ".zprofile", ".zshrc", ".zlogin"])
        #expect(result.stdout.contains("zdotdir=[unset] posix=[unset]"), "\(result.stdout)")
    }

    @Test("zsh keeps a ZDOTDIR the user set")
    func zshKeepsUserZdotdir() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let zdotdir = try sandbox.makeDirectory("zdot")
        try sandbox.writeStartupFiles([".zshenv", ".zshrc"], in: zdotdir)
        try sandbox.append(#"print -r -- "zdotdir=[${ZDOTDIR-unset}]""#, to: zdotdir + "/.zshrc")
        let result = try sandbox.runLoginShell(input: "cd /\necho marker-done\n", extraEnvironment: ["ZDOTDIR": zdotdir])
        #expect(try sandbox.startupLog() == [".zshenv", ".zshrc"])
        #expect(result.stdout.contains("zdotdir=[\(zdotdir)]"), "\(result.stdout)")
        #expect(result.reportedDirectories.last == "/", "\(result.stdout.debugDescription)")
    }

    @Test("A bash login shell reports its directory and runs its startup files once",
          .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashReportsDirectory() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        try sandbox.writeStartupFiles([".bash_profile"], in: sandbox.home)
        // A PROMPT_COMMAND from the startup files keeps running beside the hook.
        try sandbox.append(#"PROMPT_COMMAND='echo user-prompt-hook'"#, to: sandbox.home + "/.bash_profile")
        let target = try sandbox.makeDirectory("proj/sub dir")
        let input = """
            cd '\(target)'
            shopt -q login_shell && echo login=yes
            [[ -o posix ]] && echo posix=yes
            echo "env=[${ENV-unset}] histfile=[$HISTFILE] exported=[$(env | grep -c '^HISTFILE=')]"
            echo marker-done

            """
        let result = try sandbox.runLoginShell(input: input)
        #expect(result.stdout.contains("marker-done"), "\(result.stderr)")
        #expect(result.reportedDirectories.last == target, "\(result.stdout.debugDescription)")
        #expect(try sandbox.startupLog() == [".bash_profile"])
        #expect(result.stdout.contains("login=yes"))
        #expect(!result.stdout.contains("posix=yes"))
        #expect(result.stdout.contains("env=[unset] histfile=[\(sandbox.home)/.bash_history] exported=[0]"), "\(result.stdout)")
        #expect(result.stdout.contains("user-prompt-hook"))
    }

    @Test("A bash login shell restores an ENV the user had",
          .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashRestoresUserEnv() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        let result = try sandbox.runLoginShell(input: "echo \"env=[${ENV-unset}]\"\n",
                                               extraEnvironment: ["ENV": "/nonexistent/user-env"])
        #expect(result.stdout.contains("env=[/nonexistent/user-env]"), "\(result.stdout)")
    }

    #if os(macOS)
    @Test("Apple's /bin/bash keeps the plain login shell")
    func appleBashUnchanged() throws {
        let sandbox = try ShellSandbox(shell: nil, name: nil)
        // Not interactive (no -i, no tty): the shell runs the piped commands.
        let input = """
            shopt -q login_shell && echo login=yes
            case :$SHELLOPTS: in *:posix:*) echo posix=yes ;; esac
            echo "env=[${ENV-unset}]"

            """
        let result = try sandbox.run(sandbox.launchCommand, environment: sandbox.environment(shell: "/bin/bash"), input: input)
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stdout.contains("login=yes"), "\(result.stdout)")
        #expect(!result.stdout.contains("posix=yes"), "\(result.stdout)")
        #expect(result.stdout.contains("env=[unset]"), "\(result.stdout)")
    }
    #endif

    @Test("The configured-command launch is not changed")
    func configuredCommandUnchanged() throws {
        let argv = ShellSandbox.connection().commandArguments("echo hi")
        #expect(argv.dropLast(2).last?.hasSuffix("exec \"${SHELL:-/bin/sh}\" -lc \"$1\"") == true)
    }
}

/// A temporary HOME and work directory, and a login shell wrapper.
private final class ShellSandbox {
    let root: String
    var home: String { root + "/home" }
    var work: String { root + "/work" }
    var logPath: String { root + "/startup.log" }
    private let wrapper: String?

    /// `shell` is the real shell; the wrapper at `bin/<name>` adds `-i` last
    /// (bash needs its long options first).
    init(shell: String?, name: String?) throws {
        let root = ShellSandbox.canonical(NSTemporaryDirectory()) + "/cmux-sh-\(UUID().uuidString.prefix(8))"
        self.root = root
        wrapper = name.map { root + "/bin/" + $0 }
        for dir in [home, work, root + "/bin"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if let shell, let wrapper {
            try writeExecutable(wrapper, "#!/bin/sh\nexec \(shell) \"$@\" -i\n")
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    static func connection() -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil
        ), environment: [:], bundleIdentifier: "com.cmuxterm.app.debug.svedit")
    }

    var launchCommand: [String] { Self.connection().shellCommand }

    func environment(shell: String) -> [String: String] {
        ["HOME": home, "SHELL": shell, "PATH": "/usr/bin:/bin", "TERM": "dumb",
         "CMUX_TEST_STARTUP_LOG": logPath]
    }

    func runLoginShell(input: String, extraEnvironment: [String: String] = [:]) throws -> ShellResult {
        let shell = try #require(wrapper)
        let environment = environment(shell: shell).merging(extraEnvironment) { _, new in new }
        let result = try run(launchCommand, environment: environment, input: input + "exit\n")
        return result
    }

    func makeDirectory(_ relative: String) throws -> String {
        let path = work + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return ShellSandbox.canonical(path)
    }

    /// Each file appends its own name to the startup log.
    func writeStartupFiles(_ names: [String], in directory: String) throws {
        for name in names {
            try "echo \(name) >> \"$CMUX_TEST_STARTUP_LOG\"\n".write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
        }
    }

    func append(_ line: String, to path: String) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func startupLog() throws -> [String] {
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func run(_ argv: [String], environment: [String: String], input: String, timeout: TimeInterval = 60) throws -> ShellResult {
        let inputPath = root + "/stdin", errorPath = root + "/stderr"
        try input.write(toFile: inputPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: errorPath, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: work)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = try FileHandle(forWritingTo: URL(fileURLWithPath: errorPath))
        process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [process] in
            if process.isRunning { process.terminate() }
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus,
                           stdout: String(decoding: stdout, as: UTF8.self),
                           stderr: (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? "")
    }

    func writeExecutable(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// realpath(3): Foundation's resolvingSymlinksInPath drops `/private`.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    /// The paths of the OSC 7 reports, in order (`ESC ] 7 ; kitty-shell-cwd://host/path BEL`).
    var reportedDirectories: [String] {
        let prefix = "\u{1b}]7;kitty-shell-cwd://"
        return stdout.components(separatedBy: prefix).dropFirst().compactMap { chunk in
            guard let end = chunk.firstIndex(of: "\u{07}") else { return nil }
            let url = chunk[..<end]
            guard let slash = url.firstIndex(of: "/") else { return nil }
            return String(url[slash...])
        }
    }
}
