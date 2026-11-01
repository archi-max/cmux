import Foundation

/// One member of a SystemVerilog enum: its name and value, `width` bits, most significant first.
public struct SlangEnumMember: Sendable, Equatable, Hashable {
    public var name: String
    public var bits: String

    public init(name: String, bits: String) {
        self.name = name
        self.bits = bits
    }
}

/// A SystemVerilog enum type as one instance elaborates it (a parameterized enum can have
/// another width, and other values, in another instance).
public struct SlangEnumType: Sendable, Equatable, Hashable {
    /// slang's name for it: `fsm.state_t`, `cpu_pkg::op_t`, or `enum{RED,GREEN,BLUE}` for an anonymous one.
    public var name: String
    public var width: Int
    public var members: [SlangEnumMember]

    public init(name: String, width: Int, members: [SlangEnumMember]) {
        self.name = name
        self.width = width
        self.members = members
    }

    /// The first member with value `bits` (already `width` long), if any.
    public func memberName(forBits bits: String) -> String? {
        members.first { $0.bits == bits }?.name
    }

    /// How a value of this type reads: the member's name; a known value no member has, as a hex
    /// literal (shown with a marker); a value with x or z bits as `x`, `z` or a binary literal.
    public func display(_ value: String) -> SlangEnumDisplay {
        let bits = SlangEnumValues.fitted(value.lowercased(), width: width)
        if bits.allSatisfy({ $0 == "0" || $0 == "1" }) {
            if let name = memberName(forBits: bits) { return .member(name) }
            return .unknown(SlangEnumValues.hexLiteral(bits))
        }
        if bits.allSatisfy({ $0 == "z" }) { return .unknownBits("z") }
        if bits.allSatisfy({ $0 != "0" && $0 != "1" && $0 != "z" }) { return .unknownBits("x") }
        return .unknownBits("\(bits.count)'b" + String(bits.map { $0 == "0" || $0 == "1" || $0 == "z" ? $0 : "x" }))
    }
}

/// An enum-typed value as the editor shows it.
public enum SlangEnumDisplay: Sendable, Equatable {
    case member(String)
    /// A known value no member has (`3'h2`); shown with a `?` after it.
    case unknown(String)
    /// x, z, or a mix (`3'b0x1`).
    case unknownBits(String)

    public var text: String {
        switch self {
        case .member(let name): return name
        case .unknown(let literal): return literal + "?"
        case .unknownBits(let text): return text
        }
    }

    public var isMember: Bool {
        if case .member = self { return true }
        return false
    }
}

/// A signal whose declared type is an enum, or an unpacked array of one (`isArray`: its
/// elements, `hist[0]`, have the type).
public struct SlangEnumSignal: Sendable, Equatable {
    public var type: SlangEnumType
    public var isArray: Bool

    public init(type: SlangEnumType, isArray: Bool) {
        self.type = type
        self.isArray = isArray
    }
}

/// Enum types already read, so each typedef is asked about once: by the typedef's position
/// and the width an instance gives it, and declarations by their position.
public actor SlangEnumTypeCache {
    var types: [String: SlangEnumType?] = [:]
    var declarationLinks: [String: SlangEnumValues.TypeLink?] = [:]

    public init() {}

    public func removeAll() {
        types.removeAll()
        declarationLinks.removeAll()
    }

    func type(_ key: String) -> SlangEnumType?? { types[key] }
    func setType(_ type: SlangEnumType?, _ key: String) { types[key] = type }
    func link(_ key: String) -> SlangEnumValues.TypeLink?? { declarationLinks[key] }
    func setLink(_ link: SlangEnumValues.TypeLink?, _ key: String) { declarationLinks[key] = link }
}

/// Reading enum types from slang-server's text: getScope's `type`, hovers and declarations.
public enum SlangEnumValues {
    /// The most members one type may have, and the widest enum read.
    static let maxMembers = 4096
    static let maxWidth = 4096

