import Foundation

/// The waveform debugger's line breakpoints (cmux): a breakpoint on an RTL line hits when a signal
/// the line assigns changes. These are the textual parts: what a line watches, and how a
/// breakpoint stays on its line while the file is edited and finds it again by text on reopen.
public enum WaveformLineBreakpoint {
    /// The signals a breakpoint on `line` watches: the targets of its assignments (`x <=`, `x =`,
    /// `assign x =`, `{x, y} =`, `wire x = ...`), else every identifier it reads (`if (a && b)`,
    /// `case (state)`, a declaration), in order, each once.
    public static func watchedSignals(of line: SystemVerilogInlineScan.Line, in text: NSString) -> [String] {
        let content = text.substring(with: line.contentRange)
        let units = Array(content.utf16)
        var targets: [String] = []
        var read: [String] = []
        for identifier in line.identifiers {
            let column = identifier.offset - line.contentRange.location
            let length = identifier.name.utf16.count
            if !read.contains(identifier.name) { read.append(identifier.name) }
            let assigned = SystemVerilogAssignmentScanner.isAssignmentTarget(line: content, column: column, length: length)
                || isInitialized(units, after: column + length)
            if assigned, !targets.contains(identifier.name) { targets.append(identifier.name) }
        }
        return targets.isEmpty ? read : targets
    }

    /// A declaration's initializer follows the name: a single `=` (not `==`, `<=`, `=>`).
    private static func isInitialized(_ units: [UInt16], after end: Int) -> Bool {
        var index = end
        while index < units.count, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        guard index < units.count, units[index] == 0x3D else { return false }
        let next = index + 1 < units.count ? units[index + 1] : 0
        return next != 0x3D && next != 0x3E
    }

    /// Where a breakpoint whose line started at `offset` is after an edit: the start of the line
    /// its text is on now. `editedRange` is the edited range in the new text and `changeInLength`
    /// the edit's change in length (NSTextStorage's). A line deleted takes the line now there.
    public static func offset(_ offset: Int, afterEditing editedRange: NSRange, changeInLength: Int, in text: NSString) -> Int {
        let oldEnd = editedRange.location + editedRange.length - changeInLength
        var moved = offset
        if offset >= oldEnd {
            moved = offset + changeInLength
        } else if offset > editedRange.location {
            moved = editedRange.location
        }
        return lineStart(containing: moved, in: text)
    }

    /// The start of the line holding UTF-16 offset `offset` (clamped to the text).
    public static func lineStart(containing offset: Int, in text: NSString) -> Int {
        var index = max(0, min(offset, text.length))
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 { break }
            index -= 1
        }
        return index
    }

    /// A line's text as breakpoints compare it: trimmed, with each run of spaces and tabs as one space.
    public static func lineText(_ line: String) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// The line (0-based) whose text matches `lineText`, the nearest to `near` when several do; nil when none.
    public static func line(matching lineText: String, near: Int, in text: NSString) -> Int? {
        lines(matching: lineText, near: near, in: text).first
    }

    /// Every line (0-based) whose text matches `lineText`, nearest to `near` first (a tie: the earlier).
    public static func lines(matching lineText: String, near: Int, in text: NSString) -> [Int] {
        let wanted = self.lineText(lineText)
        guard !wanted.isEmpty else { return [] }
        var found: [Int] = []
        var number = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            if self.lineText(text.substring(with: range)) == wanted { found.append(number) }
            number += 1
        }
        return found.sorted { (abs($0 - near), $0) < (abs($1 - near), $1) }
    }
}
