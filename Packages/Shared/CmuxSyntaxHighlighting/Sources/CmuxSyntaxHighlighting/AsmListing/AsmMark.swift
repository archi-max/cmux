import Foundation

/// A breakpoint in an assembly listing, keyed by PC (written for cmux; design §6). It remembers its
/// instruction's symbol, offset and text so it can follow the code across a rebuild.
public struct AsmMark: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var listingPath: String
    public var pc: UInt64
    public var symbol: String?
    public var offset: UInt64
    public var encoding: UInt64?
    /// The instruction's text as the listing printed it, whitespace collapsed.
    public var text: String
    public var enabled: Bool
    public var condition: String?
    /// The commit channel it is pinned to (NRET > 1); nil: any.
    public var channel: Int?
    /// Neither its symbol+offset nor its PC is in the current listing (kept: it may come back).
    public var lost: Bool

    public init(id: UUID = UUID(), listingPath: String = "", pc: UInt64, symbol: String?, offset: UInt64, encoding: UInt64?,
                text: String, enabled: Bool = true, condition: String? = nil, channel: Int? = nil, lost: Bool = false) {
        self.id = id
        self.listingPath = listingPath
        self.pc = pc
        self.symbol = symbol
        self.offset = offset
        self.encoding = encoding
        self.text = text
        self.enabled = enabled
        self.condition = condition
        self.channel = channel
        self.lost = lost
    }

    public init(listing: AsmListing, instruction: AsmInstruction, listingPath: String = "") {
        _ = listing
        self.init(listingPath: listingPath, pc: instruction.pc, symbol: instruction.symbol, offset: instruction.offset,
                  encoding: instruction.encoding, text: Self.textKey(instruction.text))
    }

    private enum CodingKeys: String, CodingKey {
        case id, listingPath, pc, symbol, offset, encoding, text, enabled, condition, channel, lost
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        listingPath = try c.decodeIfPresent(String.self, forKey: .listingPath) ?? ""
        pc = try c.decode(UInt64.self, forKey: .pc)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        encoding = try c.decodeIfPresent(UInt64.self, forKey: .encoding)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel)
        lost = try c.decodeIfPresent(Bool.self, forKey: .lost) ?? false
    }

    /// How a mark was placed in a listing.
    public enum Placement: Sendable, Equatable {
        /// At its symbol+offset, whose instruction text is unchanged.
        case symbol
        /// In its symbol at another offset (code was added or removed before it in the function): the
        /// instruction with its text nearest its old offset, when exactly one is nearest. The UI says so.
        case moved
        /// At its PC (no symbol, or the symbol's instruction changed).
        case pc
        case lost
    }

    /// The mark placed in `listing`, and its line there. Design Q8: follow the code by symbol+offset when
    /// the instruction text still matches; then (cmux's refinement) the same text elsewhere in the symbol,
    /// nearest the old offset; else stay at the PC; else lost.
    public func resolved(in listing: AsmListing) -> (mark: AsmMark, line: Int?, how: Placement) {
        var mark = self
        if let symbol, let inst = listing.instruction(symbol: symbol, offset: offset), Self.textKey(inst.text) == text {
            mark.pc = inst.pc
            mark.encoding = inst.encoding
            mark.lost = false
            return (mark, inst.line, .symbol)
        }
        if let symbol, let inst = listing.nearestInstruction(symbol: symbol, offset: offset, textKey: text) {
            mark.pc = inst.pc
            mark.offset = inst.offset
            mark.encoding = inst.encoding
            mark.lost = false
            return (mark, inst.line, .moved)
        }
        if let inst = listing.instruction(forPC: pc) {
            mark.symbol = inst.symbol
            mark.offset = inst.offset
            mark.encoding = inst.encoding
            mark.text = Self.textKey(inst.text)
            mark.lost = false
            return (mark, inst.line, .pc)
        }
        mark.lost = true
        return (mark, nil, .lost)
    }

    /// An instruction's text without what moves with the code: absolute addresses before a `<sym+off>`
    /// (`80000008 <_start+0x8>`, llvm's `0x80000008 <…>`, a `# 80000068 <table>` comment) and the offset
    /// inside it, with its whitespace collapsed.
    public static func textKey(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == " " || c == "\t" {
                pendingSpace = !out.isEmpty
                i = text.index(after: i)
                continue
            }
            // An address token followed by spaces and `<`: dropped.
            if c.isHexDigit, out.isEmpty || pendingSpace || out.last == "," {
                var j = i
                if c == "0", text.index(after: j) < text.endIndex, text[text.index(after: j)] == "x" { j = text.index(j, offsetBy: 2) }
                var k = j
                while k < text.endIndex, text[k].isHexDigit, text[k].isASCII, !text[k].isUppercase { k = text.index(after: k) }
                var after = k
                while after < text.endIndex, text[after] == " " || text[after] == "\t" { after = text.index(after: after) }
                if k > j, after > k, after < text.endIndex, text[after] == "<" {
                    if pendingSpace { out.append(" ") }
                    pendingSpace = false
                    i = after
                    continue
                }
            }
            // A target's offset (`<_start+0x8>`) moves with the code too: only its symbol is kept.
            if c == "+" || c == "-", out.contains("<"), !out.hasSuffix(">") {
                var k = text.index(after: i)
                if k < text.endIndex, text[k] == "0", text.index(after: k) < text.endIndex, text[text.index(after: k)] == "x" {
                    k = text.index(k, offsetBy: 2)
                    let digits = k
                    while k < text.endIndex, text[k].isHexDigit { k = text.index(after: k) }
                    if k > digits, k < text.endIndex, text[k] == ">" {
                        pendingSpace = false
                        i = k
                        continue
                    }
                }
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }
}