    public enum ScopeType: Sendable, Equatable {
        /// `Enum state_t (logic[2:0])`: the members come from the typedef.
        case named(name: String, width: Int)
        /// `Enum enum{RED=32'sd0,...}e$3 (bit[31:0])`: the type names its members itself.
        case anonymous(SlangEnumType)
        /// `state_t$[0:1]`: an unpacked array; its element type, by name.
        case array(elementType: String)
    }

    /// getScope's `type` of a variable, when it is an enum or an unpacked array.
    public static func scopeType(_ text: String) -> ScopeType? {
        let type = text.trimmingCharacters(in: .whitespaces)
        if !type.hasPrefix("Enum "), let dollar = type.range(of: "$[") {
            let element = String(type[..<dollar.lowerBound])
            return element.isEmpty || element.contains(" ") ? nil : .array(elementType: element)
        }
        guard type.hasPrefix("Enum "), type.hasSuffix(")"), let open = type.range(of: " (", options: .backwards) else { return nil }
        let name = String(type[type.index(type.startIndex, offsetBy: 5)..<open.lowerBound])
        let base = String(type[open.upperBound..<type.index(before: type.endIndex)])
        guard !name.isEmpty, let width = baseWidth(base) else { return nil }
        if name.hasPrefix("enum{") {
            guard let close = name.lastIndex(of: "}") else { return nil }
            let body = name[name.index(name.startIndex, offsetBy: 5)..<close]
            var members: [SlangEnumMember] = []
            for item in body.split(separator: ",") {
                let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let bits = literalBits(parts[1], width: width) else { return nil }
                members.append(.init(name: parts[0], bits: bits))
            }
            guard !members.isEmpty, members.count <= maxMembers else { return nil }
            let label = "enum{" + members.map(\.name).joined(separator: ",") + "}"
            return .anonymous(SlangEnumType(name: label, width: width, members: members))
        }
        return .named(name: name, width: width)
    }

    /// `logic[2:0]` -> 3, `logic` -> 1.
    static func baseWidth(_ base: String) -> Int? {
        let text = base.replacingOccurrences(of: " signed", with: "")
        guard let open = text.firstIndex(of: "[") else {
            return ["logic", "bit", "reg"].contains(text) ? 1 : nil
        }
        guard text.hasSuffix("]") else { return nil }
        let range = text[text.index(after: open)..<text.index(before: text.endIndex)].split(separator: ":")
        guard range.count == 2, let msb = Int(range[0]), let lsb = Int(range[1]) else { return nil }
        let width = abs(msb - lsb) + 1
        return width <= maxWidth ? width : nil
    }

    /// A Verilog number literal (`3'b100`, `32'sd2`, `'h1f`, `12`) as exactly `width` bits; nil for
    /// anything else (a name, an expression, x or z digits).
    public static func literalBits(_ literal: String, width: Int) -> String? {
        guard width > 0, width <= maxWidth else { return nil }
        let text = literal.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        var digits = text
        var base = 10
        if let tick = text.firstIndex(of: "'") {
            var rest = text[text.index(after: tick)...]
            if rest.first == "s" { rest = rest.dropFirst() }
            guard let radix = rest.first else { return nil }
            switch radix {
            case "b": base = 2
            case "o": base = 8
            case "d": base = 10
            case "h": base = 16
            default: return nil
            }
            digits = String(rest.dropFirst())
        }
        guard !digits.isEmpty, digits.count <= maxWidth else { return nil }
        var bits: [Character] = []
        switch base {
        case 2, 8, 16:
            let per = base == 2 ? 1 : (base == 8 ? 3 : 4)
            for digit in digits {
                guard let value = digit.hexDigitValue, value < base else { return nil }
                for shift in stride(from: per - 1, through: 0, by: -1) {
                    bits.append((value >> shift) & 1 == 1 ? "1" : "0")
                }
            }
        default:
            // Decimal: long division by 2 over the digit string.
            var number = digits.compactMap(\.wholeNumberValue)
            guard number.count == digits.count else { return nil }
            while !(number.isEmpty || number.allSatisfy({ $0 == 0 })) {
                var next: [Int] = []
                var carry = 0
                for digit in number {
                    let value = carry * 10 + digit
                    if !next.isEmpty || value / 2 > 0 { next.append(value / 2) }
                    carry = value % 2
                }
                bits.insert(carry == 1 ? "1" : "0", at: 0)
                number = next
            }
            if bits.isEmpty { bits = ["0"] }
        }
        return fitted(String(bits), width: width)
    }

