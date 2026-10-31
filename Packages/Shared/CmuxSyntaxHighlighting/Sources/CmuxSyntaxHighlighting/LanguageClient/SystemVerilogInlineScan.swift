import Foundation

/// Finds, for the editor's inline waveform values, the identifiers on some lines
/// of a SystemVerilog file and the module each line belongs to. Comments,
/// strings, keywords, system tasks, macros, `` `define `` bodies, based
/// numbers' digits and member names after a dot are left out, and so is
/// everything in a scope of its own: functions, tasks, classes, covergroups,
/// property and sequence declarations, and generate regions (`generate`, and
/// the `for`, `if` and `case` blocks a module holds outside procedural code):
/// a name declared there is not the module's signal of that name. Nested
/// modules and `` `ifdef `` branches (two headers for one module) are followed.
///
/// The file is read from its start, so a block comment or module opened above
/// the lines is known. `Cache` keeps the reader's state every few hundred lines
/// and starts from the nearest one, so after the first read only the text from
/// there to the lines is read again.
public enum SystemVerilogInlineScan {
    public struct Identifier: Equatable, Sendable {
        public var name: String
        /// UTF-16 offset in the text.
        public var offset: Int

        public init(name: String, offset: Int) {
            self.name = name
            self.offset = offset
        }
    }

    public struct Line: Equatable, Sendable {
        /// The line without its line break.
        public var contentRange: NSRange
        /// The module (or interface, program) the line is in.
        public var module: String?
        public var identifiers: [Identifier]

        public init(contentRange: NSRange, module: String?, identifiers: [Identifier]) {
            self.contentRange = contentRange
            self.module = module
            self.identifiers = identifiers
        }
    }

    /// The UTF-16 code units of `string`, copied in one go.
    public static func units(of string: NSString) -> [UInt16] {
        var units = [UInt16](repeating: 0, count: string.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { string.getCharacters(base, range: NSRange(location: 0, length: string.length)) }
        }
        return units
    }

    /// The lines of `text` that `range` (UTF-16) touches, in order.
    public static func lines(in text: String, range: NSRange) -> [Line] {
        var cache = Cache(units: units(of: text as NSString))
        return cache.lines(in: range)
    }

    /// A file's text and the reader's state at checkpoints through it.
    public struct Cache: Sendable {
        public private(set) var units: [UInt16]
        private var checkpoints: [Checkpoint] = []
        /// Lines between checkpoints.
        static let checkpointLines = 256

        public init(units: [UInt16] = []) {
            self.units = units
        }

        /// The text changed from `location` on (UTF-16, in the old and new text alike).
        public mutating func replaceUnits(_ units: [UInt16], editedFrom location: Int) {
            self.units = units
            checkpoints.removeAll { $0.offset > location }
        }

        /// The lines that `range` touches, in order.
        public mutating func lines(in range: NSRange) -> [Line] {
            let count = units.count
            let rangeStart = max(0, min(range.location, count))
            let rangeEnd = max(rangeStart, min(NSMaxRange(range), count))
            let resume = checkpoints.last { $0.offset <= rangeStart }
            var reader = Reader(units: units, state: resume?.state ?? State())
            var index = resume?.offset ?? 0
            var linesSinceCheckpoint = 0
            var lines: [Line] = []
            while true {
                if linesSinceCheckpoint == Self.checkpointLines {
                    linesSinceCheckpoint = 0
                    if index > (checkpoints.last?.offset ?? -1) {
                        checkpoints.append(Checkpoint(offset: index, state: reader.state))
                    }
                }
                var lineEnd = index
                while lineEnd < count, units[lineEnd] != 0x0A { lineEnd += 1 }
                let touches = rangeStart == rangeEnd
                    ? index <= rangeStart && rangeStart <= lineEnd
                    : index < rangeEnd && lineEnd >= rangeStart
                let moduleBefore = reader.state.structure.modules.last
                let identifiers = reader.readLine(from: index, to: lineEnd, collect: touches)
                if touches {
                    var contentEnd = lineEnd
                    if contentEnd > index, units[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                    lines.append(Line(
                        contentRange: NSRange(location: index, length: contentEnd - index),
                        module: reader.state.structure.modules.last ?? moduleBefore,
                        identifiers: identifiers
                    ))
                }
                guard lineEnd < count, lineEnd + 1 < max(rangeEnd, rangeStart + 1) else { break }
                index = lineEnd + 1
                linesSinceCheckpoint += 1
            }
            return lines
        }
    }

