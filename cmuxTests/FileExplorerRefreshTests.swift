import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Right-click Refresh in the Files panel: the tree can fall out of sync with
/// the filesystem (an SSH host has no watcher), so the blank area re-lists the
/// whole tree and a folder row re-lists that folder, both through the store's
/// normal listing path.
@MainActor
@Suite("File explorer refresh", .serialized)
struct FileExplorerRefreshTests {
    @Test("Refreshing the root re-lists the tree and keeps expanded folders open")
    func refreshRootRelistsTree() async throws {
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [.init(name: "src", path: "/p/src", isDirectory: true)]
        provider.listings["/p/src"] = [.init(name: "a.sv", path: "/p/src/a.sv", isDirectory: false)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 1 }
        store.expand(node: store.rootNodes[0])
        try await waitUntil("src listed") { store.rootNodes[0].children?.count == 1 }

        provider.listings["/p"] = [
            .init(name: "src", path: "/p/src", isDirectory: true),
            .init(name: "new.txt", path: "/p/new.txt", isDirectory: false),
        ]
        provider.listings["/p/src"] = [
            .init(name: "a.sv", path: "/p/src/a.sv", isDirectory: false),
            .init(name: "b.sv", path: "/p/src/b.sv", isDirectory: false),
        ]
        store.refresh(directoryAt: "/p")
        try await waitUntil("new root entry") { store.rootNodes.map(\.name) == ["src", "new.txt"] }
        try await waitUntil("expanded folder re-listed") { store.rootNodes[0].children?.count == 2 }
        #expect(store.isExpanded(store.rootNodes[0]))
    }

