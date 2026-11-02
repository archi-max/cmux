import Foundation

extension SSHFileExplorerProvider {
    /// Downloads `path` (absolute) if it is a regular file of at most
    /// `maxBytes`, and returns its stamp, read before the bytes. Over the
    /// file channel this is one request (a one-candidate probe); nothing is
    /// sent for a missing or oversize file. Throws
    /// ``RemoteFileProbe/Failure/noFile`` or ``RemoteFileProbe/Failure/tooLarge``.
    func downloadFileWithStamp(path: String, to localURL: URL, maxBytes: Int64) async throws -> SSHRemoteFileStamp {
        // The probe expands `~`; only an absolute path is passed to it.
        guard path.hasPrefix("/") else {
            let stamp = try await fileStamp(path: path)
            guard stamp.size <= maxBytes else { throw RemoteFileProbe.Failure.tooLarge }
            try await downloadFile(path: path, to: localURL, maxBytes: maxBytes)
            return stamp
        }
        do {
            let header = try await probeDownload(candidates: [path], maxBytes: maxBytes, to: localURL)
            return SSHRemoteFileStamp(modificationTime: header.modificationTime, size: header.size)
        } catch is RemoteFileProbe.Oversize {
            throw RemoteFileProbe.Failure.tooLarge
        }
    }
}
