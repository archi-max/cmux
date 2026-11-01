import Foundation

/// A commit breakpoint's fields (cmux-debugger-commits.js): stop where the dump's commit stream commits
/// an instruction at one of `pcs` (kind `pc`, on `channel` when pinned), one whose text matches `pattern`
/// (`commitText`), or one that writes `loc` (`write`: `a0`, `csr:mtvec`, `mem:0x80001000/4`). Saved in the
/// session with its signal breakpoint (whose path is empty); every field is optional in the encoding.
struct WaveformDebuggerCommitBreakpoint: Codable, Equatable, Sendable {
    var pcs: [String]?
    var channel: Int?
    var pattern: String?
    var caseSensitive: Bool?
    var anyRegisterNames: Bool?
    var loc: String?

    static let kinds: Set<String> = ["pc", "commitText", "write"]
    /// The page's limits (cmux-debugger-commits.js MAX_PCS, cmux-textmatch.js MAX_PATTERN).
    static let maxAddresses = 64
    static let maxPatternLength = WaveformDebuggerTextBreakpoint.maxPatternLength

    init(pcs: [String]? = nil, channel: Int? = nil, pattern: String? = nil, caseSensitive: Bool? = nil,
         anyRegisterNames: Bool? = nil, loc: String? = nil) {
        self.pcs = pcs
        self.channel = channel
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.anyRegisterNames = anyRegisterNames
        self.loc = loc
    }

    private static func isAddress(_ text: String) -> Bool {
        let digits = text.hasPrefix("0x") ? text.dropFirst(2) : Substring(text)
        return !digits.isEmpty && digits.count <= 16 && digits.allSatisfy(\.isHexDigit)
    }

    private static func isLocation(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64, !text.contains(where: \.isWhitespace) else { return false }
        if text.hasPrefix("mem:") {
            let parts = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let size = Int(parts[1]), (1...64).contains(size) else { return false }
            return isAddress(String(parts[0]))
        }
        return true
    }

    /// From the page's `breakpoints` event; nil when it isn't one the page could have made.
    init?(pageItem item: [String: Any], kind: String) {
        switch kind {
        case "pc":
            guard let pcs = item["pcs"] as? [String], !pcs.isEmpty, pcs.count <= Self.maxAddresses, pcs.allSatisfy(Self.isAddress) else { return nil }
            self.init(pcs: pcs, channel: (item["channel"] as? Int).flatMap { $0 >= 0 ? $0 : nil })
        case "commitText":
            guard let pattern = item["pattern"] as? String, !pattern.isEmpty, pattern.count <= Self.maxPatternLength else { return nil }
            self.init(pattern: pattern, caseSensitive: item["caseSensitive"] as? Bool, anyRegisterNames: item["anyRegisterNames"] as? Bool)
        case "write":
            guard let loc = item["loc"] as? String, Self.isLocation(loc) else { return nil }
            self.init(loc: loc)
        default:
            return nil
        }
    }

    var pageFields: [String: Any] {
        var fields: [String: Any] = [:]
        if let pcs { fields["pcs"] = pcs }
        if let channel { fields["channel"] = channel }
        if let pattern { fields["pattern"] = pattern }
        if let caseSensitive { fields["caseSensitive"] = caseSensitive }
        if let anyRegisterNames { fields["anyRegisterNames"] = anyRegisterNames }
        if let loc { fields["loc"] = loc }
        return fields
    }

    /// Strings of the page's commit breakpoints (merged into WaveformDebugger's page strings).
    static func pageStrings() -> [String: String] {
        [
            "debuggerBreakAtAddress": String(localized: "waveformDebugger.commit.breakAtAddress", defaultValue: "Break at Address…"),
            "debuggerBreakOnCommitText": String(
                localized: "waveformDebugger.commit.breakOnText",
                defaultValue: "Break When Next Instruction Matches…"
            ),
            "debuggerBreakWhenWritten": String(localized: "waveformDebugger.commit.breakWhenWritten", defaultValue: "Break When Written…"),
            "debuggerAddressPrompt": String(
                localized: "waveformDebugger.commit.addressPrompt",
                defaultValue: "Break when an instruction at this address commits"
            ),
            "debuggerAddressPlaceholder": String(
                localized: "waveformDebugger.commit.addressPlaceholder",
                defaultValue: "A hex address, for example 0x80000010 (several: separate them with commas)"
            ),
            "debuggerCommitTextPrompt": String(
                localized: "waveformDebugger.commit.textPrompt",
                defaultValue: "Break when a committed instruction's text matches"
            ),
            "debuggerWrittenPrompt": String(
                localized: "waveformDebugger.commit.writtenPrompt",
                defaultValue: "Break when an instruction writes this register, CSR or memory"
            ),
            "debuggerWrittenPlaceholder": String(
                localized: "waveformDebugger.commit.writtenPlaceholder",
                defaultValue: "a0, x5, mstatus, [0x80001000] (a word) or [0x80001000]/1 (bytes)"
            ),
            "debuggerEditAddress": String(localized: "waveformDebugger.commit.editAddress", defaultValue: "Edit Address…"),
            "debuggerEditLocation": String(localized: "waveformDebugger.commit.editLocation", defaultValue: "Edit Location…"),
            "debuggerBreakpointPc": String(localized: "waveformDebugger.commit.pcLabel", defaultValue: "PC %@"),
            "debuggerBreakpointPcAt": String(localized: "waveformDebugger.commit.pcAtLabel", defaultValue: "%1$@ (%2$@)"),
            "debuggerBreakpointCommitText": String(localized: "waveformDebugger.commit.textLabel", defaultValue: "Next instruction ~ /%@/"),
            "debuggerBreakpointWritten": String(localized: "waveformDebugger.commit.writtenLabel", defaultValue: "%@ written"),
            "debuggerCommitError": String(localized: "waveformDebugger.commit.error", defaultValue: "Breakpoint %1$@: %2$@"),
            "debuggerCommitBadAddress": String(
                localized: "waveformDebugger.commit.badAddress",
                defaultValue: "an address is a hex number of up to 16 digits"
            ),
            "debuggerCommitBadLocation": String(
                localized: "waveformDebugger.commit.badLocation",
                defaultValue: "give a register (a0, x5), a CSR (mstatus) or memory ([0x80001000])"
            ),
            "debuggerCommitsNone": String(
                localized: "waveformDebugger.commit.noStream",
                defaultValue: "%@: this dump has no commit stream (RVFI or similar) to search"
            ),
            "debuggerCommitsNoInsn": String(
                localized: "waveformDebugger.commit.noInsn",
                defaultValue: "%@: the commit stream has no instruction word"
            ),
            "debuggerCommitTooMany": String(
                localized: "waveformDebugger.commit.tooMany",
                defaultValue: "At most %@ breakpoints of this kind can be enabled"
            ),
        ]
    }
}
