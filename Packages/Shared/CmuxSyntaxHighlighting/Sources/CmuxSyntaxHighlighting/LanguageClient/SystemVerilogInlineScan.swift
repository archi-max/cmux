import Foundation

/// Finds, for the editor's inline waveform values, the identifiers on some lines
/// of a SystemVerilog file and the module each line belongs to. Comments,
/// strings, keywords, system tasks, macros, based numbers' digits and member
/// names after a dot are left out, and so is everything inside a function,
/// task, generate region or `for (genvar …)` loop: a name declared there is
/// not the module's signal of that name. The file is read from its start, so
/// a block comment or module opened above the lines is known.
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

    public static let keywords: Set<String> = [
        "always", "always_comb", "always_ff", "always_latch", "and", "assign", "automatic", "begin", "bit", "break",
        "byte", "case", "casex", "casez", "class", "const", "continue", "default", "do", "else", "end", "endcase",
        "endclass", "endfunction", "endgenerate", "endinterface", "endmodule", "endpackage", "endprogram", "endtask",
        "enum", "export", "extern", "final", "for", "foreach", "forever", "function", "generate", "genvar", "if",
        "import", "initial", "inout", "input", "int", "integer", "interface", "localparam", "logic", "longint",
        "modport", "module", "negedge", "not", "or", "output", "package", "packed", "parameter", "posedge",
        "priority", "program", "pure", "real", "reg", "repeat", "return", "shortint", "signed", "static", "struct",
        "task", "typedef", "union", "unique", "unique0", "unsigned", "var", "virtual", "void", "while", "wire", "xor",
    ]

    /// The lines of `text` that `range` (UTF-16) touches, in order.
    public static func lines(in text: String, range: NSRange) -> [Line] {
        let units = Array(text.utf16)
        let rangeStart = max(0, min(range.location, units.count))
        let rangeEnd = max(rangeStart, min(NSMaxRange(range), units.count))
        var scanner = Scanner(units: units)
        var lines: [Line] = []
        var index = 0
        while true {
            var lineEnd = index
            while lineEnd < units.count, units[lineEnd] != 0x0A { lineEnd += 1 }
            let touches = rangeStart == rangeEnd
                ? index <= rangeStart && rangeStart <= lineEnd
                : index < rangeEnd && lineEnd >= rangeStart
            let moduleBefore = scanner.module
            let identifiers = scanner.scanLine(from: index, to: lineEnd, collect: touches)
            if touches {
                var contentEnd = lineEnd
                if contentEnd > index, units[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                lines.append(Line(
                    contentRange: NSRange(location: index, length: contentEnd - index),
                    module: scanner.module ?? moduleBefore,
                    identifiers: identifiers
                ))
            }
            guard lineEnd < units.count, lineEnd + 1 < max(rangeEnd, rangeStart + 1) else { break }
            index = lineEnd + 1
        }
        return lines
    }

    private struct Scanner {
        let units: [UInt16]
        var module: String?
        var inBlockComment = false
        /// Function, task, generate and generate-loop nesting; identifiers count only at 0.
        var localDepth = 0
        /// For each open `begin`, whether it opened a generate loop's body.
        var beginStack: [Bool] = []
        var expectsModuleName = false
        var forHeaderDepth: Int?
        var pendingGenerateLoop = false
        /// In an import, export or extern declaration, up to its `;`.
        var inDeclarationPrototype = false
        var lastWords: [String] = []

        init(units: [UInt16]) {
            self.units = units
        }

        mutating func scanLine(from start: Int, to end: Int, collect: Bool) -> [Identifier] {
            var out: [Identifier] = []
            var index = start
            // The previous code unit, with comments and strings read as spaces.
            var previous: UInt16 = 0x20
            var inString = false
            while index < end {
                let unit = units[index]
                let next = index + 1 < end ? units[index + 1] : 0
                if inBlockComment {
                    if unit == 0x2A, next == 0x2F { inBlockComment = false; index += 2 } else { index += 1 } // */
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
                if unit == 0x2F, next == 0x2A { inBlockComment = true; index += 2; previous = 0x20; continue } // /*
                if unit == 0x22 { inString = true; index += 1; previous = 0x20; continue }
                if unit == 0x5C { // \escaped identifier, up to white space
                    while index < end, !Self.isSpace(units[index]) { index += 1 }
                    previous = 0x20
                    continue
                }
                if Self.isIdentifierStart(unit) {
                    var wordEnd = index + 1
                    while wordEnd < end, Self.isIdentifierPart(units[wordEnd]) { wordEnd += 1 }
                    let word = String(decoding: units[index..<wordEnd], as: UTF16.self)
                    let excluded = Self.isIdentifierPart(previous) || previous == 0x27 || previous == 0x60 || previous == 0x2E // ' ` .
                    if !excluded, let identifier = handleWord(word, at: index), collect {
                        out.append(identifier)
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
                    if let depth = forHeaderDepth { forHeaderDepth = depth + 1 }
                case 0x29: // )
                    if let depth = forHeaderDepth { forHeaderDepth = depth - 1 == 0 ? nil : depth - 1 }
                case 0x3B: // ;
                    if forHeaderDepth == nil { pendingGenerateLoop = false }
                    expectsModuleName = false
                    inDeclarationPrototype = false
                default:
                    break
                }
                if !Self.isSpace(unit) { previous = unit } else { previous = 0x20 }
                index += 1
            }
            return out
        }

        /// Handles a word; returns it when it is an identifier of the module.
        private mutating func handleWord(_ word: String, at offset: Int) -> Identifier? {
            defer { lastWords = Array((lastWords + [word]).suffix(2)) }
            if expectsModuleName {
                if word == "automatic" || word == "static" { return nil }
                expectsModuleName = false
                module = word
                return nil
            }
            switch word {
            case "module", "interface", "program":
                // `interface` also names an interface port's type inside a module; only a module-level one opens a module.
                if module == nil || word == "module" {
                    expectsModuleName = true
                    localDepth = 0
                    beginStack = []
                }
                return nil
            case "endmodule", "endinterface", "endprogram":
                module = nil
                localDepth = 0
                beginStack = []
                return nil
            case "import", "export", "extern":
                inDeclarationPrototype = true
                return nil
            case "function", "task":
                // DPI imports and extern or pure virtual prototypes have no body.
                if !lastWords.contains(where: { ["import", "export", "extern", "pure"].contains($0) }) {
                    localDepth += 1
                }
                return nil
            case "endfunction", "endtask", "endgenerate":
                localDepth = max(0, localDepth - 1)
                return nil
            case "generate":
                localDepth += 1
                return nil
            case "for":
                forHeaderDepth = 0
                return nil
            case "genvar":
                if forHeaderDepth != nil { pendingGenerateLoop = true }
                return nil
            case "begin":
                beginStack.append(pendingGenerateLoop)
                if pendingGenerateLoop { localDepth += 1 }
                pendingGenerateLoop = false
                return nil
            case "end":
                if beginStack.popLast() == true { localDepth = max(0, localDepth - 1) }
                return nil
            default:
                break
            }
            // A genvar loop's header names its genvar, not a signal.
            let inGenerateLoopHeader = pendingGenerateLoop && forHeaderDepth != nil
            guard module != nil, localDepth == 0, !inDeclarationPrototype, !inGenerateLoopHeader,
                  !SystemVerilogInlineScan.keywords.contains(word) else { return nil }
            return Identifier(name: word, offset: offset)
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
