import Foundation

/// A text breakpoint's fields (Break When Text Matches…, cmux-debugger-text.js): stop where the
/// signal, shown in `format`, takes a value whose text matches `pattern`. Saved in the session with
/// its signal breakpoint; every field is optional in the encoding, so older sessions decode.
struct WaveformDebuggerTextBreakpoint: Codable, Equatable, Sendable {
    var format: String
    var pattern: String
    var caseSensitive: Bool?
    var anyRegisterNames: Bool?

    /// The page's limits (cmux-textmatch.js MAX_PATTERN, the format ids it accepts).
    static let maxPatternLength = 4096

    init(format: String, pattern: String, caseSensitive: Bool? = nil, anyRegisterNames: Bool? = nil) {
        self.format = format
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.anyRegisterNames = anyRegisterNames
    }

    /// From the page's `breakpoints` event; nil when it isn't a text breakpoint the page could have made.
    init?(pageItem item: [String: Any]) {
        guard let format = item["format"] as? String, !format.isEmpty, format.count <= 256,
              let pattern = item["pattern"] as? String, !pattern.isEmpty, pattern.count <= Self.maxPatternLength else { return nil }
        self.init(format: format, pattern: pattern, caseSensitive: item["caseSensitive"] as? Bool,
                  anyRegisterNames: item["anyRegisterNames"] as? Bool)
    }

    var pageFields: [String: Any] {
        var fields: [String: Any] = ["format": format, "pattern": pattern]
        if let caseSensitive { fields["caseSensitive"] = caseSensitive }
        if let anyRegisterNames { fields["anyRegisterNames"] = anyRegisterNames }
        return fields
    }

    /// Strings of the page's text breakpoints (merged into WaveformDebugger's page strings).
    static func pageStrings() -> [String: String] {
        [
            "debuggerBreakWhenTextMatches": String(localized: "waveformDebugger.text.breakWhenMatches", defaultValue: "Break When Text Matches…"),
            "debuggerTextPrompt": String(localized: "waveformDebugger.text.prompt", defaultValue: "Break when %1$@, shown as %2$@, matches"),
            "debuggerTextPlaceholder": String(
                localized: "waveformDebugger.text.placeholder",
                defaultValue: "A regular expression, for example jal ra or ^csrw mtvec"
            ),
            "debuggerBreakpointText": String(localized: "waveformDebugger.text.label", defaultValue: "%1$@ ~ /%2$@/ (%3$@)"),
            "debuggerTextError": String(localized: "waveformDebugger.text.error", defaultValue: "Text breakpoint %1$@: %2$@"),
            "debuggerTextBadFormat": String(localized: "waveformDebugger.text.badFormat", defaultValue: "this format cannot be searched as text"),
            "debuggerTextNoPattern": String(localized: "waveformDebugger.text.noPattern", defaultValue: "the pattern is empty"),
            "debuggerTextPatternTooLong": String(
                localized: "waveformDebugger.text.patternTooLong",
                defaultValue: "the pattern is longer than %@ characters"
            ),
            "debuggerTextNoAlias": String(localized: "waveformDebugger.text.noAlias", defaultValue: "its alias table is not loaded"),
            "debuggerTextTooSlow": String(
                localized: "waveformDebugger.text.tooSlow",
                defaultValue: "the pattern took too long to match, so the search stopped"
            ),
            "debuggerTextTooManyValues": String(
                localized: "waveformDebugger.text.tooManyValues",
                defaultValue: "the signal has too many different values to search here"
            ),
            "debuggerTextTooMany": String(
                localized: "waveformDebugger.text.tooMany",
                defaultValue: "At most %@ text breakpoints can be enabled at once."
            ),
            "debuggerEditTextPattern": String(localized: "waveformDebugger.text.editPattern", defaultValue: "Edit Pattern…"),
            "debuggerTextMatchCase": String(localized: "waveformDebugger.text.matchCase", defaultValue: "Match Case"),
            "debuggerTextAnyRegisterNames": String(
                localized: "waveformDebugger.text.anyRegisterNames",
                defaultValue: "Match Either Register Name (a0 or x10)"
            ),
            "debuggerTextFormatAlias": String(localized: "waveformDebugger.text.format.alias", defaultValue: "alias %@"),
            "debuggerTextFormat_riscv": String(localized: "waveformDebugger.text.format.riscv", defaultValue: "RISC-V"),
            "debuggerTextFormat_riscv_numeric": String(localized: "waveformDebugger.text.format.riscvNumeric", defaultValue: "RISC-V, x0–x31"),
            "debuggerTextFormat_riscv_noalias": String(
                localized: "waveformDebugger.text.format.riscvNoAlias",
                defaultValue: "RISC-V, no pseudo-instructions"
            ),
            "debuggerTextFormat_riscv_numeric_noalias": String(
                localized: "waveformDebugger.text.format.riscvNumericNoAlias",
                defaultValue: "RISC-V, x0–x31, no pseudo-instructions"
            ),
            "debuggerTextFormat_hexadecimal": String(localized: "waveformDebugger.text.format.hexadecimal", defaultValue: "hex"),
            "debuggerTextFormat_binary": String(localized: "waveformDebugger.text.format.binary", defaultValue: "binary"),
            "debuggerTextFormat_octal": String(localized: "waveformDebugger.text.format.octal", defaultValue: "octal"),
            "debuggerTextFormat_decimal": String(localized: "waveformDebugger.text.format.decimal", defaultValue: "decimal"),
            "debuggerTextFormat_signed": String(localized: "waveformDebugger.text.format.signed", defaultValue: "signed decimal"),
            "debuggerTextFormat_ascii": String(localized: "waveformDebugger.text.format.ascii", defaultValue: "ASCII"),
        ]
    }
}