    private struct Checkpoint: Sendable {
        var offset: Int
        var state: State
    }

    private enum Block: Sendable { case plain, generate, procedural }

    /// What `` `else `` puts back: the state at the matching `` `ifdef ``.
    private struct Structure: Sendable {
        var modules: [String] = []
        /// Local-scope nesting (functions, classes, generate regions); identifiers count only at 0.
        var localDepth = 0
        var blocks: [Block] = []
        var cases: [Block] = []
        /// Inside an always/initial/final block's begin…end (or procedural case).
        var proceduralDepth = 0
        /// After always/initial/final, until its statement's begin or `;`.
        var proceduralPending = false
        /// After a module-level for/if/else, until its begin or `;`.
        var generatePending = false
    }

    private struct State: Sendable {
        var structure = Structure()
        var directives: [Structure] = []
        var inBlockComment = false
        var inDefine = false
        var expectsModuleName = false
        var parenDepth = 0
        /// In an import, export, extern or pure declaration, up to its `;`.
        var inPrototype = false
        /// A procedural statement just ended with `;`; an `else` continues it.
        var proceduralMayContinue = false
        var lastKeyword: Keyword?
    }

    private enum Keyword: Sendable {
        case module, endmodule, scopeOpen, scopeClose, function, classKeyword, property
        case typedef, assertion, procedural, begin, end, forKeyword, ifKeyword, elseKeyword
        case caseKeyword, endcase, generate, prototype, other
    }

    private static let keywordKinds: [String: Keyword] = {
        var kinds: [String: Keyword] = [:]
        for word in [
            "and", "assign", "automatic", "bit", "break", "byte", "const", "continue", "default", "do", "enum",
            "forever", "foreach", "genvar", "inout", "input", "int", "integer", "localparam", "logic", "longint",
            "modport", "negedge", "not", "or", "output", "package", "endpackage", "packed", "parameter", "posedge",
            "priority", "real", "reg", "repeat", "return", "shortint", "signed", "static", "struct", "union", "unique",
            "unique0", "unsigned", "var", "virtual", "void", "wait", "while", "wire", "xor", "inside", "with",
            "tri", "supply0", "supply1", "wand", "wor", "string", "chandle", "event", "time", "realtime", "type",
            "clocking", "endclocking", "disable", "iff", "null", "this", "super", "new", "let",
        ] { kinds[word] = .other }
        for word in ["module", "macromodule", "interface", "program"] { kinds[word] = .module }
        for word in ["endmodule", "endinterface", "endprogram"] { kinds[word] = .endmodule }
        for word in ["covergroup", "checker"] { kinds[word] = .scopeOpen }
        for word in ["endfunction", "endtask", "endclass", "endgroup", "endproperty", "endsequence", "endchecker", "endgenerate"] {
            kinds[word] = .scopeClose
        }
        for word in ["function", "task"] { kinds[word] = .function }
        kinds["class"] = .classKeyword
        for word in ["property", "sequence"] { kinds[word] = .property }
        kinds["typedef"] = .typedef
        for word in ["assert", "assume", "cover", "restrict", "expect"] { kinds[word] = .assertion }
        for word in ["always", "always_comb", "always_ff", "always_latch", "initial", "final"] { kinds[word] = .procedural }
        for word in ["begin", "fork"] { kinds[word] = .begin }
        for word in ["end", "join", "join_any", "join_none"] { kinds[word] = .end }
        kinds["for"] = .forKeyword
        kinds["if"] = .ifKeyword
        kinds["else"] = .elseKeyword
        for word in ["case", "casex", "casez", "randcase"] { kinds[word] = .caseKeyword }
        kinds["endcase"] = .endcase
        kinds["generate"] = .generate
        for word in ["import", "export", "extern", "pure"] { kinds[word] = .prototype }
        return kinds
    }()

