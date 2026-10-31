import Foundation

/// A read-only remote command for Find in Files on an SSH workspace.
/// Placeholder API; the implementation follows in the next commit.
struct SSHFileSearchCommand: Equatable, Sendable {
    static let ripgrepMarker = "cmux-search:rg"
    static let grepMarker = "cmux-search:grep"
    static let gitListMarker = "cmux-files:git"
    static let findListMarker = "cmux-files:find"
    static let missingRootStatus: Int32 = 66
    static let remoteTimeoutStatus: Int32 = 124

    let command: String

    static func isCaseInsensitive(query: String) -> Bool { false }

    static func contentSearch(query: String, rootPath: String, remoteTimeoutSeconds: Int) -> Self {
        Self(command: "sh -c ':'")
    }

    static func fileList(rootPath: String, maxDepth: Int, remoteTimeoutSeconds: Int) -> Self {
        Self(command: "sh -c ':'")
    }
}
