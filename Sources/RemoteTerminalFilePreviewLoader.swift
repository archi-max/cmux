import CmuxTerminalCore
import CryptoKit
import Darwin
import Foundation

/// Downloads click-preview candidates through the same transport used by the SSH file explorer.
actor RemoteTerminalFilePreviewLoader {
    private let provider: SSHFileExplorerProvider
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let budgetBytes: Int64
    /// Local files open panels show; eviction never removes them.
    private let shownPaths: @MainActor @Sendable () -> Set<String>

    init(
        provider: SSHFileExplorerProvider,
        cacheDirectory: URL,
        fileManager: FileManager,
        budgetBytes: Int64 = RemotePreviewCacheBudget.defaultBudgetBytes,
        shownPaths: @escaping @MainActor @Sendable () -> Set<String>
    ) {
        self.provider = provider
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.budgetBytes = budgetBytes
        self.shownPaths = shownPaths
    }

    /// Downloads the first file the clicked `tokens` name, in one round trip
    /// (``RemoteFileProbe``): every spelling, with and without a trailing
    /// `:line[:column]`, `~` expanded on the host. `workingDirectory` is asked
    /// only when a token is relative.
    func load(
        tokens: [String],
        workingDirectory: @escaping @Sendable () async -> String?
    ) async throws -> RemotePreviewDownload {
        try Task.checkCancellation()
        let resolver = RemoteTerminalPathResolver()
        let directory = resolver.needsWorkingDirectory(tokens: tokens) ? await workingDirectory() : nil
        try Task.checkCancellation()
        let host = String(provider.destination.split(separator: "@").last ?? "")
        let references = resolver.references(
            tokens: tokens,
            workingDirectory: directory,
            homeDirectory: nil,
            remoteHost: host,
            expandsHomeOnHost: true
        )
        return try await download(references: references, maxBytes: nil)
    }

    func load(tokens: [String], workingDirectory: String?) async throws -> RemotePreviewDownload {
        try await load(tokens: tokens, workingDirectory: { workingDirectory })
    }

    /// Downloads exactly `path` (no spelling variants), at most `maxBytes`.
    /// For `cmux open`, where the remote CLI has already resolved the one
    /// path it means. The host checks the size before it sends anything, in
    /// the same round trip, so an oversize file costs no transfer; the read
    /// itself also stops after `maxBytes + 1` bytes, so a file that grew
    /// meanwhile is refused too, leaving nothing in the cache.
    func load(exactPath path: String, maxBytes: Int64) async throws -> RemotePreviewDownload {
        try Task.checkCancellation()
        return try await download(references: [RemoteFileReference(path: path)], maxBytes: maxBytes)
    }

    private func download(references: [RemoteFileReference], maxBytes: Int64?) async throws -> RemotePreviewDownload {
        guard !references.isEmpty else { throw FileExplorerError.providerUnavailable }
        let identity = [provider.destination, provider.port.map(String.init) ?? "", provider.identityFile ?? ""]
            + provider.sshOptions
        let identityData = try JSONSerialization.data(withJSONObject: identity)
        let namespace = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        let namespaceDirectory = cacheDirectory.appendingPathComponent(namespace)
        try fileManager.createDirectory(
            at: namespaceDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let staging = namespaceDirectory.appendingPathComponent(UUID().uuidString + ".download")
        defer { try? fileManager.removeItem(at: staging) }
        let header: RemoteFileProbe.Header
        do {
            header = try await provider.probeDownload(
                candidates: references.map(\.path), maxBytes: maxBytes, to: staging
            )
        } catch RemoteFileProbe.Failure.tooLarge {
            throw RemoteTerminalFilePreviewError.fileTooLarge
        } catch is RemoteFileProbe.Failure {
            try Task.checkCancellation()
            throw FileExplorerError.providerUnavailable
        }
        try Task.checkCancellation()
        if let maxBytes {
            let size = (try? fileManager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= maxBytes else {
                RemotePreviewCacheBudget.discard(staging, cacheRoot: cacheDirectory, fileManager: fileManager)
                throw RemoteTerminalFilePreviewError.fileTooLarge
            }
        }
        // Keyed by the host path that was read, so every spelling of one file shares its copy.
        let digest = SHA256.hash(data: Data(header.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = namespaceDirectory.appendingPathComponent(digest)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent((header.path as NSString).lastPathComponent)
        let isNew = !fileManager.fileExists(atPath: destination.path)
        // Read before the rename (which keeps it): afterwards a concurrent
        // download of the same host file may already have replaced it.
        let published = RemotePreviewDownload.fileNumber(of: staging)
        // Publish a complete file atomically; an existing preview never sees a partial download.
        guard rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let shown = await shownPaths()
        RemotePreviewCacheBudget.evict(
            in: cacheDirectory,
            budgetBytes: budgetBytes,
            keeping: shown.union([destination.path]),
            recentUseGrace: RemotePreviewCacheBudget.defaultRecentUseGrace,
            fileManager: fileManager
        )
        let reference = references.indices.contains(header.index) ? references[header.index] : nil
        return RemotePreviewDownload(
            url: destination,
            isNew: isNew,
            fileNumber: published,
            remotePath: header.path,
            remoteStamp: SSHRemoteFileStamp(statOutput: "\(header.modificationTime) \(header.size)"),
            line: reference?.line,
            column: reference?.column
        )
    }
}

enum RemoteTerminalFilePreviewError: Error, Equatable {
    /// The host file is larger than a gesture-free open may download.
    case fileTooLarge
}
