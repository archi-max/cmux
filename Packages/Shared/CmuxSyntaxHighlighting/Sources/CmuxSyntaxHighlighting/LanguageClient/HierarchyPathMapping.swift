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

        public init(designPrefix: String, dumpPrefix: String) {
            self.designPrefix = designPrefix
            self.dumpPrefix = dumpPrefix
        }
    }

    public var rules: [Rule]

    public init(rules: [Rule] = []) {
        self.rules = rules
    }

    public func dumpPath(forDesignPath path: String) -> String {
        Self.rewrite(path, rules.map { ($0.designPrefix, $0.dumpPrefix) })
    }

    public func designPath(forDumpPath path: String) -> String {
        Self.rewrite(path, rules.map { ($0.dumpPrefix, $0.designPrefix) })
    }

    /// Adds `rule`, replacing any rule for the same design prefix.
    public mutating func setRule(_ rule: Rule) {
        rules.removeAll { $0.designPrefix == rule.designPrefix }
        rules.append(rule)
    }

    /// One `design = dump` rule per line, for editing by hand.
    public var text: String {
        rules.map { "\($0.designPrefix) = \($0.dumpPrefix)" }.joined(separator: "\n")
    }

    /// Parses `text`'s format; blank lines and lines starting with `#` are skipped.
    /// Returns nil when a line is not `design = dump`.
    public init?(text: String) {
        var rules: [Rule] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "=")
            guard parts.count == 2 else { return nil }
            let design = parts[0].trimmingCharacters(in: .whitespaces)
            let dump = parts[1].trimmingCharacters(in: .whitespaces)
            guard !design.isEmpty || !dump.isEmpty else { return nil }
            rules.removeAll { $0.designPrefix == design }
            rules.append(Rule(designPrefix: design, dumpPrefix: dump))
        }
        self.rules = rules
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

    static func join(_ segments: [String]) -> String {
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
/// one whose children best overlap the root's children.
public enum HierarchyPrefixInference {
    /// Children of the scope at a path (`[]` is the hierarchy's root, listing its tops), or nil if it is not a scope.
    public typealias Children = ([String]) async -> [HierarchyNode]?

    /// Editor → waveform. `designPath` is not in the dump as is; returns the
    /// rule mapping its root (first segment) to the dump scope under which
    /// the rest of the path exists and whose children best overlap
    /// `designRootChildren`. Searches breadth first, shallowest scope first on ties.
    public static func dumpRule(
        forDesignPath designPath: String,
        designRootChildren: Set<String>,
        dumpChildren: Children,
        maxDepth: Int = 4,
        maxScopes: Int = 400,
        isolation: isolated (any Actor)? = #isolation
    ) async -> HierarchyPathMapping.Rule? {
        let path = HierarchyPathMapping.segments(designPath)
        guard path.count >= 2 else { return nil }
        let rest = Array(path.dropFirst())
        var best: (score: Int, scope: [String])?
        var queue: [[String]] = [[]]
        var visited = 0
        while !queue.isEmpty, visited < maxScopes {
            let scope = queue.removeFirst()
            visited += 1
            guard let kids = await dumpChildren(scope) else { continue }
            if !scope.isEmpty, kids.contains(where: { $0.name == rest[0] }),
               await exists(scope + rest, dumpChildren: dumpChildren) {
                let score = Set(kids.map(\.name)).intersection(designRootChildren).count
                if best == nil || score > best!.score {
                    best = (score, scope)
                    if score == designRootChildren.count { break }
                }
            }
            if scope.count < maxDepth {
                queue.append(contentsOf: kids.filter(\.isScope).map { scope + [$0.name] })
            }
        }
        guard let best else { return nil }
        return .init(designPrefix: path[0], dumpPrefix: HierarchyPathMapping.join(best.scope))
    }

    /// Waveform → editor. `dumpPath` is not in the design as is; returns the
    /// rule mapping a design top (`designRoots`: name → its children) to the
    /// prefix of `dumpPath` whose dump children best overlap that top's.
    public static func designRule(
        forDumpPath dumpPath: String,
        designRoots: [String: Set<String>],
        dumpChildren: Children,
        isolation: isolated (any Actor)? = #isolation
    ) async -> HierarchyPathMapping.Rule? {
        let path = HierarchyPathMapping.segments(dumpPath)
        guard path.count >= 2 else { return nil }
        var best: (score: Int, rule: HierarchyPathMapping.Rule)?
        for length in 1..<path.count {
            let prefix = Array(path.prefix(length))
            guard let kids = await dumpChildren(prefix) else { break }
            let names = Set(kids.map(\.name))
            for (root, rootChildren) in designRoots.sorted(by: { $0.key < $1.key })
            where rootChildren.contains(path[length]) {
                let score = names.intersection(rootChildren).count
                if best == nil || score > best!.score {
                    best = (score, .init(designPrefix: root, dumpPrefix: HierarchyPathMapping.join(prefix)))
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
    /// True for `x = ...`, `x <= ...`, `x[3:0] <= ...` and `x.field = ...`
    /// when what precedes the identifier on the line is nothing, `assign`,
    /// `begin`, `else`, `;`, `)` (an `if (...)` or event control) or a case label's `:`.
    public static func isAssignmentTarget(line: String, column: Int, length: Int) -> Bool {
        let units = Array(line.utf16)
        guard column >= 0, length > 0, column + length <= units.count else { return false }
        var index = column + length
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
        guard index < units.count else { return false }
        let next = index + 1 < units.count ? units[index + 1] : 0
        let isAssignment: Bool
        if units[index] == 0x3D { // =
            isAssignment = next != 0x3D
        } else if units[index] == 0x3C, next == 0x3D { // <=
            isAssignment = index + 2 >= units.count || units[index + 2] != 0x3D
        } else {
            isAssignment = false
        }
        guard isAssignment else { return false }
        let prefix = String(decoding: units[0..<column], as: UTF16.self)
            .trimmingCharacters(in: .whitespaces)
        if prefix.isEmpty { return true }
        if let last = prefix.last, ";):".contains(last) {
            // `::` is a scope operator, not a case label.
            return !prefix.hasSuffix("::")
        }
        let lastWord = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map(String.init)
        return ["assign", "begin", "else", "always_comb", "always_latch", "always", "initial", "final"]
            .contains(lastWord ?? "") && prefix.hasSuffix(lastWord ?? "")
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24: return true
        default: return false
        }
    }
}