/// How well a listing matches the instructions a dump committed (design §4: "this listing doesn't
/// match the dump").
public struct AsmListingMatch: Sendable, Equatable {
    /// Distinct committed PCs that are instructions of the listing with raw bytes.
    public var checked = 0
    public var matched = 0
    /// Distinct committed PCs the listing has no instruction at (another image, a boot ROM).
    public var notInListing = 0
    public var firstMismatch: (pc: UInt64, committed: UInt64, listing: UInt64)?

    public var agrees: Bool { checked > 0 && matched == checked }

    public static func == (a: Self, b: Self) -> Bool {
        a.checked == b.checked && a.matched == b.matched && a.notInListing == b.notInListing
            && a.firstMismatch?.pc == b.firstMismatch?.pc && a.firstMismatch?.committed == b.firstMismatch?.committed
            && a.firstMismatch?.listing == b.firstMismatch?.listing
    }
}

extension AsmListing {
    /// In `symbol`, the instruction whose text key is `textKey` nearest `offset` (code first). Nil on a
    /// tie (two as near, both code or both not): which one was meant is unknown, so none is guessed.
    func nearestInstruction(symbol: String, offset: UInt64, textKey: String) -> AsmInstruction? {
        var best: AsmInstruction?
        var tied = false
        for index in indicesBySymbol[symbol] ?? [] {
            let inst = instructions[Int(index)]
            guard AsmMark.textKey(inst.text) == textKey else { continue }
            let distance = inst.offset > offset ? inst.offset - offset : offset - inst.offset
            if let b = best {
                let bestDistance = b.offset > offset ? b.offset - offset : offset - b.offset
                if (inst.isCode && !b.isCode) || (inst.isCode == b.isCode && distance < bestDistance) {
                    best = inst
                    tied = false
                } else if inst.isCode == b.isCode && distance == bestDistance && inst.pc != b.pc {
                    tied = true
                }
            } else {
                best = inst
            }
        }
        return tied ? nil : best
    }

    /// Compares up to `limit` distinct committed PCs' instructions with the listing's encodings. A
    /// 16-bit (compressed) instruction is compared on its low 16 bits.
    public func match(committed: [(pc: UInt64, insn: UInt64)], limit: Int = 1000) -> AsmListingMatch {
        var result = AsmListingMatch()
        var seen = Set<UInt64>()
        for (pc, insn) in committed {
            guard seen.count < limit else { break }
            guard seen.insert(pc).inserted else { continue }
            guard let inst = instruction(forPC: pc) else { result.notInListing += 1; continue }
            guard let encoding = inst.encoding else { continue }
            result.checked += 1
            let mask: UInt64 = inst.size >= 8 ? .max : (UInt64(1) << UInt64(inst.size * 8)) - 1
            if insn & mask == encoding & mask {
                result.matched += 1
            } else if result.firstMismatch == nil {
                result.firstMismatch = (pc, insn, encoding)
            }
        }
        return result
    }
}
