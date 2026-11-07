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

    // MARK: Review cases

    @Test("bash: a PROMPT_COMMAND ending in & or a comment keeps working and the hook still runs",
          .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashPromptCommandSeparators() throws {
        for userHook in ["echo user-hook-ran &", "echo user-hook-ran # a note"] {
            let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
            try sandbox.append("PROMPT_COMMAND='\(userHook)'", to: sandbox.home + "/.bash_profile")
            let target = try sandbox.makeDirectory("t")
            let result = try sandbox.runLoginShell(input: "cd '\(target)'\nsleep 0.2\necho marker-done\n")
            #expect(!result.stderr.contains("syntax error"), "\(userHook): \(result.stderr)")
            #expect(result.stdout.contains("user-hook-ran"), "\(userHook)")
            #expect(result.reportedDirectories.last == target, "\(userHook): \(result.stdout.debugDescription)")
        }
    }

    @Test("bash: an array PROMPT_COMMAND keeps its entries", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashArrayPromptCommand() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        try sandbox.append("PROMPT_COMMAND=('echo array-hook-ran')", to: sandbox.home + "/.bash_profile")
        let target = try sandbox.makeDirectory("t")
        let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho marker-done\n")
        #expect(result.stdout.contains("array-hook-ran"))
        #expect(result.reportedDirectories.last == target, "\(result.stdout.debugDescription)")
    }

    @Test("bash: the shell state matches the plain login launch", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashStateMatchesPlainLaunch() throws {
        let probe = "shopt -p; set +o; echo \"path=[$PATH] histfile=[$HISTFILE]\"; env | grep -E '^(ENV|CMUX_SSH_[A-Z_]*)=' | sort\n"
        var outputs: [[String]] = []
        for plain in [true, false] {
            let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
            try sandbox.writeStartupFiles([".bash_profile", ".bash_login", ".profile"], in: sandbox.home)
            let result = try sandbox.runLoginShell(input: probe, launch: plain ? ShellSandbox.plainLaunch : nil)
            let lines = result.stdout.components(separatedBy: "\n").map { line in
                // The OSC 7 report shares a line with the next output.
                line.replacingOccurrences(of: #"\u001b\]7;[^\u0007]*\u0007"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: sandbox.root, with: "<root>")
            }
            outputs.append(lines + ["log=\(try sandbox.startupLog())"])
        }
        #expect(outputs[0] == outputs[1], "\(Set(outputs[0]).symmetricDifference(Set(outputs[1])))")
        #expect(outputs[1].last == #"log=[".bash_profile"]"#)
    }

    @Test("bash: each directory is reported once, with this host's name", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashReportsEachDirectoryOnce() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        let target = try sandbox.makeDirectory("t")
        let result = try sandbox.runLoginShell(input: "true\ncd '\(target)'\ntrue\ncd .\ntrue\n")
        #expect(result.reportedDirectories == [sandbox.work, target], "\(result.stdout.debugDescription)")
        #expect(Set(result.reportedHosts) == [ShellSandbox.hostName], "\(result.reportedHosts)")
    }

    @Test("zsh: each directory is reported once, with this host's name, and nothing leaks")
    func zshReportsEachDirectoryOnce() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let target = try sandbox.makeDirectory("t")
        let result = try sandbox.runLoginShell(input: "true\ncd '\(target)'\ntrue\nprint -r -- \"leaks=[$(env | grep -c '^CMUX_SSH_')]\"\n")
        #expect(result.reportedDirectories == [sandbox.work, target], "\(result.stdout.debugDescription)")
        #expect(Set(result.reportedHosts) == [ShellSandbox.hostName], "\(result.reportedHosts)")
        #expect(result.stdout.contains("leaks=[0]"), "\(result.stdout)")
    }

    @Test("bash: a HOME that bash would expand in ENV keeps the plain login launch", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashExpandingHomeFallsBack() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash", homeName: "ho$me")
        try sandbox.writeStartupFiles([".bash_profile"], in: sandbox.home)
        let result = try sandbox.runLoginShell(input: "echo \"env=[${ENV-unset}]\"\n")
        #expect(try sandbox.startupLog() == [".bash_profile"], "\(result.stderr)")
        #expect(result.stdout.contains("env=[unset]"), "\(result.stdout)")
    }

    @Test("bash: a failed install keeps the plain login launch", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashFailedInstallFallsBack() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        try sandbox.writeStartupFiles([".bash_profile"], in: sandbox.home)
        try sandbox.makeHomeReadOnly()
        defer { sandbox.makeHomeWritable() }
        let result = try sandbox.runLoginShell(input: "echo \"env=[${ENV-unset}]\"\n")
        #expect(try sandbox.startupLog() == [".bash_profile"])
        #expect(result.stdout.contains("env=[unset]"), "\(result.stdout)")
        #expect(result.stderr.isEmpty || !result.stderr.contains("cmux"), "\(result.stderr)")
    }

    @Test("zsh: a failed install keeps the plain login launch")
    func zshFailedInstallFallsBack() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        try sandbox.writeStartupFiles([".zshenv", ".zshrc"], in: sandbox.home)
        try sandbox.makeHomeReadOnly()
        defer { sandbox.makeHomeWritable() }
        let result = try sandbox.runLoginShell(input: "print -r -- \"zdotdir=[${ZDOTDIR-unset}]\"\n")
        #expect(try sandbox.startupLog() == [".zshenv", ".zshrc"])
        #expect(result.stdout.contains("zdotdir=[unset]"), "\(result.stdout)")
    }

    @Test("The sourced files are installed private under a permissive umask, and a writable one is refused",
          .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func installIsPrivateAndCheckedBeforeUse() throws {
        let sandbox = try ShellSandbox(shell: try #require(Self.gnuBash), name: "bash")
        let target = try sandbox.makeDirectory("t")
        _ = try sandbox.runLoginShell(input: "true\n", umask: "000")
        let install = sandbox.hookDirectory
        for file in ["shell/bash-env", "shell/zsh/.zshenv"] {
            #expect(try sandbox.mode(install + "/" + file) == 0o644, "\(file)")
        }
        for dir in ["", "/shell", "/shell/zsh"] {
            #expect(try sandbox.mode(install + dir) == 0o700, "\(install + dir)")
        }
        // cmux creates the whole chain below HOME itself.
        var parent = (install as NSString).deletingLastPathComponent
        while parent != sandbox.home {
            #expect(try sandbox.mode(parent) == 0o700, "\(parent)")
            parent = (parent as NSString).deletingLastPathComponent
        }
        // A file someone else could have rewritten is not sourced.
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: install + "/shell/bash-env")
        let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho \"env=[${ENV-unset}]\"\n")
        #expect(result.reportedDirectories.isEmpty, "\(result.stdout.debugDescription)")
        #expect(result.stdout.contains("env=[unset]"))
    }

    @Test("zsh: the hook survives a .zshrc that reassigns precmd_functions, and needs no autoload")
    func zshHookSurvivesReassignedHooks() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        try sandbox.append("fpath=()", to: sandbox.home + "/.zshenv")
        try sandbox.append("precmd_functions=()", to: sandbox.home + "/.zshrc")
        let target = try sandbox.makeDirectory("t")
        let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho marker-done\n")
        #expect(!result.stderr.contains("add-zsh-hook"), "\(result.stderr)")
        #expect(result.reportedDirectories.last == target, "\(result.stdout.debugDescription)")
    }

    @Test("A cd in a subshell or command substitution prints nothing and is not reported")
    func subshellDirectoryChangesAreSilent() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            let target = try sandbox.makeDirectory("sub")
            if name == "zsh" { try sandbox.append("X=$(cd sub && pwd)", to: sandbox.home + "/.zshrc") }
            let input = """
                true
                echo "[$(cd sub && pwd)]"
                (cd /usr && true)
                true
                echo "x=[${X-none}]"

                """
            let result = try sandbox.runLoginShell(input: input)
            #expect(result.stdout.contains("[\(target)]"), "\(name): \(result.stdout.debugDescription)")
            if name == "zsh" {
                #expect(result.stdout.contains("x=[\(target)]"), "\(name): \(result.stdout.debugDescription)")
            }
            #expect(result.reportedDirectories == [sandbox.work], "\(name): \(result.stdout.debugDescription)")
        }
    }

    @Test("A group- or other-writable parent of the install keeps the plain login launch")
    func writableInstallParentFallsBack() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            for (levels, mode) in [(1, 0o775), (2, 0o757), (3, 0o775)] {
                let sandbox = try ShellSandbox(shell: shell, name: name)
                let target = try sandbox.makeDirectory("t")
                _ = try sandbox.runLoginShell(input: "true\n")
                var parent = sandbox.hookDirectory
                for _ in 0..<levels { parent = (parent as NSString).deletingLastPathComponent }
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: parent)
                // The user's group is not a private one here, whatever this machine's is.
                let path = try sandbox.fakeGroupDatabase(nil)
                let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho \"env=[${ENV-unset}] zdotdir=[${ZDOTDIR-unset}]\"\n",
                                                       extraEnvironment: ["PATH": path])
                #expect(result.reportedDirectories.isEmpty, "\(name) \(parent): \(result.stdout.debugDescription)")
                #expect(result.stdout.contains("env=[unset] zdotdir=[unset]"), "\(name) \(parent): \(result.stdout)")
            }
        }
    }

    /// Ubuntu and Debian log in with umask 002, so the `mkdir -p ~/.local/bin`
    /// of the cmux-tui install leaves `~/.local` group-writable. The sourced
    /// files live in a chain cmux creates itself below HOME, so that does not
    /// matter, and no group write is ever trusted.
    @Test("A group-writable ~/.local from a umask 002 login does not stop the hook")
    func umask002LocalDirectoryDoesNotStopTheHook() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            let target = try sandbox.makeDirectory("t")
            for dir in [".local", ".local/bin", ".local/share"] {
                try FileManager.default.createDirectory(atPath: sandbox.home + "/" + dir, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: sandbox.home + "/" + dir)
            }
            let path = try sandbox.fakeGroupDatabase(nil)
            let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho marker-done\n",
                                                   extraEnvironment: ["PATH": path], umask: "002")
            #expect(result.stdout.contains("marker-done"), "\(name): \(result.stderr)")
            #expect(result.reportedDirectories.last == target, "\(name): \(result.stdout.debugDescription)")
        }
    }

    /// Group write is never trusted, even for a group whose only listed member
    /// is the user: on Linux the group bits are the ACL mask, so they would
    /// let every named ACL entry write, and the group database cannot show
    /// every member (primary-group users, duplicate GIDs, sssd).
    @Test("A HOME writable by the user's own group keeps the plain login launch")
    func groupWritableHomeStaysPlain() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            let target = try sandbox.makeDirectory("t")
            let path = try sandbox.fakeGroupDatabase("\(NSUserName()):x:\(getgid()):")
            _ = try sandbox.runLoginShell(input: "true\n", extraEnvironment: ["PATH": path])
            try sandbox.giveHookChainTheUsersGroup()
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: sandbox.home)
            let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho \"env=[${ENV-unset}] zdotdir=[${ZDOTDIR-unset}]\"\n",
                                                   extraEnvironment: ["PATH": path])
            #expect(result.reportedDirectories.isEmpty, "\(name): \(result.stdout.debugDescription)")
            #expect(result.stdout.contains("env=[unset] zdotdir=[unset]"), "\(name): \(result.stdout)")
        }
    }

    /// zsh reads `$ZDOTDIR/.zshenv.zwc` instead of `.zshenv` when it exists and is newer.
    @Test("zsh: a compiled .zshenv.zwc someone else could write keeps the plain login launch")
    func zshUnsafeCompiledEnvStaysPlain() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let target = try sandbox.makeDirectory("t")
        _ = try sandbox.runLoginShell(input: "true\n")
        let compiled = sandbox.hookDirectory + "/shell/zsh/.zshenv.zwc"
        FileManager.default.createFile(atPath: compiled, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: compiled)
        let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho \"zdotdir=[${ZDOTDIR-unset}]\"\n")
        #expect(result.reportedDirectories.isEmpty, "\(result.stdout.debugDescription)")
        #expect(result.stdout.contains("zdotdir=[unset]"), "\(result.stdout)")
    }

    /// The host `cmux` directory goes first on PATH, so whoever can write it or
    /// any parent can put an `ls` there that every command in the terminal runs.
    @Test("The host cmux is put on PATH only from a private chain cmux created below HOME")
    func cliIsOnPathOnlyFromAPrivateChain() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let cli = sandbox.cliDirectory
        #expect(cli.hasPrefix(sandbox.home + "/.cmux-ssh/"), "\(cli)")
        let path = try sandbox.fakeGroupDatabase(nil)
        // A macOS login shell's path_helper reorders PATH, so look at what `cmux` is.
        let probe = "echo \"cmux=[$(command -v cmux)] path=[$PATH]\"\n"
        let first = try sandbox.runLoginShell(input: probe, extraEnvironment: ["PATH": path])
        #expect(first.stdout.contains("cmux=[\(cli)/cmux]"), "\(first.stdout)")
        // A parent someone else can write: PATH is left alone.
        let parent = ((cli as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: parent)
        let open = try sandbox.runLoginShell(input: probe, extraEnvironment: ["PATH": path])
        #expect(!open.stdout.contains(cli), "\(open.stdout)")
        #expect(open.stdout.contains("cmux=[]"), "\(open.stdout)")
        // So is a CLI file someone else can rewrite.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: cli + "/cmux")
        let writable = try sandbox.runLoginShell(input: probe, extraEnvironment: ["PATH": path])
        #expect(!writable.stdout.contains(cli), "\(writable.stdout)")
    }

    @Test("The configured-command launch also leaves PATH alone when the CLI chain is not private")
    func configuredCommandCliNeedsAPrivateChain() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let cli = sandbox.cliDirectory
        let path = try sandbox.fakeGroupDatabase(nil)
        let launch = ShellSandbox.connection().commandArguments("echo \"cmux=[$(command -v cmux)] path=[$PATH]\"")
        let ok = try sandbox.runLoginShell(input: "", extraEnvironment: ["PATH": path], launch: launch)
        #expect(ok.stdout.contains("cmux=[\(cli)/cmux]"), "\(ok.stdout) \(ok.stderr)")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: sandbox.home)
        let open = try sandbox.runLoginShell(input: "", extraEnvironment: ["PATH": path], launch: launch)
        #expect(!open.stdout.contains(cli) && open.stdout.contains("cmux=[]"), "\(open.stdout) \(open.stderr)")
    }

    @Test("Nothing is installed through a symlinked ~/.cmux-ssh")
    func installSkipsASymlinkedRoot() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let elsewhere = sandbox.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox.home + "/.cmux-ssh", withDestinationPath: elsewhere)
        let path = try sandbox.fakeGroupDatabase(nil)
        let result = try sandbox.runLoginShell(input: "echo \"cmux=[$(command -v cmux)] zdotdir=[${ZDOTDIR-unset}]\"\n", extraEnvironment: ["PATH": path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
        #expect(result.stdout.contains("cmux=[] zdotdir=[unset]"), "\(result.stdout)")
    }

    static let refusalNotice = "cmux: shell integration disabled: "

    /// A refused chain costs the terminal `cmux open` and the Files panel's `cd`
    /// tracking; one line says why, HOME-relative, once per terminal.
    @Test("A refused chain prints one HOME-relative line; a private one prints none")
    func refusalIsReportedOnce() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            let path = try sandbox.fakeGroupDatabase(nil)
            let fine = try sandbox.runLoginShell(input: "true\n", extraEnvironment: ["PATH": path])
            #expect(!fine.stderr.contains(Self.refusalNotice), "\(name): \(fine.stderr)")
            // Both the CLI and the hook are refused here; one line covers them.
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: sandbox.home)
            let refused = try sandbox.runLoginShell(input: "true\n", extraEnvironment: ["PATH": path])
            let lines = refused.stderr.components(separatedBy: "\n").filter { $0.contains(Self.refusalNotice) }
            #expect(lines.count == 1, "\(name): \(refused.stderr)")
            #expect(lines.first?.hasPrefix(Self.refusalNotice + "~ ") == true, "\(name): \(lines)")
            #expect(lines.first?.contains("cmux open") == true, "\(name): \(lines)")
            #expect(!refused.stderr.contains(sandbox.home), "\(name): \(refused.stderr)")
            // Only the hook refused: the line names the file, below HOME.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.home)
            let env = sandbox.hookDirectory + "/" + (name == "bash" ? "shell/bash-env" : "shell/zsh/.zshenv")
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: env)
            let hook = try sandbox.runLoginShell(input: "true\n", extraEnvironment: ["PATH": path])
            let relative = "~/" + env.dropFirst(sandbox.home.count + 1)
            #expect(hook.stderr.components(separatedBy: "\n").filter { $0.contains(Self.refusalNotice + relative + " ") }.count == 1,
                    "\(name): \(hook.stderr)")
        }
    }

    @Test("A symlinked ~/.cmux-ssh is reported; a configured command's output never is")
    func refusalNoticeCases() throws {
        let sandbox = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let path = try sandbox.fakeGroupDatabase(nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: sandbox.home)
        let configured = try sandbox.runLoginShell(input: "", extraEnvironment: ["PATH": path],
                                                   launch: ShellSandbox.connection().commandArguments("echo done"))
        #expect(configured.stdout.contains("done"), "\(configured.stdout) \(configured.stderr)")
        #expect(!configured.stderr.contains(Self.refusalNotice), "\(configured.stderr)")
        #expect(!configured.stdout.contains(Self.refusalNotice), "\(configured.stdout)")

        let fresh = try ShellSandbox(shell: "/bin/zsh", name: "zsh")
        let elsewhere = fresh.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fresh.home + "/.cmux-ssh", withDestinationPath: elsewhere)
        let linked = try fresh.runLoginShell(input: "true\n", extraEnvironment: ["PATH": try fresh.fakeGroupDatabase(nil)])
        let lines = linked.stderr.components(separatedBy: "\n").filter { $0.contains(Self.refusalNotice) }
        #expect(lines.count == 1 && lines.first?.hasPrefix(Self.refusalNotice + "~/.cmux-ssh ") == true, "\(linked.stderr)")
    }

    static let setfacl: String? = ["/usr/bin/setfacl", "/bin/setfacl"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// POSIX ACLs (Linux): a named entry that can write HOME or the hook chain
    /// could swap the sourced file. Each case keeps the plain launch, also when
    /// the group database calls the user's group private.
    @Test("An ACL that lets someone else write HOME or the hook chain keeps the plain login launch",
          .enabled(if: setfacl != nil, "needs setfacl (Linux)"))
    func aclWritableChainStaysPlain() throws {
        guard let setfacl = Self.setfacl else { return }
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        // (ACL, where, before the first install)
        let cases: [(String, String, Bool)] = [
            ("u:nobody:rwx", "", false), ("g:nobody:rwx", "", false), ("d:u:nobody:rwx", "", true),
            ("u:nobody:rwx", "/.cmux-ssh", false),
        ]
        for (shell, name) in shells where FileManager.default.isExecutableFile(atPath: shell) {
            for (acl, relative, before) in cases {
                let sandbox = try ShellSandbox(shell: shell, name: name)
                let target = try sandbox.makeDirectory("t")
                let path = try sandbox.fakeGroupDatabase("\(NSUserName()):x:\(getgid()):")
                let apply = { _ = try sandbox.run([setfacl, "-m", acl, sandbox.home + relative], environment: [:], input: "") }
                if before { try apply() }
                _ = try sandbox.runLoginShell(input: "true\n", extraEnvironment: ["PATH": path])
                if !before { try apply() }
                let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho \"env=[${ENV-unset}] zdotdir=[${ZDOTDIR-unset}]\"\n",
                                                       extraEnvironment: ["PATH": path])
                #expect(result.reportedDirectories.isEmpty, "\(name) \(acl) on ~\(relative): \(result.stdout.debugDescription)")
                #expect(result.stdout.contains("env=[unset] zdotdir=[unset]"), "\(name) \(acl) on ~\(relative): \(result.stdout)")
            }
        }
    }

    /// Two terminals that start together both install. GNU find exits 1 when
    /// an entry it listed is gone by the time it looks at it, as another
    /// installer's temporary file is once renamed. The fake find does that for
    /// every walk of a directory's contents, so only a check that looks at the
    /// files it relies on, and not at what else is in the directory, passes.
    @Test("Another installer's temporary files in the install directory do not stop the hook")
    func concurrentInstallerDoesNotStopTheHook() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            let target = try sandbox.makeDirectory("t")
            _ = try sandbox.runLoginShell(input: "true\n")
            let path = try sandbox.fakeGroupDatabase(nil)
            try sandbox.writeExecutable(sandbox.fakeBin + "/find", """
                #!/bin/sh
                for a in "$@"; do [ "$a" = -prune ] && exec /usr/bin/find "$@"; done
                /usr/bin/find "$@"
                echo "find: '$1/shell/bash-env.4242': No such file or directory" >&2
                exit 1

                """)
            let result = try sandbox.runLoginShell(input: "cd '\(target)'\necho marker-done\n", extraEnvironment: ["PATH": path])
            #expect(result.stdout.contains("marker-done"), "\(name): \(result.stderr)")
            #expect(result.reportedDirectories.last == target, "\(name): \(result.stdout.debugDescription)")
        }
    }

    @Test("A directory name with control characters is not reported")
    func controlCharactersAreNotReported() throws {
        var shells: [(String, String)] = [("/bin/zsh", "zsh")]
        if let bash = Self.gnuBash { shells.append((bash, "bash")) }
        for (shell, name) in shells {
            let sandbox = try ShellSandbox(shell: shell, name: name)
            _ = try sandbox.makeDirectory("evil\u{1b}]0;PWNED\u{07}x")
            _ = try sandbox.makeDirectory("nl\nPWNED")
            let result = try sandbox.runLoginShell(input: "cd \"$(printf 'evil\\033]0;PWNED\\007x')\"\ncd ..\ncd nl?PWNED\necho marker-done\n")
            #expect(result.stdout.contains("marker-done"), "\(name): \(result.stderr)")
            #expect(result.reportedDirectories == [sandbox.work], "\(name): \(result.stdout.debugDescription)")
            #expect(!result.stdout.contains("\u{1b}]0;"), "\(name): \(result.stdout.debugDescription)")
        }
    }

    @Test("bash: a child shell that inherits PROMPT_COMMAND does not look the hook up", .enabled(if: gnuBash != nil, "needs a bash that honors ENV in POSIX mode (CMUX_TEST_GNU_BASH)"))
    func bashChildShellSkipsMissingHook() throws {
        let bash = try #require(Self.gnuBash)
        let sandbox = try ShellSandbox(shell: bash, name: "bash")
        try sandbox.append("export PROMPT_COMMAND='true'", to: sandbox.home + "/.bash_profile")
        let child = "printf '%s\\n' 'command_not_found_handle() { echo \"lookup:$1\"; return 127; }' 'true' 'true' | \(bash) --norc -i 2>/dev/null\n"
        let result = try sandbox.runLoginShell(input: child + "echo marker-done\n")
        #expect(result.stdout.contains("marker-done"), "\(result.stderr)")
        #expect(!result.stdout.contains("lookup:"), "\(result.stdout)")
    }

    @Test("The configured-command launch is not changed")
    func configuredCommandUnchanged() throws {
        let argv = ShellSandbox.connection().commandArguments("echo hi")
        #expect(argv.dropLast(2).last?.hasSuffix("exec \"${SHELL:-/bin/sh}\" -lc \"$1\"") == true)
    }
}