    /// `bits` as `width` bits: a shorter value is extended with its top bit when that is x or z
    /// (as VCD does), else with 0; a longer one keeps its low bits.
    static func fitted(_ bits: String, width: Int) -> String {
        if bits.count == width { return bits }
        if bits.count > width { return String(bits.suffix(width)) }
        let top = bits.first ?? "0"
        let fill: Character = top == "x" || top == "z" ? top : "0"
        return String(repeating: fill, count: width - bits.count) + bits
    }

    /// `bits` as a sized hex literal (`3'h1`); a hex digit with x or z bits is `?`.
    public static func hexLiteral(_ bits: String) -> String {
        let chars = Array(bits.lowercased())
        var digits: [Character] = []
        var end = chars.count
        while end > 0 {
            let start = max(0, end - 4)
            let group = chars[start..<end]
            if group.allSatisfy({ $0 == "0" || $0 == "1" }) {
                let value = group.reduce(0) { $0 * 2 + ($1 == "1" ? 1 : 0) }
                digits.insert(Character(String(value, radix: 16)), at: 0)
            } else {
                digits.insert("?", at: 0)
            }
            end = start
        }
        return "\(chars.count)'h" + String(digits)
    }

    // MARK: Hovers

    public struct TypeLink: Sendable, Equatable {
        public var uri: URL
        /// The type's name in its declaration (0-based line, UTF-16 character).
        public var position: LSPPosition
    }

