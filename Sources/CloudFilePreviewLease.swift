import CmuxCloud
import Foundation

/// Transferred from a completed download to its preview panel. Cloud VM
/// previews are read-only; SSH previews save back through `sshProvider`.
// The remote stamp is guarded by stampLock; every other property is immutable.
final class CloudFilePreviewLease: @unchecked Sendable {
    let url: URL
    let remotePath: String
    let remoteIdentity: String
    /// The provider an editable SSH preview uploads saves through.
    let sshProvider: SSHFileExplorerProvider?
    /// An empty stand-in for a file read in place on the remote host; never downloaded.
    let isPlaceholder: Bool
    private let cache: CloudFilePreviewCache
    private let stampLock = NSLock()
    private var stamp: SSHRemoteFileStamp?
    private var unverified: Bool
    private var localCopy: LocalCopyState?

    /// The local copy's modification date and size as the cache last wrote it.
    private struct LocalCopyState: Equatable {
        let modificationDate: Date?
        let size: Int64?

        init(url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modificationDate = attributes?[.modificationDate] as? Date
            size = attributes?[.size] as? Int64
        }
    }

    init(
        url: URL,
        remotePath: String,
        remoteIdentity: String,
        cache: CloudFilePreviewCache,
        sshProvider: SSHFileExplorerProvider? = nil,
        remoteStamp: SSHRemoteFileStamp? = nil,
        isPlaceholder: Bool = false,
        isUnverified: Bool = false
    ) {
        self.url = url
        self.remotePath = remotePath
        self.remoteIdentity = remoteIdentity
        self.cache = cache
        self.sshProvider = sshProvider
        self.stamp = remoteStamp
        self.isPlaceholder = isPlaceholder
        self.unverified = isUnverified
    }

    deinit {
        let url = url, cache = cache
        Task { await cache.release(url) }
    }

    var isEditable: Bool { sshProvider != nil }

    /// The remote file's stamp as of the last download or save, if it could be read.
    var remoteStamp: SSHRemoteFileStamp? {
        get {
            stampLock.lock()
            defer { stampLock.unlock() }
            return stamp
        }
        set {
            stampLock.lock()
            defer { stampLock.unlock() }
            stamp = newValue
        }
    }

    /// Whether the copy came from the cache's recent copy and hasn't been
    /// checked against the host since; ``remoteStamp`` is then that copy's stamp.
    var isUnverified: Bool {
        get { stampLock.withLock { unverified } }
        set { stampLock.withLock { unverified = newValue } }
    }

    /// Notes the local copy's state after the cache wrote it.
    func recordLocalCopy() {
        let state = LocalCopyState(url: url)
        stampLock.withLock { localCopy = state }
    }

    /// Whether the local copy is still as the cache last wrote it.
    func localCopyIsUnchanged() -> Bool {
        let state = LocalCopyState(url: url)
        return stampLock.withLock { localCopy != nil && localCopy == state && state.size != nil }
    }

    /// Refreshes the copy from the host; true when it was replaced.
    @discardableResult
    func refresh(using provider: any RemoteFileExplorerProvider) async throws -> Bool {
        try await cache.refresh(self, provider: provider)
    }

    /// Re-downloads an editable SSH preview through its own provider.
    @discardableResult
    func refreshFromRemote() async throws -> Bool {
        guard let sshProvider else { throw FileExplorerError.providerUnavailable }
        return try await cache.refresh(self, provider: sshProvider)
    }

    /// Uploads `contents` to the remote file. Unless `overwrite` is set, throws
    /// ``FileExplorerError/remoteFileChanged`` when the remote file changed since
    /// it was last downloaded or saved.
    func upload(_ contents: Data, overwrite: Bool) async throws {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard let sshProvider else { throw FileExplorerError.providerUnavailable }
        let stamp = try await sshProvider.writeFile(
            path: remotePath,
            contents: contents,
            expectedStamp: overwrite ? nil : remoteStamp
        )
        remoteStamp = stamp
        isUnverified = false
        await cache.remember(path: remotePath, identity: remoteIdentity, contents: contents, stamp: stamp)
    }
}
