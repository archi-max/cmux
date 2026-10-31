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
            SSHFileSearchCommand.fileList(rootPath: root, maxDepth: 8, remoteTimeoutSeconds: 18),
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
        #expect(content.contains("nice -n 10"))
        #expect(content.contains("timeout 27"))
    }

    @Test
    func testSmartCaseMatchesRipgrep() {
        #expect(SSHFileSearchCommand.isCaseInsensitive(query: "hello world"))
        #expect(!SSHFileSearchCommand.isCaseInsensitive(query: "Hello"))
        #expect(SSHFileSearchCommand.contentSearch(query: "abc", rootPath: "/r", remoteTimeoutSeconds: 5)
            .command.contains("grep -rnIsF --null $lb -i "))
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

    // MARK: Parsing

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
        process.executableURL = URL(fileURLWithPath: shell)
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        // -f keeps csh from reading the runner's ~/.cshrc; fish gets --no-config.
        if shell.hasSuffix("csh") {
            process.arguments = ["-f", "-c", command]
        } else if shell.hasSuffix("fish") {
            process.arguments = ["--no-config", "-c", command]
        } else {
            process.arguments = ["-c", command]
        }
        process.environment = ["PATH": path, "HOME": NSTemporaryDirectory(), "LC_ALL": "en_US.UTF-8"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
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

    private static func grepLine(_ path: String, _ line: Int, _ text: String) -> Data {
        Data(path.utf8) + Data([0]) + Data("\(line):\(text)\n".utf8)
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
