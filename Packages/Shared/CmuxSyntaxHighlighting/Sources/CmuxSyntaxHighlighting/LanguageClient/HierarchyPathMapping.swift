import Foundation

/// Maps hierarchical paths between the elaborated design (slang-server) and a
/// waveform dump, whose hierarchy usually has a different root: the design
/// may be compiled with the DUT as top (`cpu.rf.data`) while the simulator
/// dumped it under the testbench (`top_tb.dut.rf.data`).
///
/// Each rule replaces a whole-segment prefix; the longest matching rule wins,
/// in either direction. A path no rule matches maps to itself.
public struct HierarchyPathMapping: Codable, Sendable, Equatable {
    public struct Rule: Codable, Sendable, Equatable {
        public var designPrefix: String
        public var dumpPrefix: String
        /// Added by cmux from the two hierarchies rather than written by the user.
        /// Only these are ever dropped automatically.
        public var isInferred: Bool

        public init(designPrefix: String, dumpPrefix: String, isInferred: Bool = false) {
            self.designPrefix = designPrefix
            self.dumpPrefix = dumpPrefix
            self.isInferred = isInferred
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            designPrefix = try container.decode(String.self, forKey: .designPrefix)
            dumpPrefix = try container.decode(String.self, forKey: .dumpPrefix)
            isInferred = try container.decodeIfPresent(Bool.self, forKey: .isInferred) ?? false
        }
    }

    /// Inferred rules kept per design prefix (one per dumped instance of the design root).
    public static let maxInferredRulesPerPrefix = 8

    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    /// The dump path for `path` under the longest matching design prefix. With
    /// several rules for that prefix (several dumped instances), the first: a
    /// user rule before inferred ones.
    public func dumpPath(forDesignPath path: String) -> String {
        dumpPaths(forDesignPath: path)[0]
    }

    /// Every dump path `path` maps to: one per rule with the longest matching
    /// design prefix, user rules first; `[path]` when no rule matches.
    public func dumpPaths(forDesignPath path: String) -> [String] {
        let pathSegments = Self.segments(path)
        var bestLength = -1
        var matches: [Rule] = []
        for rule in rules {
            let from = Self.segments(rule.designPrefix)
            guard from.count <= pathSegments.count, Array(pathSegments.prefix(from.count)) == from else { continue }
            if from.count > bestLength {
                bestLength = from.count
                matches = [rule]
            } else if from.count == bestLength {
                matches.append(rule)
            }
        }
        guard !matches.isEmpty else { return [path] }
        var result: [String] = []
        for rule in matches.filter({ !$0.isInferred }) + matches.filter(\.isInferred) {
            let mapped = Self.join(Self.segments(rule.dumpPrefix) + pathSegments.dropFirst(bestLength))
            if !result.contains(mapped) { result.append(mapped) }
        }
        return result
    }

    public func designPath(forDumpPath path: String) -> String {
        Self.rewrite(path, rules.map { ($0.dumpPrefix, $0.designPrefix) })
    }

    /// Adds an inferred rule unless the same mapping is already present. A user
    /// rule is never replaced; the oldest inferred rules for the prefix go first
    /// once there are `maxInferredRulesPerPrefix`.
    public mutating func addInferredRule(designPrefix: String, dumpPrefix: String) {
        guard !rules.contains(where: { $0.designPrefix == designPrefix && $0.dumpPrefix == dumpPrefix }) else { return }
        rules.append(Rule(designPrefix: designPrefix, dumpPrefix: dumpPrefix, isInferred: true))
        let inferred = rules.indices.filter { rules[$0].isInferred && rules[$0].designPrefix == designPrefix }
        if inferred.count > Self.maxInferredRulesPerPrefix {
            let drop = Set(inferred.prefix(inferred.count - Self.maxInferredRulesPerPrefix))
            rules = rules.indices.filter { !drop.contains($0) }.map { rules[$0] }
        }
    }

    private static let inferredMarker = "# inferred"

    /// One `design = dump` rule per line, for editing by hand; inferred rules end in `# inferred`.
    public var text: String {
        rules.map { rule in
            "\(rule.designPrefix) = \(rule.dumpPrefix)" + (rule.isInferred ? "  \(Self.inferredMarker)" : "")
        }.joined(separator: "\n")
    }

