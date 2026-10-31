import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Remote preview downloads (⌘-click and `cmux open`) share one cache; it is
/// kept under a size budget, least recently written first.
@Suite(.serialized)
struct RemotePreviewCacheBudgetTests {
    private static func makeCache(_ files: [(String, Int, TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-preview-cache-\(UUID().uuidString)", isDirectory: true)
        for (relativePath, size, age) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
            )
        }
        return root
    }

    private static func exists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    @Test
    func testOldestFilesGoFirstUntilTheCacheFitsTheBudget() throws {
        let root = try Self.makeCache([
            ("ns/a/old.sv", 400, 7_200), ("ns/b/middle.sv", 400, 3_600),
            ("ns/c/new.sv", 400, 1_800), ("other/d/kept.sv", 400, 9_000),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("other/d/kept.sv")
        let removed = RemotePreviewCacheBudget.evict(in: root, budgetBytes: 900, keeping: [kept.path], recentUseGrace: 60)
        #expect(removed.count == 2)
        #expect(!Self.exists(root, "ns/a/old.sv"))
        #expect(!Self.exists(root, "ns/b/middle.sv"))
        #expect(Self.exists(root, "ns/c/new.sv"))
        #expect(Self.exists(root, "other/d/kept.sv"))
        // Emptied per-path directories go too.
        #expect(!Self.exists(root, "ns/a"))
    }

    @Test
    func testRecentlyWrittenFilesAreNotEvicted() throws {
        // A preview opened a moment ago may still be on screen.
        let root = try Self.makeCache([("ns/a/open.sv", 1_000, 5), ("ns/b/stale.sv", 1_000, 7_200)])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = RemotePreviewCacheBudget.evict(in: root, budgetBytes: 10, keeping: [], recentUseGrace: 600)
        #expect(Self.exists(root, "ns/a/open.sv"))
        #expect(!Self.exists(root, "ns/b/stale.sv"))
    }

    @Test
    func testUnderBudgetNothingIsRemoved() throws {
        let root = try Self.makeCache([("ns/a/x.sv", 100, 7_200), ("ns/b/y.sv", 100, 7_200)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RemotePreviewCacheBudget.evict(in: root, budgetBytes: 1_000, keeping: [], recentUseGrace: 60).isEmpty)
        #expect(RemotePreviewCacheBudget.evict(in: root.appendingPathComponent("missing"), budgetBytes: 0, keeping: [], recentUseGrace: 0).isEmpty)
    }

    @Test
    func testDiscardingADownloadRemovesItsDirectoryButNothingAbove() throws {
        let root = try Self.makeCache([("ns/a/refused.webarchive", 10, 0), ("ns/b/other.sv", 10, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        RemotePreviewCacheBudget.discard(root.appendingPathComponent("ns/a/refused.webarchive"), cacheRoot: root)
        #expect(!Self.exists(root, "ns/a"))
        #expect(Self.exists(root, "ns/b/other.sv"))
        #expect(Self.exists(root, ""))
        // Never outside the cache.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-outside-\(UUID().uuidString)")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        RemotePreviewCacheBudget.discard(outside, cacheRoot: root)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func testDiscardLeavesAFileAnOpenPanelShows() throws {
        // The cache path is fixed per host file, so a download that won't be
        // shown may be the very file a viewer in another window has open.
        let root = try Self.makeCache([("ns/a/README.md", 10, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = root.appendingPathComponent("ns/a/README.md")
        RemotePreviewCacheBudget.discard(shown, cacheRoot: root, keeping: [shown.path])
        #expect(Self.exists(root, "ns/a/README.md"))
        RemotePreviewCacheBudget.discard(shown, cacheRoot: root, keeping: [])
        #expect(!Self.exists(root, "ns/a"))
    }

    @Test
    func testOnlyADownloadThatCreatedItsFileIsDiscarded() throws {
        let root = try Self.makeCache([("ns/a/README.md", 10, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ns/a/README.md")
        // Replaced a file an earlier open made: that open may still show it.
        RemotePreviewCacheBudget.discard(RemotePreviewDownload(url: url, isNew: false), cacheRoot: root, keeping: [])
        #expect(Self.exists(root, "ns/a/README.md"))
        RemotePreviewCacheBudget.discard(RemotePreviewDownload(url: url, isNew: true), cacheRoot: root, keeping: [url.path])
        #expect(Self.exists(root, "ns/a/README.md"))
        RemotePreviewCacheBudget.discard(RemotePreviewDownload(url: url, isNew: true), cacheRoot: root, keeping: [])
        #expect(!Self.exists(root, "ns/a"))
    }

    @Test
    func testADiscardLeavesAFileANewerDownloadPutInItsPlace() throws {
        // Two opens of one host file share a cache path: the older one's
        // discard must not delete what the newer one renamed there.
        let root = try Self.makeCache([("ns/a/wave.vcd", 10, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ns/a/wave.vcd")
        let older = RemotePreviewDownload(url: url, isNew: true, fileNumber: RemotePreviewDownload.fileNumber(of: url))
        let staging = root.appendingPathComponent("ns/a/newer.download")
        try Data(count: 20).write(to: staging)
        #expect(rename(staging.path, url.path) == 0)
        RemotePreviewCacheBudget.discard(older, cacheRoot: root, keeping: [])
        #expect(Self.exists(root, "ns/a/wave.vcd"))
        let newer = RemotePreviewDownload(url: url, isNew: true, fileNumber: RemotePreviewDownload.fileNumber(of: url))
        RemotePreviewCacheBudget.discard(newer, cacheRoot: root, keeping: [])
        #expect(!Self.exists(root, "ns/a"))
    }

    // MARK: cmux open of a dump read in place: when it opens, and how long its viewer refreshes

    @Test
    func testInPlaceOpenNeedsAConnectedSSHRootAndATerminalItsOwn() {
        typealias Gate = RemotePreviewInPlaceGate
        #expect(Gate.route(sshRootAvailable: true, terminalIsRemote: true, hasWorkspacePane: true) == .open)
        // A Dock terminal: nothing to split, so a notice instead of "not SSH".
        #expect(Gate.route(sshRootAvailable: true, terminalIsRemote: true, hasWorkspacePane: false) == .noticeNoPane)
        #expect(Gate.route(sshRootAvailable: false, terminalIsRemote: true, hasWorkspacePane: true) == .unavailable)
        #expect(Gate.route(sshRootAvailable: true, terminalIsRemote: false, hasWorkspacePane: true) == .unavailable)
    }

    @Test
    func testTheOpenNeedsItsTerminalButTheViewerOnlyItsWorkspaceConnection() {
        typealias Gate = RemotePreviewInPlaceGate
        // The open itself: selected, not retired, the terminal still on the same connection.
        #expect(Gate.openIsCurrent(isSelected: true, isRetired: false, terminalConfiguration: "a", openedWith: "a"))
        #expect(!Gate.openIsCurrent(isSelected: true, isRetired: false, terminalConfiguration: "b", openedWith: "a"))
        #expect(!Gate.openIsCurrent(isSelected: true, isRetired: false, terminalConfiguration: nil as String?, openedWith: "a"))
        #expect(!Gate.openIsCurrent(isSelected: false, isRetired: false, terminalConfiguration: "a", openedWith: "a"))
        #expect(!Gate.openIsCurrent(isSelected: true, isRetired: true, terminalConfiguration: "a", openedWith: "a"))
        // The viewer outlives its terminal (closed, or no longer in ssh): it
        // keeps refreshing while the workspace keeps that connection.
        #expect(Gate.panelIsCurrent(isSelected: true, isRetired: false, workspaceConfiguration: "a", openedWith: "a"))
        #expect(!Gate.panelIsCurrent(isSelected: true, isRetired: false, workspaceConfiguration: "b", openedWith: "a"))
        #expect(!Gate.panelIsCurrent(isSelected: true, isRetired: false, workspaceConfiguration: nil as String?, openedWith: "a"))
        #expect(!Gate.panelIsCurrent(isSelected: false, isRetired: false, workspaceConfiguration: "a", openedWith: "a"))
        #expect(!Gate.panelIsCurrent(isSelected: true, isRetired: true, workspaceConfiguration: "a", openedWith: "a"))
    }

    @Test
    func testTheViewerFollowsTheSSHIdentityNotTheRelaySession() {
        typealias Gate = RemotePreviewInPlaceGate
        let opened = SSHFileExplorerConnection(destination: "u@host", port: 22, identityFile: nil, sshOptions: ["-oControlPath=/tmp/c"])
        // A relay port or token rewrite leaves these four fields, so the viewer keeps refreshing.
        let rewritten = Gate.sshIdentity(
            transportIsSSH: true, destination: "u@host", port: 22, identityFile: nil, sshOptions: ["-oControlPath=/tmp/c"]
        )
        #expect(rewritten == opened)
        #expect(Gate.panelIsCurrent(isSelected: true, isRetired: false, workspaceConfiguration: rewritten, openedWith: opened))
        let otherHost = Gate.sshIdentity(
            transportIsSSH: true, destination: "u@other", port: 22, identityFile: nil, sshOptions: ["-oControlPath=/tmp/c"]
        )
        #expect(!Gate.panelIsCurrent(isSelected: true, isRetired: false, workspaceConfiguration: otherHost, openedWith: opened))
        #expect(Gate.sshIdentity(transportIsSSH: false, destination: "u@host", port: 22, identityFile: nil, sshOptions: []) == nil)
    }
}
