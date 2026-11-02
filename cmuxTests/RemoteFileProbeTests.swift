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

    @Test func aZeroCapProbeLocatesAFileOnTheHostWithoutSendingIt() throws {
        // A clicked waveform dump is read in place on the host: only its host
        // path is needed, from a relative link, in one run.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("build/sim", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: dir.appendingPathComponent("dump.fsdb"))
        for shell in Self.shells {
            let result = try run(
                RemoteFileProbe.command(candidates: [dir.path + "/dump.fsdb:3", dir.path + "/dump.fsdb"], maxBytes: 0),
                shell: shell, home: root, in: root
            )
            let sent = root.appendingPathComponent("o-" + UUID().uuidString)
            do {
                _ = try RemoteFileProbe.outcome(status: result.status, raw: result.raw, to: sent)
                Issue.record("\(shell): a refused file must not count as sent")
            } catch let oversize as RemoteFileProbe.Oversize {
                #expect(oversize.header.index == 1, "\(shell)")
                #expect(oversize.header.path == dir.path + "/dump.fsdb", "\(shell)")
                #expect(oversize.header.size == 4096, "\(shell)")
            } catch {
                Issue.record("\(shell): \(error)")
            }
            #expect(((try? Data(contentsOf: sent)) ?? Data()).isEmpty, "\(shell): no bytes of the dump")
        }
    }

    @Test func theProbesOwnStatusesMapToTheirOutcomes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("raw")
        try Data("ssh: connect failed\n".utf8).write(to: raw)
        #expect(throws: RemoteFileProbe.Failure.noFile) {
            _ = try RemoteFileProbe.outcome(status: RemoteFileProbe.noFileStatus, raw: raw, to: root.appendingPathComponent("o"))
        }
        #expect(throws: RemoteFileProbe.Failure.tooLarge) {
            _ = try RemoteFileProbe.outcome(status: RemoteFileProbe.tooLargeStatus, raw: raw, to: root.appendingPathComponent("o"))
        }
        #expect(try RemoteFileProbe.outcome(status: 255, raw: raw, to: root.appendingPathComponent("o")) == nil)
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

    private func header(_ index: Int, _ path: String) -> String {
        "cmux-probe:\(index) 1 3 \(Data(path.utf8).base64EncodedString())\n"
    }

    @Test func aMarkerInsideABannerLineIsNotTheHeader() throws {
        let data = Data(("motd: " + header(7, "/fake") + header(0, "/home/u/a.sv") + "abc").utf8)
        let (parsed, offset) = try RemoteFileProbe.parseHeader(in: data)
        #expect(parsed.index == 0)
        #expect(parsed.path == "/home/u/a.sv")
        #expect(data[offset...] == Data("abc".utf8))
    }

    @Test func aHeaderWithARelativePathIsMalformed() {
        #expect(throws: RemoteFileProbe.Failure.malformedOutput) {
            _ = try RemoteFileProbe.parseHeader(in: Data((header(0, "a.sv") + "abc").utf8))
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

    private func placement(
        selected: Bool = true, retired: Bool = false, sourceUnchanged: Bool = true,
        configurationUnchanged: Bool = true, focused: Bool, key: Bool
    ) -> RemotePreviewPlacement? {
        RemotePreviewOpenRules.placement(
            isSelected: selected, isRetired: retired, sourceUnchanged: sourceUnchanged,
            configurationUnchanged: configurationUnchanged, sourceIsFocused: focused, windowIsKey: key
        )
    }

    @Test func aDownloadTakesFocusOnlyWhileTheUserIsStillOnTheSourceTerminal() {
        #expect(placement(focused: true, key: true) == .focused)
    }

    @Test func aLateDownloadNeverTakesTheKeyboardFromAnotherPanel() {
        // ⌘-click, then typing in another terminal of the workspace during the
        // download: the keystrokes must stay there.
        #expect(placement(focused: false, key: true) == .unfocused)
        #expect(placement(focused: true, key: false) == .unfocused, "another window or app is in front")
        #expect(placement(focused: false, key: false) == .unfocused)
    }

    @Test func aDownloadWhoseWorkspaceWasLeftStillOpensThereUnfocused() {
        // Switching workspaces during the download used to drop the file silently.
        #expect(placement(selected: false, focused: true, key: true) == .unfocusedInAnotherWorkspace)
        #expect(placement(selected: false, focused: false, key: false) == .unfocusedInAnotherWorkspace)
    }

    @Test func aDownloadIsDroppedWhenItsSourceIsGone() {
        #expect(placement(retired: true, focused: true, key: true) == nil)
        #expect(placement(sourceUnchanged: false, focused: true, key: true) == nil, "the terminal was replaced")
        #expect(placement(configurationUnchanged: false, focused: true, key: true) == nil, "the connection changed")
        #expect(placement(selected: false, sourceUnchanged: false, focused: false, key: false) == nil)
    }

    @Test func onlyAFocusedPlacementTakesTheKeyboard() {
        // Every open reads this: a download, an already-open file `cmux open`
        // shows again, and a dump the waveform viewer reads in place.
        #expect(RemotePreviewPlacement.focused.takesFocus)
        #expect(!RemotePreviewPlacement.unfocused.takesFocus)
        #expect(!RemotePreviewPlacement.unfocusedInAnotherWorkspace.takesFocus)
        #expect(placement(focused: false, key: true)?.takesFocus == false, "the in-place viewer while the user types elsewhere")
    }

    @Test func onlyAnOpenInALeftWorkspaceIsAnnounced() {
        // Including `cmux open` of a file already open there.
        #expect(RemotePreviewPlacement.unfocusedInAnotherWorkspace.announcesOpen)
        #expect(!RemotePreviewPlacement.unfocused.announcesOpen)
        #expect(!RemotePreviewPlacement.focused.announcesOpen)
        #expect(placement(selected: false, focused: true, key: true)?.announcesOpen == true)
    }

    @Test func aFailedPreviewLogsWhyWithoutPathsOrSSHOutput() {
        #expect(RemotePreviewOpenRules.failureReason(RemoteFileProbe.Failure.noFile) == "noFile")
        #expect(RemotePreviewOpenRules.failureReason(RemoteFileProbe.Failure.malformedOutput) == "malformedOutput")
        #expect(RemotePreviewOpenRules.failureReason(RemoteFileProbe.Failure.tooLarge) == "tooLarge")
        let header = RemoteFileProbe.Header(index: 0, path: "/home/u/secret.fsdb", modificationTime: 1, size: 2)
        #expect(RemotePreviewOpenRules.failureReason(RemoteFileProbe.Oversize(header: header)) == "tooLarge")
        #expect(RemotePreviewOpenRules.failureReason(URLError(.timedOut)) == "timeout")
        struct SSHFailed: Error, CustomStringConvertible { var description: String { "/home/u/x: denied" } }
        let other = RemotePreviewOpenRules.failureReason(SSHFailed())
        #expect(other == "SSHFailed", "the type, never the message")
    }

    @Test func aTerminalsDumpOpensOverThatTerminalsOwnConnection() {
        // The Files panel need not be connected (or rooted on the host) for a
        // terminal's link or `cmux open` to open a dump the host reads.
        #expect(RemotePreviewOpenRules.inPlaceConnection(terminal: "u@host:22", filesRoot: nil as String?) == "u@host:22")
        #expect(RemotePreviewOpenRules.inPlaceConnection(terminal: "u@host:22", filesRoot: "u@host:22") == "u@host:22")
        #expect(RemotePreviewOpenRules.inPlaceConnection(terminal: nil as String?, filesRoot: "u@host:22") == nil,
                "a terminal that isn't on the host never opens there")
    }

    private final class Flag: @unchecked Sendable {
        var value: RemotePreviewPlacement?
        init(_ value: RemotePreviewPlacement?) { self.value = value }
    }

    @Test func thePlacementIsReadAgainAfterTheLeaseIsPrepared() async {
        // The user leaves the terminal while the download is moved into the lease cache.
        let state = Flag(.focused)
        let moved = await RemotePreviewOpenRules.openAfter({ state.value = .unfocused; return 1 }, placement: { state.value })
        #expect(moved?.1 == .unfocused)
        let gone = await RemotePreviewOpenRules.openAfter({ state.value = nil; return 1 }, placement: { state.value })
        #expect(gone == nil, "the source went away during the await")
        let failed = await RemotePreviewOpenRules.openAfter({ () -> Int? in nil }, placement: { .focused })
        #expect(failed == nil)
    }

    private func viewer(markdown: Bool, routesMarkdown: Bool = true, routesSupported: Bool = true) -> RemoteClickViewer? {
        RemotePreviewOpenRules.clickViewer(isMarkdown: markdown, routesMarkdown: routesMarkdown, routesSupportedFile: routesSupported)
    }

    @Test func aClickedMarkdownFileOpensLeasedAndRendered() {
        // Like `cmux open` and the Files panel: the host path in the header,
        // Save to the host. The Markdown viewer could only show the cache copy.
        #expect(viewer(markdown: true) == .renderedMarkdown)
        #expect(viewer(markdown: true, routesSupported: false) == .renderedMarkdown, "the Markdown route alone is enough")
        #expect(viewer(markdown: true, routesMarkdown: false) == .source, "Markdown routing off: its source, still leased")
    }

    @Test func otherClickedFilesOpenLeasedAsSourceOrNotAtAll() {
        // HTML included: a host page is never a local web page.
        #expect(viewer(markdown: false) == .source)
        #expect(viewer(markdown: false, routesSupported: false) == nil)
        #expect(viewer(markdown: true, routesMarkdown: false, routesSupported: false) == nil)
    }
}
