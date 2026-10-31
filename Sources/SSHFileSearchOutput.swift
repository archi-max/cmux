import Foundation

/// Placeholder API for parsing SSH search output; the implementation follows in the next commit.
struct SSHFileSearchLineParser: Sendable {
    enum Format: Equatable, Sendable {
        case unknown
        case ripgrep
        case grep
    }

    let rootPath: String
    let query: String
    private(set) var format: Format = .unknown

    init(rootPath: String, query: String) {
        self.rootPath = rootPath
        self.query = query
    }

    mutating func parse(line: Data) -> FileSearchResult? { nil }

    static func columnNumber(of query: String, in lineText: String) -> Int { 1 }

    static func remoteRelativePath(_ path: String, rootPath: String) -> String { path }
}

struct SSHFileSearchAccumulator: Sendable {
    private(set) var results: [FileSearchResult] = []

    init(rootPath: String, query: String, maxResults: Int, snapshotInterval: TimeInterval) {}

    var format: SSHFileSearchLineParser.Format { .unknown }

    mutating func consume(_ data: Data, now: Date = Date()) -> FileSearchPipelineUpdate? { nil }

    mutating func consumeStderr(_ data: Data) {}

    mutating func markTimedOut() {}

    mutating func finish(status: Int32) -> FileSearchPipelineUpdate {
        FileSearchPipelineUpdate(results: [], status: .noMatches, isSearching: false, shouldStopProcess: false)
    }
}

enum SSHFileSearchMessages {
    static var timedOut: String {
        String(localized: "fileExplorer.search.sshTimedOut", defaultValue: "The host took too long to answer")
    }

    static var folderNotFound: String {
        String(localized: "fileExplorer.search.sshFolderNotFound", defaultValue: "Folder not found on the host")
    }

    static func exited(status: Int32) -> String {
        String(
            format: String(localized: "fileExplorer.search.sshExited", defaultValue: "Remote search exited with status %d"),
            Int(status)
        )
    }
}
