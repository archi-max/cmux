import CmuxCore
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerRootResolverTests: XCTestCase {

    // MARK: - Local home paths

    func testHomeDirectoryDisplaysAsTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~")
    }

    func testSubdirectoryOfHomeDisplaysWithTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Projects/myapp",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~/Projects/myapp")
    }

    func testNonHomePathDisplaysVerbatim() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/var/log",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "/var/log")
    }

    func testNilHomePathReturnsFullPath() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents",
            homePath: nil
        )
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    func testEmptyHomePathReturnsFullPath() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents",
            homePath: ""
        )
        XCTAssertEqual(result, "/Users/alice/Documents")
    }

    // MARK: - SSH home paths

    func testSSHHomePathDisplaysAsTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/home/deploy",
            homePath: "/home/deploy"
        )
        XCTAssertEqual(result, "~")
    }

    func testSSHSubdirectoryDisplaysWithTilde() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/home/deploy/app/src",
            homePath: "/home/deploy"
        )
        XCTAssertEqual(result, "~/app/src")
    }

    func testSSHRootPathDisplaysVerbatim() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/etc/nginx",
            homePath: "/root"
        )
        XCTAssertEqual(result, "/etc/nginx")
    }

    // MARK: - Trailing slash normalization

    func testTrailingSlashOnHomeIsNormalized() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/",
            homePath: "/Users/alice/"
        )
        XCTAssertEqual(result, "~")
    }

    func testTrailingSlashOnPathIsNormalized() {
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alice/Documents/",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "~/Documents")
    }

    // MARK: - Edge cases

    func testSimilarPrefixDoesNotMatch() {
        // "/Users/alicex" should NOT match home="/Users/alice"
        let result = FileExplorerRootResolver.displayPath(
            for: "/Users/alicex/Documents",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "/Users/alicex/Documents")
    }

    func testEmptyPathReturnsEmpty() {
        let result = FileExplorerRootResolver.displayPath(
            for: "",
            homePath: "/Users/alice"
        )
        XCTAssertEqual(result, "")
    }
}

/// "Set as Files Root" overrides the terminal-derived root for local and SSH
/// workspaces, survives session restore, and "Follow Terminal Directory" undoes it.
@MainActor
@Suite
struct FileExplorerWorkspaceRootPinTests {
    private final class NotificationCounter { var value = 0 }

    @Test
    func pinOverridesTheLocalTerminalDirectoryUntilCleared() {
        let workspace = Workspace()
        workspace.currentDirectory = "/tmp/cmux-pin-test/terminal"
        let resolver = FileExplorerWorkspaceRootResolver()
        #expect(resolver.resolve(workspace) == .local(workspaceId: workspace.id, path: "/tmp/cmux-pin-test/terminal"))

        workspace.setFileExplorerPinnedRootPath("/tmp/cmux-pin-test/pinned")
        #expect(resolver.resolve(workspace) == .local(workspaceId: workspace.id, path: "/tmp/cmux-pin-test/pinned"))

        // The terminal moving does not move a pinned root.
        workspace.currentDirectory = "/tmp/cmux-pin-test/elsewhere"
        #expect(resolver.resolve(workspace) == .local(workspaceId: workspace.id, path: "/tmp/cmux-pin-test/pinned"))

        workspace.setFileExplorerPinnedRootPath(nil)
        #expect(resolver.resolve(workspace) == .local(workspaceId: workspace.id, path: "/tmp/cmux-pin-test/elsewhere"))
    }

    @Test
    func blankPinFollowsTheTerminalDirectory() {
        let workspace = Workspace()
        workspace.setFileExplorerPinnedRootPath("/tmp/cmux-pin-test/pinned")
        workspace.setFileExplorerPinnedRootPath("   ")
        #expect(workspace.fileExplorerPinnedRootPath == nil)
    }

    @Test
    func pinOverridesTheSSHRootAndKeepsTheConnection() throws {
        let workspace = Workspace()
        try #require(workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev-host",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: String(repeating: "a", count: 16),
                relayToken: String(repeating: "b", count: 64),
                localSocketPath: "/tmp/cmux-pin-test.sock",
                terminalStartupCommand: "ssh dev-host"
            ),
            autoConnect: false
        ))
        let resolver = FileExplorerWorkspaceRootResolver()
        guard case let .remoteSSH(_, unpinnedConnection, _, _, _, _) = resolver.resolve(workspace) else {
            Issue.record("expected an SSH root")
            return
        }

        workspace.setFileExplorerPinnedRootPath("/srv/project")
        guard case let .remoteSSH(workspaceId, connection, _, rootPath, _, _) = resolver.resolve(workspace) else {
            Issue.record("expected an SSH root")
            return
        }
        #expect(workspaceId == workspace.id)
        #expect(rootPath == "/srv/project")
        #expect(connection == unpinnedConnection)
        #expect(connection.destination == "dev-host")
    }

    @Test
    func pinChangesNotifyOnlyWhenTheValueChanges() {
        let workspace = Workspace()
        let notifications = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .workspaceFileExplorerRootPinDidChange,
            object: workspace,
            queue: nil
        ) { _ in MainActor.assumeIsolated { notifications.value += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        workspace.setFileExplorerPinnedRootPath("/tmp/cmux-pin-test/pinned")
        workspace.setFileExplorerPinnedRootPath("/tmp/cmux-pin-test/pinned")
        workspace.setFileExplorerPinnedRootPath(nil)
        workspace.setFileExplorerPinnedRootPath(nil)
        #expect(notifications.value == 2)
    }

    @Test
    func pinSurvivesSessionRestore() throws {
        let workspace = Workspace()
        workspace.setFileExplorerPinnedRootPath("/tmp/cmux-pin-test/pinned")
        let saved = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        )
        #expect(saved.fileExplorerPinnedRootPath == "/tmp/cmux-pin-test/pinned")

        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(saved)
        #expect(restored.fileExplorerPinnedRootPath == "/tmp/cmux-pin-test/pinned")

        // Files follows the terminal directory when the snapshot has no pin.
        workspace.setFileExplorerPinnedRootPath(nil)
        let unpinned = try JSONEncoder().encode(workspace.sessionSnapshot(includeScrollback: false))
        let object = try #require(try JSONSerialization.jsonObject(with: unpinned) as? [String: Any])
        #expect(object["fileExplorerPinnedRootPath"] == nil)
    }
}
