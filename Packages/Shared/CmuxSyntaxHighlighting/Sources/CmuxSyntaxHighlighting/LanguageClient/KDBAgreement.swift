import Foundation

/// Where a row the KDB maps to slang's design differs between the compiled design (the KDB's
/// model) and slang's, or what could not be checked. Slang's statements evaluate the row: they are
/// what ran only when nothing here differs.
public enum KDBDifference: Hashable, Sendable {
    /// A parameter (or localparam) of an instance on the row's chain: its values (nil: that side lacks it).
    case parameter(instance: String, name: String, compiled: String?, slang: String?)
    /// The signal's width, range, signedness or array shape.
    case shape(signal: String)
    /// The instance's ports (names, directions, widths).
    case ports(instance: String)
    /// The lines that write the signal.
    case writes(signal: String)
    /// A source of the chain's instances changed after the compile (slang reads the new text).
    case sourceNewer(file: String)
    case notChecked(KDBCheck)

    /// The difference's kind, for counts (`KDBCoverage`).
    public var kind: String {
        switch self {
        case .parameter: "parameter"
        case .shape: "shape"
        case .ports: "ports"
        case .writes: "writes"
        case .sourceNewer: "sourceNewer"
        case .notChecked(let check): "notChecked." + check.rawValue
        }
    }
}

public enum KDBCheck: String, Hashable, Sendable {
    /// The export (an older exporter) or slang's model has no parameters.
    case parameters
    /// No compile time in the export, or no source times from slang's side.
    case sources
}

/// The checks behind an exact KDB mapping. What is checked: the parameters of every instance on
/// the row's chain (from the matched level down), the signal's shape, the row instance's ports and
/// the signal's write lines, and that no source of the chain's instances is newer than the compile.
/// Not checked: a right-hand side that differs without a parameter, width, port or line to show it
/// (a define expanding to another literal, in a file older than the compile).
public enum KDBAgreement {
    /// One level of the row's chain: the KDB's instance (its dump path and model) and slang's model there.
    public struct Level {
        public let path: String
        public let compiled: [String: Any]
        public let slang: [String: Any]

        public init(path: String, compiled: [String: Any], slang: [String: Any]) {
            self.path = path
            self.compiled = compiled
            self.slang = slang
        }
    }

    /// What differs for `signal` (a name in the last level's instance); empty: they agree.
    /// `compiledAt` and `sourceTimes` (path -> modification time), both in ms since 1970.
    public static func differences(chain: [Level], signal: String, compiledAt: Int64?, sourceTimes: [String: Int64]?) -> [KDBDifference] {
        guard let row = chain.last else { return [] }
        var out: [KDBDifference] = []
        // Parameters, down the chain.
        if chain.contains(where: { $0.compiled["params"] as? [String: Any] == nil || $0.slang["params"] as? [String: Any] == nil }) {
            out.append(.notChecked(.parameters))
        } else {
            for level in chain {
                let compiled = level.compiled["params"] as? [String: Any] ?? [:]
                let slang = level.slang["params"] as? [String: Any] ?? [:]
                for name in Set(compiled.keys).union(slang.keys).sorted() {
                    let a = compiled[name], b = slang[name]
                    if let a, let b, sameValue(a, b) { continue }
                    out.append(.parameter(instance: level.path, name: name, compiled: a.map(text), slang: b.map(text)))
                }
            }
        }
        // The signal's shape.
        let compiledSignal = (row.compiled["signals"] as? [String: Any])?[signal] as? [String: Any]
        let slangSignal = (row.slang["signals"] as? [String: Any])?[signal] as? [String: Any]
        if let compiledSignal, let slangSignal, !sameShape(compiledSignal, slangSignal) {
            out.append(.shape(signal: signal))
        }
        // The instance's ports.
        if let compiled = row.compiled["ports"] as? [[String: Any]], let slang = row.slang["ports"] as? [[String: Any]],
           portSet(compiled) != portSet(slang) {
            out.append(.ports(instance: row.path))
        }
        // The signal's write lines (slang's model with its statements only).
        if row.slang["assigns"] != nil || row.slang["procs"] != nil, row.compiled["writes"] != nil,
           !sameWrites(compiledLines(row.compiled, signal), slangWrites(row.slang)[signal] ?? []) {
            out.append(.writes(signal: signal))
        }
        // Sources newer than the compile.
        if let compiledAt, let sourceTimes {
            var seen: Set<String> = []
            var unknown = false
            for level in chain {
                for file in level.slang["files"] as? [String] ?? [] where seen.insert(file).inserted {
                    guard let time = time(of: file, in: sourceTimes) else {
                        unknown = true
                        continue
                    }
                    if time > compiledAt { out.append(.sourceNewer(file: file)) }
                }
            }
            if unknown { out.append(.notChecked(.sources)) }
        } else {
            out.append(.notChecked(.sources))
        }
        return out
    }