    /// Parses `text`'s format; blank lines and lines starting with `#` are skipped.
    /// A line splits at its first `=`, so a dump prefix may contain `=`.
    /// Returns nil when a line is not `design = dump`.
    public init?(text: String) {
        var rules: [Rule] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var isInferred = false
            if line.hasSuffix(Self.inferredMarker) {
                isInferred = true
                line = String(line.dropLast(Self.inferredMarker.count))
            }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let design = Self.trimmedPrefix(line[..<equals])
            let dump = Self.trimmedPrefix(line[line.index(after: equals)...])
            guard !design.isEmpty || !dump.isEmpty else { return nil }
            guard !rules.contains(where: { $0.designPrefix == design && $0.dumpPrefix == dump }) else { continue }
            rules.append(Rule(designPrefix: design, dumpPrefix: dump, isInferred: isInferred))
        }
        self.rules = rules
    }

    /// Trims whitespace, keeping the space that ends an escaped identifier (`\a.b `).
    private static func trimmedPrefix(_ text: Substring) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = segments(trimmed).last, last.hasPrefix("\\"), !last.hasSuffix(" ") else { return trimmed }
        return trimmed + " "
    }

    /// Splits a hierarchical path at dots outside brackets and escaped identifiers.
    public static func segments(_ path: String) -> [String] {
        var result: [String] = []
        var current = ""
        var bracketDepth = 0
        var inEscaped = false
        for character in path {
            if inEscaped {
                current.append(character)
                if character == " " { inEscaped = false }
                continue
            }
            switch character {
            case "\\" where current.isEmpty:
                inEscaped = true
                current.append(character)
            case "[":
                bracketDepth += 1
                current.append(character)
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            case "." where bracketDepth == 0:
                result.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.isEmpty || !result.isEmpty { result.append(current) }
        return result
    }

    public static func join(_ segments: [String]) -> String {
        segments.joined(separator: ".")
    }

    private static func rewrite(_ path: String, _ pairs: [(from: String, to: String)]) -> String {
        let pathSegments = segments(path)
        var best: (length: Int, to: [String])?
        for pair in pairs {
            let from = segments(pair.from)
            guard from.count <= pathSegments.count,
                  Array(pathSegments.prefix(from.count)) == from,
                  from.count > (best?.length ?? -1) else { continue }
            best = (from.count, segments(pair.to))
        }
        guard let best else { return path }
        return join(best.to + pathSegments.dropFirst(best.length))
    }
}

/// A child in a hierarchy being searched: a scope (instance, generate block) or a signal.
public struct HierarchyNode: Sendable, Equatable {
    public var name: String
    public var isScope: Bool

    public init(name: String, isScope: Bool) {
        self.name = name
        self.isScope = isScope
    }
}

/// Finds the prefix rule that lines a design path up with a dump hierarchy by
/// matching the instance tree: the scope that plays the role of a root is the
/// one whose children overlap the root's children enough (see `requiredOverlap`).
public enum HierarchyPrefixInference {
    /// Children of the scope at a path (`[]` is the hierarchy's root, listing its tops), or nil if it is not a scope.
    public typealias Children = ([String]) async -> [HierarchyNode]?

    public enum DumpRuleResult: Sendable, Equatable {
        /// The design root's dump scopes that hold the path, best first. Several
        /// when they match equally well (two instances of the design): ask.
        case found([HierarchyPathMapping.Rule])
        /// The scope most like the design root is in the dump, but the signal under it is not (not dumped).
        case notDumped(HierarchyPathMapping.Rule)
        case notFound
    }

    /// Names a candidate scope must share with a root of `count` children:
    /// at least half of them, and at least two (one for a root with one child).
    public static func requiredOverlap(childCount count: Int) -> Int {
        max(min(2, count), (count + 1) / 2)
    }

    /// Instance names are far more telling than `clk` or `rst`, so a shared scope child counts twice.
    static func score(_ kids: [HierarchyNode], against rootChildren: [HierarchyNode]) -> (overlap: Int, score: Int) {
        let rootScopes = Set(rootChildren.filter(\.isScope).map(\.name))
        let rootNames = Set(rootChildren.map(\.name))
        var overlap = 0
        var score = 0
        for name in Set(kids.map(\.name)) where rootNames.contains(name) {
            overlap += 1
            score += rootScopes.contains(name) ? 2 : 1
        }
        return (overlap, score)
    }

    /// Editor → waveform. `designPath` is not in the dump as is; looks breadth
    /// first for dump scopes whose children overlap `designRootChildren` (the
    /// children of the path's first segment in the design) enough, and returns
    /// rules mapping that root to them. Never matches on an empty root.
    public static func dumpRules(
        forDesignPath designPath: String,
        designRootChildren: [HierarchyNode],
        dumpChildren: Children,
        maxDepth: Int = 4,
        maxScopes: Int = 400,
        isolation: isolated (any Actor)? = #isolation
    ) async -> DumpRuleResult {
        let path = HierarchyPathMapping.segments(designPath)
        guard path.count >= 2, !designRootChildren.isEmpty else { return .notFound }
        let rest = Array(path.dropFirst())
        let required = requiredOverlap(childCount: Set(designRootChildren.map(\.name)).count)
        var found: [(score: Int, scope: [String])] = []
        var bestMissing: (score: Int, scope: [String])?
        var queue: [[String]] = [[]]
        var visited = 0
        while !queue.isEmpty, visited < maxScopes {
            let scope = queue.removeFirst()
            visited += 1
            guard let kids = await dumpChildren(scope) else { continue }
            if !scope.isEmpty {
                let match = score(kids, against: designRootChildren)
                if match.overlap >= required {
                    if kids.contains(where: { $0.name == rest[0] }), await exists(scope + rest, dumpChildren: dumpChildren) {
                        found.append((match.score, scope))
                        // The root's own subtree does not hold another copy of the root.
                        continue
                    }
                    // A testbench sharing clk and rst can pass for a small root; the root may be further down.
                    if bestMissing == nil || match.score > bestMissing!.score {
                        bestMissing = (match.score, scope)
                    }
                }
            }
            if scope.count < maxDepth {
                queue.append(contentsOf: kids.filter(\.isScope).map { scope + [$0.name] })
            }
        }
        let rule = { (scope: [String]) in
            HierarchyPathMapping.Rule(designPrefix: path[0], dumpPrefix: HierarchyPathMapping.join(scope), isInferred: true)
        }
        let bestFound = found.map(\.score).max()
        if let missing = bestMissing, missing.score > (bestFound ?? -1) {
            return .notDumped(rule(missing.scope))
        }
        guard let bestFound else { return .notFound }
        return .found(found.filter { $0.score == bestFound }.map { rule($0.scope) })
    }

    /// Waveform → editor. `dumpPath` is not in the design as is; returns the
    /// rule mapping a design top (`designRoots`: name → its children) to the
    /// prefix of `dumpPath` whose dump children overlap that top's enough, best first.
    public static func designRule(
        forDumpPath dumpPath: String,
        designRoots: [String: [HierarchyNode]],
        dumpChildren: Children,
        isolation: isolated (any Actor)? = #isolation
    ) async -> HierarchyPathMapping.Rule? {
        let path = HierarchyPathMapping.segments(dumpPath)
        guard path.count >= 2 else { return nil }
        var best: (score: Int, rule: HierarchyPathMapping.Rule)?
        for length in 1..<path.count {
            let prefix = Array(path.prefix(length))
            guard let kids = await dumpChildren(prefix) else { break }
            for (root, rootChildren) in designRoots.sorted(by: { $0.key < $1.key })
            where rootChildren.contains(where: { $0.name == path[length] }) {
                let match = score(kids, against: rootChildren)
                guard match.overlap >= requiredOverlap(childCount: Set(rootChildren.map(\.name)).count) else { continue }
                if best == nil || match.score > best!.score {
                    best = (match.score, .init(designPrefix: root, dumpPrefix: HierarchyPathMapping.join(prefix), isInferred: true))
                }
            }
        }
        return best?.rule
    }

    /// Whether `path` names an item in the hierarchy.
    public static func exists(
        _ path: [String],
        dumpChildren: Children,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        guard let last = path.last else { return false }
        guard let kids = await dumpChildren(Array(path.dropLast())) else { return false }
        return kids.contains { $0.name == last }
    }
}

/// Textual check for whether a reference to a signal is the target of an
/// assignment, used to find a signal's driver lines from its references.
/// slang-server reports drivers only as fan-in signals, not statements.
public enum SystemVerilogAssignmentScanner {
    /// `line` is the reference's line; `column` and `length` (UTF-16) locate the identifier.
    ///
    /// True for `x = ...`, `x <= ...`, `x += ...` (and the other compound
    /// operators), `x++`, `x[3:0] <= ...`, `x.field = ...` and a concatenation
    /// target `{x, y} = ...`, when what precedes the target on the line is
    /// nothing, `assign`, `begin`, `else`, `;`, `)` (an `if (...)` or event
    /// control) or a case label's `:`.
    ///
    /// A target split from its statement keyword across lines is not seen.
    public static func isAssignmentTarget(line: String, column: Int, length: Int) -> Bool {
        let units = Array(line.utf16)
        guard column >= 0, length > 0, column + length <= units.count else { return false }
        if isTarget(units, start: column, end: column + length) { return true }
        // Inside a concatenation: the whole `{...}` must be the target.
        guard let open = unmatchedOpenBrace(units, before: column),
              let close = matchingCloseBrace(units, after: column + length) else { return false }
        return isTarget(units, start: open, end: close + 1)
    }

    private static func isTarget(_ units: [UInt16], start: Int, end: Int) -> Bool {
        var index = end
        func skipSpaces() {
            while index < units.count, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        }
        // Selects and member accesses after the name.
        while true {
            skipSpaces()
            guard index < units.count else { return false }
            if units[index] == 0x5B { // [
                var depth = 0
                while index < units.count {
                    if units[index] == 0x5B { depth += 1 }
                    if units[index] == 0x5D { depth -= 1; if depth == 0 { index += 1; break } }
                    index += 1
                }
                continue
            }
            if units[index] == 0x2E { // .
                index += 1
                while index < units.count, isIdentifierUnit(units[index]) { index += 1 }
                continue
            }
            break
        }
        guard index < units.count, isAssignmentOperator(units, at: index) else { return false }
        return isStatementStart(String(decoding: units[0..<start], as: UTF16.self))
    }

    /// `=`, `<=`, `op=` for the compound operators, or `++`/`--`.
    private static func isAssignmentOperator(_ units: [UInt16], at index: Int) -> Bool {
        func unit(_ offset: Int) -> UInt16 { index + offset < units.count ? units[index + offset] : 0 }
        let equals: UInt16 = 0x3D
        switch unit(0) {
        case equals:
            return unit(1) != equals
        case 0x3C: // <
            if unit(1) == equals { return unit(2) != equals } // <= (the comparison is ruled out by the statement start)
            if unit(1) == 0x3C { return unit(2) == equals || (unit(2) == 0x3C && unit(3) == equals) } // <<= <<<=
            return false
        case 0x3E: // >
            return unit(1) == 0x3E && (unit(2) == equals || (unit(2) == 0x3E && unit(3) == equals)) // >>= >>>=
        case 0x2B, 0x2D: // + -
            return unit(1) == equals || unit(1) == unit(0)
        case 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E: // * / % & | ^
            return unit(1) == equals
        default:
            return false
        }
    }

    private static func isStatementStart(_ text: String) -> Bool {
        let prefix = text.trimmingCharacters(in: .whitespaces)
        if prefix.isEmpty { return true }
        if let last = prefix.last, ";):".contains(last) {
            // `::` is a scope operator, not a case label.
            return !prefix.hasSuffix("::")
        }
        let lastWord = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map(String.init)
        return ["assign", "begin", "else", "always_comb", "always_latch", "always", "always_ff", "initial", "final"]
            .contains(lastWord ?? "") && prefix.hasSuffix(lastWord ?? "")
    }

    private static func unmatchedOpenBrace(_ units: [UInt16], before index: Int) -> Int? {
        var depth = 0
        var i = index - 1
        while i >= 0 {
            switch units[i] {
            case 0x7D: depth += 1 // }
            case 0x7B: // {
                if depth == 0 { return i }
                depth -= 1
            case 0x3B: return nil // ;
            default: break
            }
            i -= 1
        }
        return nil
    }

    private static func matchingCloseBrace(_ units: [UInt16], after index: Int) -> Int? {
        var depth = 0
        var i = index
        while i < units.count {
            switch units[i] {
            case 0x7B: depth += 1
            case 0x7D:
                if depth == 0 { return i }
                depth -= 1
            case 0x3B: return nil
            default: break
            }
            i += 1
        }
        return nil
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24: return true
        default: return false
        }
    }
}
