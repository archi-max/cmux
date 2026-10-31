import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct RemoteTerminalFilePreviewLoaderTests {
    @Test func nativeSSHPreviewRequiresTheProjectedConnection() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        let configuration = WorkspaceRemoteConfiguration(
            destination: "fixture@remote.invalid", port: 2222, identityFile: "/tmp/fixture-key",
            sshOptions: ["ProxyJump=fixture-jump"], localProxyPort: nil, relayPort: nil,
            relayID: nil, relayToken: nil, localSocketPath: nil, terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.remoteConfiguration = configuration
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == nil)
        let resource = SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id),
            kind: .terminal, key: "term_" + UUID().uuidString
        )
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        #expect(workspace.activeRemoteTerminalSurfaceIds.isEmpty)
        #expect(workspace.terminalLinkIsRemoteTerminal(panelID))
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == configuration)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "fixture@different.invalid", port: 2222, identityFile: "/tmp/fixture-key",
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true
        )
        // An old projection must neither download from the replacement host nor resolve locally.
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == nil)
        #expect(workspace.terminalLinkIsRemoteTerminal(panelID))
    }

    @Test func downloadsRemoteBytesInsteadOfReadingLocalShadow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shadow = root.appendingPathComponent("same name.txt")
        try Data("local shadow".utf8).write(to: shadow)
        let transport = PreviewDownloadTransport(files: [shadow.path: Data("remote bytes".utf8)])
        let loader = makeLoader(transport: transport, cache: root.appendingPathComponent("cache"))
        let result = try await loader.load(tokens: [shadow.path], workingDirectory: nil).url
        #expect(result != shadow)
        #expect(result.lastPathComponent == shadow.lastPathComponent)
        #expect(try String(contentsOf: result, encoding: .utf8) == "remote bytes")
        #expect(try String(contentsOf: shadow, encoding: .utf8) == "local shadow")
        #expect(await transport.requests.paths == [shadow.path])
    }

    @Test func retriesEscapedSpellingAgainstRemoteHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/home/remote/file name.txt": Data("remote".utf8)])
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["~/file\\ name.txt,"], workingDirectory: "/wrong"
        ).url
        #expect(result.lastPathComponent == "file name.txt")
        #expect(try String(contentsOf: result, encoding: .utf8) == "remote")
        let paths = await transport.requests.paths.filter { $0 != "HOME" }
        #expect(paths.last == "/home/remote/file name.txt")
        #expect(paths.allSatisfy { $0.hasPrefix("/home/remote/") })
    }

    @Test func cancellationDoesNotBeginAHomeLookupOrDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: [:])
        let loader = makeLoader(transport: transport, cache: root)
        let task = Task { try await loader.load(tokens: ["~/file.txt"], workingDirectory: nil) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled request completed")
        } catch is CancellationError {
        }
        #expect(await transport.requests.paths.isEmpty)
    }

    // MARK: cmux open (exact path, size-capped)

    @Test func commandLineDownloadStopsAtTheCapEvenWhenTheHostUnderstatesTheSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The file grew (or the host lied) between the size check and the download.
        let transport = PreviewDownloadTransport(
            files: ["/home/u/grow.log": Data(count: 2_000)], statedSizes: ["/home/u/grow.log": 10]
        )
        let cache = root.appendingPathComponent("cache")
        await #expect(throws: RemoteTerminalFilePreviewError.fileTooLarge) {
            _ = try await makeLoader(transport: transport, cache: cache).load(exactPath: "/home/u/grow.log", maxBytes: 1_000)
        }
        #expect(await transport.requests.caps == [1_000])
        let left = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        #expect(left.isEmpty, "a refused download must not stay in the cache")
    }

    @Test func commandLineDownloadRefusesAnOversizeFileBeforeFetchingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(
            files: ["/home/u/big.fsdb": Data(count: 10)], statedSizes: ["/home/u/big.fsdb": 5_000]
        )
        await #expect(throws: RemoteTerminalFilePreviewError.fileTooLarge) {
            _ = try await makeLoader(transport: transport, cache: root).load(exactPath: "/home/u/big.fsdb", maxBytes: 1_000)
        }
        #expect(await transport.requests.paths.isEmpty)
    }

    @Test func commandLineDownloadUsesOnlyTheExactPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // A ⌘-click would retry "/home/u/a.txt" for "/home/u/a.txt,"; cmux open must not.
        let transport = PreviewDownloadTransport(files: ["/home/u/a.txt": Data("x".utf8)])
        await #expect(throws: (any Error).self) {
            _ = try await makeLoader(transport: transport, cache: root).load(exactPath: "/home/u/a.txt,", maxBytes: 1_000)
        }
        #expect(await transport.requests.paths.allSatisfy { $0 == "/home/u/a.txt," })
        let fits = try await makeLoader(transport: transport, cache: root).load(exactPath: "/home/u/a.txt", maxBytes: 1_000).url
        #expect(try Data(contentsOf: fits) == Data("x".utf8))
    }

    @Test func commandLineOpensRefuseQuickLookOnlyTypesBeforeDownloading() {
        for refused in ["/h/page.webarchive", "/h/mail.eml", "/h/report.docx", "/h/sheet.xlsx"] {
            #expect(FilePreviewKindResolver.opensOnlyThroughQuickLook(path: refused), "\(refused)")
        }
        for allowed in [
            "/h/alu.sv", "/h/notes.txt", "/h/page.html", "/h/README.md", "/h/doc.pdf", "/h/pic.png",
            "/h/wave.fsdb", "/h/Makefile", "/h/README", "/h/Info.plist", "/h/clip.mp4", "/h/run.log",
        ] {
            #expect(!FilePreviewKindResolver.opensOnlyThroughQuickLook(path: allowed), "\(allowed)")
        }
    }

    @Test func evictionSparesFilesOpenPanelsShowWhateverTheirAge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shown = root.appendingPathComponent("other/a/open.sv")
        let stale = root.appendingPathComponent("other/b/stale.sv")
        for url in [shown, stale] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 500).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: url.path)
        }
        let transport = PreviewDownloadTransport(files: ["/home/u/new.sv": Data(count: 10)])
        let shownPath = shown.path
        let loader = makeLoader(transport: transport, cache: root, budgetBytes: 100, shownPaths: { [shownPath] })
        let fetched = try await loader.load(exactPath: "/home/u/new.sv", maxBytes: 1_000).url
        #expect(FileManager.default.fileExists(atPath: fetched.path))
        #expect(FileManager.default.fileExists(atPath: shown.path), "a file an open preview shows must stay")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func commandLineOpensReadFSDBInPlaceAndDownloadOtherWaveforms() {
        // FSDB is read by Verdi's reader on the host, as the Files panel does: never downloaded.
        #expect(FilePreviewKindResolver.commandLineOpenRoute(path: "/h/wave.fsdb") == .readInPlaceOnHost)
        #expect(FilePreviewKindResolver.commandLineOpenRoute(path: "/h/WAVE.FSDB") == .readInPlaceOnHost)
        #expect(FilePreviewKindResolver.commandLineOpenRoute(path: "/h/page.webarchive") == .filesPanelOnly)
        for downloaded in ["/h/wave.vcd", "/h/wave.fst", "/h/wave.ghw", "/h/alu.sv"] {
            #expect(FilePreviewKindResolver.commandLineOpenRoute(path: downloaded) == .download, "\(downloaded)")
        }
    }

    @Test func aDownloadSaysWhetherItCreatedTheCacheFile() async throws {
        // Only a file this request created may be discarded: an earlier open of
        // the same host file uses the same cache path and may still be shown.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/home/u/a.sv": Data("x".utf8)])
        let loader = makeLoader(transport: transport, cache: root)
        let first = try await loader.load(exactPath: "/home/u/a.sv", maxBytes: 1_000)
        let second = try await loader.load(exactPath: "/home/u/a.sv", maxBytes: 1_000)
        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(first.url == second.url)
        let clicked = try await loader.load(tokens: ["/home/u/a.sv"], workingDirectory: nil)
        #expect(!clicked.isNew)
    }

    private func makeLoader(
        transport: PreviewDownloadTransport,
        cache: URL,
        budgetBytes: Int64 = RemotePreviewCacheBudget.defaultBudgetBytes,
        shownPaths: @escaping @MainActor @Sendable () -> Set<String> = { [] }
    ) -> RemoteTerminalFilePreviewLoader {
        RemoteTerminalFilePreviewLoader(
            provider: SSHFileExplorerProvider(
                destination: "fixture@host", port: 2200, identityFile: nil, sshOptions: [],
                homePath: "", isAvailable: true, transport: transport
            ),
            cacheDirectory: cache,
            fileManager: FileManager(),
            budgetBytes: budgetBytes,
            shownPaths: shownPaths
        )
    }
}

