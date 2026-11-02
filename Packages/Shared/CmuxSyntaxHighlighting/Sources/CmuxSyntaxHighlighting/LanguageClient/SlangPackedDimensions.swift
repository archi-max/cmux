import Foundation

/// One packed dimension as declared: `[left:right]`.
public struct SlangPackedRange: Sendable, Equatable, Hashable {
    public var left: Int
    public var right: Int

    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }

    public var count: Int { abs(left - right) + 1 }
}

/// The packed dimensions of a signal, from slang-server's getScope `type`: the waveform viewer
/// splits a row along them (Split > By Declared Dimensions). A dump flattens a packed array to
/// one vector, but the design says where its elements are.
public enum SlangPackedDimensions {
    /// Most dimensions, and most bits, a type may have.
    static let maxDimensions = 8
    static let maxWidth = 1 << 20

    /// `logic[1:0][31:0]` (or `output logic[1:0][31:0]`, `bit`, `reg`, `signed`) -> [1:0], [31:0].
    /// Nil for one dimension or none, an element type whose width the text doesn't give (a
    /// struct, an enum: `pair_t[1:0]`), an unpacked array (`...$[0:3]`), and anything else.
    /// slang resolves parameters and spells out typedefs of plain vectors, so bounds are numbers.
    public static func parse(_ text: String) -> [SlangPackedRange]? {
        var words = text.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = words.first, ["input", "output", "inout", "ref"].contains(first) { words.removeFirst() }
        guard let last = words.last, let bracket = last.firstIndex(of: "[") else { return nil }
        let head = words.dropLast() + [String(last[..<bracket])].filter { !$0.isEmpty }
        let base = head.filter { $0 != "signed" && $0 != "unsigned" }
        // The base and at most a sign: `logic`, `logic signed` (the dimensions follow the last word).
        guard base.count == 1, ["logic", "bit", "reg"].contains(base[0]) else { return nil }
        let dims = String(last[bracket...])
        var ranges: [SlangPackedRange] = []
        var rest = Substring(dims)
        while !rest.isEmpty {
            guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return nil }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let bounds = inner.split(separator: ":", omittingEmptySubsequences: false)
            guard bounds.count == 2, let left = Int(bounds[0]), let right = Int(bounds[1]) else { return nil }
            ranges.append(SlangPackedRange(left: left, right: right))
            rest = rest[rest.index(after: close)...]
        }
        guard ranges.count >= 2, ranges.count <= maxDimensions else { return nil }
        guard width(ranges) <= maxWidth else { return nil }
        return ranges
    }

    /// The bits the dimensions hold together.
    public static func width(_ ranges: [SlangPackedRange]) -> Int {
        ranges.reduce(1) { product, range in product > maxWidth ? product : product * range.count }
    }
}

extension LanguageServerSession {
    /// The signals of design instance `hierPath` that are packed arrays, with their dimensions,
    /// by name. One getScope read; no hovers.
    public func slangPackedSignals(inScope hierPath: String) async throws -> [String: [SlangPackedRange]] {
        let result = try await executeCommand("slang.getScope", argument: .string(hierPath))
        var out: [String: [SlangPackedRange]] = [:]
        for item in result.arrayValue ?? [] {
            guard let name = item["instName"]?.stringValue, let type = item["type"]?.stringValue,
                  let kind = item["kind"]?.stringValue, kind == "Logic" || kind == "Port" || kind == "Net",
                  let ranges = SlangPackedDimensions.parse(type) else { continue }
            out[name] = ranges
        }
        return out
    }
}