    @Test("Refreshing a folder re-lists only that folder")
    func refreshFolderRelistsOnlyThatFolder() async throws {
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [
            .init(name: "src", path: "/p/src", isDirectory: true),
            .init(name: "doc", path: "/p/doc", isDirectory: true),
        ]
        provider.listings["/p/src"] = [.init(name: "a.sv", path: "/p/src/a.sv", isDirectory: false)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 2 }
        let src = try #require(store.rootNodes.first { $0.name == "src" })
        store.expand(node: src)
        try await waitUntil("src listed") { src.children?.count == 1 }
        let rootNodes = store.rootNodes

        provider.listings["/p/src"] = [
            .init(name: "a.sv", path: "/p/src/a.sv", isDirectory: false),
            .init(name: "b.sv", path: "/p/src/b.sv", isDirectory: false),
        ]
        provider.listedPaths = []
        store.refresh(directoryAt: "/p/src")
        try await waitUntil("src re-listed") { src.children?.map(\.name) == ["a.sv", "b.sv"] }
        #expect(provider.listedPaths == ["/p/src"])
        #expect(store.rootNodes.map(ObjectIdentifier.init) == rootNodes.map(ObjectIdentifier.init),
                "the rest of the tree stays as it is")
    }

    @Test("A folder that was never listed is left for its next expand")
    func refreshUnlistedFolderDoesNothing() async throws {
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [.init(name: "src", path: "/p/src", isDirectory: true)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 1 }
        provider.listedPaths = []
        store.refresh(directoryAt: "/p/src")
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.listedPaths.isEmpty)
    }

    @Test("Refresh targets the clicked folder, or the root for the blank area, and never a file")
    func refreshMenuTarget() {
        let folder = FileExplorerNode(name: "src", path: "/p/src", isDirectory: true)
        let file = FileExplorerNode(name: "a.sv", path: "/p/a.sv", isDirectory: false)
        #expect(FileExplorerRefreshMenuTarget.path(clickedNode: folder, rootPath: "/p") == "/p/src")
        #expect(FileExplorerRefreshMenuTarget.path(clickedNode: nil, rootPath: "/p") == "/p")
        #expect(FileExplorerRefreshMenuTarget.path(clickedNode: file, rootPath: "/p") == nil)
        #expect(FileExplorerRefreshMenuTarget.path(clickedNode: nil, rootPath: "") == nil)
    }

    @Test("The blank-area context menu offers Refresh")
    func blankAreaMenuOffersRefresh() async throws {
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [.init(name: "src", path: "/p/src", isDirectory: true)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 1 }
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .files)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        let refresh = menu.items.first { $0.title == String(localized: "fileExplorer.contextMenu.refresh", defaultValue: "Refresh") }
        #expect(refresh != nil, "items: \(menu.items.map(\.title))")
        #expect((refresh?.representedObject as? String) == "/p")
        withExtendedLifetime(container) {}
    }

    @Test("A folder Refresh cancels the listings still running under it")
    func refreshCancelsDescendantLoads() async throws {
        // A stale listing of an expanded child must not land after the new one,
        // or the store's path index points at nodes that are off screen.
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [.init(name: "src", path: "/p/src", isDirectory: true)]
        provider.listings["/p/src"] = [.init(name: "sub", path: "/p/src/sub", isDirectory: true)]
        provider.listings["/p/src/sub"] = [.init(name: "deep", path: "/p/src/sub/deep", isDirectory: true)]
        provider.heldPaths = ["/p/src/sub"]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 1 }
        let src = store.rootNodes[0]
        store.expand(node: src)
        try await waitUntil("src listed") { src.children?.count == 1 }
        store.expand(node: try #require(src.children?.first))
        try await waitUntil("old sub listing held") { provider.heldCount(for: "/p/src/sub") == 1 }

        store.refresh(directoryAt: "/p/src")
        try await waitUntil("new sub listing held") { provider.heldCount(for: "/p/src/sub") == 2 }
        let sub = try #require(src.children?.first)
        provider.release("/p/src/sub", index: 1)
        try await waitUntil("new sub listed") { sub.children?.count == 1 }
        provider.release("/p/src/sub", index: 0)
        try await Task.sleep(for: .milliseconds(100))

        // The visible `deep` is the one Refresh must reach.
        let deep = try #require(sub.children?.first)
        store.expand(node: deep)
        try await waitUntil("deep listed") { deep.children != nil }
        provider.listings["/p/src/sub/deep"] = [.init(name: "x.sv", path: "/p/src/sub/deep/x.sv", isDirectory: false)]
        store.refresh(directoryAt: "/p/src/sub/deep")
        try await waitUntil("visible deep re-listed") { deep.children?.map(\.name) == ["x.sv"] }
    }

    @Test("A folder Refresh also drops Go to File's kept listing")
    func folderRefreshInvalidatesGoToFile() async throws {
        let provider = RefreshListingProvider()
        provider.listings["/p"] = [.init(name: "src", path: "/p/src", isDirectory: true)]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitUntil("root listed") { store.rootNodes.count == 1 }
        store.expand(node: store.rootNodes[0])
        try await waitUntil("src listed") { store.rootNodes[0].children != nil }

        let source = GoToFileSnapshotSource.local(rootPath: "/files-refresh-test-\(UUID().uuidString)")
        _ = try await GoToFileSnapshotLoader.cache.value(for: source) { GoToFileSnapshot(paths: ["old"], isTruncated: false) }
        store.refresh(directoryAt: "/p/src")
        let after = try await GoToFileSnapshotLoader.cache.value(for: source) { GoToFileSnapshot(paths: ["new"], isTruncated: false) }
        #expect(after.paths == ["new"])
    }

    @Test("Repeated Refreshes run git status once more at the end, not once each")
    func repeatedRefreshesCoalesceGitStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-refresh-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("git.log")
        let fakeGit = directory.appendingPathComponent("fake-git")
        // Each `status` takes a while, as over SSH.
        try """
            #!/bin/sh
            case "$1" in
              rev-parse) pwd ;;
              status) echo status >> '\(log.path)'; sleep 0.4 ;;
            esac
            """.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)
        // The log and the fake git live outside the root, so the root's watcher stays quiet.
        let root = directory.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FileExplorerStore(gitStatusProvider: GitStatusProvider(gitExecutableURL: fakeGit))
        store.setProviderForTesting(LocalFileExplorerProvider())
        store.setRootPath(root.path)
        try await Task.sleep(for: .milliseconds(1_000))
        try? FileManager.default.removeItem(at: log)

        for _ in 0..<4 { store.refresh(directoryAt: root.path) }
        try await Task.sleep(for: .milliseconds(1_800))
        let runs = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
        #expect(runs == 2, "one run in flight, then one for the Refreshes that came during it; got \(runs)")
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RefreshListingProvider: FileExplorerProvider {
    var listings: [String: [FileExplorerEntry]] = [:]
    var listedPaths: [String] = []
    /// Listings of these paths wait for ``release(_:index:)``.
    var heldPaths: Set<String> = []
    private var held: [String: [CheckedContinuation<Void, Never>?]] = [:]
    var homePath: String { "/p" }
    var isAvailable: Bool { true }
    var supportsTrash: Bool { false }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listedPaths.append(path)
        if heldPaths.contains(path) {
            await withCheckedContinuation { continuation in
                held[path, default: []].append(continuation)
            }
        }
        return listings[path] ?? []
    }

    func heldCount(for path: String) -> Int { held[path]?.count ?? 0 }

    func release(_ path: String, index: Int) {
        held[path]?[index]?.resume()
        held[path]?[index] = nil
    }

    func createFile(path: String) async throws { throw FileExplorerError.mutationFailed }
    func createDirectory(path: String) async throws { throw FileExplorerError.mutationFailed }
    func rename(path: String, to destinationPath: String) async throws { throw FileExplorerError.mutationFailed }
    func delete(path: String) async throws { throw FileExplorerError.mutationFailed }
    func copy(path: String, to destinationPath: String) async throws { throw FileExplorerError.mutationFailed }
    func moveToTrash(path: String) async throws { throw FileExplorerError.mutationFailed }
}
