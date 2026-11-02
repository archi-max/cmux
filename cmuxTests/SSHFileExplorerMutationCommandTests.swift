import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Runs the generated SSH mutation commands through real local shells, the
/// way the remote login shell would receive them.
@Suite(.serialized)
struct SSHFileExplorerMutationCommandTests {
    /// A name with a quote, `$`, a leading `-` and a precomposed (NFC) letter.
    private static let hostileName = "-it's $HOME \u{E9}.txt"

    @Test
    func testCommandsWrapAQuotedShScriptWithoutRawUserText() {
        let path = "/home/dev/\(Self.hostileName)"
        let destination = "/home/dev/\(Self.hostileName) copy"
        let commands: [SSHFileExplorerMutationCommand] = [
            .createFile(path: path),
            .createDirectory(path: path),
            .rename(path: path, to: destination),
            .delete(path: path),
            .copy(path: path, to: destination),
        ]
        for mutation in commands {
            let command = mutation.command
            #expect(command.hasPrefix("sh -c '"))
            #expect(command.hasSuffix("'"))
            let script = command.dropFirst("sh -c '".count).dropLast()
            #expect(!script.contains("'"))
            #expect(!script.contains("\\"))
            #expect(!script.contains("!"))
            #expect(!script.contains("$HOME"))
            #expect(command.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(script.contains(Data(path.utf8).base64EncodedString()))
        }

        let create = SSHFileExplorerMutationCommand.createFile(path: path).command
        #expect(create.contains("then exit 73; fi"))
        #expect(create.contains("set -C; : > \"$t\""))
        #expect(create.contains("[ -w \"$dir\" ] || exit 77"))
        #expect(SSHFileExplorerMutationCommand.createDirectory(path: path).command.contains("mkdir -- \"$t\""))
        #expect(SSHFileExplorerMutationCommand.rename(path: path, to: destination).command
            .contains("mv -n -- \"$s\" \"$t\""))
        #expect(SSHFileExplorerMutationCommand.delete(path: path).command.contains("rm -rf -- \"$t\""))
        #expect(SSHFileExplorerMutationCommand.copy(path: path, to: destination).command
            .contains("cp -R -p -- \"$s\" \"$t\""))
    }

    @Test
    func testCreateCommandsKeepExactNamesAndNeverTruncate() throws {
        for shell in Self.availableShells {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent(Self.hostileName).path

            #expect(try Self.run(.createFile(path: path), shell: shell) == 0)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names.map(\.precomposedStringWithCanonicalMapping) == [Self.hostileName])

            try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
            #expect(try Self.run(.createFile(path: path), shell: shell) == 73)
            #expect(try Self.run(.createDirectory(path: path), shell: shell) == 73)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
        }
    }

    @Test
    func testRenameAndCopyCommandsRefuseExistingDestinations() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("a.txt").path
        let destination = directory.appendingPathComponent("b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: source))
        try Data("b".utf8).write(to: URL(fileURLWithPath: destination))

        #expect(try Self.run(.rename(path: source, to: destination)) == 73)
        #expect(try Self.run(.copy(path: source, to: destination)) == 73)
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "b")

        let copyPath = directory.appendingPathComponent("a copy.txt").path
        #expect(try Self.run(.copy(path: source, to: copyPath)) == 0)
        #expect(try String(contentsOfFile: copyPath, encoding: .utf8) == "a")

        #expect(try Self.run(.delete(path: copyPath)) == 0)
        #expect(!FileManager.default.fileExists(atPath: copyPath))
    }

    @Test
    func testCaseOnlyRenameCommandRenames() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Readme.md").path
        let destination = directory.appendingPathComponent("README.md").path
        try Data("content".utf8).write(to: URL(fileURLWithPath: source))

        // The temp folder is usually on a case-insensitive volume, where
        // `[ -e README.md ]` also matches the source.
        #expect(try Self.run(.rename(path: source, to: destination)) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["README.md"])
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "content")
    }

    /// One run removes the whole selection, in order, and reports each removal,
    /// so a failure part way through still says which items are gone.
    @Test
    func testBatchDeleteRemovesInOrderAndStopsAtTheFirstFailure() throws {
        for shell in Self.availableShells {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(Self.hostileName).path
            let folder = directory.appendingPathComponent("folder").path
            try FileManager.default.createDirectory(atPath: folder + "/nested", withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: file, contents: Data("x".utf8)))
            let missing = directory.appendingPathComponent("missing").path
            let last = directory.appendingPathComponent("last").path
            #expect(FileManager.default.createFile(atPath: last, contents: Data()))

            let all = try Self.runCapturing(.delete(paths: [file, folder], nonce: "n1"), shell: shell)
            #expect(all.status == 0)
            #expect(SSHFileExplorerMutationCommand.removedIndices(in: all.output, nonce: "n1") == [0, 1])
            #expect(!FileManager.default.fileExists(atPath: file))
            #expect(!FileManager.default.fileExists(atPath: folder))

            let partial = try Self.runCapturing(.delete(paths: [last, missing, last], nonce: "n2"), shell: shell)
            #expect(partial.status == 74)
            #expect(SSHFileExplorerMutationCommand.removedIndices(in: partial.output, nonce: "n2") == [0])
            #expect(!FileManager.default.fileExists(atPath: last))
        }
        let command = SSHFileExplorerMutationCommand.delete(paths: ["/home/dev/\(Self.hostileName)"], nonce: "n3").command
        #expect(command.hasPrefix("sh -c '"))
        #expect(!command.dropFirst("sh -c '".count).dropLast().contains("'"))
        #expect(command.unicodeScalars.allSatisfy { $0.isASCII })
    }

    /// Linux caps one argument at 128 KiB, and sshd hands the whole command to
    /// the login shell as one argument, so long paths must split into more runs.
    @Test
    func testDeleteBatchesKeepEachCommandUnderTheArgumentLimit() throws {
        let longName = String(repeating: "n", count: 200)
        let paths = (0..<450).map { "/home/dev/\(longName)-\($0)" }
        let batches = SSHFileExplorerMutationCommand.deleteBatches(paths)
        #expect(Array(batches.joined()) == paths)
        #expect(batches.count > 3)
        for batch in batches {
            #expect(!batch.isEmpty)
            #expect(batch.count <= 200)
            let command = SSHFileExplorerMutationCommand.delete(paths: batch, nonce: String(repeating: "f", count: 32)).command
            #expect(command.utf8.count <= 64 * 1024)
        }
        let short = (0..<450).map { "/home/dev/\($0)" }
        #expect(SSHFileExplorerMutationCommand.deleteBatches(short).map(\.count) == [200, 200, 50])
        // One path longer than the budget still gets a run of its own.
        let huge = "/home/dev/" + String(repeating: "h", count: 70_000)
        #expect(SSHFileExplorerMutationCommand.deleteBatches(["/a", huge, "/b"]) == [["/a"], [huge], ["/b"]])

        // Every run of a long-path selection works through a real shell.
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = (0..<250).map { directory.appendingPathComponent("\(longName)-\($0)").path }
        for file in files { #expect(FileManager.default.createFile(atPath: file, contents: Data())) }
        for batch in SSHFileExplorerMutationCommand.deleteBatches(files) {
            let result = try Self.runCapturing(.delete(paths: batch, nonce: "n4"), shell: "/bin/sh")
            #expect(result.status == 0)
            #expect(SSHFileExplorerMutationCommand.removedIndices(in: result.output, nonce: "n4") == Array(batch.indices))
        }
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    /// `$(...)` drops trailing newlines, so a missing `keep<newline>` must not
    /// fall back to removing its sibling `keep`.
    @Test
    func testDeleteKeepsTrailingNewlinesInTheName() throws {
        for shell in Self.availableShells {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let keep = directory.appendingPathComponent("keep").path
            #expect(FileManager.default.createFile(atPath: keep, contents: Data()))
            #expect(try Self.run(.delete(path: keep + "\n"), shell: shell) == 74)
            let batch = try Self.runCapturing(.delete(paths: [keep + "\n\n"], nonce: "n5"), shell: shell)
            #expect(batch.status == 74)
            #expect(FileManager.default.fileExists(atPath: keep))

            let named = directory.appendingPathComponent("gone\n").path
            #expect(FileManager.default.createFile(atPath: named, contents: Data()))
            #expect(try Self.run(.delete(path: named), shell: shell) == 0)
            #expect(!FileManager.default.fileExists(atPath: named))
        }
    }

    /// A login dotfile can print anything, but not the nonce of this run.
    @Test
    func testRemovedIndicesOnlyTrustTheRunNonce() throws {
        let output = "cmux-removed:0\ncmux-removed-other:1\nxcmux-removed-abc:2\ncmux-removed-abc:3\n"
        #expect(SSHFileExplorerMutationCommand.removedIndices(in: output, nonce: "abc") == [3])
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f").path
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        let spoof = "printf \"cmux-removed:0\\ncmux-removed-x:0\\n\"; "
        let mutation = SSHFileExplorerMutationCommand.delete(paths: [file], nonce: "abc")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", spoof + mutation.command]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(SSHFileExplorerMutationCommand.removedIndices(in: String(decoding: data, as: UTF8.self), nonce: "abc") == [0])
    }

    private static func runCapturing(
        _ mutation: SSHFileExplorerMutationCommand,
        shell: String
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shell.hasSuffix("csh") ? ["-f", "-c", mutation.command] : ["-c", mutation.command]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `/bin/sh` always, plus csh to show a non-POSIX login shell works.
    private static var availableShells: [String] {
        ["/bin/sh", "/bin/csh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ mutation: SSHFileExplorerMutationCommand, shell: String = "/bin/sh") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -f keeps csh from reading the runner's ~/.cshrc.
        process.arguments = shell.hasSuffix("csh") ? ["-f", "-c", mutation.command] : ["-c", mutation.command]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
