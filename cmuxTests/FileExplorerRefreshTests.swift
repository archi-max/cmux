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
    var homePath: String { "/p" }
    var isAvailable: Bool { true }
    var supportsTrash: Bool { false }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listedPaths.append(path)
        return listings[path] ?? []
    }

    func createFile(path: String) async throws { throw FileExplorerError.mutationFailed }
    func createDirectory(path: String) async throws { throw FileExplorerError.mutationFailed }
    func rename(path: String, to destinationPath: String) async throws { throw FileExplorerError.mutationFailed }
    func delete(path: String) async throws { throw FileExplorerError.mutationFailed }
    func copy(path: String, to destinationPath: String) async throws { throw FileExplorerError.mutationFailed }
    func moveToTrash(path: String) async throws { throw FileExplorerError.mutationFailed }
}
