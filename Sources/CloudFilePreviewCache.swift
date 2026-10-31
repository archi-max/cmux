import CmuxCloud
import Darwin
import Foundation

/// Owns only its newly-created preview files. Open panels hold leases, so no
/// scan, timeout, or another Files pane can delete a document still in use.
actor CloudFilePreviewCache {
    private static let staleDirectoryAge: TimeInterval = 60 * 60
    private let root: URL
    private let maximumEntries: Int
    private var entries: Set<URL> = []
    private var cleanupTask: Task<Void, Never>?
    private var refreshTasks: [URL: Task<Void, Error>] = [:]

    /// Reserves a unique cache root without creating files or scanning until a preview is requested.
    init(directory: URL = FileManager.default.temporaryDirectory, maximumEntries: Int = 32) {
        let owner = ProcessInfo.processInfo.processIdentifier
        root = directory.appendingPathComponent(
            "cmux-cloud-previews-\(owner)-\(UUID().uuidString)",
            isDirectory: true
        )
        self.maximumEntries = maximumEntries
    }

    /// Removes old preview directories owned by exited processes, preserving every live owner's files.
    private static func removeStaleDirectories(in directory: URL) {
        guard !Task.isCancelled else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            // Fetch metadata only after filtering out unrelated temporary files.
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-staleDirectoryAge)
        for url in urls where url.lastPathComponent.hasPrefix("cmux-cloud-previews-") {
            guard !Task.isCancelled else { return }
            let components = url.lastPathComponent.split(separator: "-")
            guard components.count > 3, let owner = Int32(components[3]) else { continue }
            if owner == ProcessInfo.processInfo.processIdentifier || kill(owner, 0) == 0 || errno == EPERM {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Downloads a preview held by a lease and starts this cache's one-time stale-file cleanup.
    /// SSH previews stay writable and record the remote stamp for the save-time conflict check.
    func materialize(path: String, provider: any RemoteFileExplorerProvider) async throws -> CloudFilePreviewLease {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        if provider is CloudVMFileExplorerProvider, entries.count >= maximumEntries {
            throw FileExplorerError.previewCapacity
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (path as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw FileExplorerError.providerUnavailable }
        if cleanupTask == nil {
            // Most Files stores never open a remote preview. Scanning on creation
            // lets workspace churn saturate the cooperative executor with file I/O.
            let parent = root.deletingLastPathComponent()
            cleanupTask = Task.detached(priority: .utility) { Self.removeStaleDirectories(in: parent) }
        }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        entries.insert(url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let sshProvider = provider as? SSHFileExplorerProvider
            // Read before downloading: a write in between then shows up as a conflict.
            let stamp = try? await sshProvider?.fileStamp(path: path)
            try await provider.downloadFile(path: path, to: url)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: Self.previewPermissions(for: provider)],
                                                  ofItemAtPath: url.path)
            return CloudFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity,
                                         cache: self, sshProvider: sshProvider, remoteStamp: stamp)
        } catch {
            release(url)
            throw error
        }
    }

    /// A lease for a remote file the viewer reads in place on the host (FSDB):
    /// an empty local stand-in carries the name, and nothing is downloaded.
    func placeholder(path: String, provider: any RemoteFileExplorerProvider) throws -> CloudFilePreviewLease {
        // The viewer still moves the file's data to this Mac (and installs a helper on the host).
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        if cleanupTask == nil {
            let parent = root.deletingLastPathComponent()
            cleanupTask = Task.detached(priority: .utility) { Self.removeStaleDirectories(in: parent) }
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (path as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw FileExplorerError.providerUnavailable }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        entries.insert(url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: Data(),
                                                 attributes: [.posixPermissions: 0o400]) else {
                throw FileExplorerError.providerUnavailable
            }
            return CloudFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity,
                                         cache: self, isPlaceholder: true)
        } catch {
            release(url)
            throw error
        }
    }

    func refresh(_ lease: CloudFilePreviewLease, provider: any RemoteFileExplorerProvider) async throws {
        // The viewer re-reads a placeholder's file on the host when it reloads.
        guard !lease.isPlaceholder else { return }
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard entries.contains(lease.url) else { throw FileExplorerError.providerUnavailable }
        guard lease.remoteIdentity == provider.remoteIdentity else { throw FileExplorerError.providerUnavailable }
        if let task = refreshTasks[lease.url] { return try await task.value }
        let path = lease.remotePath, destination = lease.url
        let permissions = Self.previewPermissions(for: provider)
        let task = Task<Void, Error> {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".cmux-refresh-" + UUID().uuidString, isDirectory: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let sshProvider = provider as? SSHFileExplorerProvider
            let stamp = try? await sshProvider?.fileStamp(path: path)
            try await provider.downloadFile(path: path, to: temporary)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            if sshProvider != nil { lease.remoteStamp = stamp }
        }
        refreshTasks[destination] = task
        do {
            try await task.value
            refreshTasks[destination] = nil
        } catch {
            refreshTasks[destination] = nil
            throw error
        }
    }

    /// SSH previews are editable and saved back; Cloud VM previews stay read-only.
    private static func previewPermissions(for provider: any RemoteFileExplorerProvider) -> Int {
        provider is SSHFileExplorerProvider ? 0o600 : 0o400
    }

    func release(_ url: URL) {
        guard entries.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if entries.isEmpty { try? FileManager.default.removeItem(at: root) }
    }

    deinit { cleanupTask?.cancel() }
}
