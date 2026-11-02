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
    private var refreshTasks: [URL: Task<Bool, Error>] = [:]
    /// The last copy of each recently opened SSH file and its host stamp, so a
    /// reopen paints at once and is checked against the host afterwards.
    private let recentRoot: URL
    private var recent: [String: RecentCopy] = [:]
    private var recentOrder: [String] = []
    static let recentMaximumEntries = 32
    static let recentMaximumFileBytes: Int64 = 8 << 20
    static let recentMaximumBytes: Int64 = 64 << 20

    private struct RecentCopy {
        let url: URL
        let stamp: SSHRemoteFileStamp
    }

    /// Reserves a unique cache root without creating files or scanning until a preview is requested.
    init(directory: URL = FileManager.default.temporaryDirectory, maximumEntries: Int = 32) {
        let owner = ProcessInfo.processInfo.processIdentifier
        root = directory.appendingPathComponent(
            "cmux-cloud-previews-\(owner)-\(UUID().uuidString)",
            isDirectory: true
        )
        recentRoot = URL(fileURLWithPath: root.path + "-recent", isDirectory: true)
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
    ///
    /// With `allowRecentCopy`, an SSH file opened recently is served from its
    /// last copy without a download; the lease is then ``CloudFilePreviewLease/isUnverified``
    /// and carries that copy's stamp, so its caller refreshes it from the host
    /// and a save before that conflicts with any newer host file.
    func materialize(
        path: String,
        provider: any RemoteFileExplorerProvider,
        allowRecentCopy: Bool = false
    ) async throws -> CloudFilePreviewLease {
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
            if allowRecentCopy, let sshProvider,
               let copy = recent[Self.recentKey(provider.remoteIdentity, path)],
               (try? FileManager.default.copyItem(at: copy.url, to: url)) != nil {
                touchRecent(Self.recentKey(provider.remoteIdentity, path))
                try FileManager.default.setAttributes([.posixPermissions: Self.previewPermissions(for: provider)],
                                                      ofItemAtPath: url.path)
                let lease = CloudFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity,
                                                  cache: self, sshProvider: sshProvider, remoteStamp: copy.stamp,
                                                  isUnverified: true)
                lease.recordLocalCopy()
                return lease
            }
            // Read before downloading: a write in between then shows up as a conflict.
            let stamp = try? await sshProvider?.fileStamp(path: path)
            try await provider.downloadFile(path: path, to: url)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: Self.previewPermissions(for: provider)],
                                                  ofItemAtPath: url.path)
            if sshProvider != nil { remember(path: path, identity: provider.remoteIdentity, file: url, stamp: stamp) }
            let lease = CloudFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity,
                                              cache: self, sshProvider: sshProvider, remoteStamp: stamp)
            lease.recordLocalCopy()
            return lease
        } catch {
            release(url)
            throw error
        }
    }

    /// Takes `file`, a complete download of `path` made elsewhere (a terminal
    /// link or `cmux open`), into this cache under an editable SSH lease, so
    /// its preview names the host path, saves back with the conflict check
    /// and refreshes like one opened from the Files panel. `file` is moved.
    func adopt(
        file: URL,
        path: String,
        provider: SSHFileExplorerProvider,
        stamp: SSHRemoteFileStamp?
    ) throws -> CloudFilePreviewLease {
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
            try FileManager.default.moveItem(at: file, to: url)
            try FileManager.default.setAttributes([.posixPermissions: Self.previewPermissions(for: provider)],
                                                  ofItemAtPath: url.path)
            remember(path: path, identity: provider.remoteIdentity, file: url, stamp: stamp)
            let lease = CloudFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity,
                                              cache: self, sshProvider: provider, remoteStamp: stamp)
            lease.recordLocalCopy()
            return lease
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

    /// Replaces the lease's copy with the host's file. Returns false, after one
    /// stat, when the host file still has the copy's stamp and the copy is as
    /// it was downloaded; true when the copy was replaced.
    @discardableResult
    func refresh(_ lease: CloudFilePreviewLease, provider: any RemoteFileExplorerProvider) async throws -> Bool {
        // The viewer re-reads a placeholder's file on the host when it reloads.
        guard !lease.isPlaceholder else { return false }
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard entries.contains(lease.url) else { throw FileExplorerError.providerUnavailable }
        guard lease.remoteIdentity == provider.remoteIdentity else { throw FileExplorerError.providerUnavailable }
        if let task = refreshTasks[lease.url] { return try await task.value }
        let path = lease.remotePath, destination = lease.url
        let permissions = Self.previewPermissions(for: provider)
        let task = Task<Bool, Error> {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".cmux-refresh-" + UUID().uuidString, isDirectory: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let sshProvider = provider as? SSHFileExplorerProvider
            let stamp = try? await sshProvider?.fileStamp(path: path)
            if sshProvider != nil, let stamp, stamp == lease.remoteStamp, lease.localCopyIsUnchanged() {
                lease.isUnverified = false
                return false
            }
            try await provider.downloadFile(path: path, to: temporary)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            if sshProvider != nil {
                lease.remoteStamp = stamp
                lease.isUnverified = false
                self.remember(path: path, identity: lease.remoteIdentity, file: destination, stamp: stamp)
            }
            lease.recordLocalCopy()
            return true
        }
        refreshTasks[destination] = task
        do {
            let replaced = try await task.value
            refreshTasks[destination] = nil
            return replaced
        } catch {
            refreshTasks[destination] = nil
            throw error
        }
    }

    /// SSH previews are editable and saved back; Cloud VM previews stay read-only.
    private static func previewPermissions(for provider: any RemoteFileExplorerProvider) -> Int {
        provider is SSHFileExplorerProvider ? 0o600 : 0o400
    }

    private static func recentKey(_ identity: String, _ path: String) -> String { identity + "\u{0}" + path }

    /// Keeps a copy of `file` as the recent copy of `path` with `stamp`; with
    /// no stamp (it couldn't be read) or a large file, forgets the old one.
    func remember(path: String, identity: String, file: URL, stamp: SSHRemoteFileStamp?) {
        let key = Self.recentKey(identity, path)
        forgetRecent(key)
        guard let stamp, let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
              size <= Self.recentMaximumFileBytes else { return }
        let copy = recentRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: recentRoot, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            return
        }
        recent[key] = RecentCopy(url: copy, stamp: stamp)
        recentOrder.append(key)
        var total = recentOrder.reduce(Int64(0)) { sum, key in
            sum + (((try? FileManager.default.attributesOfItem(atPath: recent[key]?.url.path ?? ""))?[.size] as? Int64) ?? 0)
        }
        while recentOrder.count > Self.recentMaximumEntries || (total > Self.recentMaximumBytes && recentOrder.count > 1) {
            let oldest = recentOrder[0]
            total -= ((try? FileManager.default.attributesOfItem(atPath: recent[oldest]?.url.path ?? ""))?[.size] as? Int64) ?? 0
            forgetRecent(oldest)
        }
    }

    /// Records `contents` as the host file after a save that wrote them with `stamp`.
    func remember(path: String, identity: String, contents: Data, stamp: SSHRemoteFileStamp) {
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(".cmux-recent-" + UUID().uuidString, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard (try? contents.write(to: staged)) != nil else {
            forgetRecent(Self.recentKey(identity, path))
            return
        }
        remember(path: path, identity: identity, file: staged, stamp: stamp)
    }

    private func touchRecent(_ key: String) {
        recentOrder.removeAll { $0 == key }
        recentOrder.append(key)
    }

    private func forgetRecent(_ key: String) {
        guard let copy = recent.removeValue(forKey: key) else { return }
        recentOrder.removeAll { $0 == key }
        try? FileManager.default.removeItem(at: copy.url)
    }

    func release(_ url: URL) {
        guard entries.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if entries.isEmpty { try? FileManager.default.removeItem(at: root) }
    }

    deinit {
        cleanupTask?.cancel()
        try? FileManager.default.removeItem(at: recentRoot)
    }
}