    /// Keywords by an FNV-1a hash of their UTF-16 units, so words are looked up without building a String.
    private static let keywordTable: [UInt64: [(units: [UInt16], kind: Keyword)]] = {
        var table: [UInt64: [(units: [UInt16], kind: Keyword)]] = [:]
        for (word, kind) in keywordKinds {
            let units = Array(word.utf16)
            table[hash(units[...]), default: []].append((units, kind))
        }
        return table
    }()

    /// All keywords, for callers that want the list.
    public static var keywords: Set<String> { Set(keywordKinds.keys) }

    private static let maxKeywordLength = 12

    private static func hash(_ units: ArraySlice<UInt16>) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for unit in units {
            value = (value ^ UInt64(unit)) &* 0x100000001b3
        }
        return value
    }

    private static func keyword(_ units: ArraySlice<UInt16>) -> Keyword? {
        guard units.count <= maxKeywordLength, let entries = keywordTable[hash(units)] else { return nil }
        return entries.first { $0.units.elementsEqual(units) }?.kind
    }

    private static let directiveIfdef: [[UInt16]] = ["ifdef", "ifndef"].map { Array($0.utf16) }
    private static let directiveElse: [[UInt16]] = ["else", "elsif"].map { Array($0.utf16) }
    private static let directiveEndif = Array("endif".utf16)
    private static let directiveDefine = Array("define".utf16)

    private struct Reader {
        let units: [UInt16]
        var state: State

        mutating func readLine(from start: Int, to end: Int, collect: Bool) -> [Identifier] {
            var out: [Identifier] = []
            if state.inDefine {
                // A `define body continues while its lines end with a backslash.
                state.inDefine = Self.endsWithBackslash(units, from: start, to: end)
                return out
            }
            var index = start
            // The previous code unit, with comments and strings read as spaces.
            var previous: UInt16 = 0x20
            var inString = false
            while index < end {
                let unit = units[index]
                let next = index + 1 < end ? units[index + 1] : 0
                if state.inBlockComment {
                    if unit == 0x2A, next == 0x2F { state.inBlockComment = false; index += 2 } else { index += 1 } // */
                    previous = 0x20
                    continue
                }
                if inString {
                    if unit == 0x5C { index += 2; continue }
                    if unit == 0x22 { inString = false }
                    index += 1
                    previous = 0x20
                    continue
                }
                if unit == 0x2F, next == 0x2F { break } // //
                if unit == 0x2F, next == 0x2A { state.inBlockComment = true; index += 2; previous = 0x20; continue } // /*
                if unit == 0x22 { inString = true; index += 1; previous = 0x20; continue }
                if unit == 0x5C { // \escaped identifier, up to white space
                    while index < end, !Self.isSpace(units[index]) { index += 1 }
                    previous = 0x20
                    continue
                }
                if unit == 0x60 { // `directive or `MACRO
                    var wordEnd = index + 1
                    while wordEnd < end, Self.isIdentifierPart(units[wordEnd]) { wordEnd += 1 }
                    let word = units[(index + 1)..<wordEnd]
                    if word.elementsEqual(directiveDefine) {
                        state.inDefine = Self.endsWithBackslash(units, from: start, to: end)
                        return out
                    }
                    directive(word)
                    previous = 0x20
                    index = wordEnd
                    continue
                }
                if Self.isIdentifierStart(unit) {
                    var wordEnd = index + 1
                    while wordEnd < end, Self.isIdentifierPart(units[wordEnd]) { wordEnd += 1 }
                    let excluded = Self.isIdentifierPart(previous) || previous == 0x27 || previous == 0x2E // ' .
                    if !excluded {
                        let kind = keyword(units[index..<wordEnd])
                        if let kind {
                            handle(kind, units[index..<wordEnd])
                        } else if let identifier = word(from: index, to: wordEnd, collect: collect) {
                            out.append(identifier)
                        }
                    }
                    previous = units[wordEnd - 1]
                    index = wordEnd
                    continue
                }
                if Self.isDigit(unit) {
                    // A number, with its base and digits (8'hff, 1_000).
                    var numberEnd = index + 1
                    while numberEnd < end, Self.isIdentifierPart(units[numberEnd]) || units[numberEnd] == 0x27 { numberEnd += 1 }
                    previous = 0x30
                    index = numberEnd
                    continue
                }
                switch unit {
                case 0x28: // (
                    state.parenDepth += 1
                case 0x29: // )
                    state.parenDepth = max(0, state.parenDepth - 1)
                case 0x3B: // ;
                    if state.parenDepth == 0 { statementEnded() }
                default:
                    break
                }
                previous = Self.isSpace(unit) ? 0x20 : unit
                index += 1
            }
            return out
        }