/// A temporary HOME and work directory, and a login shell wrapper.
private final class ShellSandbox {
    let root: String
    private let homeName: String
    var home: String { root + "/" + homeName }
    var work: String { root + "/work" }
    var logPath: String { root + "/startup.log" }
    private let wrapper: String?

    /// `shell` is the real shell; the wrapper at `bin/<name>` adds `-i` last
    /// (bash needs its long options first).
    init(shell: String?, name: String?, homeName: String = "home") throws {
        let root = ShellSandbox.canonical(NSTemporaryDirectory()) + "/cmux-sh-\(UUID().uuidString.prefix(8))"
        self.root = root
        self.homeName = homeName
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

    /// The launch before shell integration: the host `cmux` install, then `exec "$SHELL" -l`.
    static var plainLaunch: [String] {
        ["/bin/sh", "-c", connection().hostOpenCommand.shellPrelude + "exec \"${SHELL:-/bin/sh}\" -l"]
    }

    func runLoginShell(input: String, extraEnvironment: [String: String] = [:], umask: String? = nil,
                       launch: [String]? = nil) throws -> ShellResult {
        let shell = try #require(wrapper)
        let environment = environment(shell: shell).merging(extraEnvironment) { _, new in new }
        var argv = launch ?? launchCommand
        if let umask { argv = ["/bin/sh", "-c", "umask \(umask); exec \"$@\"", "sh"] + argv }
        return try run(argv, environment: environment, input: input + "exit\n")
    }

    /// The host `cmux` install directory under this HOME.
    var installDirectory: String {
        home + "/" + Self.connection().hostOpenCommand.installDirectory.replacingOccurrences(of: "$HOME/", with: "")
    }

    /// Commands that stand in for the host's, first on PATH.
    var fakeBin: String { root + "/fakebin" }

    /// A `getent` that answers `group <gid>` with `line` (`name:x:gid:members`),
    /// or finds no group for nil. Returns the PATH that uses it.
    func fakeGroupDatabase(_ line: String?) throws -> String {
        try FileManager.default.createDirectory(atPath: fakeBin, withIntermediateDirectories: true)
        let answer = line.map { "[ \"$1\" = group ] && [ \"$2\" = \(getgid()) ] && { echo '\($0)'; exit 0; }\n" } ?? ""
        try writeExecutable(fakeBin + "/getent", "#!/bin/sh\n\(answer)exit 2\n")
        return fakeBin + ":/usr/bin:/bin"
    }

    /// New directories take their parent's group on macOS; make the hook files,
    /// its files and each parent up to HOME the user's primary group.
    func giveHookChainTheUsersGroup() throws {
        var paths = [home]
        var parent = hookDirectory
        while parent != home {
            paths.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        if let walk = FileManager.default.enumerator(atPath: hookDirectory) {
            for case let relative as String in walk { paths.append(hookDirectory + "/" + relative) }
        }
        for path in paths where chown(path, uid_t.max, getgid()) != 0 {
            throw POSIXError(.EPERM)
        }
    }

    /// The host `cmux` directory under this HOME.
    var cliDirectory: String {
        home + "/" + Self.connection().hostOpenCommand.installDirectory.replacingOccurrences(of: "$HOME/", with: "")
    }

    /// Where the sourced shell files are installed under this HOME.
    var hookDirectory: String {
        home + "/" + Self.connection().hostOpenCommand.shellIntegrationDirectory.replacingOccurrences(of: "$HOME/", with: "")
    }

    func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func makeHomeReadOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home)
    }

    func makeHomeWritable() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
    }

    static var hostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        return String(cString: buffer)
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

    /// The OSC 7 reports, in order (`ESC ] 7 ; kitty-shell-cwd://host/path BEL`).
    private var reports: [(host: String, path: String)] {
        let prefix = "\u{1b}]7;kitty-shell-cwd://"
        return stdout.components(separatedBy: prefix).dropFirst().compactMap { chunk in
            guard let end = chunk.firstIndex(of: "\u{07}") else { return nil }
            let url = chunk[..<end]
            guard let slash = url.firstIndex(of: "/") else { return nil }
            return (String(url[..<slash]), String(url[slash...]))
        }
    }

    var reportedDirectories: [String] { reports.map(\.path) }
    var reportedHosts: [String] { reports.map(\.host) }
}
