import Foundation

/// Finds the SystemVerilog `module` declaration a caret is on or inside, for
/// the editor's "Set as SystemVerilog Top Level". Comments, strings,
/// `` `define `` bodies, `extern module` prototypes and the second header of a
/// module split by `` `ifdef `` are skipped. Interfaces, programs and packages
/// are not modules and give nil. Nested modules give the innermost one.
public enum SystemVerilogModuleLocator {
    public struct Declaration: Equatable, Sendable {
        public var name: String
        /// UTF-16 offset of the `module` (or `macromodule`) keyword.
        public var keywordOffset: Int
        /// UTF-16 offset just past `endmodule`, or the text's end when the module is not closed.
        public var endOffset: Int

        public init(name: String, keywordOffset: Int, endOffset: Int) {
            self.name = name
            self.keywordOffset = keywordOffset
            self.endOffset = endOffset
        }
    }

    /// Every module declaration of `text`, outer before inner, in source order of their headers.
    public static func declarations(in text: String) -> [Declaration] {
        let units = Array(text.utf16)
        var open: [Declaration] = []
        var done: [Declaration] = []
        var pendingKeyword: Int?
        var inPrototype = false
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let next = index + 1 < count ? units[index + 1] : 0
            if unit == 0x2F, next == 0x2F { // // comment
                while index < count, units[index] != 0x0A { index += 1 }
                continue
            }
            if unit == 0x2F, next == 0x2A { // /* comment */
                index += 2
                while index < count, !(units[index] == 0x2A && index + 1 < count && units[index + 1] == 0x2F) { index += 1 }
                index = min(count, index + 2)
                continue
            }
            if unit == 0x28, next == 0x2A, index + 2 < count, units[index + 2] != 0x29 { // (* attribute *), not @(*)
                index += 2
                while index < count, !(units[index] == 0x2A && index + 1 < count && units[index + 1] == 0x29) { index += 1 }
                index = min(count, index + 2)
                continue
            }
            if unit == 0x22 { // "string"
                index += 1
                while index < count, units[index] != 0x22, units[index] != 0x0A {
                    index += units[index] == 0x5C ? 2 : 1
                }
                index += 1
                continue
            }
            if unit == 0x60 { // `directive
                let wordEnd = identifierEnd(units, from: index + 1)
                if String(decoding: units[(index + 1)..<wordEnd], as: UTF16.self) == "define" {
                    // The body runs to the end of the line, continued by trailing backslashes.
                    var lineEnd = wordEnd
                    while lineEnd < count {
                        if units[lineEnd] == 0x0A {
                            var back = lineEnd - 1
                            while back > wordEnd, units[back] == 0x0D || units[back] == 0x20 || units[back] == 0x09 { back -= 1 }
                            if units[back] != 0x5C { break }
                        }
                        lineEnd += 1
                    }
                    index = lineEnd
                } else {
                    index = wordEnd
                }
                continue
            }
            if unit == 0x5C { // \escaped identifier, up to white space
                let start = index
                while index < count, !isSpace(units[index]) { index += 1 }
                if let keyword = pendingKeyword {
                    pendingKeyword = nil
                    let name = String(decoding: units[(start + 1)..<index], as: UTF16.self)
                    openModule(name: name, keyword: keyword, open: &open)
                }
                continue
            }
            if isIdentifierStart(unit) {
                let wordEnd = identifierEnd(units, from: index)
                let previous = index > 0 ? units[index - 1] : 0x20
                if isIdentifierPart(previous) || previous == 0x27 || previous == 0x2E { // part of 8'hff or a.b
                    index = wordEnd
                    continue
                }
                let word = String(decoding: units[index..<wordEnd], as: UTF16.self)
                if let keyword = pendingKeyword {
                    if word == "automatic" || word == "static" {
                        index = wordEnd
                        continue
                    }
                    pendingKeyword = nil
                    openModule(name: word, keyword: keyword, open: &open)
                } else {
                    switch word {
                    case "module", "macromodule":
                        if inPrototype {
                            inPrototype = false
                        } else {
                            pendingKeyword = index
                        }
                    case "extern":
                        inPrototype = true
                    case "endmodule":
                        if var closed = open.popLast() {
                            closed.endOffset = wordEnd
                            done.append(closed)
                        }
                    default:
                        break
                    }
                }
                index = wordEnd
                continue
            }
            if unit == 0x3B { inPrototype = false }
            index += 1
        }
        done.append(contentsOf: open.map { Declaration(name: $0.name, keywordOffset: $0.keywordOffset, endOffset: count) })
        return done.sorted { $0.keywordOffset < $1.keywordOffset }
    }

    /// The innermost module declaration containing `offset` (UTF-16). A caret
    /// in the indentation before the `module` keyword counts as on it.
    public static func declaration(at offset: Int, in text: String) -> Declaration? {
        let units = Array(text.utf16)
        return declarations(in: text).last { declaration in
            var start = declaration.keywordOffset
            while start > 0, units[start - 1] == 0x20 || units[start - 1] == 0x09 { start -= 1 }
            return start <= offset && offset <= declaration.endOffset
        }
    }

    /// A header naming the module already open is the `` `else `` branch of the same declaration.
    private static func openModule(name: String, keyword: Int, open: inout [Declaration]) {
        guard !name.isEmpty, open.last?.name != name else { return }
        open.append(Declaration(name: name, keywordOffset: keyword, endOffset: keyword))
    }

    private static func identifierEnd(_ units: [UInt16], from start: Int) -> Int {
        var end = start
        while end < units.count, isIdentifierPart(units[end]) { end += 1 }
        return end
    }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }

    private static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (unit >= 0x30 && unit <= 0x39) || unit == 0x24
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C
    }
}
