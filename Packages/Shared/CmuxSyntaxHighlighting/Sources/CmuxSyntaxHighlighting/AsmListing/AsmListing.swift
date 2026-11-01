import Foundation

/// A source location objdump printed for the code below it (`-l`, or llvm-objdump's `; file:line`).
public struct AsmSourceRef: Sendable, Equatable, Hashable {
    public var file: String
    public var line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

/// Which objdump wrote a listing.
public enum AsmListingFlavor: Sendable, Equatable {
    case gnu
    case llvm
    case unknown
}

/// One instruction (or data unit, in `-D` listings) of an objdump listing.
public struct AsmInstruction: Sendable, Equatable {
    /// 0-based line in the listing's text.
    public var line: Int
    public var pc: UInt64
    /// Bytes. With `--no-show-raw-insn` it comes from the next address (0 when there is none).
    public var size: Int
    /// The raw bytes as a little-endian number; nil without raw bytes or past 64 bits.
    public var encoding: UInt64?
    /// Mnemonic and operands as printed, with objdump's `# …` tail.
    public var text: String
    /// The global symbol the instruction is in (`.L` local labels don't start one).
    public var symbol: String?
    public var offset: UInt64
    public var section: String?
    /// False for data sections disassembled by `-D`: they never win a reverse lookup over code.
    public var isCode: Bool
    /// A branch, call or address operand objdump resolved (`80000008 <_start+0x8>`).
    public var target: UInt64?
    public var targetSymbol: String?
    public var source: AsmSourceRef?
}

public struct AsmLabel: Sendable, Equatable {
    public var line: Int
    public var address: UInt64
    public var name: String
    public var section: String?
}

public struct AsmRelocation: Sendable, Equatable {
    public var line: Int
    public var pc: UInt64
    public var type: String
    public var data: String
}

public struct AsmSourceLocation: Sendable, Equatable {
    public var line: Int
    public var source: AsmSourceRef
}

/// A parsed objdump listing with its pc → line and line → pc tables. Built by `AsmListingParser`.
public struct AsmListing: Sendable {
    public internal(set) var fileFormat: String?
    public internal(set) var flavor: AsmListingFlavor = .unknown
    /// In line order.
    public internal(set) var instructions: [AsmInstruction] = []
    public internal(set) var labels: [AsmLabel] = []
    public internal(set) var relocations: [AsmRelocation] = []
    public internal(set) var sourceLocations: [AsmSourceLocation] = []
    /// Lines holding objdump's `...` (zeros left out).
    public internal(set) var elidedLines: [Int] = []
    public internal(set) var lineCount = 0
    /// More lines than the cap: the rest were not read.
    public internal(set) var truncated = false

    var indexByLine: [Int32] = []
    var indexByPC: [UInt64: Int32] = [:]
    var indicesBySymbol: [String: [Int32]] = [:]

    /// 32 or 64 from the file format (`elf32-littleriscv`), when the listing says.
    public var xlen: Int? {
        guard let format = fileFormat else { return nil }
        if format.hasPrefix("elf32") { return 32 }
        if format.hasPrefix("elf64") { return 64 }
        return nil
    }

    public func instruction(atLine line: Int) -> AsmInstruction? {
        guard line >= 0, line < indexByLine.count else { return nil }
        let index = indexByLine[line]
        return index < 0 ? nil : instructions[Int(index)]
    }

    public func pc(forLine line: Int) -> UInt64? {
        instruction(atLine: line)?.pc
    }

    /// The instruction at `pc`: code first, then the first in the listing.
    public func instruction(forPC pc: UInt64) -> AsmInstruction? {
        indexByPC[pc].map { instructions[Int($0)] }
    }

    public func line(forPC pc: UInt64) -> Int? {
        instruction(forPC: pc)?.line
    }

    /// The first instruction line at or after `line` (a click on a label snaps to its first instruction).
    public func instructionLine(atOrAfter line: Int) -> Int? {
        var lo = 0, hi = instructions.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if instructions[mid].line < line { lo = mid + 1 } else { hi = mid }
        }
        return lo < instructions.count ? instructions[lo].line : nil
    }

    /// The instruction at `symbol + offset` (code first), as a breakpoint follows its code across a rebuild.
    public func instruction(symbol: String, offset: UInt64) -> AsmInstruction? {
        guard let indices = indicesBySymbol[symbol] else { return nil }
        var found: AsmInstruction?
        for index in indices {
            let candidate = instructions[Int(index)]
            guard candidate.offset == offset else { continue }
            if candidate.isCode { return candidate }
            if found == nil { found = candidate }
        }
        return found
    }

    /// `symbol + offset` of a pc: its instruction's, else the nearest code label at or below it.
    public func symbolize(pc: UInt64) -> (symbol: String, offset: UInt64)? {
        if let inst = instruction(forPC: pc), let symbol = inst.symbol { return (symbol, inst.offset) }
        var best: AsmLabel?
        for label in labels where label.address <= pc && !label.name.hasPrefix(".L")
            && AsmListingParser.isCodeSection(label.section) {
            if best.map({ label.address > $0.address }) ?? true { best = label }
        }
        return best.map { ($0.name, pc - $0.address) }
    }

    mutating func buildTables() {
        indexByLine = [Int32](repeating: -1, count: lineCount)
        indexByPC.reserveCapacity(instructions.count)
        for (i, inst) in instructions.enumerated() {
            if inst.line < indexByLine.count { indexByLine[inst.line] = Int32(i) }
            if let existing = indexByPC[inst.pc] {
                if !instructions[Int(existing)].isCode && inst.isCode { indexByPC[inst.pc] = Int32(i) }
            } else {
                indexByPC[inst.pc] = Int32(i)
            }
            if let symbol = inst.symbol { indicesBySymbol[symbol, default: []].append(Int32(i)) }
        }
    }
}
