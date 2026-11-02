import Foundation

/// PLACEHOLDER (red commit).
struct FilePreviewPathPresentation: Equatable, Sendable {
    let displayedPath: String
    let copyPath: String
    let localCopyPath: String?

    init(localPath: String, remotePath: String?) {
        displayedPath = localPath
        copyPath = localPath
        localCopyPath = nil
    }
}
