import Foundation

/// One file list for a Go to File palette session, relative to its root.
///
/// The palette takes one snapshot when it opens and ranks it locally on every
/// keystroke, following the session-snapshot design of manaflow-ai/cmux#18661
/// (Go to File quick open, local workspaces).
struct GoToFileSnapshot: Equatable, Sendable {
    /// At most this many paths are kept; a bigger tree marks the snapshot truncated.
    static let maxPaths = 50_000
    /// Deepest directory level `find` descends to outside a Git work tree.
    static let maxFindDepth = 8

    var paths: [String]
    var isTruncated: Bool

    static let empty = GoToFileSnapshot(paths: [], isTruncated: false)

    /// Parses ``SSHFileSearchCommand/fileList(rootPath:maxDepth:remoteTimeoutSeconds:)``
    /// output: an optional marker line, then NUL-separated paths.
    /// `find` prints `./a/b`; the `./` is dropped so both tools agree.
    static func parse(listOutput data: Data, maxPaths: Int = maxPaths) -> GoToFileSnapshot {
        var body = data[data.startIndex...]
        if let newline = body.firstIndex(of: 10) {
            let first = String(decoding: body[body.startIndex..<newline], as: UTF8.self)
            if first == SSHFileSearchCommand.gitListMarker || first == SSHFileSearchCommand.findListMarker {
                body = body[body.index(after: newline)...]
            }
        }
        return parse(nulSeparated: body, maxPaths: maxPaths)
    }

    /// Parses NUL-separated relative paths, keeping at most `maxPaths`.
    static func parse<Bytes: Collection>(nulSeparated bytes: Bytes, maxPaths: Int = maxPaths) -> GoToFileSnapshot
    where Bytes.Element == UInt8, Bytes.SubSequence: Collection {
        var paths: [String] = []
        let limit = max(0, maxPaths)
        for piece in bytes.split(separator: 0, omittingEmptySubsequences: true) {
            var path = String(decoding: piece, as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, path != "." else { continue }
            guard paths.count < limit else { return GoToFileSnapshot(paths: paths, isTruncated: true) }
            paths.append(path)
        }
        return GoToFileSnapshot(paths: paths, isTruncated: false)
    }
}

/// Fuzzy ranking for Go to File.
///
/// A query matches a path when its characters appear in order (ignoring case
/// and spaces). Matches score higher at word starts (after `/`, `_`, `-`, `.`,
/// a space, or a lower-to-upper case change), in runs of consecutive
/// characters, and inside the file name; gaps cost a little. Ties prefer the
/// shorter path, then the alphabetical one.
enum GoToFileRanker {
    private static let matchScore = 16
    private static let boundaryBonus = 24
    private static let firstCharacterBonus = 8
    private static let consecutiveBonus = 20
    private static let gapPenalty = 1
    private static let fileNameBonus = 40
    private static let fileNamePrefixBonus = 30
    private static let exactFileNameBonus = 200

