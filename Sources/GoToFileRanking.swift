import Foundation

/// One file list for a Go to File palette session. Placeholder API; the
/// implementation follows in the next commit.
struct GoToFileSnapshot: Equatable, Sendable {
    static let maxPaths = 50_000
    static let maxFindDepth = 8

    var paths: [String]
    var isTruncated: Bool

    static let empty = GoToFileSnapshot(paths: [], isTruncated: false)

    static func parse(listOutput data: Data, maxPaths: Int = maxPaths) -> GoToFileSnapshot { .empty }
}

enum GoToFileRanker {
    static func rank(paths: [String], query: String, limit: Int, shouldCancel: () -> Bool = { false }) -> [String] { [] }

    static func score(query: String, path: String) -> Int? { nil }
}
