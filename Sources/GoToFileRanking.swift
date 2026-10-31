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

    /// Parses ``SSHFileSearchCommand/fileList(rootPath:maxDepth:remoteTimeoutSeconds:watchdog:)``
    /// output: the marker line, then NUL-separated paths. Anything a login
    /// shell printed before the marker is dropped; without a marker the whole
    /// output is read as paths. `find` prints `./a/b`; the `./` is dropped so
    /// both tools agree. Repeated paths (unmerged entries appear once per
    /// stage in `git ls-files -c`) are kept once.
    static func parse(listOutput data: Data, maxPaths: Int = maxPaths) -> GoToFileSnapshot {
        guard let bodyStart = markerEnd(in: data) else { return parse(nulSeparated: data, maxPaths: maxPaths) }
        return parse(nulSeparated: data[bodyStart...], maxPaths: maxPaths)
    }

    /// The index just past the first marker line, or nil when there is none.
    static func markerEnd(in data: Data) -> Data.Index? {
        var best: Data.Index?
        for marker in [SSHFileSearchCommand.gitListMarker, SSHFileSearchCommand.findListMarker] {
            let line = Data((marker + "\n").utf8)
            if data.starts(with: line) { return data.startIndex + line.count }
            if let range = data.range(of: Data("\n".utf8) + line), best.map({ range.upperBound < $0 }) ?? true {
                best = range.upperBound
            }
        }
        return best
    }

    /// Parses NUL-separated relative paths, keeping at most `maxPaths`.
    static func parse<Bytes: Collection>(nulSeparated bytes: Bytes, maxPaths: Int = maxPaths) -> GoToFileSnapshot
    where Bytes.Element == UInt8, Bytes.SubSequence: Collection {
        var paths: [String] = []
        var seen = Set<String>()
        let limit = max(0, maxPaths)
        for piece in bytes.split(separator: 0, omittingEmptySubsequences: true) {
            var path = String(decoding: piece, as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, path != ".", seen.insert(path).inserted else { continue }
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
///
/// Matching works on lowercased UTF-8 bytes prepared once per snapshot
/// (``Index``), with a cheap subsequence check before the alignment, so a
/// keystroke over 50,000 paths stays well under a frame budget.
enum GoToFileRanker {
    private static let matchScore = 16
    private static let boundaryBonus = 24
    private static let firstCharacterBonus = 8
    private static let consecutiveBonus = 20
    private static let gapPenalty = 1
    private static let fileNameBonus = 40
    private static let fileNamePrefixBonus = 30
    private static let exactFileNameBonus = 200
    private static let unset = Int.min / 4

    /// A snapshot prepared for ranking.
    struct Index: Sendable {
        fileprivate struct Candidate: Sendable {
            let path: String
            let lower: [UInt8]
            /// Per byte: 0, or the word-start bonus.
            let bonus: [UInt8]
            let nameStart: Int
        }

        fileprivate let candidates: [Candidate]
        /// Candidate indices in alphabetical order, for the empty query.
        fileprivate let alphabetical: [Int]
        fileprivate let maxLength: Int

        var count: Int { candidates.count }

        init(paths: [String]) {
            var candidates: [Candidate] = []
            candidates.reserveCapacity(paths.count)
            var maxLength = 0
            for path in paths {
                let original = Array(path.utf8)
                let lower = Array(path.lowercased().utf8)
                // lowercased() can change a non-ASCII byte length; case humps then come from `lower` alone.
                let caseSource = original.count == lower.count ? original : lower
                var bonus = [UInt8](repeating: 0, count: lower.count)
                for index in lower.indices {
                    if index == 0 {
                        bonus[index] = UInt8(GoToFileRanker.boundaryBonus + GoToFileRanker.firstCharacterBonus)
                        continue
                    }
                    let before = caseSource[index - 1]
                    let isSeparator = before == UInt8(ascii: "/") || before == UInt8(ascii: "_")
                        || before == UInt8(ascii: "-") || before == UInt8(ascii: ".") || before == UInt8(ascii: " ")
                    let isHump = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(before)
                        && (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(caseSource[index])
                    if isSeparator || isHump { bonus[index] = UInt8(GoToFileRanker.boundaryBonus) }
                }
                let nameStart = (lower.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
                maxLength = max(maxLength, lower.count)
                candidates.append(Candidate(path: path, lower: lower, bonus: bonus, nameStart: nameStart))
            }
            self.candidates = candidates
            self.maxLength = maxLength
            alphabetical = candidates.indices.sorted {
                candidates[$0].path.localizedStandardCompare(candidates[$1].path) == .orderedAscending
            }
        }
    }

    /// The outcome of one ranking: the best paths and every matching candidate.
    struct Ranking: Sendable {
        let paths: [String]
        /// All matches, to narrow the next ranking when the query only grows.
        let matches: [Int]
    }

    /// The best `limit` paths for `query`, best first. An empty query lists paths alphabetically.
    static func rank(
        paths: [String],
        query: String,
        limit: Int,
        shouldCancel: () -> Bool = { false }
    ) -> [String] {
        rank(index: Index(paths: paths), query: query, limit: limit, shouldCancel: shouldCancel).paths
    }

    /// Ranks a prepared snapshot. Pass `within` (an earlier ranking's
    /// `matches`) when `query` extends that ranking's query.
    static func rank(
        index: Index,
        query: String,
        limit: Int,
        within: [Int]? = nil,
        shouldCancel: () -> Bool = { false }
    ) -> Ranking {
        guard limit > 0 else { return Ranking(paths: [], matches: []) }
        let needle = normalizedNeedle(query)
        if needle.isEmpty {
            let ordered: [Int]
            if let within {
                let kept = Set(within)
                ordered = index.alphabetical.filter { kept.contains($0) }
            } else {
                ordered = index.alphabetical
            }
            return Ranking(paths: ordered.prefix(limit).map { index.candidates[$0].path }, matches: ordered.sorted())
        }
        var scratch = Scratch(capacity: index.maxLength)
        var scored: [(candidate: Int, score: Int)] = []
        var count = 0
        func consider(_ position: Int) -> Bool {
            count += 1
            if count.isMultiple(of: 512), shouldCancel() { return false }
            if let score = score(needle: needle, candidate: index.candidates[position], scratch: &scratch) {
                scored.append((position, score))
            }
            return true
        }
        if let within {
            for position in within where !consider(position) { return Ranking(paths: [], matches: []) }
        } else {
            for position in index.candidates.indices where !consider(position) { return Ranking(paths: [], matches: []) }
        }
        let candidates = index.candidates
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = candidates[lhs.candidate], right = candidates[rhs.candidate]
            if left.lower.count != right.lower.count { return left.lower.count < right.lower.count }
            return left.path < right.path
        }
        return Ranking(
            paths: scored.prefix(limit).map { candidates[$0.candidate].path },
            matches: scored.map(\.candidate).sorted()
        )
    }

    /// The score of `path` for `query`, or nil when it does not match.
    static func score(query: String, path: String) -> Int? {
        let index = Index(paths: [path])
        var scratch = Scratch(capacity: index.maxLength)
        let needle = normalizedNeedle(query)
        guard !needle.isEmpty else { return 0 }
        return score(needle: needle, candidate: index.candidates[0], scratch: &scratch)
    }

    /// Query bytes, lowercased like the candidates, without whitespace.
    private static func normalizedNeedle(_ query: String) -> [UInt8] {
        Array(String(query.filter { !$0.isWhitespace }).lowercased().utf8)
    }

    /// Reused DP rows, sized to the longest path.
    private struct Scratch {
        var previous: [Int]
        var current: [Int]
        init(capacity: Int) {
            previous = [Int](repeating: GoToFileRanker.unset, count: max(1, capacity))
            current = previous
        }
    }

    private static func score(needle: [UInt8], candidate: Index.Candidate, scratch: inout Scratch) -> Int? {
        let lower = candidate.lower
        guard isSubsequence(needle, of: lower, from: 0) else { return nil }
        let fullScore = alignmentScore(needle: needle, candidate: candidate, from: 0, scratch: &scratch) ?? 0
        let nameStart = candidate.nameStart
        guard isSubsequence(needle, of: lower, from: nameStart),
              let nameAlignment = alignmentScore(needle: needle, candidate: candidate, from: nameStart, scratch: &scratch)
        else { return fullScore }
        return max(fullScore, nameAlignment + nameScore(needle: needle, lower: lower, from: nameStart) + fileNameBonus)
    }

    private static func nameScore(needle: [UInt8], lower: [UInt8], from start: Int) -> Int {
        let name = lower[start...]
        if name.elementsEqual(needle) { return exactFileNameBonus }
        let stem = name.firstIndex(of: UInt8(ascii: ".")).map { name[..<$0] } ?? name
        if stem.elementsEqual(needle) { return exactFileNameBonus }
        if name.starts(with: needle) { return fileNamePrefixBonus }
        return 0
    }

    private static func isSubsequence(_ needle: [UInt8], of haystack: [UInt8], from start: Int) -> Bool {
        var index = 0
        var position = start
        while position < haystack.count {
            if haystack[position] == needle[index] {
                index += 1
                if index == needle.count { return true }
            }
            position += 1
        }
        return false
    }

    /// Best alignment of `needle` in the candidate from byte `start` on
    /// (Smith-Waterman style, linear gaps).
    private static func alignmentScore(
        needle: [UInt8],
        candidate: Index.Candidate,
        from start: Int,
        scratch: inout Scratch
    ) -> Int? {
        let lower = candidate.lower
        let bonuses = candidate.bonus
        let n = lower.count - start
        let m = needle.count
        guard m <= n else { return nil }
        for j in 0..<n { scratch.previous[j] = unset }
        for i in 0..<m {
            var bestBefore = unset // max over k < j of previous[k] + gapPenalty * k
            let wanted = needle[i]
            for j in 0..<n {
                if j > 0, i > 0, scratch.previous[j - 1] != unset {
                    bestBefore = max(bestBefore, scratch.previous[j - 1] + gapPenalty * (j - 1))
                }
                guard lower[start + j] == wanted else {
                    scratch.current[j] = unset
                    continue
                }
                // A word start counts at the name's first byte too.
                let boundary = j == 0 && start > 0 ? boundaryBonus : Int(bonuses[start + j])
                let base = matchScore + boundary
                if i == 0 {
                    scratch.current[j] = base - gapPenalty * min(j, 8)
                    continue
                }
                var best = unset
                if bestBefore != unset {
                    best = bestBefore - gapPenalty * (j - 1) + base
                }
                if j > 0, scratch.previous[j - 1] != unset {
                    best = max(best, scratch.previous[j - 1] + base + consecutiveBonus)
                }
                scratch.current[j] = best
            }
            swap(&scratch.previous, &scratch.current)
        }
        var best = unset
        for j in 0..<n { best = max(best, scratch.previous[j]) }
        return best == unset ? nil : best
    }
}
