import CmuxSyntaxHighlighting
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The remote side of a terminal file link or `cmux open`: one ssh run tries
/// every candidate spelling and streams the first regular file, instead of
/// one ssh run per spelling plus a `$HOME` lookup and a separate `stat`.
/// Runs the real script under the shells a host's login shell may be.
@Suite struct RemoteFileProbeTests {
    private static let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Run {
        var status: Int32
        var raw: URL
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fo-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Runs `command` like ssh does: `<login shell> -c <command>`, stdout to a file.
    private func run(_ command: String, shell: String, home: URL, in root: URL) throws -> Run {
        let raw = root.appendingPathComponent("raw-" + UUID().uuidString)
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardOutput = try FileHandle(forWritingTo: raw)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, raw: raw)
    }

    @Test func oneRunTriesTheSpellingsInOrderAndStreamsTheFirstFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rtl/alu.sv")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Binary-safe: NUL bytes, no trailing newline, and a fake header line inside.
        let bytes = Data("module alu;\n\u{0}cmux-probe:0 1 2 x\nendmodule".utf8)
        try bytes.write(to: file)
        let candidates = [file.path + ":42", root.appendingPathComponent("rtl").path, file.path]
        for shell in Self.shells {
            let result = try run(RemoteFileProbe.command(candidates: candidates, maxBytes: nil), shell: shell, home: root, in: root)
            #expect(result.status == 0, "\(shell)")
            let out = root.appendingPathComponent("out-" + UUID().uuidString)
            let header = try RemoteFileProbe.extract(from: result.raw, to: out)
            #expect(header.index == 2, "\(shell): a directory is not a file")
            #expect(header.path == file.path, "\(shell)")
            #expect(header.size == Int64(bytes.count), "\(shell)")
            #expect(header.modificationTime > 0, "\(shell)")
            #expect(try Data(contentsOf: out) == bytes, "\(shell)")
        }
    }

    @Test func tildeIsExpandedOnTheHost() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home dir")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: home.appendingPathComponent("proj/a.sv"))
        for shell in Self.shells {
            let result = try run(RemoteFileProbe.command(candidates: ["~/proj/a.sv"], maxBytes: nil), shell: shell, home: home, in: root)
            #expect(result.status == 0, "\(shell)")
            let header = try RemoteFileProbe.extract(from: result.raw, to: root.appendingPathComponent("o-" + UUID().uuidString))
            #expect(header.path == home.appendingPathComponent("proj/a.sv").path, "\(shell): the host's own path, ~ expanded")
        }
    }

    @Test func pathsWithSpacesQuotesAndNonASCIISurvive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rés umé 'q' \"d\" $x `y`.sv")
        try Data("ok".utf8).write(to: file)
        for shell in Self.shells {
            let result = try run(RemoteFileProbe.command(candidates: [file.path], maxBytes: nil), shell: shell, home: root, in: root)
            #expect(result.status == 0, "\(shell)")
            let out = root.appendingPathComponent("o-" + UUID().uuidString)
            let header = try RemoteFileProbe.extract(from: result.raw, to: out)
            #expect(header.path == file.path, "\(shell)")
            #expect(try Data(contentsOf: out) == Data("ok".utf8), "\(shell)")
        }
    }

    @Test func noCandidateIsAFileExitsWithTheNoFileStatus() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for shell in Self.shells {
            let result = try run(
                RemoteFileProbe.command(candidates: [root.appendingPathComponent("nope").path, root.path], maxBytes: nil),
                shell: shell, home: root, in: root
            )
            #expect(result.status == RemoteFileProbe.noFileStatus, "\(shell)")
        }
    }

    @Test func aCappedProbeRefusesAnOversizeFileWithoutSendingIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("big.log")
        try Data(count: 100).write(to: file)
        for shell in Self.shells {
            let result = try run(RemoteFileProbe.command(candidates: [file.path], maxBytes: 10), shell: shell, home: root, in: root)
            #expect(result.status == RemoteFileProbe.tooLargeStatus, "\(shell)")
            let sent = root.appendingPathComponent("o-" + UUID().uuidString)
            let header = try RemoteFileProbe.extract(from: result.raw, to: sent)
            #expect(header.size == 100, "\(shell): the header still says how big it is")
            #expect(try Data(contentsOf: sent).isEmpty, "\(shell): the file's bytes are not sent")
            let fits = try run(RemoteFileProbe.command(candidates: [file.path], maxBytes: 100), shell: shell, home: root, in: root)
            #expect(fits.status == 0, "\(shell)")
        }
    }

    @Test func loginShellBannersBeforeTheHeaderAreSkipped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.sv")
        try Data("body".utf8).write(to: file)
        let command = "echo Welcome to the host; echo conda activated; " + RemoteFileProbe.command(candidates: [file.path], maxBytes: nil)
        let result = try run(command, shell: "/bin/sh", home: root, in: root)
        #expect(result.status == 0)
        let out = root.appendingPathComponent("o")
        let header = try RemoteFileProbe.extract(from: result.raw, to: out)
        #expect(header.index == 0)
        #expect(try Data(contentsOf: out) == Data("body".utf8))
    }

    @Test func outputWithoutAHeaderIsMalformed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw")
        try Data("no header here\n".utf8).write(to: raw)
        #expect(throws: RemoteFileProbe.Failure.malformedOutput) {
            _ = try RemoteFileProbe.extract(from: raw, to: root.appendingPathComponent("o"))
        }
    }

    // MARK: Open rules

    private actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    @Test func aClickUsesTheShellsLiveDirectoryNotTheSpawnDirectory() async {
        // A cmux-tui terminal reports the directory it was spawned in; after a
        // `cd` only the live query knows where the shell is.
        let counter = Counter()
        let live: @Sendable () async -> String? = { await counter.bump(); return "/home/u/proj" }
        let directory = await RemotePreviewOpenRules.workingDirectory(needsDirectory: true, live: live, snapshot: "/home/u")
        let asked = await counter.count
        #expect(directory == "/home/u/proj")
        #expect(asked == 1)
    }

    @Test func theLiveDirectoryIsNotAskedForAbsoluteLinks() async {
        let counter = Counter()
        let live: @Sendable () async -> String? = { await counter.bump(); return "/x" }
        let directory = await RemotePreviewOpenRules.workingDirectory(needsDirectory: false, live: live, snapshot: "/home/u")
        let asked = await counter.count
        #expect(directory == "/home/u")
        #expect(asked == 0, "no extra round trip when nothing is relative")
    }

    @Test func theSnapshotDirectoryIsTheFallbackWhenTheLiveQueryFails() async {
        let none: @Sendable () async -> String? = { nil }
        let fallback = await RemotePreviewOpenRules.workingDirectory(needsDirectory: true, live: none, snapshot: "/home/u")
        #expect(fallback == "/home/u")
        let relative: @Sendable () async -> String? = { "proj" }
        let notAbsolute = await RemotePreviewOpenRules.workingDirectory(needsDirectory: true, live: relative, snapshot: "/home/u")
        #expect(notAbsolute == "/home/u")
    }

    @Test func aFinishedDownloadOpensAfterTheUserMovedToAnotherTabOfTheWorkspace() {
        // `cmux open` and ⌘-click take a few hundred ms to seconds; switching
        // tabs meanwhile used to drop the file silently.
        #expect(RemotePreviewOpenRules.downloadMayOpen(
            isSelected: true, isRetired: false, sourceUnchanged: true, configurationUnchanged: true,
            sourceIsFocused: false, windowIsKey: false
        ))
        #expect(!RemotePreviewOpenRules.downloadMayOpen(
            isSelected: false, isRetired: false, sourceUnchanged: true, configurationUnchanged: true,
            sourceIsFocused: true, windowIsKey: true
        ), "another workspace is selected")
        #expect(!RemotePreviewOpenRules.downloadMayOpen(
            isSelected: true, isRetired: false, sourceUnchanged: true, configurationUnchanged: false,
            sourceIsFocused: true, windowIsKey: true
        ), "the connection changed")
        #expect(!RemotePreviewOpenRules.downloadMayOpen(
            isSelected: true, isRetired: false, sourceUnchanged: false, configurationUnchanged: true,
            sourceIsFocused: true, windowIsKey: true
        ), "the terminal was replaced")
        #expect(!RemotePreviewOpenRules.downloadMayOpen(
            isSelected: true, isRetired: true, sourceUnchanged: true, configurationUnchanged: true,
            sourceIsFocused: true, windowIsKey: true
        ))
    }
}
