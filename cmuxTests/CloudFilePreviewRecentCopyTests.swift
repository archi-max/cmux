import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with one file whose stamp moves on every write, counting the
/// requests an open makes.
private final class CountingHostTransport: SSHFileExplorerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: Data
    private var stamp: SSHRemoteFileStamp
    private(set) var stats = 0
    private(set) var downloads = 0
    private(set) var writes: [SSHRemoteFileStamp?] = []

    init(contents: Data, modificationTime: Int64 = 1000) {
        self.contents = contents
        stamp = SSHRemoteFileStamp(modificationTime: modificationTime, size: Int64(contents.count))
    }

    /// [stats, downloads] so far.
    var counts: [Int] { lock.withLock { [stats, downloads] } }
    var downloadCount: Int { lock.withLock { downloads } }
    var expectedStamps: [SSHRemoteFileStamp?] { lock.withLock { writes } }

    /// Someone else writes the host file.
    func replace(with data: Data) {
        lock.withLock {
            contents = data
            stamp = SSHRemoteFileStamp(modificationTime: stamp.modificationTime + 1, size: Int64(data.count))
        }
    }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String { "/home/dev" }
    func listDirectory(path: String, connection: SSHFileExplorerConnection, showHidden: Bool) async throws -> [FileExplorerEntry] { [] }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL) async throws {
        let data = lock.withLock { downloads += 1; return contents }
        try data.write(to: localURL)
    }

    /// One host request: the stamp, read first, and the bytes.
    func downloadFileWithStamp(path: String, connection: SSHFileExplorerConnection, to localURL: URL) async throws -> SSHRemoteFileStamp? {
        let (data, current): (Data, SSHRemoteFileStamp) = lock.withLock { downloads += 1; return (contents, stamp) }
        try data.write(to: localURL)
        return current
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL, maxBytes: Int64) async throws {
        try await downloadFile(path: path, connection: connection, to: localURL)
    }

    func probeDownload(candidates: [String], maxBytes: Int64?, connection: SSHFileExplorerConnection,
                       to localURL: URL) async throws -> RemoteFileProbe.Header {
        throw RemoteFileProbe.Failure.noFile
    }

    func fileStamp(path: String, connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        lock.withLock { stats += 1; return stamp }
    }

    func writeFile(path: String, contents data: Data, expectedStamp: SSHRemoteFileStamp?,
                   connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        try lock.withLock {
            writes.append(expectedStamp)
            if let expectedStamp, expectedStamp != stamp { throw FileExplorerError.remoteFileChanged }
            contents = data
            stamp = SSHRemoteFileStamp(modificationTime: stamp.modificationTime + 1, size: Int64(data.count))
            return stamp
        }
    }
}

/// Reopening an SSH file paints its last copy without waiting on the host,
/// then checks it with one stat; a copy that turns out stale is replaced, and
/// is never saved over the newer host file.
@Suite(.serialized) struct CloudFilePreviewRecentCopyTests {
    private let path = "/home/dev/rtl/top.sv"

    private func fixture(_ text: String) -> (CloudFilePreviewCache, SSHFileExplorerProvider, CountingHostTransport, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ff-recent-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = CountingHostTransport(contents: Data(text.utf8))
        let provider = SSHFileExplorerProvider(destination: "dev@host", port: nil, identityFile: nil, sshOptions: [],
                                               homePath: "/home/dev", isAvailable: true, transport: host)
        return (CloudFilePreviewCache(directory: directory), provider, host, directory)
    }

    private func text(_ lease: CloudFilePreviewLease) throws -> String {
        String(decoding: try Data(contentsOf: lease.url), as: UTF8.self)
    }

    @Test func aReopenPaintsTheLastCopyWithoutADownload() async throws {
        let (cache, provider, host, directory) = fixture("module top; endmodule\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        #expect(!first.isUnverified && host.counts == [0, 1], "a first open is one host request: \(host.counts)")
        await cache.release(first.url)

        let reopened = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        let shown = try text(reopened)
        #expect(shown == "module top; endmodule\n")
        #expect(reopened.isUnverified && reopened.remoteStamp == first.remoteStamp)
        #expect(host.counts == [0, 1], "the reopen itself asks the host nothing: \(host.counts)")

        // Unchanged on the host: the check is one stat and no download.
        let replaced = try await reopened.refresh(using: provider)
        #expect(!replaced && !reopened.isUnverified && host.counts == [1, 1], "\(host.counts)")
    }

    @Test func aStaleCopyIsReplacedAndNeverSavedOverTheNewerHostFile() async throws {
        let (cache, provider, host, directory) = fixture("old\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        let oldStamp = first.remoteStamp
        await cache.release(first.url)
        host.replace(with: Data("new from a teammate\n".utf8))

        let reopened = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        let shown = try text(reopened)
        #expect(shown == "old\n" && reopened.remoteStamp == oldStamp)
        // A save of the stale copy, before the check lands, conflicts.
        await #expect(throws: FileExplorerError.remoteFileChanged) {
            try await reopened.upload(Data("edited old\n".utf8), overwrite: false)
        }
        #expect(host.expectedStamps == [oldStamp])

        let replaced = try await reopened.refresh(using: provider)
        #expect(replaced && !reopened.isUnverified)
        let refreshed = try text(reopened)
        #expect(refreshed == "new from a teammate\n")
        #expect(reopened.remoteStamp != oldStamp)
        try await reopened.upload(Data("merged\n".utf8), overwrite: false)
    }

    @Test func aRefreshDownloadsWhenTheLocalCopyWasTouched() async throws {
        let (cache, provider, host, directory) = fixture("a\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try await cache.materialize(path: path, provider: provider)
        // Changed beside the cache (another size and a later date): the host file comes back.
        try Data("local scribble\n".utf8).write(to: lease.url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: lease.url.path)
        let replaced = try await lease.refresh(using: provider)
        let shown = try text(lease)
        #expect(replaced && host.downloadCount == 2 && shown == "a\n")
    }

    @Test func aSaveBecomesTheNextReopensCopy() async throws {
        let (cache, provider, host, directory) = fixture("v1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        try await lease.upload(Data("v2\n".utf8), overwrite: false)
        let saved = lease.remoteStamp
        await cache.release(lease.url)
        let reopened = try await cache.materialize(path: path, provider: provider, allowRecentCopy: true)
        let shown = try text(reopened)
        #expect(shown == "v2\n" && reopened.remoteStamp == saved && host.downloadCount == 1)
        // Another host or connection never sees this host's copy.
        let other = SSHFileExplorerProvider(destination: "dev@other", port: nil, identityFile: nil, sshOptions: [],
                                            homePath: "/home/dev", isAvailable: true, transport: host)
        let elsewhere = try await cache.materialize(path: path, provider: other, allowRecentCopy: true)
        #expect(!elsewhere.isUnverified && host.downloadCount == 2)
    }

    @Test func withoutTheOptionEveryOpenDownloads() async throws {
        let (cache, provider, host, directory) = fixture("x\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await cache.materialize(path: path, provider: provider)
        await cache.release(first.url)
        let second = try await cache.materialize(path: path, provider: provider)
        #expect(!second.isUnverified && host.downloadCount == 2)
    }
}
