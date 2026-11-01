import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Find in Files over SSH: the remote command, run through real local shells the
/// way a remote login shell receives it, and the parsing of its output.
@Suite(.serialized)
struct SSHFileSearchTests {
    /// Quote, `$`, `!`, backslash, double quote and a precomposed letter.
    private static let hostileQuery = "it's $HOME! \\ \"q\" \u{E9}"

    // MARK: Command construction

    @Test
    func testCommandsWrapAQuotedShScriptWithoutRawUserText() {
        let root = "/home/dev/it's $HOME! \u{E9}"
        let commands = [
            SSHFileSearchCommand.contentSearch(query: Self.hostileQuery, rootPath: root, remoteTimeoutSeconds: 27),
            SSHFileSearchCommand.contentSearch(query: "Upper", rootPath: root, remoteTimeoutSeconds: 27),
            SSHFileSearchCommand.fileList(rootPath: root, maxDepth: 8, remoteTimeoutSeconds: 18, watchdog: true),
            SSHFileSearchCommand.fileList(rootPath: root, maxDepth: 8, remoteTimeoutSeconds: 18, watchdog: false),
        ]
        for search in commands {
            let command = search.command
            #expect(command.hasPrefix("sh -c '"))
            #expect(command.hasSuffix("'"))
            let script = command.dropFirst("sh -c '".count).dropLast()
            #expect(!script.contains("'"))
            #expect(!script.contains("\\"))
            #expect(!script.contains("!"))
            #expect(!script.contains("\n"))
            #expect(!script.contains("$HOME"))
            #expect(command.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(script.contains(Data(root.utf8).base64EncodedString()))
        }
        let content = commands[0].command
        #expect(content.contains(Data(Self.hostileQuery.utf8).base64EncodedString()))
        #expect(content.contains("command -v rg"))
        #expect(content.contains("rg --json"))
        #expect(content.contains("grep -rnIsF --null"))
        #expect(content.contains("--exclude-dir=node_modules"))
        // No rg but a Git work tree: git grep, which honours .gitignore (a
        // gitignored .venv must not fill the result cap before the sources).
        #expect(content.contains(SSHFileSearchCommand.gitGrepMarker))
        #expect(content.contains("grep -nIF -z --untracked --exclude-standard"))
        // An empty fsmonitor is "off" on every git; before 2.36 "false" names a hook to run.
        #expect(content.contains("g=\"git -c core.fsmonitor= -c core.untrackedCache=false\""))
        #expect(!content.contains("core.fsmonitor=false"))
        #expect(content.contains("[ \"$($g rev-parse --is-inside-work-tree 2>/dev/null)\" = true ]"))
        // The whole git grep call: under timeout and nice, output-changing config off,
        // the query quoted, every excluded directory but .git as a pathspec.
        let lowercase = SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/r", remoteTimeoutSeconds: 5).command
        #expect(lowercase.contains(
            "$w nice -n 10 $g -c color.grep=false -c grep.fullName=false -c grep.column=false "
                + "grep -nIF -z --untracked --exclude-standard -i -e \"$q\" -- . "
                + "\":(exclude,glob)**/node_modules/**\" \":(exclude,glob)**/dist/**\" "
                + "\":(exclude,glob)**/build/**\" \":(exclude,glob)**/DerivedData/**\";"
        ))
        #expect(!content.contains(":(exclude,glob)**/.git/**"))
        // grep --exclude-dir also skips a root of that name, so the root's own name is dropped.
        let buildRoot = SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/p/build", remoteTimeoutSeconds: 5).command
        #expect(!buildRoot.contains("--exclude-dir=build"))
        #expect(buildRoot.contains("--exclude-dir=node_modules"))
        let venvRoot = SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/p/.venv/", remoteTimeoutSeconds: 5).command
        #expect(!venvRoot.contains("--exclude-dir=.venv"))
        #expect(venvRoot.contains("--exclude-dir=build"))
        // Outside a work tree, plain grep also skips virtualenvs and caches.
        for name in [".venv", "venv", "__pycache__", ".cache"] {
            #expect(content.contains("--exclude-dir=\(name)"), "\(name)")
        }
        #expect(content.contains("nice -n 10"))
        #expect(content.contains("timeout 27"))
    }

    @Test
    func testSmartCaseMatchesRipgrep() {
        #expect(SSHFileSearchCommand.isCaseInsensitive(query: "hello world"))
        #expect(!SSHFileSearchCommand.isCaseInsensitive(query: "Hello"))
        #expect(SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/r", remoteTimeoutSeconds: 5)
            .command.contains("grep -rnIsF --null $lb -i "))
        #expect(SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/r", remoteTimeoutSeconds: 5)
            .command.contains("--exclude-standard -i "))
        #expect(!SSHFileSearchCommand.contentSearch(query: "aBc", rootPath: "/r", remoteTimeoutSeconds: 5)
            .command.contains(" -i "))
    }

    // MARK: Running through login shells

    @Test
    func testGrepFallbackFindsLiteralMatchesInEveryShell() throws {
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(found.format == .grep, "shell \(shell)")
            #expect(found.status == .matches, "shell \(shell)")
            #expect(found.relativePaths == ["dir/a:b.txt", "Upper.txt"], "shell \(shell)")
            let colonMatch = try #require(found.results.first { $0.relativePath == "dir/a:b.txt" })
            #expect(colonMatch.lineNumber == 2)
            #expect(colonMatch.columnNumber == 5)
            #expect(colonMatch.preview == "say hello: there")
            #expect(colonMatch.path == root.path + "/dir/a:b.txt")
        }
    }

    @Test
    func testGrepFallbackKeepsHostileQueriesLiteral() throws {
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in Self.availableShells {
            let found = try Self.search(Self.hostileQuery, root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(found.relativePaths == ["hostile.txt"], "shell \(shell)")
            let upper = try Self.search("HELLO", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(upper.relativePaths == ["Upper.txt"], "shell \(shell)")
            let none = try Self.search("absent-needle", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(none.status == .noMatches, "shell \(shell)")
        }
    }

    @Test
    func testRipgrepPathFindsTheSameMatchesWhenAvailable() throws {
        guard let ripgrep = RipgrepExecutableResolver.resolve() else { return }
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ripgrep.url.deletingLastPathComponent().path + ":" + Self.pathWithoutRipgrep
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: root.path, shell: shell, path: path)
            #expect(found.format == .ripgrep, "shell \(shell)")
            #expect(found.status == .matches, "shell \(shell)")
            #expect(found.relativePaths == ["dir/a:b.txt", "Upper.txt"], "shell \(shell)")
            let colonMatch = try #require(found.results.first { $0.relativePath == "dir/a:b.txt" })
            #expect(colonMatch.lineNumber == 2)
            #expect(colonMatch.columnNumber == 5)
            let hostile = try Self.search(Self.hostileQuery, root: root.path, shell: shell, path: path)
            #expect(hostile.relativePaths == ["hostile.txt"], "shell \(shell)")
        }
    }

    @Test
    func testMissingRootReportsFolderNotFound() throws {
        let found = try Self.search("x", root: "/nonexistent-cmux-\(UUID().uuidString)", shell: "/bin/sh",
                                    path: Self.pathWithoutRipgrep)
        #expect(found.status == .failed(SSHFileSearchMessages.folderNotFound))
    }

    @Test
    func testWatchdogStopsTheRemoteCommandWhenTheClientGoesAway() throws {
        let token = "31.\(Int.random(in: 1_000...9_999))"
        let command = SSHRemoteShellScript.command(lines: ["sleep \(token)", "exit 7"], watchdog: true)
        for shell in Self.availableShells {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", Self.setsidExec, shell] + (shell.hasSuffix("csh") ? ["-f", "-c", command] : ["-c", command])
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            Thread.sleep(forTimeInterval: 0.4)
            #expect(Self.processCount(matching: "sleep \(token)") == 1, "shell \(shell)")
            // ssh going away closes the channel: the remote stdin hits EOF.
            try stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            #expect(!process.isRunning, "shell \(shell)")
            Thread.sleep(forTimeInterval: 0.2)
            #expect(Self.processCount(matching: "sleep \(token)") == 0, "shell \(shell)")
            if process.isRunning { process.terminate() }
        }
        // A finished body keeps its exit status with the watchdog in place.
        let quick = SSHRemoteShellScript.command(lines: ["exit 7"], watchdog: true)
        let quickRun = try Self.run(quick, shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(quickRun.status == 7)
        #expect(SSHFileSearchCommand.contentSearch(query: "q", rootPath: "/r", remoteTimeoutSeconds: 5).command
            .contains("kill 0"))
    }

    @Test
    func testWatchdogReachesTheToolThroughAGNUStyleTimeout() throws {
        // GNU `timeout` moves its child into a process group of its own unless
        // given --foreground. GNU forwards the watchdog's SIGTERM to that child,
        // but a `timeout` that doesn't would hide the tool from `kill 0`; this
        // fake models that one.
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-fake-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let fake = """
        #!/usr/bin/perl
        if ($ARGV[0] eq "--foreground") { shift; shift; exec @ARGV or exit 127; }
        setpgrp(0, 0); shift;
        my $pid = fork();
        if ($pid == 0) { exec @ARGV or exit 127; }
        waitpid($pid, 0); exit($? >> 8);

        """
        let fakeURL = bin.appendingPathComponent("timeout")
        try Data(fake.utf8).write(to: fakeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)
        let token = "33.\(Int.random(in: 1_000...9_999))"
        let command = SSHRemoteShellScript.command(
            lines: [SSHRemoteShellScript.timeoutPrefix(seconds: 20), "$w sleep \(token)"],
            watchdog: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.setsidExec, "/bin/sh", "-c", command]
        process.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 0.5)
        #expect(Self.processCount(matching: "sleep \(token)") == 1)
        try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(Self.processCount(matching: "sleep \(token)") == 0)
        if process.isRunning { process.terminate() }
    }

    @Test
    func testBannersBeforeTheMarkerAreIgnored() throws {
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = SSHFileSearchCommand.contentSearch(query: "hello", rootPath: root.path, remoteTimeoutSeconds: 20)
        for banner in ["printf Welcome; ", "echo conda activated; "] {
            let output = try Self.run(banner + command.command, shell: "/bin/sh", path: Self.pathWithoutRipgrep)
            var accumulator = SSHFileSearchAccumulator(rootPath: root.path, query: "hello", maxResults: 500, snapshotInterval: 60)
            _ = accumulator.consume(output.stdout)
            let update = accumulator.finish(status: output.status)
            #expect(update.status == .matches, "banner \(banner)")
            #expect(update.results.count == 2, "banner \(banner)")
        }
    }

    @Test
    func testBusyBoxStyleTimeoutStillRuns() throws {
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // BusyBox before 1.30: only `timeout -t N cmd ...`.
        let fake = "#!/bin/sh\n[ \"$1\" = -t ] || exit 1\nshift 2\nexec \"$@\"\n"
        let fakeURL = bin.appendingPathComponent("timeout")
        try Data(fake.utf8).write(to: fakeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)
        let found = try Self.search("hello", root: root.path, shell: "/bin/sh", path: bin.path + ":" + Self.pathWithoutRipgrep)
        #expect(found.status == .matches)
        #expect(found.relativePaths == ["dir/a:b.txt", "Upper.txt"])
    }

    @Test
    func testMissingMarkerAndDecodeFailuresAreFailures() {
        func finish(_ status: Int32, output: String) -> FileSearchSnapshot.Status {
            var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 60)
            _ = accumulator.consume(Data(output.utf8))
            return accumulator.finish(status: status).status
        }
        #expect(finish(0, output: "") == .failed(SSHFileSearchMessages.didNotRun))
        #expect(finish(1, output: "motd line\n") == .failed(SSHFileSearchMessages.didNotRun))
        #expect(finish(65, output: "") == .failed(SSHFileSearchMessages.decodeFailed))
        #expect(finish(2, output: "") != .noMatches)
        #expect(finish(0, output: "Welcome" + SSHFileSearchCommand.grepMarker + "\n") == .noMatches)
    }

    @Test
    func testHugeLinesAreSkippedWithoutQuadraticRescans() {
        var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 0)
        _ = accumulator.consume(Data((SSHFileSearchCommand.grepMarker + "\n").utf8))
        var head = Data("/r/min.js".utf8)
        head.append(0)
        head.append(contentsOf: Array("1:".utf8))
        _ = accumulator.consume(head)
        let chunk = Data(repeating: UInt8(ascii: "n"), count: 32 * 1024)
        let started = Date()
        for _ in 0..<128 { _ = accumulator.consume(chunk) } // a 4 MB line
        _ = accumulator.consume(Data("\n".utf8) + Self.grepLine("/r/ok", 3, "n"))
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(accumulator.finish(status: 0).results.map(\.relativePath) == ["ok"])
    }

    @Test
    func testGitWorkTreesSearchWithGitGrepAndSkipIgnoredTrees() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let root = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(found.format == .gitGrep, "shell \(shell)")
            #expect(found.status == .matches, "shell \(shell)")
            // Tracked and untracked files; not the gitignored .venv, not node_modules.
            #expect(found.relativePaths == ["dir/a:b.sv", "new.sv", "r\u{E9}sum\u{E9}.sv", "Upper.sv"], "shell \(shell)")
            let colonMatch = try #require(found.results.first { $0.relativePath == "dir/a:b.sv" })
            #expect(colonMatch.path == root.path + "/dir/a:b.sv")
            #expect(colonMatch.lineNumber == 2)
            #expect(colonMatch.columnNumber == 5)
            #expect(colonMatch.preview == "say hello: there")
            // Smart case: an uppercase query is case-sensitive.
            let upper = try Self.search("HELLO", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(upper.relativePaths == ["Upper.sv"], "shell \(shell)")
            let none = try Self.search("absent-needle", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(none.format == .gitGrep, "shell \(shell)")
            #expect(none.status == .noMatches, "shell \(shell)")
        }
        // A root below the top of the work tree: paths are relative to the root searched.
        let sub = try Self.search("hello", root: root.path + "/dir", shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(sub.format == .gitGrep)
        #expect(sub.relativePaths == ["a:b.sv"])
        #expect(sub.results.first?.path == root.path + "/dir/a:b.sv")
    }

    @Test
    func testTheListingChecksThatRevParseSaysTrue() {
        let list = SSHFileSearchCommand.fileList(rootPath: "/r", maxDepth: 8, remoteTimeoutSeconds: 5, watchdog: false).command
        #expect(list.contains("g=\"git -c core.fsmonitor= -c core.untrackedCache=false\""))
        #expect(list.contains("[ \"$($g rev-parse --is-inside-work-tree 2>/dev/null)\" = true ]"))
    }

    @Test
    func testGitGrepIsOnlyUsedWhereItSeesWhatRipgrepWould() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        // An ignored root (a gitignored .venv, a build/ folder): git grep would
        // find nothing in it, so grep searches it, as rg would.
        let root = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let ignored = try Self.search("hello", root: root.path + "/.venv", shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(ignored.format == .grep)
        #expect(ignored.relativePaths == ["lib/site.py"])
        // Inside .git, rev-parse prints "false" (exit 0): not a work tree.
        let dotGit = try Self.search("hello", root: root.path + "/.git", shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(dotGit.format == .grep)
        let listing = try Self.run(
            SSHFileSearchCommand.fileList(rootPath: root.path + "/.git", maxDepth: 4, remoteTimeoutSeconds: 10, watchdog: false).command,
            shell: "/bin/sh", path: Self.pathWithoutRipgrep
        )
        #expect(listing.stdout.contains(Data((SSHFileSearchCommand.findListMarker + "\n").utf8)))

        // A nested repository: git grep treats it as one opaque directory.
        let nested = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: nested) }
        let inner = nested.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("hello from a nested repo\n".utf8).write(to: inner.appendingPathComponent("n.sv"))
        let innerInit = try Self.run("git init -q .", shell: "/bin/sh", path: "/usr/bin:/bin", directory: inner.path)
        #expect(innerInit.status == 0)
        let withNested = try Self.search("hello", root: nested.path, shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(withNested.format == .grep)
        #expect(withNested.relativePaths.contains("inner/n.sv"))

        // A submodule (a gitlink in the index): git grep wouldn't descend into it.
        let submodule = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: submodule) }
        let gitlink = try Self.run(
            "git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,mod",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: submodule.path
        )
        #expect(gitlink.status == 0)
        let withSubmodule = try Self.search("hello", root: submodule.path, shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(withSubmodule.format == .grep)
    }

    @Test
    func testGitGrepFallsBackWhereCheckIgnoreAndQuotingMissIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        // A folder .gitignore lists but that holds tracked files (committed
        // before the rule, or force-added): plain check-ignore says "not
        // ignored", yet git grep --untracked --exclude-standard finds nothing
        // in it. rg, given that folder as its root, searches it.
        let tracked = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: tracked) }
        for relativePath in ["gen/g.sv", "build/sub/b.sv"] {
            let url = tracked.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello generated\n".utf8).write(to: url)
        }
        let addIgnored = try Self.run(
            "git add gen/g.sv && printf 'gen/\\nbuild\\n' >> .gitignore && git add -f build/sub/b.sv",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: tracked.path
        )
        #expect(addIgnored.status == 0)
        for shell in Self.availableShells {
            for (root, expected) in [("gen", "g.sv"), ("build", "sub/b.sv"), ("build/sub", "b.sv")] {
                let found = try Self.search("hello", root: tracked.path + "/" + root, shell: shell, path: Self.pathWithoutRipgrep)
                #expect(found.format == .grep, "\(root), shell \(shell)")
                #expect(found.relativePaths == [expected], "rg searches an explicitly opened ignored folder: \(root), shell \(shell)")
            }
            // The work-tree top level keeps git grep (rg skips those tracked files there too).
            let top = try Self.search("hello", root: tracked.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(top.format == .gitGrep, "shell \(shell)")
        }

        // Nested repositories whose names git quotes in ls-files output.
        for name in ["r\u{E9}sum\u{E9}", "q\"x", "back\\slash", "tab\tname"] {
            let nested = try Self.makeGitSearchTree()
            defer { try? FileManager.default.removeItem(at: nested) }
            let inner = nested.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            try Data("hello nested\n".utf8).write(to: inner.appendingPathComponent("n.sv"))
            // An untracked file listed after the repository, so its entry is not the last one.
            try Data("plain\n".utf8).write(to: nested.appendingPathComponent("zz.sv"))
            let innerInit = try Self.run("git init -q .", shell: "/bin/sh", path: "/usr/bin:/bin", directory: inner.path)
            #expect(innerInit.status == 0)
            for shell in Self.availableShells {
                let found = try Self.search("hello", root: nested.path, shell: shell, path: Self.pathWithoutRipgrep)
                #expect(found.format == .grep, "nested repo \(name), shell \(shell)")
                #expect(found.relativePaths.contains(name + "/n.sv"), "nested repo \(name), shell \(shell)")
            }
        }
    }

    @Test
    func testNestedRepoCheckWorksWhenGrepPrintsNothingForBinaryInput() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        // GNU grep 3.5+ (Linux hosts) prints nothing on stdout for input with a
        // NUL; BSD grep prints "Binary file ... matches", which hides a missing tr.
        let shim = try Self.makeGNULikeGrepShim()
        defer { try? FileManager.default.removeItem(at: shim) }
        let nested = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: nested) }
        let inner = nested.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("hello nested\n".utf8).write(to: inner.appendingPathComponent("n.sv"))
        let innerInit = try Self.run("git init -q .", shell: "/bin/sh", path: "/usr/bin:/bin", directory: inner.path)
        #expect(innerInit.status == 0)
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: nested.path, shell: shell, path: shim.path + ":" + Self.pathWithoutRipgrep)
            #expect(found.format == .grep, "GNU-like grep, shell \(shell)")
            #expect(found.relativePaths.contains("plain/n.sv"), "GNU-like grep, shell \(shell)")
        }
    }

    @Test
    func testNestedRepoAndSubmoduleNamesThatAreNotUTF8StillFallBack() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        // GNU grep in a UTF-8 locale treats a matching line holding invalid
        // UTF-8 (a Latin-1 "été") as binary and prints nothing on stdout.
        // APFS refuses such names, so a git shim adds the entry a Linux host's
        // `ls-files -z -o` would print for a nested repository named n\351t\351.
        let shim = try Self.makeGNULikeGrepShim()
        defer { try? FileManager.default.removeItem(at: shim) }
        let git = shim.appendingPathComponent("git")
        try Data("""
        #!/bin/sh
        case " $* " in
        *" ls-files -z -o "*) /usr/bin/git "$@" || exit; printf 'n\\351t\\351/\\000'; exit 0 ;;
        esac
        exec /usr/bin/git "$@"

        """.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        let nested = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: nested) }
        // A submodule named m\351, listed raw because the user's config sets core.quotePath=false.
        // Its own shim has no git wrapper, so only the submodule check can catch it.
        let grepOnly = try Self.makeGNULikeGrepShim()
        defer { try? FileManager.default.removeItem(at: grepOnly) }
        let submodule = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: submodule) }
        let gitlink = try Self.run(
            "git config core.quotePath false && git update-index --add --cacheinfo "
                + "\"160000,1111111111111111111111111111111111111111,$(printf 'm\\351')\"",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: submodule.path
        )
        #expect(gitlink.status == 0)
        for shell in Self.availableShells {
            let withNested = try Self.search("hello", root: nested.path, shell: shell, path: shim.path + ":" + Self.pathWithoutRipgrep)
            #expect(withNested.format == .grep, "non-UTF-8 nested repo, shell \(shell)")
            let withSubmodule = try Self.search("hello", root: submodule.path, shell: shell, path: grepOnly.path + ":" + Self.pathWithoutRipgrep)
            #expect(withSubmodule.format == .grep, "non-UTF-8 submodule, shell \(shell)")
        }
    }

    @Test
    func testAnIgnoredNestedRepoKeepsGitGrep() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        // A repository cloned into an ignored folder (deps/ in .gitignore):
        // rg skips it, so git grep keeps the root and its ignore rules.
        let root = try Self.makeGitSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dep = root.appendingPathComponent("deps/dep")
        try FileManager.default.createDirectory(at: dep, withIntermediateDirectories: true)
        try Data("hello from an ignored dependency\n".utf8).write(to: dep.appendingPathComponent("d.sv"))
        let setup = try Self.run(
            "printf 'deps/\\n' >> .gitignore && (cd deps/dep && git init -q .)",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: root.path
        )
        #expect(setup.status == 0)
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(found.format == .gitGrep, "shell \(shell)")
            #expect(!found.relativePaths.contains("deps/dep/d.sv"), "shell \(shell)")
        }
    }

    @Test
    func testGitGrepIgnoresTheRepositorysOwnConfig() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let root = try Self.makeGitSearchTree(hostileConfig: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(".git/ran")
        for shell in Self.availableShells {
            let found = try Self.search("hello", root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(found.format == .gitGrep, "shell \(shell)")
            #expect(found.relativePaths == ["dir/a:b.sv", "new.sv", "r\u{E9}sum\u{E9}.sv", "Upper.sv"], "shell \(shell)")
            let colonMatch = try #require(found.results.first { $0.relativePath == "dir/a:b.sv" })
            #expect(colonMatch.lineNumber == 2)
            #expect(colonMatch.preview == "say hello: there", "no colour codes, no column field")
            let sub = try Self.search("hello", root: root.path + "/dir", shell: shell, path: Self.pathWithoutRipgrep)
            #expect(sub.relativePaths == ["a:b.sv"], "grep.fullName stays off, shell \(shell)")
            // The query stays literal through git grep too (and beats patternType=perl).
            let hostile = try Self.search(Self.hostileQuery, root: root.path, shell: shell, path: Self.pathWithoutRipgrep)
            #expect(hostile.format == .gitGrep, "shell \(shell)")
            #expect(hostile.relativePaths == ["hostile.sv"], "shell \(shell)")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "repository config ran a command, shell \(shell)")
        }
    }

    @Test
    func testGrepOutsideAWorkTreeSkipsVirtualenvsAndCaches() throws {
        let root = try Self.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for relativePath in [".venv/lib/site.py", "venv/x.py", "pkg/__pycache__/m.py", ".cache/c.txt"] {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("hello from \(relativePath)\n".utf8).write(to: url)
        }
        let found = try Self.search("hello", root: root.path, shell: "/bin/sh", path: Self.pathWithoutRipgrep)
        #expect(found.format == .grep)
        #expect(found.relativePaths == ["dir/a:b.txt", "Upper.txt"])
    }

    // MARK: Parsing

    @Test
    func testGitGrepLinesHaveANulAfterTheLineNumberAndPathsRelativeToTheRoot() {
        var parser = SSHFileSearchLineParser(rootPath: "/srv/repo/", query: "needle")
        #expect(parser.parse(line: Data(("motd" + SSHFileSearchCommand.gitGrepMarker).utf8)) == nil)
        #expect(parser.format == .gitGrep)
        func line(_ path: String, _ number: String, _ text: String) -> Data {
            Data(path.utf8) + Data([0]) + Data(number.utf8) + Data([0]) + Data(text.utf8)
        }
        // Colons in the path and in the text; the line number ends at a NUL, not a colon.
        let colon = parser.parse(line: line("rtl/a:12:b.sv", "7", "  x = needle:1; // 3:4"))
        #expect(colon?.path == "/srv/repo/rtl/a:12:b.sv")
        #expect(colon?.relativePath == "rtl/a:12:b.sv")
        #expect(colon?.lineNumber == 7)
        #expect(colon?.columnNumber == 7)
        #expect(colon?.preview == "x = needle:1; // 3:4")
        // Non-ASCII path (git -z prints it unquoted) and text.
        let accented = parser.parse(line: line("r\u{E9}sum\u{E9}/caf\u{E9}.sv", "3", "\u{E9}\u{E9}needle"))
        #expect(accented?.path == "/srv/repo/r\u{E9}sum\u{E9}/caf\u{E9}.sv")
        #expect(accented?.relativePath == "r\u{E9}sum\u{E9}/caf\u{E9}.sv")
        #expect(accented?.columnNumber == 5)
        // grep's `path NUL line:text` shape is not git grep's.
        #expect(parser.parse(line: Data("a.sv".utf8) + Data([0]) + Data("7:needle".utf8)) == nil)
        #expect(parser.parse(line: line("a.sv", "x", "needle")) == nil)
        #expect(parser.parse(line: line("a.sv", "0", "needle")) == nil)
        #expect(parser.parse(line: line("", "1", "needle")) == nil)
        // The root itself is "/".
        var top = SSHFileSearchLineParser(rootPath: "/", query: "needle")
        _ = top.parse(line: Data(SSHFileSearchCommand.gitGrepMarker.utf8))
        #expect(top.parse(line: line("etc/x", "1", "needle"))?.path == "/etc/x")
    }

    @Test
    func testGrepLinesSplitAtTheNulSoColonsInPathsSurvive() {
        var parser = SSHFileSearchLineParser(rootPath: "/srv/repo", query: "needle")
        #expect(parser.parse(line: Data("Last login: Fri".utf8)) == nil)
        #expect(parser.format == .unknown)
        #expect(parser.parse(line: Data(SSHFileSearchCommand.grepMarker.utf8)) == nil)
        #expect(parser.format == .grep)

        let line = Data("/srv/repo/a:12:b.sv".utf8) + Data([0]) + Data("7:  x = needle:1;".utf8)
        let result = parser.parse(line: line)
        #expect(result?.path == "/srv/repo/a:12:b.sv")
        #expect(result?.relativePath == "a:12:b.sv")
        #expect(result?.lineNumber == 7)
        #expect(result?.columnNumber == 7)
        #expect(result?.preview == "x = needle:1;")

        #expect(parser.parse(line: Data("Binary file /srv/repo/core.bin matches".utf8)) == nil)
        #expect(parser.parse(line: Data("/srv/repo/x".utf8) + Data([0]) + Data("notanumber:text".utf8)) == nil)
        #expect(parser.parse(line: Data("/srv/repo/x".utf8) + Data([0]) + Data("0:needle".utf8)) == nil)
    }

    @Test
    func testGrepColumnIsAUTF8ByteOffsetLikeRipgrep() {
        #expect(SSHFileSearchLineParser.columnNumber(of: "x", in: "\u{E9}\u{E9}x") == 5)
        #expect(SSHFileSearchLineParser.columnNumber(of: "abc", in: "xxABC") == 3)
        #expect(SSHFileSearchLineParser.columnNumber(of: "ABC", in: "xxabc") == 1)
    }

    @Test
    func testRipgrepJSONLinesParseAfterTheMarker() {
        var parser = SSHFileSearchLineParser(rootPath: "/srv/repo/", query: "Search")
        _ = parser.parse(line: Data(SSHFileSearchCommand.ripgrepMarker.utf8))
        #expect(parser.format == .ripgrep)
        let begin = #"{"type":"begin","data":{"path":{"text":"/srv/repo/src/App.swift"}}}"#
        #expect(parser.parse(line: Data(begin.utf8)) == nil)
        let match = #"{"type":"match","data":{"path":{"text":"/srv/repo/src/App.swift"},"lines":{"text":"let s = Search\n"},"line_number":42,"submatches":[{"match":{"text":"Search"},"start":8,"end":14}]}}"#
        let result = parser.parse(line: Data(match.utf8))
        #expect(result?.relativePath == "src/App.swift")
        #expect(result?.lineNumber == 42)
        #expect(result?.columnNumber == 9)
        #expect(result?.preview == "let s = Search")
    }

    @Test
    func testRemoteRelativePathNeverRewritesHostPaths() {
        #expect(SSHFileSearchLineParser.remoteRelativePath("/private/tmp/x/a", rootPath: "/private/tmp/x") == "a")
        #expect(SSHFileSearchLineParser.remoteRelativePath("/a/b", rootPath: "/") == "a/b")
        #expect(SSHFileSearchLineParser.remoteRelativePath("/elsewhere/b", rootPath: "/root") == "/elsewhere/b")
    }

    // MARK: Accumulation, truncation and status

    @Test
    func testChunksSplitMidLineAndStreamSnapshots() {
        var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 0)
        let output = Data((SSHFileSearchCommand.grepMarker + "\n").utf8)
            + Self.grepLine("/r/one", 1, "n1") + Self.grepLine("/r/two", 2, "n2")
        let cut = output.count - 4
        let first = accumulator.consume(output.prefix(cut))
        #expect(first?.results.map(\.relativePath) == ["one"])
        #expect(first?.status == .searching)
        #expect(first?.isSearching == true)
        let second = accumulator.consume(output.suffix(from: cut))
        #expect(second?.results.map(\.relativePath) == ["one", "two"])
        let done = accumulator.finish(status: 0)
        #expect(done.status == .matches)
        #expect(done.isSearching == false)
    }

    @Test
    func testCapStopsTheSearchWithALimitedNote() {
        var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 3, snapshotInterval: 60)
        var output = Data((SSHFileSearchCommand.grepMarker + "\n").utf8)
        for index in 0..<10 { output += Self.grepLine("/r/f\(index)", index + 1, "n") }
        let update = accumulator.consume(output)
        #expect(update?.status == .limited(3))
        #expect(update?.shouldStopProcess == true)
        #expect(update?.results.count == 3)
        #expect(accumulator.consume(Self.grepLine("/r/late", 1, "n")) == nil)
        // ssh then dies from SIGTERM; the cap stays the outcome.
        #expect(accumulator.finish(status: 15).status == .limited(3))
    }

    @Test
    func testExitStatusesMapToClearOutcomes() {
        func finish(_ status: Int32, stderr: String = "", withResult: Bool = false, timedOut: Bool = false)
            -> FileSearchSnapshot.Status {
            var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 60)
            var output = Data((SSHFileSearchCommand.grepMarker + "\n").utf8)
            if withResult { output += Self.grepLine("/r/a", 1, "n") }
            _ = accumulator.consume(output)
            accumulator.consumeStderr(Data(stderr.utf8))
            if timedOut { accumulator.markTimedOut() }
            return accumulator.finish(status: status).status
        }
        #expect(finish(1) == .noMatches)
        #expect(finish(0, withResult: true) == .matches)
        #expect(finish(2, stderr: "grep: x: Permission denied", withResult: true) == .matches)
        #expect(finish(2) == .noMatches)
        #expect(finish(2, stderr: "rg: bad flag") == .failed("rg: bad flag"))
        #expect(finish(124, withResult: true) == .failed(SSHFileSearchMessages.timedOut))
        #expect(finish(15, timedOut: true) == .failed(SSHFileSearchMessages.timedOut))
        #expect(finish(255, stderr: "ssh: connect to host h port 22: Connection refused")
            == .failed("ssh: connect to host h port 22: Connection refused"))
        #expect(finish(66) == .failed(SSHFileSearchMessages.folderNotFound))
        #expect(finish(9) == .failed(SSHFileSearchMessages.exited(status: 9)))
    }

    @Test
    func testLoginShellNoiseNeverBecomesTheError() {
        let noise = "/home/u/.bashrc: line 36: export: `/home/u/.bashrc': not a valid identifier\n"
        func finish(_ status: Int32, stderr: String, sawMarker: Bool = true) -> FileSearchSnapshot.Status {
            var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 60)
            if sawMarker { _ = accumulator.consume(Data((SSHFileSearchCommand.grepMarker + "\n").utf8)) }
            accumulator.consumeStderr(Data(stderr.utf8))
            return accumulator.finish(status: status).status
        }
        // grep -s exits 2 for unreadable files; rc-file chatter is not a failure.
        #expect(finish(2, stderr: noise) == .noMatches)
        #expect(finish(2, stderr: noise + "rg: ./x: Permission denied (os error 13)\n")
            == .failed("rg: ./x: Permission denied (os error 13)"))
        #expect(finish(9, stderr: noise) == .failed(SSHFileSearchMessages.exited(status: 9)))
        #expect(finish(255, stderr: noise + "client_loop: send disconnect: Broken pipe\n")
            == .failed("client_loop: send disconnect: Broken pipe"))
        // Before the tool runs, everything ssh printed is the diagnosis.
        #expect(finish(255, stderr: "ssh: Could not resolve hostname nohost\n", sawMarker: false)
            == .failed("ssh: Could not resolve hostname nohost"))
    }

    @Test
    func testTrailingLineWithoutNewlineIsKept() {
        var accumulator = SSHFileSearchAccumulator(rootPath: "/r", query: "n", maxResults: 10, snapshotInterval: 60)
        var output = Data((SSHFileSearchCommand.grepMarker + "\n").utf8) + Self.grepLine("/r/a", 1, "n")
        output.removeLast()
        _ = accumulator.consume(output)
        #expect(accumulator.finish(status: 0).results.map(\.relativePath) == ["a"])
    }

    // MARK: Helpers

    private struct Found {
        let format: SSHFileSearchLineParser.Format
        let status: FileSearchSnapshot.Status
        let results: [FileSearchResult]
        var relativePaths: [String] { results.map(\.relativePath).sorted { $0.lowercased() < $1.lowercased() } }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Perl one-liner: `setsid`, then exec the remaining arguments.
    static let setsidExec = "use POSIX (); POSIX::setsid(); exec @ARGV or exit 127"

    private static let pathWithoutRipgrep = "/usr/bin:/bin:/usr/sbin:/sbin"

    static var availableShells: [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `command` the way sshd does: `<login shell> -c <command>`.
    static func run(
        _ command: String,
        shell: String,
        path: String,
        directory: String? = nil
    ) throws -> (stdout: Data, stderr: Data, status: Int32) {
        let process = Process()
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        // -f keeps csh from reading the runner's ~/.cshrc; fish gets --no-config.
        let shellArguments: [String]
        if shell.hasSuffix("csh") {
            shellArguments = ["-f", "-c", command]
        } else if shell.hasSuffix("fish") {
            shellArguments = ["--no-config", "-c", command]
        } else {
            shellArguments = ["-c", command]
        }
        // Like sshd, start the command in a session of its own, so a script's
        // watchdog `kill 0` can only reach that command.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", setsidExec, shell] + shellArguments
        process.environment = ["PATH": path, "HOME": NSTemporaryDirectory(), "LC_ALL": "en_US.UTF-8"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Like an ssh channel, stdin stays open until the command is done.
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        defer { try? stdin.fileHandleForWriting.close() }
        // stderr drains on its own queue so neither pipe can fill and stall the shell.
        let errorBox = DataBox()
        let errorDone = DispatchSemaphore(value: 0)
        let errorHandle = stderr.fileHandleForReading
        DispatchQueue.global().async {
            errorBox.data = errorHandle.readDataToEndOfFile()
            errorDone.signal()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errorDone.wait()
        process.waitUntilExit()
        return (output, errorBox.data, process.terminationStatus)
    }

    private static func search(_ query: String, root: String, shell: String, path: String) throws -> Found {
        let command = SSHFileSearchCommand.contentSearch(query: query, rootPath: root, remoteTimeoutSeconds: 20)
        let output = try run(command.command, shell: shell, path: path)
        var accumulator = SSHFileSearchAccumulator(rootPath: root, query: query, maxResults: 500, snapshotInterval: 60)
        _ = accumulator.consume(output.stdout)
        accumulator.consumeStderr(output.stderr)
        let format = accumulator.format
        let update = accumulator.finish(status: output.status)
        return Found(format: format, status: update.status, results: update.results)
    }

    static func processCount(matching pattern: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Anchored, so the shells whose own command line mentions it don't count.
        process.arguments = ["-f", "^" + pattern]
        let output = Pipe()
        process.standardOutput = output
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).count
    }

    private static func grepLine(_ path: String, _ line: Int, _ text: String) -> Data {
        Data(path.utf8) + Data([0]) + Data("\(line):\(text)\n".utf8)
    }

    /// A directory holding a `grep` that acts like GNU grep 3.5+ on a Linux
    /// host: binary input prints nothing on stdout, and in a UTF-8 locale input
    /// with invalid UTF-8 counts as binary. Put it first on PATH.
    static func makeGNULikeGrepShim() throws -> URL {
        let shim = FileManager.default.temporaryDirectory.appendingPathComponent("gnu-grep-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        let grep = shim.appendingPathComponent("grep")
        try Data("""
        #!/bin/sh
        case "$1" in -r*) exec /usr/bin/grep --binary-files=without-match "$@" ;; esac
        case "${LC_ALL:-${LC_CTYPE:-$LANG}}" in
        *UTF-8*|*utf8*) exec /usr/bin/perl -e '
            local $/; my $data = <STDIN>; my $text = $data;
            utf8::decode($text) or exit 1;
            open(my $grep, "|-", "/usr/bin/grep", "--binary-files=without-match", @ARGV) or exit 2;
            print $grep $data; close $grep; exit($? >> 8);
            ' -- "$@" ;;
        esac
        exec /usr/bin/grep --binary-files=without-match "$@"

        """.utf8).write(to: grep)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grep.path)
        return shim
    }

    /// A Git work tree: `hello` in tracked, untracked and non-ASCII-named
    /// files, and in a gitignored `.venv` and an unignored `node_modules`
    /// that the search must skip.
    static func makeGitSearchTree(hostileConfig: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-gitgrep-\(UUID().uuidString)", isDirectory: true)
        let files: [(String, String)] = [
            (".gitignore", ".venv/\n"),
            ("dir/a:b.sv", "first line\nsay hello: there\n"),
            ("Upper.sv", "HELLO upper\n"),
            ("r\u{E9}sum\u{E9}.sv", "hello accented\n"),
            ("new.sv", "untracked hello\n"),
            ("hostile.sv", "prefix \(hostileQuery) suffix\n"),
            (".venv/lib/site.py", "hello from the virtualenv\n"),
            ("node_modules/pkg/index.js", "hello from node_modules\n"),
        ]
        for (relativePath, contents) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let setup = try run(
            "git init -q . && git add .gitignore dir Upper.sv r*.sv",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: root.path
        )
        guard setup.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        if hostileConfig {
            // Set after `git add`: every hook and filter here would leave .git/ran behind.
            let marker = root.appendingPathComponent(".git/ran").path
            let hook = root.appendingPathComponent(".git/hook.sh")
            try Data("#!/bin/sh\ntouch '\(marker)'\nexit 1\n".utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let config = """
            [core]
            \tpager = touch '\(marker)'
            \tfsmonitor = \(hook.path)
            [pager]
            \tgrep = touch '\(marker)'
            [grep]
            \tcolumn = true
            \tfullName = true
            \tlineNumber = false
            \tpatternType = perl
            [color]
            \tui = always
            \tgrep = always
            [diff "x"]
            \ttextconv = touch '\(marker)'
            [filter "x"]
            \tprocess = touch '\(marker)'
            \tclean = touch '\(marker)'
            \tsmudge = touch '\(marker)'

            """
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent(".git/config"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(config.utf8))
            try handle.close()
            try Data("* diff=x filter=x\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        }
        return root
    }

    /// `hello` appears in two searchable files and in four places the search must skip.
    static func makeSearchTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-search-\(UUID().uuidString)", isDirectory: true)
        let files: [(String, Data)] = [
            ("dir/a:b.txt", Data("first line\nsay hello: there\n".utf8)),
            ("Upper.txt", Data("HELLO upper\n".utf8)),
            ("hostile.txt", Data("prefix \(hostileQuery) suffix\n".utf8)),
            (".git/config", Data("hello from git\n".utf8)),
            ("node_modules/pkg/index.js", Data("hello from node_modules\n".utf8)),
            ("sub/build/out.txt", Data("hello from build\n".utf8)),
            // A regular file named like an excluded directory.
            ("src/build", Data("no match here\n".utf8)),
            ("blob.bin", Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x01, 0x02, 0x0A])),
        ]
        for (relativePath, contents) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        return root
    }
}
