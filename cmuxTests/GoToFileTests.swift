import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Go to File: fuzzy ranking, the file-list snapshot (parsed and run through
/// real shells), and the palette session model.
@Suite(.serialized)
struct GoToFileTests {
    // MARK: Ranking

    private static let tree = [
        "hdl/valu_ctrl.sv",
        "hdl/alu.sv",
        "hdl/cpu.sv",
        "hvl/top_tb.sv",
        "hdl/top.sv",
        "hdl/reg_file_sel.sv",
        "hdl/references.sv",
        "docs/README.md",
        "hdl/pipeline/alu_stage.sv",
    ]

    @Test
    func testFileNamePrefixBeatsAMatchInsideAWord() throws {
        let ranked = GoToFileRanker.rank(paths: Self.tree, query: "alu", limit: 10)
        #expect(ranked.first == "hdl/alu.sv")
        let stage = try #require(ranked.firstIndex(of: "hdl/pipeline/alu_stage.sv"))
        let inside = try #require(ranked.firstIndex(of: "hdl/valu_ctrl.sv"))
        #expect(stage < inside)
    }

    @Test
    func testNonMatchingPathsAreDropped() {
        #expect(GoToFileRanker.rank(paths: Self.tree, query: "xyz", limit: 10).isEmpty)
        #expect(GoToFileRanker.score(query: "ula", path: "hdl/alu.sv") == nil)
    }

    @Test
    func testWordStartsBeatScatteredLetters() {
        let ranked = GoToFileRanker.rank(paths: Self.tree, query: "rfs", limit: 10)
        #expect(ranked.first == "hdl/reg_file_sel.sv")
        #expect(ranked.contains("hdl/references.sv"))
    }

    @Test
    func testDirectoryQueriesMatchAcrossSlashes() {
        let ranked = GoToFileRanker.rank(paths: Self.tree, query: "hvl/top", limit: 10)
        #expect(ranked.first == "hvl/top_tb.sv")
        #expect(!ranked.contains("hdl/cpu.sv"))
    }

    @Test
    func testCaseAndSpacesAreIgnored() {
        #expect(GoToFileRanker.rank(paths: Self.tree, query: "ReadMe", limit: 1) == ["docs/README.md"])
        #expect(GoToFileRanker.rank(paths: Self.tree, query: "reg file", limit: 1) == ["hdl/reg_file_sel.sv"])
    }

    @Test
    func testExactFileNameWinsAndTiesPreferShorterPaths() {
        let paths = ["a/b/c/top.sv", "x/top.sv", "x/top_tb.sv"]
        #expect(GoToFileRanker.rank(paths: paths, query: "top.sv", limit: 3).first == "x/top.sv")
        #expect(GoToFileRanker.rank(paths: paths, query: "top", limit: 3).prefix(2) == ["x/top.sv", "a/b/c/top.sv"])
    }

    @Test
    func testEmptyQueryListsAlphabeticallyWithinTheLimit() {
        let ranked = GoToFileRanker.rank(paths: Self.tree, query: "  ", limit: 3)
        #expect(ranked == ["docs/README.md", "hdl/alu.sv", "hdl/cpu.sv"])
        #expect(GoToFileRanker.rank(paths: Self.tree, query: "s", limit: 0).isEmpty)
    }

    @Test
    func testNarrowingAnExtendedQueryMatchesAFullRanking() {
        let paths = Self.tree + (0..<2_000).map { "gen/m\($0 % 37)/unit_\($0).sv" }
        let index = GoToFileRanker.Index(paths: paths)
        var previous: GoToFileRanker.Ranking?
        var typed = ""
        for character in "un_1sv" {
            typed.append(character)
            let narrowed = GoToFileRanker.rank(index: index, query: typed, limit: 50, within: previous?.matches)
            let full = GoToFileRanker.rank(index: index, query: typed, limit: 50)
            #expect(narrowed.paths == full.paths, "query \(typed)")
            #expect(narrowed.matches == full.matches, "query \(typed)")
            previous = narrowed
        }
    }

    @Test
    func testRankingFiftyThousandPathsIsFastEnoughToType() {
        let paths = (0..<GoToFileSnapshot.maxPaths).map { "src/module_\($0 % 211)/sub\($0 % 13)/file_\($0).sv" }
        let index = GoToFileRanker.Index(paths: paths)
        let started = Date()
        let first = GoToFileRanker.rank(index: index, query: "m", limit: 200)
        _ = GoToFileRanker.rank(index: index, query: "mf", limit: 200, within: first.matches)
        // A generous bound for debug builds; the target is well under 100 ms optimized.
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test
    func testCancellationStopsRanking() {
        let paths = (0..<2_000).map { "dir/file\($0).sv" }
        #expect(GoToFileRanker.rank(paths: paths, query: "file", limit: 10, shouldCancel: { true }).isEmpty)
    }

    // MARK: Snapshot parsing

    @Test
    func testListOutputDropsTheMarkerAndDotSlash() {
        let git = Data((SSHFileSearchCommand.gitListMarker + "\n").utf8) + Self.nulList(["a.sv", "dir/b c.sv", "new\nline.sv"])
        #expect(GoToFileSnapshot.parse(listOutput: git).paths == ["a.sv", "dir/b c.sv", "new\nline.sv"])
        let find = Data((SSHFileSearchCommand.findListMarker + "\n").utf8) + Self.nulList(["./a.sv", "./d/b.sv", ""])
        #expect(GoToFileSnapshot.parse(listOutput: find) == GoToFileSnapshot(paths: ["a.sv", "d/b.sv"], isTruncated: false))
    }

    @Test
    func testListOutputIsCappedAndMarkedTruncated() {
        let output = Data((SSHFileSearchCommand.findListMarker + "\n").utf8) + Self.nulList((0..<10).map { "./f\($0)" })
        let snapshot = GoToFileSnapshot.parse(listOutput: output, maxPaths: 4)
        #expect(snapshot.paths == ["f0", "f1", "f2", "f3"])
        #expect(snapshot.isTruncated)
        #expect(!GoToFileSnapshot.parse(listOutput: output, maxPaths: 10).isTruncated)
    }

    @Test
    func testListOutputFindsTheMarkerAfterABannerAndDropsDuplicates() {
        // A login shell may print to stdout, with or without a newline, before the marker.
        for banner in ["Welcome", "conda activated\n", ""] {
            let output = Data((banner + "\n" + SSHFileSearchCommand.gitListMarker + "\n").utf8)
                + Self.nulList(["a.sv", "conflict.sv", "conflict.sv", "conflict.sv", "b.sv"])
            #expect(GoToFileSnapshot.parse(listOutput: output).paths == ["a.sv", "conflict.sv", "b.sv"], "banner \(banner)")
        }
    }

    // MARK: Listing through login shells

    @Test
    func testFindListingPrunesExcludedDirectoriesInEveryShell() throws {
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10, watchdog: false).command
        for shell in SSHFileSearchTests.availableShells {
            let output = try SSHFileSearchTests.run(command, shell: shell, path: "/usr/bin:/bin")
            #expect(output.status == 0, "shell \(shell)")
            #expect(output.stdout.contains(Data((SSHFileSearchCommand.findListMarker + "\n").utf8)), "shell \(shell)")
            #expect(GoToFileSnapshot.parse(listOutput: output.stdout).paths.sorted()
                == ["Upper.txt", "blob.bin", "dir/a:b.txt", "hostile.txt", "src/build"], "shell \(shell)")
        }
    }

    @Test
    func testGitListingHonorsIgnoreRulesAndIncludesUntrackedFiles() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try Data("ignored.log\nnode_modules/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("x".utf8).write(to: root.appendingPathComponent("ignored.log"))
        let git = try SSHFileSearchTests.run(
            "git init -q . && git add Upper.txt && git -c user.email=t@e -c user.name=t commit -qm init",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: root.path
        )
        #expect(git.status == 0)
        let command = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10, watchdog: false).command
        for shell in SSHFileSearchTests.availableShells {
            let output = try SSHFileSearchTests.run(command, shell: shell, path: "/usr/bin:/bin")
            #expect(output.stdout.contains(Data((SSHFileSearchCommand.gitListMarker + "\n").utf8)), "shell \(shell)")
            let paths = GoToFileSnapshot.parse(listOutput: output.stdout).paths.sorted()
            #expect(paths == [".gitignore", "Upper.txt", "blob.bin", "dir/a:b.txt", "hostile.txt", "src/build", "sub/build/out.txt"],
                    "shell \(shell)")
        }
    }

    @Test
    func testLoaderListsLocalRootsAndReportsMissingOnes() async throws {
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GoToFileSnapshotLoader.load(.local(rootPath: root.path))
        #expect(snapshot.paths.contains("dir/a:b.txt"))
        #expect(!snapshot.paths.contains { $0.hasPrefix("node_modules") })
        await #expect(throws: GoToFileSnapshotError.folderNotFound) {
            _ = try await GoToFileSnapshotLoader.load(.local(rootPath: "/nonexistent-cmux-\(UUID().uuidString)"))
        }
    }

    @Test
    func testLoaderTimesOutAndCapsOutput() async throws {
        let slow = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c", "sleep 5"])
        let started = Date()
        await #expect(throws: GoToFileSnapshotError.timedOut) {
            _ = try await GoToFileSnapshotLoader.load(slow, timeoutSeconds: 1)
        }
        #expect(Date().timeIntervalSince(started) < 4)

        let flood = GoToFileSnapshotLoader.Invocation(
            executable: "/bin/sh",
            arguments: ["-c", "echo cmux-files:find; i=0; while :; do i=$((i+1)); printf './file-name-padding-%08d\\0' $i; done"]
        )
        let capped = try await GoToFileSnapshotLoader.load(flood, timeoutSeconds: 10, maxOutputBytes: 64 * 1024)
        #expect(capped.isTruncated)
        #expect(!capped.paths.isEmpty)
        // Every kept name is whole: the cut-off last one is dropped.
        #expect(capped.paths.allSatisfy { $0.hasPrefix("file-name-padding-") && $0.count == 26 })
    }

    @Test
    func testLoaderStopsTheListingToolAtTheByteCap() async throws {
        // The script runs find in a child of sh; stopping only sh would leave
        // find blocked on a full pipe and the session stuck loading.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20_000 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("file-with-a-long-name-\(index).sv").path, contents: nil)
        }
        let list = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 30, watchdog: false).command
        let invocation = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c", list])
        let started = Date()
        let finished = Self.Flag()
        let load = Task.detached {
            let snapshot = try await GoToFileSnapshotLoader.load(invocation, timeoutSeconds: 30, maxOutputBytes: 16 * 1024)
            finished.set()
            return snapshot
        }
        while !finished.value, Date().timeIntervalSince(started) < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(finished.value, "the listing never returned after the byte cap")
        if finished.value {
            let snapshot = try await load.value
            #expect(snapshot.isTruncated)
            #expect(!snapshot.paths.isEmpty)
        }
    }

    @Test
    func testGitListingNeverRunsTheRepositorysFsmonitorHook() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        let marker = root.appendingPathComponent("hook-ran")
        let hook = root.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let setup = try SSHFileSearchTests.run(
            "git init -q . && git config core.fsmonitor '\(hook.path)' && git add Upper.txt",
            shell: "/bin/sh", path: "/usr/bin:/bin", directory: root.path
        )
        #expect(setup.status == 0)
        try? FileManager.default.removeItem(at: marker)
        let command = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10, watchdog: false).command
        let output = try SSHFileSearchTests.run(command, shell: "/bin/sh", path: "/usr/bin:/bin")
        #expect(GoToFileSnapshot.parse(listOutput: output.stdout).paths.contains("Upper.txt"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "core.fsmonitor ran")
    }

    @Test
    func testLoaderFailureNamesTheToolNotTheLoginShell() async {
        let noisy = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c",
            "echo \"/home/u/.bashrc: line 1: noise\" >&2; echo \"fatal: not a git repository\" >&2; exit 3"])
        await #expect(throws: GoToFileSnapshotError.failed("fatal: not a git repository")) {
            _ = try await GoToFileSnapshotLoader.load(noisy)
        }
        let quiet = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c",
            "echo cmux-files:find; echo \"/home/u/.bashrc: line 1: noise\" >&2; exit 3"])
        await #expect(throws: GoToFileSnapshotError.failed(SSHFileSearchMessages.exited(status: 3))) {
            _ = try await GoToFileSnapshotLoader.load(quiet)
        }
    }

    @Test
    func testLoaderToleratesBannersAndReportsShellsThatSkippedTheList() async throws {
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let list = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10, watchdog: false).command
        let bannered = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c", "printf Welcome; " + list])
        let listed = try await GoToFileSnapshotLoader.load(bannered)
        #expect(listed.paths.contains("dir/a:b.txt"))
        let silent = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c", "echo motd; exit 0"])
        await #expect(throws: GoToFileSnapshotError.failed(SSHFileSearchMessages.didNotRun)) {
            _ = try await GoToFileSnapshotLoader.load(silent)
        }
        let noBase64 = GoToFileSnapshotLoader.Invocation(executable: "/bin/sh", arguments: ["-c", "exit 65"])
        await #expect(throws: GoToFileSnapshotError.failed(SSHFileSearchMessages.decodeFailed)) {
            _ = try await GoToFileSnapshotLoader.load(noBase64)
        }
    }

    @Test
    func testSSHInvocationRunsTheListScriptThroughSSH() {
        let connection = SSHFileExplorerConnection(destination: "ews-01", port: nil, identityFile: nil, sshOptions: [])
        let invocation = GoToFileSnapshotLoader.invocation(
            for: .ssh(connection: connection, rootPath: "/home/u/repo"),
            sshArguments: { connection, command in ["-o", "BatchMode=yes", connection.destination, command] }
        )
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.prefix(3) == ["-o", "BatchMode=yes", "ews-01"])
        #expect(invocation.arguments.last
            == SSHFileSearchCommand.fileList(rootPath: "/home/u/repo", maxDepth: 8, remoteTimeoutSeconds: 18, watchdog: true).command)
        #expect(invocation.keepsStdinOpen)
        let local = GoToFileSnapshotLoader.invocation(for: .local(rootPath: "/tmp"), sshArguments: { _, c in [c] })
        #expect(!local.keepsStdinOpen)
        #expect(!local.arguments.joined().contains("kill 0"))
    }

    // MARK: Palette session

    @MainActor
    @Test
    func testSessionListsOnceAndRanksEveryQuery() async throws {
        let calls = CallCounter()
        let model = GoToFilePaletteModel(loadSnapshot: { _ in
            calls.increment()
            return GoToFileSnapshot(paths: Self.tree, isTruncated: true)
        })
        model.begin(source: .local(rootPath: "/w"), workspaceId: UUID())
        model.update(query: "alu")
        try await Self.waitUntil { model.results.first == "hdl/alu.sv" && !model.isLoading }
        #expect(model.isTruncated)
        #expect(model.selectedRelativePath == "hdl/alu.sv")
        #expect(model.absolutePath(forRelativePath: "hdl/alu.sv") == "/w/hdl/alu.sv")

        model.update(query: "cpu")
        // Until the new ranking lands, the old rows can't be opened for the new query.
        if model.results.first != "hdl/cpu.sv" { #expect(model.selectedRelativePath == nil) }
        try await Self.waitUntil { model.results.first == "hdl/cpu.sv" }
        #expect(model.moveSelection(by: 5))
        #expect(model.selectedIndex == model.results.count - 1)
        #expect(calls.value == 1)

        model.end()
        #expect(!model.isActive)
        #expect(model.results.isEmpty)
        #expect(model.selectedRelativePath == nil)
    }

    @MainActor
    @Test
    func testEnterBeforeTheRankingLandsOpensTheTopResult() async throws {
        let model = GoToFilePaletteModel(loadSnapshot: { _ in GoToFileSnapshot(paths: Self.tree, isTruncated: false) })
        var opened: [String] = []
        model.onDeferredOpen = { opened.append($0) }
        model.begin(source: .local(rootPath: "/w"), workspaceId: UUID())
        model.update(query: "cpu")
        // Nothing is ranked yet, so Enter is queued instead of dropped.
        #expect(model.openSelectionOrQueue() == nil)
        try await Self.waitUntil { !opened.isEmpty }
        #expect(opened == ["hdl/cpu.sv"])
        // Once results are current, Enter opens at once and nothing is queued.
        #expect(model.openSelectionOrQueue() == "hdl/cpu.sv")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(opened == ["hdl/cpu.sv"])
        #expect(!model.opensWhenRanked)
        // Ending the session drops a queued Enter.
        model.update(query: "alu")
        #expect(model.openSelectionOrQueue() == nil)
        model.end()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(opened == ["hdl/cpu.sv"])
    }

    @MainActor
    @Test
    func testSessionReportsListingFailures() async throws {
        let model = GoToFilePaletteModel(loadSnapshot: { _ in throw GoToFileSnapshotError.folderNotFound })
        model.begin(source: .local(rootPath: "/w"), workspaceId: UUID())
        try await Self.waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage == SSHFileSearchMessages.folderNotFound)
        #expect(!model.isLoading)
    }

    @MainActor
    @Test
    func testEndingASessionDropsItsLateSnapshot() async throws {
        let gate = AsyncGate()
        let model = GoToFilePaletteModel(loadSnapshot: { source in
            await gate.wait()
            return GoToFileSnapshot(paths: [source.rootPath == "/old" ? "old.sv" : "new.sv"], isTruncated: false)
        })
        model.begin(source: .local(rootPath: "/old"), workspaceId: UUID())
        model.end()
        model.begin(source: .local(rootPath: "/new"), workspaceId: UUID())
        await gate.open()
        try await Self.waitUntil { !model.results.isEmpty }
        #expect(model.source == .local(rootPath: "/new"))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.results == ["new.sv"])
    }

    // MARK: Helpers

    private static func nulList(_ paths: [String]) -> Data {
        paths.reduce(into: Data()) { data, path in
            data.append(Data(path.utf8))
            data.append(0)
        }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("condition not met in 2 s")
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}