        private mutating func statementEnded() {
            if state.structure.proceduralPending {
                state.structure.proceduralPending = false
                state.proceduralMayContinue = true
            }
            state.structure.generatePending = false
            state.expectsModuleName = false
            state.inPrototype = false
        }

        private mutating func directive(_ word: ArraySlice<UInt16>) {
            if directiveIfdef.contains(where: { $0.elementsEqual(word) }) {
                state.directives.append(state.structure)
            } else if directiveElse.contains(where: { $0.elementsEqual(word) }) {
                if let saved = state.directives.last { state.structure = saved }
            } else if word.elementsEqual(directiveEndif) {
                _ = state.directives.popLast()
            }
        }

        /// A word that is no keyword: the module's name after `module`, else an identifier of the module.
        private mutating func word(from start: Int, to end: Int, collect: Bool) -> Identifier? {
            state.proceduralMayContinue = false
            state.lastKeyword = nil
            if state.expectsModuleName {
                state.expectsModuleName = false
                state.structure.modules.append(String(decoding: units[start..<end], as: UTF16.self))
                return nil
            }
            let structure = state.structure
            guard collect, !structure.modules.isEmpty, structure.localDepth == 0, !structure.generatePending,
                  !state.inPrototype else { return nil }
            return Identifier(name: String(decoding: units[start..<end], as: UTF16.self), offset: start)
        }

        private var atModuleLevel: Bool {
            state.structure.proceduralDepth == 0 && !state.structure.proceduralPending && state.structure.localDepth == 0
        }