    /// The link a hover's `Type:` (or `Resolved Type:`) gives to an enum type's declaration.
    public static func enumTypeLink(inHover hover: String) -> TypeLink? {
        for line in hover.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { return nil }
            let text = line.trimmingCharacters(in: .whitespaces)
            let field: Substring
            if text.hasPrefix("Type: ") {
                field = text.dropFirst(6)
            } else if text.hasPrefix("Resolved Type: ") {
                field = text.dropFirst(15)
            } else {
                continue
            }
            guard field.hasPrefix("[`Enum "), let target = field.range(of: "`](<"), field.hasSuffix(">)") else { return nil }
            let link = field[target.upperBound..<field.index(field.endIndex, offsetBy: -2)]
            guard let hash = link.lastIndex(of: "#"), let url = URL(string: String(link[..<hash])), url.isFileURL else { return nil }
            let anchor = link[link.index(after: hash)...]
            let numbers = anchor.dropFirst().split(separator: ",")
            guard anchor.hasPrefix("L"), numbers.count == 2, let row = Int(numbers[0]), let column = Int(numbers[1]),
                  row >= 1, column >= 1 else { return nil }
            return TypeLink(uri: url, position: LSPPosition(line: row - 1, character: column - 1))
        }
        return nil
    }

    /// The text of a hover's first code block (the declaration slang quotes).
    public static func firstCodeBlock(inHover hover: String) -> String? {
        let lines = hover.split(separator: "\n", omittingEmptySubsequences: false)
        guard let fence = lines.firstIndex(where: { $0.hasPrefix("```") }),
              let close = lines[(fence + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else { return nil }
        return lines[(fence + 1)..<close].joined(separator: "\n")
    }

    public struct HoverMemberValue: Sendable, Equatable {
        public var name: String
        /// The enum it belongs to, as slang names it (`fsm.state_t`).
        public var scope: String
        /// `3'b100`.
        public var literal: String
    }

    /// The values an enum member's hover gives, one section per elaborated instance.
    public static func hoverMemberValues(_ hover: String) -> [HoverMemberValue] {
        var out: [HoverMemberValue] = []
        var pending: (name: String, scope: String)?
        for line in hover.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("**EnumValue** `") {
                let parts = text.split(separator: "`", omittingEmptySubsequences: false)
                pending = parts.count >= 4 ? (String(parts[1]), String(parts[3])) : nil
            } else if text.hasPrefix("Value: `"), text.hasSuffix("`"), let member = pending {
                out.append(.init(name: member.name, scope: member.scope, literal: String(text.dropFirst(8).dropLast())))
                pending = nil
            }
        }
        return out
    }

    // MARK: Declarations

    public struct MemberRange: Sendable, Equatable {
        public var first: Int
        public var last: Int
    }

    public struct DeclaredMember: Sendable, Equatable {
        public var name: String
        /// UTF-16 offset of the name in the declaration's text.
        public var offset: Int
        /// The text after `=`, if any.
        public var explicitValue: String?
        /// `NAME[N]` (0...N-1) or `NAME[N:M]`.
        public var range: MemberRange?
    }

    /// The members of the first `enum ... { ... }` in `text` (comments are skipped); nil when
    /// there is none or it can't be read.
    public static func declaredMembers(in text: String) -> [DeclaredMember]? {
        let units = blanked(Array(text.utf16))
        guard let enumAt = word("enum", in: units) else { return nil }
        guard let open = units[enumAt...].firstIndex(of: UInt16(UInt8(ascii: "{"))) else { return nil }
        var members: [DeclaredMember] = []
        var depth = 0
        var itemStart = open + 1
        var index = open + 1
        func finish(_ end: Int) -> Bool {
            let item = Array(units[itemStart..<end])
            guard let member = member(item, at: itemStart) else { return false }
            members.append(member)
            return true
        }
        while index < units.count {
            let unit = units[index]
            if unit == UInt16(UInt8(ascii: "{")) || unit == UInt16(UInt8(ascii: "(")) || unit == UInt16(UInt8(ascii: "[")) {
                depth += 1
            } else if unit == UInt16(UInt8(ascii: ")")) || unit == UInt16(UInt8(ascii: "]")) {
                depth -= 1
            } else if unit == UInt16(UInt8(ascii: "}")) {
                if depth == 0 {
                    guard finish(index), !members.isEmpty, members.count <= maxMembers else { return nil }
                    return members
                }
                depth -= 1
            } else if unit == UInt16(UInt8(ascii: ",")), depth == 0 {
                guard finish(index) else { return nil }
            }
            if unit == UInt16(UInt8(ascii: ",")) && depth == 0 { itemStart = index + 1 }
            index += 1
        }
        return nil
    }

    private static func member(_ item: [UInt16], at start: Int) -> DeclaredMember? {
        var index = 0
        while index < item.count, isSpace(item[index]) { index += 1 }
        let nameStart = index
        while index < item.count, isIdentifier(item[index]) { index += 1 }
        guard index > nameStart else { return nil }
        let name = String(decoding: item[nameStart..<index], as: UTF16.self)
        while index < item.count, isSpace(item[index]) { index += 1 }
        var range: MemberRange?
        if index < item.count, item[index] == UInt16(UInt8(ascii: "[")) {
            guard let close = item[index...].firstIndex(of: UInt16(UInt8(ascii: "]"))) else { return nil }
            let inside = String(decoding: item[(index + 1)..<close], as: UTF16.self).replacingOccurrences(of: " ", with: "")
            let bounds = inside.split(separator: ":").compactMap { Int($0) }
            if bounds.count == 1, bounds[0] > 0 {
                range = MemberRange(first: 0, last: bounds[0] - 1)
            } else if bounds.count == 2 {
                range = MemberRange(first: bounds[0], last: bounds[1])
            } else {
                return nil
            }
            index = close + 1
            while index < item.count, isSpace(item[index]) { index += 1 }
        }
        var explicit: String?
        if index < item.count {
            guard item[index] == UInt16(UInt8(ascii: "=")) else { return nil }
            // The value as written, comments blanked.
            explicit = String(decoding: item[(index + 1)...], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !(explicit ?? "").isEmpty else { return nil }
        }
        return DeclaredMember(name: name, offset: start + nameStart, explicitValue: explicit, range: range)
    }

    /// Comments and strings turned into spaces (newlines kept), so offsets stay the same.
    private static func blanked(_ units: [UInt16]) -> [UInt16] {
        var out = units
        var index = 0
        let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*")), quote = UInt16(UInt8(ascii: "\""))
        let newline = UInt16(UInt8(ascii: "\n")), space = UInt16(UInt8(ascii: " "))
        while index < out.count {
            if out[index] == slash, index + 1 < out.count, out[index + 1] == slash {
                while index < out.count, out[index] != newline { out[index] = space; index += 1 }
            } else if out[index] == slash, index + 1 < out.count, out[index + 1] == star {
                out[index] = space; out[index + 1] = space; index += 2
                while index < out.count, !(out[index] == star && index + 1 < out.count && out[index + 1] == slash) {
                    if out[index] != newline { out[index] = space }
                    index += 1
                }
                if index < out.count { out[index] = space; index += 1 }
                if index < out.count { out[index] = space; index += 1 }
            } else if out[index] == quote {
                out[index] = space; index += 1
                while index < out.count, out[index] != quote, out[index] != newline { out[index] = space; index += 1 }
                if index < out.count, out[index] == quote { out[index] = space; index += 1 }
            } else {
                index += 1
            }
        }
        return out
    }

    private static func word(_ word: String, in units: [UInt16]) -> Int? {
        let target = Array(word.utf16)
        var index = 0
        while index + target.count <= units.count {
            if Array(units[index..<(index + target.count)]) == target,
               index == 0 || !isIdentifier(units[index - 1]),
               index + target.count == units.count || !isIdentifier(units[index + target.count]) {
                return index
            }
            index += 1
        }
        return nil
    }

    static func isIdentifier(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    /// Where `offset` of a hover's code block is in the file, given that the block's
    /// `anchorOffset` is at `anchor` there. slang quotes the declaration with its common
    /// indentation removed, so a line above the anchor's is shifted by the anchor line's.
    static func filePosition(ofBlockOffset offset: Int, in block: String, anchorOffset: Int, anchor: LSPPosition) -> LSPPosition? {
        let units = Array(block.utf16)
        guard offset <= units.count, anchorOffset <= units.count else { return nil }
        func lineAndColumn(_ at: Int) -> (line: Int, column: Int) {
            var line = 0, column = 0
            for unit in units[0..<at] {
                if unit == 0x0A { line += 1; column = 0 } else { column += 1 }
            }
            return (line, column)
        }
        let target = lineAndColumn(offset)
        let anchorAt = lineAndColumn(anchorOffset)
        let line = anchor.line - (anchorAt.line - target.line)
        guard line >= 0 else { return nil }
        if target.line == anchorAt.line {
            return LSPPosition(line: line, character: anchor.character - (anchorAt.column - target.column))
        }
        let shift = anchor.character - anchorAt.column
        return LSPPosition(line: line, character: target.column + max(0, shift))
    }

    /// The UTF-16 offset of identifier `name` in `text`, the last one at or before `before` when given.
    static func offset(ofIdentifier name: String, in text: String, before: Int? = nil) -> Int? {
        let units = blanked(Array(text.utf16))
        let target = Array(name.utf16)
        var found: Int?
        var index = 0
        while index + target.count <= units.count {
            if let before, index > before { break }
            if Array(units[index..<(index + target.count)]) == target,
               index == 0 || !isIdentifier(units[index - 1]),
               index + target.count == units.count || !isIdentifier(units[index + target.count]) {
                found = index
            }
            index += 1
        }
        return found
    }
}

