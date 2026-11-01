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
    var documentSymbols: [String: JSONValue] = [:]

    public init() {}

    public func removeAll() {
        types.removeAll()
        declarationLinks.removeAll()
        documentSymbols.removeAll()
    }

    func type(_ key: String) -> SlangEnumType?? { types[key] }
    func setType(_ type: SlangEnumType?, _ key: String) { types[key] = type }
    func link(_ key: String) -> SlangEnumValues.TypeLink?? { declarationLinks[key] }
    func setLink(_ link: SlangEnumValues.TypeLink?, _ key: String) { declarationLinks[key] = link }
    func symbols(_ key: String) -> JSONValue? { documentSymbols[key] }
    func setSymbols(_ symbols: JSONValue, _ key: String) { documentSymbols[key] = symbols }
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
    public static func fitted(_ bits: String, width: Int) -> String {
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

    // MARK: Document symbols

    /// An enum member as slang-server's documentSymbol lists it: its name and where it is declared.
    public struct SymbolMember: Sendable, Equatable {
        public var name: String
        public var position: LSPPosition
    }

    /// The members of the enum (symbol kind 10) whose range holds `position`, from a
    /// documentSymbol answer; nil when no enum there has members.
    static func enumMembers(inSymbols symbols: JSONValue, containing position: LSPPosition) -> [SymbolMember]? {
        var found: [SymbolMember]?
        visitEnums(symbols) { symbol, members in
            guard found == nil, let range = LSPResponseDecoding.range(symbol["range"]), contains(range, position) else { return }
            found = members
        }
        return found
    }

    /// The members of the enum named `name` (its own name, or the typedef's), from a documentSymbol answer.
    static func enumMembers(inSymbols symbols: JSONValue, named name: String) -> [SymbolMember]? {
        var found: [SymbolMember]?
        visitEnums(symbols) { symbol, members in
            if found == nil, symbol["name"]?.stringValue == name { found = members }
        }
        return found
    }

    private static func visitEnums(_ symbols: JSONValue, _ visit: (JSONValue, [SymbolMember]) -> Void) {
        for symbol in symbols.arrayValue ?? [] {
            if symbol["kind"]?.intValue == 10 {
                let members = (symbol["children"]?.arrayValue ?? []).compactMap { child -> SymbolMember? in
                    guard child["kind"]?.intValue == 22, let name = child["name"]?.stringValue,
                          let range = LSPResponseDecoding.range(child["selectionRange"] ?? child["range"]) else { return nil }
                    return SymbolMember(name: name, position: range.start)
                }
                if !members.isEmpty { visit(symbol, members) }
            }
            if let children = symbol["children"] { visitEnums(children, visit) }
        }
    }

    private static func contains(_ range: LSPRange, _ position: LSPPosition) -> Bool {
        let afterStart = position.line > range.start.line || (position.line == range.start.line && position.character >= range.start.character)
        let beforeEnd = position.line < range.end.line || (position.line == range.end.line && position.character <= range.end.character)
        return afterStart && beforeEnd
    }

    /// The size of a sized literal (`3'b0` -> 3).
    static func literalWidth(_ literal: String) -> Int? {
        guard let tick = literal.firstIndex(of: "'") else { return nil }
        return Int(literal[..<tick])
    }
}

