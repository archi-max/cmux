import Foundation

/// The path a file preview's header shows and copies.
///
/// A remote file (an SSH or Cloud lease) shows its host path, never cmux's
/// local cache copy; the copy is still reachable as a second menu item
/// ("Copy Local Path"), for tools on this Mac.
struct FilePreviewPathPresentation: Equatable, Sendable {
    /// What the header shows.
    let displayedPath: String
    /// What "Copy Path" puts on the pasteboard.
    let copyPath: String
    /// What "Copy Local Path" copies; nil for a local file, which has one path.
    let localCopyPath: String?

    init(localPath: String, remotePath: String?) {
        if let remotePath, !remotePath.isEmpty {
            displayedPath = remotePath
            copyPath = remotePath
            localCopyPath = localPath
        } else {
            displayedPath = localPath
            copyPath = localPath
            localCopyPath = nil
        }
    }
}
