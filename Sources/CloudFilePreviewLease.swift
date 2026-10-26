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
    private let cache: CloudFilePreviewCache
    private let stampLock = NSLock()
    private var stamp: SSHRemoteFileStamp?

    init(
        url: URL,
        remotePath: String,
        remoteIdentity: String,
        cache: CloudFilePreviewCache,
        sshProvider: SSHFileExplorerProvider? = nil,
        remoteStamp: SSHRemoteFileStamp? = nil
    ) {
        self.url = url
        self.remotePath = remotePath
        self.remoteIdentity = remoteIdentity
        self.cache = cache
        self.sshProvider = sshProvider
        self.stamp = remoteStamp
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

    func refresh(using provider: any RemoteFileExplorerProvider) async throws {
        try await cache.refresh(self, provider: provider)
    }

    /// Re-downloads an editable SSH preview through its own provider.
    func refreshFromRemote() async throws {
        guard let sshProvider else { throw FileExplorerError.providerUnavailable }
        try await cache.refresh(self, provider: sshProvider)
    }

    /// Uploads `contents` to the remote file. Unless `overwrite` is set, throws
    /// ``FileExplorerError/remoteFileChanged`` when the remote file changed since
    /// it was last downloaded or saved.
    func upload(_ contents: Data, overwrite: Bool) async throws {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard let sshProvider else { throw FileExplorerError.providerUnavailable }
        remoteStamp = try await sshProvider.writeFile(
            path: remotePath,
            contents: contents,
            expectedStamp: overwrite ? nil : remoteStamp
        )
    }
}