extension LanguageServerSession {
    /// The signals of the design scope `hierPath` whose declared type is an enum (or an unpacked
    /// array of one), by name, with the members as this instance elaborates them. A type whose
    /// members can't all be read is left out rather than shown with wrong names.
    public func slangEnumSignals(inScope hierPath: String, cache: SlangEnumTypeCache) async throws -> [String: SlangEnumSignal] {
        let result = try await executeCommand("slang.getScope", argument: .string(hierPath))
        var named: [(name: String, typeName: String, width: Int, location: LSPLocation)] = []
        var arrays: [(name: String, element: String, location: LSPLocation)] = []
        var out: [String: SlangEnumSignal] = [:]
        for item in result.arrayValue ?? [] {
            guard let name = item["instName"]?.stringValue, let type = item["type"]?.stringValue,
                  let kind = item["kind"]?.stringValue, kind == "Logic" || kind == "Port",
                  let scopeType = SlangEnumValues.scopeType(type) else { continue }
            var location: LSPLocation?
            if let uri = item["instLoc"]?["uri"]?.stringValue, let range = LSPResponseDecoding.range(item["instLoc"]?["range"]),
               let url = editorURL(forServerURI: uri) {
                location = LSPLocation(uri: url, range: range)
            }
            switch scopeType {
            case .anonymous(let enumType):
                out[name] = SlangEnumSignal(type: enumType, isArray: false)
            case .named(let typeName, let width):
                if let location { named.append((name, typeName, width, location)) }
            case .array(let element):
                if let location { arrays.append((name, element, location)) }
            }
        }
        var byTypeName: [String: SlangEnumType] = [:]
        for signal in named {
            guard let link = try await enumTypeLink(ofDeclarationAt: signal.location, cache: cache),
                  let type = try await enumType(at: link, width: signal.width, cache: cache) else { continue }
            out[signal.name] = SlangEnumSignal(type: type, isArray: false)
            byTypeName[signal.typeName] = type
        }
        for array in arrays {
            // An element type a scalar here also has, else the type named in the declaration.
            let element = array.element.split(separator: ":").last.map(String.init) ?? array.element
            if let type = byTypeName[array.element] ?? byTypeName[element] {
                out[array.name] = SlangEnumSignal(type: type, isArray: true)
                continue
            }
            guard let link = try await enumTypeLink(ofTypeNamed: element, inDeclarationAt: array.location, cache: cache),
                  let width = link.width,
                  let type = try await enumType(at: link.link, width: width, cache: cache) else { continue }
            out[array.name] = SlangEnumSignal(type: type, isArray: true)
        }
        return out
    }

