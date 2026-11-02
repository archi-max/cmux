import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with files at absolute paths, counting its requests: a stat, a
/// download, or a one-request capped probe (stamp and bytes together).
private final class RequestCountingTransport: SSHFileExplorerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let files: [String: Data]
    private var log: [String] = []

    init(files: [String: Data]) { self.files = files }

    var requests: [String] { lock.withLock { log } }
    private func note(_ request: String) { lock.withLock { log.append(request) } }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String { "/home/dev" }
    func listDirectory(path: String, connection: SSHFileExplorerConnection, showHidden: Bool) async throws -> [FileExplorerEntry] { [] }

    func fileStamp(path: String, connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        note("stat")
        guard let data = files[path] else { throw FileExplorerError.mutationFailed }
        return SSHRemoteFileStamp(modificationTime: 7, size: Int64(data.count))
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL) async throws {
        note("download")
        guard let data = files[path] else { throw FileExplorerError.mutationFailed }
        try data.write(to: localURL)
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL, maxBytes: Int64) async throws {
        note("download")
        guard let data = files[path] else { throw FileExplorerError.mutationFailed }
        try data.prefix(Int(maxBytes) + 1).write(to: localURL)
    }

    func probeDownload(candidates: [String], maxBytes: Int64?, connection: SSHFileExplorerConnection,
                       to localURL: URL) async throws -> RemoteFileProbe.Header {
        note("probe")
        for (index, path) in candidates.enumerated() {
            guard let data = files[path] else { continue }
            let header = RemoteFileProbe.Header(index: index, path: path, modificationTime: 7, size: Int64(data.count))
            if let maxBytes, Int64(data.count) > maxBytes { throw RemoteFileProbe.Oversize(header: header) }
            try data.write(to: localURL)
            return header
        }
        throw RemoteFileProbe.Failure.noFile
    }
}

/// A capped remote read (a Markdown image, a waveform session) is one host
/// request: the stamp and the bytes come together, and a file over the cap
/// or missing sends nothing.
@Suite(.serialized) struct RemoteCappedDownloadTests {
    private func provider(_ files: [String: Data]) -> (SSHFileExplorerProvider, RequestCountingTransport) {
        let transport = RequestCountingTransport(files: files)
        return (SSHFileExplorerProvider(destination: "dev@host", port: nil, identityFile: nil, sshOptions: [],
                                        homePath: "/home/dev", isAvailable: true, transport: transport), transport)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ff-capped-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aMarkdownImageIsOneHostRequest() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 1, count: 100))
        let (provider, host) = provider(["/home/dev/doc/fig.png": png])
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = MarkdownRemoteImageLoader(provider: provider, cacheDirectory: directory)
        let data = await loader.load(remotePath: "/home/dev/doc/fig.png")
        #expect(data == png)
        #expect(host.requests == ["probe"], "one request, not a stat then a download: \(host.requests)")
    }

    @Test func anOversizeOrMissingImageSendsNothing() async throws {
        let big = Data(repeating: 0, count: Int(MarkdownRemoteImageLoader.maximumImageBytes) + 1)
        let (provider, host) = provider(["/home/dev/big.png": big])
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = MarkdownRemoteImageLoader(provider: provider, cacheDirectory: directory)
        let tooBig = await loader.load(remotePath: "/home/dev/big.png")
        let missing = await loader.load(remotePath: "/home/dev/none.png")
        #expect(tooBig == nil && missing == nil)
        #expect(host.requests == ["probe", "probe"], "\(host.requests)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }

    @Test func aCappedStampedDownloadReturnsTheStampWithTheBytes() async throws {
        let (provider, host) = provider(["/srv/a.json": Data("{}".utf8)])
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("a.json")
        let stamp = try await provider.downloadFileWithStamp(path: "/srv/a.json", to: local, maxBytes: 100)
        #expect(stamp == SSHRemoteFileStamp(modificationTime: 7, size: 2) && host.requests == ["probe"])
        let bytes = try Data(contentsOf: local)
        #expect(bytes == Data("{}".utf8))
        await #expect(throws: RemoteFileProbe.Failure.tooLarge) {
            _ = try await provider.downloadFileWithStamp(path: "/srv/a.json", to: local, maxBytes: 1)
        }
        // A path that isn't absolute is never handed to the probe (which expands `~`).
        let relative = try? await provider.downloadFileWithStamp(path: "~/a.json", to: local, maxBytes: 100)
        #expect(relative == nil)
        #expect(host.requests.filter { $0 == "probe" }.count == 2)
    }
}
