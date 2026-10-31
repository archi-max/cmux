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

    // MARK: Listing through login shells

    @Test
    func testFindListingPrunesExcludedDirectoriesInEveryShell() throws {
        let root = try SSHFileSearchTests.makeSearchTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10).command
        for shell in SSHFileSearchTests.availableShells {
            let output = try SSHFileSearchTests.run(command, shell: shell, path: "/usr/bin:/bin")
            #expect(output.status == 0, "shell \(shell)")
            #expect(output.stdout.starts(with: Data((SSHFileSearchCommand.findListMarker + "\n").utf8)), "shell \(shell)")
            #expect(GoToFileSnapshot.parse(listOutput: output.stdout).paths.sorted()
                == ["Upper.txt", "blob.bin", "dir/a:b.txt", "hostile.txt"], "shell \(shell)")
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
        let command = SSHFileSearchCommand.fileList(rootPath: root.path, maxDepth: 8, remoteTimeoutSeconds: 10).command
        for shell in SSHFileSearchTests.availableShells {
            let output = try SSHFileSearchTests.run(command, shell: shell, path: "/usr/bin:/bin")
            #expect(output.stdout.starts(with: Data((SSHFileSearchCommand.gitListMarker + "\n").utf8)), "shell \(shell)")
            let paths = GoToFileSnapshot.parse(listOutput: output.stdout).paths.sorted()
            #expect(paths == [".gitignore", "Upper.txt", "blob.bin", "dir/a:b.txt", "hostile.txt", "sub/build/out.txt"],
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
            arguments: ["-c", "echo cmux-files:find; while :; do printf './file-name-padding-xxxxxxxx\\0'; done"]
        )
        let capped = try await GoToFileSnapshotLoader.load(flood, timeoutSeconds: 10, maxOutputBytes: 64 * 1024)
        #expect(capped.isTruncated)
        #expect(!capped.paths.isEmpty)
        #expect(capped.paths.allSatisfy { $0 == "file-name-padding-xxxxxxxx" })
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
    func testSSHInvocationRunsTheListScriptThroughSSH() {
        let connection = SSHFileExplorerConnection(destination: "ews-01", port: nil, identityFile: nil, sshOptions: [])
        let invocation = GoToFileSnapshotLoader.invocation(
            for: .ssh(connection: connection, rootPath: "/home/u/repo"),
            sshArguments: { connection, command in ["-o", "BatchMode=yes", connection.destination, command] }
        )
        #expect(invocation.executable == "/usr/bin/ssh")
        #expect(invocation.arguments.prefix(3) == ["-o", "BatchMode=yes", "ews-01"])
        #expect(invocation.arguments.last
            == SSHFileSearchCommand.fileList(rootPath: "/home/u/repo", maxDepth: 8, remoteTimeoutSeconds: 18).command)
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