    // MARK: Values

    /// Whether two parameter values are the same: integers by value (VCS's 8, slang's 32'sd8 or
    /// 8'hff alike), anything else by its text.
    public static func sameValue(_ a: Any, _ b: Any) -> Bool {
        if let x = integer(a), let y = integer(b) { return x == y }
        return unquoted(text(a)) == unquoted(text(b))
    }

    /// A string value's text (slang prints a string parameter quoted, NPI gives it bare).
    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    static func text(_ value: Any) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        if let string = value as? String { return string }
        return String(describing: value)
    }

    /// An integer value: a JSON integer, or a Verilog number without x/z (decimal, or sized/based).
    static func integer(_ value: Any) -> Int64? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 9.0e18 ? number.int64Value : nil
        }
        guard var string = (value as? String)?.replacingOccurrences(of: "_", with: "").lowercased().trimmingCharacters(in: .whitespaces),
              !string.isEmpty else { return nil }
        var negative = false
        if string.hasPrefix("-") {
            negative = true
            string.removeFirst()
        }
        var radix = 10
        if let tick = string.firstIndex(of: "'") {
            var rest = string[string.index(after: tick)...]
            if rest.first == "s" { rest = rest.dropFirst() }
            guard let base = rest.first else { return nil }
            switch base {
            case "d": radix = 10
            case "h": radix = 16
            case "o": radix = 8
            case "b": radix = 2
            default: return nil
            }
            string = String(rest.dropFirst())
        }
        guard let magnitude = Int64(string, radix: radix) else { return nil }
        return negative ? -magnitude : magnitude
    }

    // MARK: Shapes and ports

    static func sameShape(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        for key in ["width", "msb", "lsb", "signed"] {
            if let x = a[key], let y = b[key], !sameValue(x, y) { return false }
        }
        let arrayA = a["array"] as? [String: Any], arrayB = b["array"] as? [String: Any]
        if (arrayA == nil) != (arrayB == nil) { return false }
        if let arrayA, let arrayB {
            for key in ["lo", "hi", "elemWidth", "dims"] {
                if let x = arrayA[key], let y = arrayB[key], !sameValue(x, y) { return false }
            }
        }
        return true
    }

    /// Ports by name, direction and width (interface ports, which slang does not list, left out).
    static func portSet(_ ports: [[String: Any]]) -> Set<String> {
        Set(ports.compactMap { port in
            guard port["interface"] as? Bool != true, let name = port["name"] as? String else { return nil }
            return name + "|" + (port["dir"] as? String ?? "") + "|" + (port["width"].map(text) ?? "")
        })
    }

    // MARK: Writes

    /// The KDB's write lines of `signal`: (file, line).
    static func compiledLines(_ model: [String: Any], _ signal: String) -> [(file: String, line: Int)] {
        let files = model["files"] as? [String] ?? []
        let writes = (model["writes"] as? [String: Any])?[signal] as? [[String: Any]] ?? []
        return writes.compactMap { entry in
            guard let loc = entry["loc"] as? [Int], loc.count >= 2, loc[0] >= 0, loc[0] < files.count else { return nil }
            return (files[loc[0]], loc[1])
        }
    }

    /// Where slang's model writes each signal: (file, first line, last line). An assignment is its
    /// own line; a statement slang keeps opaque (a for loop, a task call) spans its lines.
    static func slangWrites(_ model: [String: Any]) -> [String: [(file: String, first: Int, last: Int)]] {
        let files = model["files"] as? [String] ?? []
        var names: [String: [(file: String, first: Int, last: Int)]] = [:]
        func add(_ name: String?, _ loc: Any?, span: Bool = false) {
            guard let name, !name.isEmpty, !name.hasPrefix("$") else { return }
            var list = names[name] ?? []
            if let loc = loc as? [Int], loc.count >= 2, loc[0] >= 0, loc[0] < files.count {
                let last = span && loc.count > 3 && loc[3] >= loc[1] ? loc[3] : loc[1]
                list.append((files[loc[0]], loc[1], last))
            }
            names[name] = list
        }
        func walk(_ value: Any?) {
            if let object = value as? [String: Any] {
                if object["k"] as? String == "asgn", let lhs = object["lhs"] as? [String: Any] { add(lhs["name"] as? String, object["loc"]) }
                if object["k"] as? String == "opaque" {
                    for write in object["writes"] as? [[String: Any]] ?? [] { add(write["name"] as? String, object["loc"], span: true) }
                }
                for (_, inner) in object { walk(inner) }
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        for assign in model["assigns"] as? [[String: Any]] ?? [] {
            add((assign["lhs"] as? [String: Any])?["name"] as? String, assign["loc"])
        }
        for proc in model["procs"] as? [[String: Any]] ?? [] { walk(proc["body"]) }
        return names
    }

    /// The same writes: every KDB line in one of slang's spans of the same file, every span with a KDB line.
    static func sameWrites(_ compiled: [(file: String, line: Int)], _ slang: [(file: String, first: Int, last: Int)]) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { a == b || (a as NSString).lastPathComponent == (b as NSString).lastPathComponent }
        let lines = compiled.allSatisfy { line in slang.contains { same(line.file, $0.file) && line.line >= $0.first && line.line <= $0.last } }
        let spans = slang.allSatisfy { span in compiled.contains { same($0.file, span.file) && $0.line >= span.first && $0.line <= span.last } }
        return lines && spans
    }

    /// A file's time: its path as slang's model names it, else the one path ending in it.
    static func time(of file: String, in times: [String: Int64]) -> Int64? {
        if let time = times[file] { return time }
        let ending = file.hasPrefix("/") ? file : "/" + file
        let matches = times.filter { $0.key.hasSuffix(ending) }
        return matches.count == 1 ? matches.first?.value : nil
    }
}

/// Coverage of KDB-mapped rows, counted apart from pass/fail and timing: exact, approximate (by
/// what differs), compiled only (not evaluated) and unsupported (no mapping).
public struct KDBCoverage: Sendable, Equatable {
    public private(set) var exact = 0
    public private(set) var approximate = 0
    public private(set) var compiledOnly = 0
    public private(set) var unsupported = 0
    /// Approximate rows per difference kind (a row counts once per kind).
    public private(set) var differences: [String: Int] = [:]

    public init() {}

    public mutating func add(_ outcome: SVModelResolve.Outcome) {
        switch outcome {
        case .signal:
            exact += 1
        case .approximate(_, _, _, let found):
            approximate += 1
            for kind in Set(found.map(\.kind)) { differences[kind, default: 0] += 1 }
        case .compiledOnly:
            compiledOnly += 1
        case .notElaborated, .notInDesign:
            unsupported += 1
        }
    }

    public var summary: String {
        let kinds = differences.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "exact \(exact), approximate \(approximate)\(kinds.isEmpty ? "" : " (\(kinds))"), compiled only \(compiledOnly), unsupported \(unsupported)"
    }
}