    private static func key(_ uri: URL, _ position: LSPPosition) -> String {
        "\(uri.absoluteString)#\(position.line),\(position.character)"
    }

    private func enumHover(_ uri: URL, _ position: LSPPosition) async throws -> String? {
        do {
            return try await hover(uri: uri, position: position)
        } catch LanguageServerError.responseError {
            return nil
        }
    }

    private func enumTypeLink(ofDeclarationAt location: LSPLocation, cache: SlangEnumTypeCache) async throws -> SlangEnumValues.TypeLink? {
        let key = Self.key(location.uri, location.range.start)
        if let cached = await cache.link(key) { return cached }
        let link = try await enumHover(location.uri, location.range.start).flatMap(SlangEnumValues.enumTypeLink(inHover:))
        await cache.setLink(link, key)
        return link
    }

    /// An array's element type: hovering its name where the declaration (quoted by the hover) writes it.
    private func enumTypeLink(
        ofTypeNamed typeName: String,
        inDeclarationAt location: LSPLocation,
        cache: SlangEnumTypeCache
    ) async throws -> (link: SlangEnumValues.TypeLink, width: Int?)? {
        guard let hover = try await enumHover(location.uri, location.range.start),
              let block = SlangEnumValues.firstCodeBlock(inHover: hover),
              let variable = hover.split(separator: "`", omittingEmptySubsequences: false).dropFirst().first.map(String.init),
              let variableAt = SlangEnumValues.offset(ofIdentifier: variable, in: block),
              let typeAt = SlangEnumValues.offset(ofIdentifier: typeName, in: block, before: variableAt),
              let position = SlangEnumValues.filePosition(ofBlockOffset: typeAt, in: block, anchorOffset: variableAt, anchor: location.range.start),
              let typeHover = try await enumHover(location.uri, position),
              let link = SlangEnumValues.enumTypeLink(inHover: typeHover) else { return nil }
        var width: Int?
        for line in typeHover.split(separator: "\n") where line.hasPrefix("Resolved Type: [`Enum ") {
            if let typeText = line.split(separator: "`").dropFirst().first,
               case .named(_, let found)? = SlangEnumValues.scopeType(String(typeText)) {
                width = found
                break
            }
        }
        return (link, width)
    }