private actor PreviewDownloadRequests {
    var paths: [String] = []
    var caps: [Int64] = []
    func record(_ path: String) { paths.append(path) }
    func recordCap(_ cap: Int64) { caps.append(cap) }
}

private final class PreviewDownloadTransport: SSHFileExplorerTransport, Sendable {
    let files: [String: Data]
    /// Sizes the fake host reports from `stat`; the real size when absent.
    let statedSizes: [String: Int64]
    let requests = PreviewDownloadRequests()
    init(files: [String: Data], statedSizes: [String: Int64] = [:]) {
        self.files = files
        self.statedSizes = statedSizes
    }
    nonisolated func fileStamp(path: String, connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        guard let data = files[path] else { throw FileExplorerError.providerUnavailable }
        guard let stamp = SSHRemoteFileStamp(statOutput: "1 \(statedSizes[path] ?? Int64(data.count))") else {
            throw FileExplorerError.providerUnavailable
        }
        return stamp
    }
    /// Ignores the cap on purpose: the loader must enforce it on what arrives.
    nonisolated func downloadFile(
        path: String, connection: SSHFileExplorerConnection, to localURL: URL, maxBytes: Int64
    ) async throws {
        await requests.recordCap(maxBytes)
        try await downloadFile(path: path, connection: connection, to: localURL)
    }
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        await requests.record("HOME")
        return "/home/remote"
    }
    nonisolated func listDirectory(
        path: String, connection: SSHFileExplorerConnection, showHidden: Bool
    ) async throws -> [FileExplorerEntry] { [] }
    nonisolated func downloadFile(
        path: String, connection: SSHFileExplorerConnection, to localURL: URL
    ) async throws {
        await requests.record(path)
        guard let data = files[path] else { throw FileExplorerError.providerUnavailable }
        try data.write(to: localURL)
    }
}
