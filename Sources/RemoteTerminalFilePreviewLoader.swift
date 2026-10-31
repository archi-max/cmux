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
        shownPaths: @escaping @MainActor @Sendable () -> Set<String> = { [] }
    ) {
        self.provider = provider
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.budgetBytes = budgetBytes
        self.shownPaths = shownPaths
    }

    func load(tokens: [String], workingDirectory: String?) async throws -> URL {
        try Task.checkCancellation()
        let resolver = RemoteTerminalPathResolver()
        let needsHome = tokens.contains {
            let token = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.hasPrefix("~") || token.hasPrefix("\"~") || token.hasPrefix("'~")
        }
        let home = needsHome ? try await provider.resolveHomePath() : nil
        let host = String(provider.destination.split(separator: "@").last ?? "")
        let candidates = resolver.candidates(
            tokens: tokens,
            workingDirectory: workingDirectory,
            homeDirectory: home,
            remoteHost: host
        )
        return try await download(candidates: candidates)
    }

    /// Downloads exactly `path` (no spelling variants), at most `maxBytes`.
    /// For `cmux open`, where the remote CLI has already resolved the one
    /// path it means. The host's size is checked first so an oversize file
    /// costs no transfer; the download itself also stops after `maxBytes + 1`
    /// bytes, so a file that grew meanwhile is refused too, leaving nothing
    /// in the cache.
    func load(exactPath path: String, maxBytes: Int64) async throws -> URL {
        try Task.checkCancellation()
        let stamp = try await provider.fileStamp(path: path)
        guard stamp.size <= maxBytes else { throw RemoteTerminalFilePreviewError.fileTooLarge }
        return try await download(candidates: [path], maxBytes: maxBytes)
    }

    private func download(candidates: [String], maxBytes: Int64? = nil) async throws -> URL {
        let identity = [provider.destination, provider.port.map(String.init) ?? "", provider.identityFile ?? ""]
            + provider.sshOptions
        let identityData = try JSONSerialization.data(withJSONObject: identity)
        let namespace = SHA256.hash(data: identityData).map { String(format: "%02x", $0) }.joined()
        for path in candidates {
            try Task.checkCancellation()
            let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = cacheDirectory.appendingPathComponent(namespace).appendingPathComponent(digest)
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let staging = directory.appendingPathComponent(UUID().uuidString + ".download")
            defer { try? fileManager.removeItem(at: staging) }
            do {
                if let maxBytes {
                    try await provider.downloadFile(path: path, to: staging, maxBytes: maxBytes)
                    let size = (try? fileManager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard size <= maxBytes else {
                        RemotePreviewCacheBudget.discard(staging, cacheRoot: cacheDirectory, fileManager: fileManager)
                        throw RemoteTerminalFilePreviewError.fileTooLarge
                    }
                } else {
                    try await provider.downloadFile(path: path, to: staging)
                }
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent((path as NSString).lastPathComponent)
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
                return destination
            } catch let error as RemoteTerminalFilePreviewError {
                throw error
            } catch {
                try Task.checkCancellation()
            }
        }
        throw FileExplorerError.providerUnavailable
    }
}

enum RemoteTerminalFilePreviewError: Error, Equatable {
    /// The host file is larger than a gesture-free open may download.
    case fileTooLarge
}