    /// The enum whose name is at `link`, as an instance of width `width` has it.
    private func enumType(at link: SlangEnumValues.TypeLink, width: Int, cache: SlangEnumTypeCache) async throws -> SlangEnumType? {
        let key = Self.key(link.uri, link.position) + "/\(width)"
        if let cached = await cache.type(key) { return cached }
        let type = try await readEnumType(at: link, width: width)
        await cache.setType(type, key)
        return type
    }

    private func readEnumType(at link: SlangEnumValues.TypeLink, width: Int) async throws -> SlangEnumType? {
        guard let hover = try await enumHover(link.uri, link.position),
              let block = SlangEnumValues.firstCodeBlock(inHover: hover),
              let declared = SlangEnumValues.declaredMembers(in: block) else { return nil }
        // The type's name in the block: after the closing brace (typedef), else the `enum` keyword the link points at.
        let typeName = hover.split(separator: "`", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        let lastBrace = (block as NSString).range(of: "}", options: .backwards).location
        let anchorOffset: Int
        if !typeName.isEmpty, lastBrace != NSNotFound,
           let after = SlangEnumValues.offset(ofIdentifier: typeName, in: block), after > lastBrace {
            anchorOffset = after
        } else {
            guard let enumAt = SlangEnumValues.offset(ofIdentifier: "enum", in: block) else { return nil }
            anchorOffset = enumAt
        }
        var members: [SlangEnumMember] = []
        var scopeName: String?
        var previous: [Character]?
        for member in declared {
            var value: String?
            if member.range == nil,
               let position = SlangEnumValues.filePosition(ofBlockOffset: member.offset, in: block, anchorOffset: anchorOffset, anchor: link.position),
               let memberHover = try await enumHover(link.uri, position) {
                let values = SlangEnumValues.hoverMemberValues(memberHover).filter { $0.name == member.name }
                if let found = values.first(where: { SlangEnumValues.literalWidth($0.literal) == width }) {
                    value = SlangEnumValues.literalBits(found.literal, width: width)
                    scopeName = scopeName ?? found.scope
                }
            }
            if value == nil, let explicit = member.explicitValue {
                value = SlangEnumValues.literalBits(explicit, width: width)
                guard value != nil else { return nil }
            }
            var bits: [Character]
            if let value {
                bits = Array(value)
            } else if let previous {
                guard let next = SlangEnumValues.increment(previous) else { return nil }
                bits = next
            } else {
                bits = Array(repeating: "0", count: width)
            }
            if let range = member.range {
                let step = range.first <= range.last ? 1 : -1
                for index in stride(from: range.first, through: range.last, by: step) {
                    if index != range.first {
                        guard let next = SlangEnumValues.increment(bits) else { return nil }
                        bits = next
                    }
                    members.append(.init(name: member.name + String(index), bits: String(bits)))
                }
            } else {
                members.append(.init(name: member.name, bits: String(bits)))
            }
            previous = bits
            guard members.count <= SlangEnumValues.maxMembers else { return nil }
        }
        let name = scopeName ?? (typeName.isEmpty ? "enum" : typeName)
        return SlangEnumType(name: name, width: width, members: members)
    }
}

extension SlangEnumValues {
    /// The size of a sized literal (`3'b0` -> 3).
    static func literalWidth(_ literal: String) -> Int? {
        guard let tick = literal.firstIndex(of: "'") else { return nil }
        return Int(literal[..<tick])
    }

    /// `bits` plus one, nil on overflow.
    static func increment(_ bits: [Character]) -> [Character]? {
        var out = bits
        var index = out.count - 1
        while index >= 0 {
            if out[index] == "0" { out[index] = "1"; return out }
            out[index] = "0"
            index -= 1
        }
        return nil
    }
}