    /// The best `limit` paths for `query`, best first. An empty query lists paths alphabetically.
    static func rank(
        paths: [String],
        query: String,
        limit: Int,
        shouldCancel: () -> Bool = { false }
    ) -> [String] {
        guard limit > 0 else { return [] }
        let needle = normalizedNeedle(query)
        if needle.isEmpty {
            return Array(paths.sorted(by: alphabetical).prefix(limit))
        }
        var scored: [(path: String, score: Int)] = []
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: 256), shouldCancel() { return [] }
            guard let score = score(needle: needle, path: path) else { continue }
            scored.append((path, score))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return alphabetical(lhs.path, rhs.path)
        }
        return scored.prefix(limit).map(\.path)
    }

    /// The score of `path` for `query`, or nil when it does not match.
    static func score(query: String, path: String) -> Int? {
        score(needle: normalizedNeedle(query), path: path)
    }

    /// Query characters, lowercased per character like the candidates, without spaces.
    private static func normalizedNeedle(_ query: String) -> [Character] {
        query.filter { !$0.isWhitespace }.map { $0.lowercased().first ?? $0 }
    }

    private static func score(needle: [Character], path: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(path)
        let lowered = haystack.map { $0.lowercased().first ?? $0 }
        guard isSubsequence(needle, of: lowered) else { return nil }
        let fullScore = alignmentScore(needle: needle, haystack: haystack, lowered: lowered) ?? 0

        let nameStart = (haystack.lastIndex(of: "/") ?? -1) + 1
        guard nameStart > 0 else { return fullScore + nameScore(needle: needle, lowered: lowered) + fileNameBonus }
        let name = Array(haystack[nameStart...])
        let loweredName = Array(lowered[nameStart...])
        guard isSubsequence(needle, of: loweredName),
              let nameAlignment = alignmentScore(needle: needle, haystack: name, lowered: loweredName) else {
            return fullScore
        }
        return max(fullScore, nameAlignment + nameScore(needle: needle, lowered: loweredName) + fileNameBonus)
    }

    private static func nameScore(needle: [Character], lowered name: [Character]) -> Int {
        if name == needle { return exactFileNameBonus }
        let stem = name.firstIndex(of: ".").map { Array(name[..<$0]) } ?? name
        if stem == needle { return exactFileNameBonus }
        if name.starts(with: needle) { return fileNamePrefixBonus }
        return 0
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        var index = 0
        for character in haystack where character == needle[index] {
            index += 1
            if index == needle.count { return true }
        }
        return false
    }

    /// Best alignment of `needle` in `haystack` (Smith-Waterman style, linear gaps).
    private static func alignmentScore(needle: [Character], haystack: [Character], lowered: [Character]) -> Int? {
        let n = haystack.count
        let m = needle.count
        guard m <= n else { return nil }
        let bonuses = (0..<n).map { bonus(at: $0, in: haystack) }
        let unset = Int.min / 4
        // previous[j]: best score with needle[i - 1] matched at haystack[j].
        var previous = [Int](repeating: unset, count: n)
        var current = [Int](repeating: unset, count: n)
        for i in 0..<m {
            var bestBefore = unset // max over k < j of previous[k] + gapPenalty * k
            for j in 0..<n {
                if j > 0, i > 0, previous[j - 1] != unset {
                    bestBefore = max(bestBefore, previous[j - 1] + gapPenalty * (j - 1))
                }
                guard lowered[j] == needle[i] else {
                    current[j] = unset
                    continue
                }
                let base = matchScore + bonuses[j]
                if i == 0 {
                    current[j] = base - gapPenalty * min(j, 8)
                    continue
                }
                var best = unset
                if bestBefore != unset {
                    best = bestBefore - gapPenalty * (j - 1) + base
                }
                if j > 0, previous[j - 1] != unset {
                    best = max(best, previous[j - 1] + base + consecutiveBonus)
                }
                current[j] = best
            }
            swap(&previous, &current)
        }
        let best = previous.max() ?? unset
        return best == unset ? nil : best
    }

    private static func bonus(at index: Int, in haystack: [Character]) -> Int {
        guard index > 0 else { return boundaryBonus + firstCharacterBonus }
        let before = haystack[index - 1]
        if "/_-. ".contains(before) { return boundaryBonus }
        if before.isLowercase && haystack[index].isUppercase { return boundaryBonus }
        return 0
    }

    private static func alphabetical(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    // Stubs for the failing tests; the prepared index follows in the next commit.
    struct Index: Sendable {
        let paths: [String]
        init(paths: [String]) { self.paths = paths }
    }

    struct Ranking: Sendable {
        let paths: [String]
        let matches: [Int]
    }

    static func rank(
        index: Index,
        query: String,
        limit: Int,
        within: [Int]? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> Ranking {
        Ranking(paths: rank(paths: index.paths, query: query, limit: limit, shouldCancel: shouldCancel), matches: [])
    }
}
