import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A host with files, counting its requests: a stat, a download, a capped
/// probe (stamp and bytes together), a listing or a write. A file in `growing`
/// gains bytes between its size check and its read (a log being written),
/// and `editAfterRead` has someone else change a file just after it is read.
final class CappedRequestCountingTransport: SSHFileExplorerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var stamps: [String: Int64] = [:]
    private var log: [String] = []
    var growing: Set<String> = []
    var editAfterRead = false

    init(files: [String: Data]) { self.files = files }

    var requests: [String] { lock.withLock { log } }
    func contents(_ path: String) -> Data? { lock.withLock { files[path] } }
    private func note(_ request: String) { lock.withLock { log.append(request) } }
    private func stamp(_ path: String) -> SSHRemoteFileStamp? {
        lock.withLock { files[path].map { SSHRemoteFileStamp(modificationTime: stamps[path, default: 7], size: Int64($0.count)) } }
    }
    /// The bytes a read sends: grown past what its size check saw, for a growing file.
    private func bytesRead(_ path: String, _ data: Data) -> Data {
        let sent = growing.contains(path) ? data + Data(repeating: 0x2E, count: 64) : data
        if editAfterRead { lock.withLock { stamps[path, default: 7] += 1 } }
        return sent
    }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String { "/home/dev" }

    func listDirectory(path: String, connection: SSHFileExplorerConnection, showHidden: Bool) async throws -> [FileExplorerEntry] {
        note("list")
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let known = lock.withLock { files }
        let names = Set(known.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
        return names.map { name in FileExplorerEntry(name: name, path: prefix + name, isDirectory: known[prefix + name] == nil) }
    }

    func fileStamp(path: String, connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        note("stat")
        guard let stamp = stamp(path) else { throw FileExplorerError.mutationFailed }
        return stamp
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL) async throws {
        note("download")
        guard let data = contents(path) else { throw FileExplorerError.mutationFailed }
        try bytesRead(path, data).write(to: localURL)
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL, maxBytes: Int64) async throws {
        note("download")
        guard let data = contents(path) else { throw FileExplorerError.mutationFailed }
        try bytesRead(path, data).prefix(Int(maxBytes) + 1).write(to: localURL)
    }

    func probeDownload(candidates: [String], maxBytes: Int64?, connection: SSHFileExplorerConnection,
                       to localURL: URL) async throws -> RemoteFileProbe.Header {
        note("probe")
        for (index, path) in candidates.enumerated() {
            guard let data = contents(path), let stamp = stamp(path) else { continue }
            let header = RemoteFileProbe.Header(index: index, path: path, modificationTime: stamp.modificationTime, size: stamp.size)
            if let maxBytes, stamp.size > maxBytes { throw RemoteFileProbe.Oversize(header: header) }
            // The per-exec probe: `head -c cap+1` after the size check, exit status 0.
            let sent = bytesRead(path, data)
            try (maxBytes.map { sent.prefix(Int($0) + 1) } ?? sent).write(to: localURL)
            return header
        }
        throw RemoteFileProbe.Failure.noFile
    }

    func writeFile(path: String, contents data: Data, expectedStamp: SSHRemoteFileStamp?,
                   connection: SSHFileExplorerConnection) async throws -> SSHRemoteFileStamp {
        note("write")
        if let expectedStamp, expectedStamp != stamp(path) { throw FileExplorerError.remoteFileChanged }
        lock.withLock {
            files[path] = data
            stamps[path, default: 7] += 1
        }
        return stamp(path)!
    }
}

/// A capped remote read (a Markdown image, a waveform session) is one host
/// request: the stamp and the bytes come together, and a file over the cap
/// or missing sends nothing.
@Suite(.serialized) struct RemoteCappedDownloadTests {
    private func provider(_ files: [String: Data]) -> (SSHFileExplorerProvider, CappedRequestCountingTransport) {
        let transport = CappedRequestCountingTransport(files: files)
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

    @Test func anOversizeRelativePathIsRefusedWithoutADownload() async throws {
        let (provider, host) = provider(["rel/big.json": Data(repeating: 0x20, count: 500)])
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var refused = false
        do {
            _ = try await provider.downloadFileWithStamp(path: "rel/big.json", to: directory.appendingPathComponent("b"), maxBytes: 100)
        } catch RemoteFileProbe.Failure.tooLarge {
            refused = true
        }
        #expect(refused && host.requests == ["stat"], "\(refused) \(host.requests)")
    }

    @Test func aFileThatGrowsDuringTheReadIsRefused() async throws {
        // The size check passes, then the file outgrows the cap before its bytes are read:
        // never handed over as the file, on either branch.
        let (provider, host) = provider(["/srv/log.json": Data(repeating: 0x20, count: 90),
                                         "rel/log.json": Data(repeating: 0x20, count: 90)])
        host.growing = ["/srv/log.json", "rel/log.json"]
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["/srv/log.json", "rel/log.json"] {
            var refused = false
            do {
                _ = try await provider.downloadFileWithStamp(path: path, to: directory.appendingPathComponent(UUID().uuidString), maxBytes: 100)
            } catch RemoteFileProbe.Failure.tooLarge {
                refused = true
            }
            #expect(refused, "\(path): a read that outgrew its cap was taken as the file")
        }
        // Under the cap but not the size its stamp gave: also refused.
        host.growing = []
        let (shrunk, shrinkHost) = self.provider(["/srv/s.json": Data(repeating: 0x20, count: 50)])
        shrinkHost.growing = ["/srv/s.json"]
        var refused = false
        do {
            _ = try await shrunk.downloadFileWithStamp(path: "/srv/s.json", to: directory.appendingPathComponent("s"), maxBytes: 1000)
        } catch RemoteFileProbe.Failure.tooLarge {
            refused = true
        }
        #expect(refused, "bytes that don't match the stamp's size were taken as the file")
    }
}