extension LanguageServerSession {
    /// The signals of the design scope `hierPath` whose declared type is an enum (or an unpacked
    /// array of one), by name, with the members as this instance elaborates them. Everything is
    /// slang's: the type and width from getScope, the members from documentSymbol, each member's
    /// value from its hover (the section of this instance's width). A type a member of which has
    /// no value there (a range member, `A[2]`) is left out rather than guessed.
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
            let parts = array.element.components(separatedBy: "::")
            if let type = byTypeName[array.element] ?? byTypeName[parts.last ?? ""] {
                out[array.name] = SlangEnumSignal(type: type, isArray: true)
            } else if let type = try await enumType(named: array.element, declaredIn: array.location.uri, cache: cache) {
                out[array.name] = SlangEnumSignal(type: type, isArray: true)
            }
        }
        return out
    }

    /// documentSymbol of `uri` (raw).
    func slangDocumentSymbols(_ uri: URL, cache: SlangEnumTypeCache) async throws -> JSONValue {
        let key = uri.absoluteString
        if let cached = await cache.symbols(key) { return cached }
        let symbols = try await documentSymbols(uri: uri)
        await cache.setSymbols(symbols, key)
        return symbols
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

    /// The enum whose name is at `link`, as an instance of width `width` has it.
    private func enumType(at link: SlangEnumValues.TypeLink, width: Int, cache: SlangEnumTypeCache) async throws -> SlangEnumType? {
        let key = Self.key(link.uri, link.position) + "/\(width)"
        if let cached = await cache.type(key) { return cached }
        let symbols = try await slangDocumentSymbols(link.uri, cache: cache)
        var type: SlangEnumType?
        if let members = SlangEnumValues.enumMembers(inSymbols: symbols, containing: link.position) {
            type = try await enumType(members: members, uri: link.uri, width: width)
        }
        await cache.setType(type, key)
        return type
    }

    /// An array's element type, by name: in the declaring file, else in a package
    /// (`pkg::t`, or any package of the design for an imported `t`). Its width is the one its
    /// members' values have, when there is only one (not a parameterized type).
    private func enumType(named element: String, declaredIn uri: URL, cache: SlangEnumTypeCache) async throws -> SlangEnumType? {
        let parts = element.components(separatedBy: "::")
        let name = parts.last ?? element
        var files: [URL] = parts.count == 1 ? [uri] : []
        var packages = parts.count > 1 ? [parts[0]] : []
        if packages.isEmpty {
            packages = try await slangScopeChildren("").filter { $0.kind == "Package" }.map(\.name)
        }
        for package in packages.prefix(16) {
            for path in try await slangFilesContainingModule(package) {
                if let url = editorURL(forServerURI: URL(fileURLWithPath: path).absoluteString), !files.contains(url) { files.append(url) }
            }
        }
        for file in files {
            let symbols = try await slangDocumentSymbols(file, cache: cache)
            guard let members = SlangEnumValues.enumMembers(inSymbols: symbols, named: name), let first = members.first,
                  let hover = try await enumHover(file, first.position) else { continue }
            let widths = Set(SlangEnumValues.hoverMemberValues(hover).filter { $0.name == first.name }.compactMap { SlangEnumValues.literalWidth($0.literal) })
            guard widths.count == 1, let width = widths.first else { return nil }
            return try await enumType(members: members, uri: file, width: width)
        }
        return nil
    }

    /// Each member's value from its hover (the section of `width` bits); nil if one has none.
    private func enumType(members: [SlangEnumValues.SymbolMember], uri: URL, width: Int) async throws -> SlangEnumType? {
        guard members.count <= SlangEnumValues.maxMembers else { return nil }
        var out: [SlangEnumMember] = []
        var scopeName: String?
        for member in members {
            guard let hover = try await enumHover(uri, member.position) else { return nil }
            let sections = SlangEnumValues.hoverMemberValues(hover).filter { $0.name == member.name }
            // The section of this instance's width; slang prints a 1-bit value unsized (`0`):
            // then every instance must agree.
            var value = sections.first { SlangEnumValues.literalWidth($0.literal) == width }
            if value == nil, !sections.isEmpty, sections.allSatisfy({ SlangEnumValues.literalWidth($0.literal) == nil }),
               Set(sections.map(\.literal)).count == 1 {
                value = sections.first
            }
            guard let value, let bits = SlangEnumValues.literalBits(value.literal, width: width) else { return nil }
            scopeName = scopeName ?? value.scope
            out.append(.init(name: member.name, bits: bits))
        }
        guard let scopeName else { return nil }
        return SlangEnumType(name: scopeName, width: width, members: out)
    }
}
