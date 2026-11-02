import Foundation

extension SSHFileExplorerProvider {
    /// Downloads `path` (absolute) if it is a regular file of at most
    /// `maxBytes`, and returns its stamp, read before the bytes. Over the
    /// file channel this is one request (a one-candidate probe); nothing is
    /// sent for a missing or oversize file. Throws
    /// ``RemoteFileProbe/Failure/noFile`` or ``RemoteFileProbe/Failure/tooLarge``
    /// (also when the bytes read outgrew the cap or don't match the stamp's size).
    func downloadFileWithStamp(path: String, to localURL: URL, maxBytes: Int64) async throws -> SSHRemoteFileStamp {
        // The probe expands `~`; only an absolute path is passed to it.
        let stamp: SSHRemoteFileStamp
        if path.hasPrefix("/") {
            do {
                let header = try await probeDownload(candidates: [path], maxBytes: maxBytes, to: localURL)
                stamp = SSHRemoteFileStamp(modificationTime: header.modificationTime, size: header.size)
            } catch is RemoteFileProbe.Oversize {
                throw RemoteFileProbe.Failure.tooLarge
            }
        } else {
            stamp = try await fileStamp(path: path)
            guard stamp.size <= maxBytes else { throw RemoteFileProbe.Failure.tooLarge }
            try await downloadFile(path: path, to: localURL, maxBytes: maxBytes)
        }
        // A file that grew (or changed) between its size check and its read: the
        // per-exec read sends up to `maxBytes + 1` bytes with success. Never the file.
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? NSNumber
        guard let size, size.int64Value <= maxBytes, size.int64Value == stamp.size else {
            try? FileManager.default.removeItem(at: localURL)
            throw RemoteFileProbe.Failure.tooLarge
        }
        return stamp
    }
}