        private mutating func handle(_ kind: Keyword, _ word: ArraySlice<UInt16>) {
            let last = state.lastKeyword
            let mayContinue = state.proceduralMayContinue
            state.proceduralMayContinue = false
            state.lastKeyword = kind
            switch kind {
            case .module:
                // `interface` and `program` also appear inside a module (interface ports); only open one at the top.
                let isModule = word.first == 0x6D // module, macromodule
                guard !state.inPrototype, isModule || state.structure.modules.isEmpty else { return }
                state.expectsModuleName = true
            case .endmodule:
                _ = state.structure.modules.popLast()
                if state.structure.modules.isEmpty { state.structure = Structure() }
            case .scopeOpen, .generate:
                state.structure.localDepth += 1
            case .scopeClose:
                state.structure.localDepth = max(0, state.structure.localDepth - 1)
            case .function:
                // DPI imports and extern or pure virtual prototypes have no body.
                if !state.inPrototype { state.structure.localDepth += 1 }
            case .classKeyword:
                // `typedef class c;` only declares the name.
                if last != .typedef, !state.inPrototype { state.structure.localDepth += 1 }
            case .property:
                // `assert property (…)` uses one; only a declaration has a body.
                if last != .assertion { state.structure.localDepth += 1 }
            case .procedural:
                if state.structure.proceduralDepth == 0 { state.structure.proceduralPending = true }
            case .begin:
                if state.structure.proceduralPending {
                    state.structure.proceduralPending = false
                    state.structure.proceduralDepth += 1
                    state.structure.blocks.append(.procedural)
                } else if state.structure.generatePending {
                    state.structure.generatePending = false
                    state.structure.localDepth += 1
                    state.structure.blocks.append(.generate)
                } else {
                    state.structure.blocks.append(.plain)
                }
            case .end:
                switch state.structure.blocks.popLast() {
                case .procedural?: state.structure.proceduralDepth = max(0, state.structure.proceduralDepth - 1)
                case .generate?: state.structure.localDepth = max(0, state.structure.localDepth - 1)
                default: break
                }
            case .forKeyword, .ifKeyword:
                if atModuleLevel { state.structure.generatePending = true }
            case .elseKeyword:
                if mayContinue {
                    // `always_comb if (a) x = 1; else …`: still the procedural statement.
                    state.structure.proceduralPending = true
                } else if atModuleLevel {
                    state.structure.generatePending = true
                }
            case .caseKeyword:
                if state.structure.proceduralPending || state.structure.proceduralDepth > 0 {
                    state.structure.proceduralDepth += 1
                    state.structure.cases.append(.procedural)
                } else if state.structure.localDepth == 0 {
                    state.structure.localDepth += 1
                    state.structure.cases.append(.generate)
                } else {
                    state.structure.cases.append(.plain)
                }
            case .endcase:
                switch state.structure.cases.popLast() {
                case .procedural?: state.structure.proceduralDepth = max(0, state.structure.proceduralDepth - 1)
                case .generate?: state.structure.localDepth = max(0, state.structure.localDepth - 1)
                default: break
                }
            case .prototype:
                state.inPrototype = true
            case .typedef, .assertion, .other:
                break
            }
        }

        static func endsWithBackslash(_ units: [UInt16], from start: Int, to end: Int) -> Bool {
            var index = end - 1
            while index >= start, isSpace(units[index]) { index -= 1 }
            return index >= start && units[index] == 0x5C
        }

        static func isIdentifierStart(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
        }

        static func isIdentifierPart(_ unit: UInt16) -> Bool {
            isIdentifierStart(unit) || isDigit(unit) || unit == 0x24
        }

        static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C }
    }
}

/// Back and forward stacks of jump origins, like an editor's Go Back / Go Forward.
public struct BackForwardHistory<Entry> {
    public enum Direction: Sendable { case back, forward }

    public private(set) var back: [Entry] = []
    public private(set) var forward: [Entry] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    /// A jump leaves `entry`: remember it (unless it repeats the last one) and drop what Go Forward could redo.
    public mutating func record(_ entry: Entry, isSame: (Entry, Entry) -> Bool) {
        if let last = back.last, isSame(last, entry) {
            // Already there.
        } else {
            back.append(entry)
        }
        back = Array(back.suffix(limit))
        forward = []
    }

    /// One step in `direction`: the nearest entry `isUsable` accepts (the ones it
    /// rejects are dropped), with `current` (where the step starts) put on the other stack.
    public mutating func step(_ direction: Direction, current: Entry?, isUsable: (Entry) -> Bool) -> Entry? {
        var from = direction == .back ? back : forward
        var to = direction == .back ? forward : back
        var found: Entry?
        while let entry = from.popLast() {
            if isUsable(entry) {
                found = entry
                break
            }
        }
        if found != nil, let current { to.append(current) }
        back = Array((direction == .back ? from : to).suffix(limit))
        forward = Array((direction == .back ? to : from).suffix(limit))
        return found
    }
}
