// A Swift port of Compiler Explorer's objdump-output parser (`processBinaryAsm` in
// lib/parsers/asm-parser.ts, https://github.com/compiler-explorer/compiler-explorer at
// 4341ea30ac71a06cd97bd31c3c7483e5a8802901), extended for cmux's assembly-listing breakpoints.
//
// Ported from CE: the line order of its loop (source-location records, function labels,
// instruction lines, relocation lines; its `func():` skip is implied, as such a line is never an
// instruction here), its patterns
//     lineRe        /^(?:; )?(?<file>(?:[A-Z]:[\\/]|\.?\/)[^:]+):(?<line>\d+).*/
//     labelRe       /^([\da-f]+)\s+<(.+)>:$/
//     asmOpcodeRe   /^\s*(?<address>[\da-f]+):\s*(?<opcodes>([\da-f]{2} ?)+)\s*(?<disasm>.*)/
//     relocationRe  /^\s*(?<address>[\da-f]+):\s*(?<relocname>(R_[\dA-Z_]+))\s*(?<relocdata>.*)/
//     destRe        /\s([\da-f]+)\s+<([^+>]+)(\+0x[\da-f]+)?>$/
// (here as byte scanners rather than regexes, for multi-million-line listings), and its rules
// that a label resets the current source location and that `.L` labels are local labels, not
// functions.
// cmux's additions (not in CE, which filters a listing for display and doesn't index it by
// address): section headers and data sections; the file format; `--no-show-raw-insn`,
// `--prefix-addresses` and `--visualize-jumps` lines; raw fields as little-endian numbers
// (GNU words and parcels, llvm bytes) and wrapped raw fields; `...` elisions; `0x` and `,`
// before a destination; guards that keep `-S` source text out; pc/line/symbol tables.
//
// Compiler Explorer's licence (BSD-2-Clause):
//
// Copyright (c) 2012-2022, Compiler Explorer Authors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

/// Parses GNU objdump and llvm-objdump disassembly into an `AsmListing`. Pure; run it off the main thread.
public enum AsmListingParser {
    public static let defaultMaxLines = 4_000_000

    public static func parse(_ text: String, maxLines: Int = defaultMaxLines) -> AsmListing {
        var copy = text
        return copy.withUTF8 { bytes in
            var state = State()
            var start = 0
            var lineIndex = 0
            while true {
                var end = start
                while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                if lineIndex >= maxLines {
                    state.listing.truncated = true
                    break
                }
                var lineEnd = end
                if lineEnd > start && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                state.handle(Line(bytes: bytes, start: start, end: lineEnd), index: lineIndex)
                lineIndex += 1
                if end >= bytes.count { break }
                start = end + 1
            }
            state.finish(lineCount: lineIndex)
            return state.listing
        }
    }

    /// Data sections `-D` disassembles too; anything else is taken as code.
    static func isCodeSection(_ name: String?) -> Bool {
        guard let name else { return true }
        if name.hasPrefix(".text") { return true }
        for data in dataSections {
            if name == data || name.hasPrefix(data + ".") || name.hasPrefix(data + "_") { return false }
        }
        return true
    }

    static let dataSections = [
        ".data", ".sdata", ".rodata", ".srodata", ".bss", ".sbss", ".tdata", ".tbss", ".comment", ".riscv.attributes",
        ".ARM.attributes", ".gnu.attributes", ".debug", ".zdebug", ".note", ".eh_frame", ".gcc_except_table", ".got",
        ".dynamic", ".dynsym", ".dynstr", ".symtab", ".strtab", ".shstrtab", ".init_array", ".fini_array",
        ".preinit_array", ".ctors", ".dtors", ".stab", ".tohost", ".fromhost", ".gnu.version", ".hash", ".gnu.hash",
        ".rela", ".rel", ".interp",
    ]

    // MARK: lines

    struct Line {
        let bytes: UnsafeBufferPointer<UInt8>
        let start: Int
        let end: Int

        var isEmpty: Bool { start >= end }
        subscript(_ i: Int) -> UInt8 { bytes[i] }

        func string(_ from: Int, _ to: Int) -> String {
            guard from < to else { return "" }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self)
        }

        func hasPrefix(_ prefix: StaticString, at position: Int) -> Bool {
            let count = prefix.utf8CodeUnitCount
            guard position + count <= end else { return false }
            return prefix.withUTF8Buffer { p in
                for k in 0..<count where bytes[position + k] != p[k] { return false }
                return true
            }
        }

        func skipSpace(_ from: Int) -> Int {
            var i = from
            while i < end, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            return i
        }

        /// The end of the run of lowercase hex digits at `from`.
        func hexEnd(_ from: Int) -> Int {
            var i = from
            while i < end, isHex(bytes[i]) { i += 1 }
            return i
        }

        func trimmedEnd(_ from: Int) -> Int {
            var e = end
            while e > from, bytes[e - 1] == 0x20 || bytes[e - 1] == 0x09 { e -= 1 }
            return e
        }
    }

    static func isHex(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) }

    static func hexValue(_ line: Line, _ from: Int, _ to: Int) -> UInt64? {
        guard from < to, to - from <= 16 else { return nil }
        var value: UInt64 = 0
        for i in from..<to {
            let b = line[i]
            value = value << 4 | UInt64(b <= 0x39 ? b - 0x30 : b - 0x61 + 10)
        }
        return value
    }

    /// A raw field: tokens of an even number of hex digits, one space apart, in memory order (GNU's
    /// RISC-V words and 16-bit parcels, llvm's bytes), ending at whitespace or the line's end.
    struct Raw {
        var digits = 0
        var value: UInt64? = 0
        var end = 0
    }

    static func raw(_ line: Line, _ from: Int) -> Raw? {
        var raw = Raw()
        var p = from
        while true {
            let q = line.hexEnd(p)
            let n = q - p
            guard n > 0, n % 2 == 0 else { return nil }
            if q < line.end, line[q] != 0x20, line[q] != 0x09 { return nil }
            if let token = hexValue(line, p, q), raw.digits + n <= 16, let value = raw.value {
                raw.value = value | token << UInt64(raw.digits * 4)
            } else {
                raw.value = nil
            }
            raw.digits += n
            raw.end = q
            if q + 1 < line.end, line[q] == 0x20, isHex(line[q + 1]) { p = q + 1; continue }
            return raw
        }
    }

    /// An instruction line's parts after its address (and, with `--prefix-addresses`, its `<sym+off>`).
    struct Parsed {
        var raw: Raw?
        var textStart = 0
        var textEnd = 0
        var sawTab = false
    }

    static func instructionParts(_ line: Line, after colon: Int) -> Parsed {
        var parsed = Parsed()
        var p = colon
        // Whitespace, then --visualize-jumps' arrows (`,->`, `|`, `'--`), all before the raw field.
        while p < line.end {
            let b = line[p]
            if b == 0x09 { parsed.sawTab = true }
            guard b == 0x20 || b == 0x09 || b == 0x2C || b == 0x27 || b == 0x7C || b == 0x2D || b == 0x2B || b == 0x3E else { break }
            p += 1
        }
        if let raw = raw(line, p) {
            parsed.raw = raw
            p = raw.end
            while p < line.end, line[p] == 0x20 || line[p] == 0x09 {
                if line[p] == 0x09 { parsed.sawTab = true }
                p += 1
            }
        }
        parsed.textStart = p
        parsed.textEnd = line.trimmedEnd(p)
        return parsed
    }

    // MARK: state

    struct State {
        var listing = AsmListing()
        var section: String?
        var sectionIsCode = true
        var symbol: String?
        var symbolAddress: UInt64 = 0
        var source: AsmSourceRef?
        var lastPCInSection: UInt64?

        mutating func handle(_ line: Line, index: Int) {
            if line.isEmpty { return }
            let first = line[line.start]

            if first == 0x44, line.hasPrefix("Disassembly of section ", at: line.start), line[line.end - 1] == 0x3A {
                section = line.string(line.start + 23, line.end - 1)
                sectionIsCode = AsmListingParser.isCodeSection(section)
                symbol = nil
                symbolAddress = 0
                source = nil
                lastPCInSection = nil
                return
            }
            if listing.fileFormat == nil, fileFormat(line) { return }
            if sourceLocation(line, index: index) { return }
            if label(line, index: index) { return }
            let p = line.skipSpace(line.start)
            if line.end - p == 3, line.hasPrefix("...", at: p) {
                listing.elidedLines.append(index)
                return
            }
            if relocation(line, index: index) { return }
            instruction(line, index: index)
        }

        /// `prog.elf:     file format elf32-littleriscv` (GNU: spaces; llvm: a tab).
        mutating func fileFormat(_ line: Line) -> Bool {
            var colon = line.start
            while colon < line.end, line[colon] != 0x3A { colon += 1 }
            guard colon < line.end else { return false }
            let p = line.skipSpace(colon + 1)
            guard p > colon + 1, line.hasPrefix("file format ", at: p) else { return false }
            listing.fileFormat = line.string(p + 12, line.trimmedEnd(p + 12))
            listing.flavor = line[colon + 1] == 0x09 ? .llvm : .gnu
            return true
        }

        /// CE's lineRe, kept stricter at the end: the record is all of the line but objdump's
        /// `(discriminator N)`, so a `-S` source line that holds `/x:12` stays source text.
        mutating func sourceLocation(_ line: Line, index: Int) -> Bool {
            var p = line.start
            if line.hasPrefix("; ", at: p) { p += 2 }
            let fileStart = p
            if p + 2 < line.end, line[p] >= 0x41, line[p] <= 0x5A, line[p + 1] == 0x3A, line[p + 2] == 0x2F || line[p + 2] == 0x5C {
                p += 3
            } else if line.hasPrefix("./", at: p) {
                p += 2
            } else if p < line.end, line[p] == 0x2F {
                p += 1
            } else {
                return false
            }
            while p < line.end, line[p] != 0x3A { p += 1 }
            guard p < line.end, p > fileStart else { return false }
            let colon = p
            var q = colon + 1
            while q < line.end, line[q] >= 0x30, line[q] <= 0x39 { q += 1 }
            guard q > colon + 1, let number = Int(line.string(colon + 1, q)) else { return false }
            guard q == line.end || line.hasPrefix(" (discriminator ", at: q) else { return false }
            let ref = AsmSourceRef(file: line.string(fileStart, colon), line: number)
            source = ref
            listing.sourceLocations.append(AsmSourceLocation(line: index, source: ref))
            return true
        }

        /// CE's labelRe: `80000000 <_start>:`.
        mutating func label(_ line: Line, index: Int) -> Bool {
            let hexEnd = line.hexEnd(line.start)
            guard hexEnd > line.start, hexEnd < line.end, line[hexEnd] == 0x20 || line[hexEnd] == 0x09 else { return false }
            let open = line.skipSpace(hexEnd)
            guard open < line.end, line[open] == 0x3C, line.end - open >= 4,
                  line[line.end - 1] == 0x3A, line[line.end - 2] == 0x3E,
                  let address = AsmListingParser.hexValue(line, line.start, hexEnd) else { return false }
            let name = line.string(open + 1, line.end - 2)
            listing.labels.append(AsmLabel(line: index, address: address, name: name, section: section))
            if !name.hasPrefix(".L") {
                symbol = name
                symbolAddress = address
                source = nil
            }
            return true
        }

        /// CE's relocationRe: `10: R_RISCV_CALL_PLT	sum` (llvm: `00000010:  R_…`).
        mutating func relocation(_ line: Line, index: Int) -> Bool {
            let a = line.skipSpace(line.start)
            let hexEnd = line.hexEnd(a)
            guard hexEnd > a, hexEnd < line.end, line[hexEnd] == 0x3A else { return false }
            let r = line.skipSpace(hexEnd + 1)
            guard line.hasPrefix("R_", at: r), let pc = AsmListingParser.hexValue(line, a, hexEnd) else { return false }
            var e = r + 2
            while e < line.end, (line[e] >= 0x30 && line[e] <= 0x39) || (line[e] >= 0x41 && line[e] <= 0x5A) || line[e] == 0x5F { e += 1 }
            let d = line.skipSpace(e)
            listing.relocations.append(AsmRelocation(line: index, pc: pc, type: line.string(r, e), data: line.string(d, line.trimmedEnd(d))))
            return true
        }

        /// CE's asmOpcodeRe, with the raw field optional (`--no-show-raw-insn`), plus
        /// `--prefix-addresses` lines (`80000004 <_start+0x4> li	a0,0`).
        mutating func instruction(_ line: Line, index: Int) {
            let a = line.skipSpace(line.start)
            let hexEnd = line.hexEnd(a)
            guard hexEnd > a, hexEnd < line.end, let pc = AsmListingParser.hexValue(line, a, hexEnd) else { return }
            var parsed: Parsed
            var lineSymbol: (name: String, offset: UInt64)?
            if line[hexEnd] == 0x3A {
                parsed = AsmListingParser.instructionParts(line, after: hexEnd + 1)
                if listing.flavor == .unknown { listing.flavor = line.hasPrefix(":\t", at: hexEnd) ? .gnu : .llvm }
            } else if a == line.start, line.hasPrefix(" <", at: hexEnd) {
                var close = hexEnd + 2
                while close < line.end, line[close] != 0x3E { close += 1 }
                guard close + 1 < line.end, line[close + 1] == 0x20 else { return }
                lineSymbol = Self.symbolAndOffset(line.string(hexEnd + 2, close))
                parsed = AsmListingParser.instructionParts(line, after: close + 1)
                parsed.sawTab = true
            } else {
                return
            }
            let hasText = parsed.textEnd > parsed.textStart
            // Bytes and no mnemonic: the rest of the previous instruction's bytes, wrapped.
            if !hasText, let raw = parsed.raw {
                if var last = listing.instructions.last, last.section == section, last.pc &+ UInt64(last.size) == pc {
                    if let value = last.encoding, let more = raw.value, last.size * 2 + raw.digits <= 16 {
                        last.encoding = value | more << UInt64(last.size * 8)
                    } else {
                        last.encoding = nil
                    }
                    last.size += raw.digits / 2
                    listing.instructions[listing.instructions.count - 1] = last
                    lastPCInSection = pc
                }
                return
            }
            // A mnemonic always follows a tab; objdump writes addresses in order within a section.
            // Both keep `-S` source text (`1:  j 1b`) out.
            guard hasText, parsed.sawTab else { return }
            if let lastPC = lastPCInSection, pc < lastPC { return }
            if lineSymbol == nil, symbol != nil, pc < symbolAddress { return }

            var inst = AsmInstruction(line: index, pc: pc, size: parsed.raw.map { $0.digits / 2 } ?? 0,
                                      encoding: parsed.raw?.value, text: line.string(parsed.textStart, parsed.textEnd),
                                      symbol: symbol, offset: symbol == nil ? 0 : pc &- symbolAddress, section: section,
                                      isCode: sectionIsCode, target: nil, targetSymbol: nil, source: source)
            if let lineSymbol {
                if lineSymbol.name.hasPrefix(".L"), symbol != nil {
                    inst.offset = pc &- symbolAddress
                } else {
                    symbol = lineSymbol.name
                    symbolAddress = pc &- lineSymbol.offset
                    inst.symbol = lineSymbol.name
                    inst.offset = lineSymbol.offset
                }
            }
            if let (target, name) = Self.destination(line, parsed.textStart, parsed.textEnd) {
                inst.target = target
                inst.targetSymbol = name
            }
            listing.instructions.append(inst)
            lastPCInSection = pc
        }

        /// `_start+0x4`, `sum`, `_start-0x80000000`.
        static func symbolAndOffset(_ text: String) -> (name: String, offset: UInt64) {
            if let plus = text.range(of: "+0x", options: .backwards), let offset = UInt64(text[plus.upperBound...], radix: 16) {
                return (String(text[..<plus.lowerBound]), offset)
            }
            return (text, 0)
        }

        /// CE's destRe, also after `,` (GNU's `bnez t0,80000008 <_start+0x8>`) and with llvm's `0x`.
        static func destination(_ line: Line, _ from: Int, _ to: Int) -> (UInt64, String)? {
            guard to - from >= 4, line[to - 1] == 0x3E else { return nil }
            var open = to - 2
            while open > from, line[open] != 0x3C { open -= 1 }
            guard line[open] == 0x3C, open - 1 > from, line[open - 1] == 0x20 else { return nil }
            var nameEnd = open + 1
            while nameEnd < to - 1, line[nameEnd] != 0x2B, line[nameEnd] != 0x3E {
                if line[nameEnd] == 0x2D, line.hasPrefix("-0x", at: nameEnd) { break }
                nameEnd += 1
            }
            guard nameEnd > open + 1 else { return nil }
            var hexEnd = open - 1
            while hexEnd > from, line[hexEnd - 1] == 0x20 { hexEnd -= 1 }
            var hexStart = hexEnd
            while hexStart > from, AsmListingParser.isHex(line[hexStart - 1]) { hexStart -= 1 }
            guard hexStart < hexEnd else { return nil }
            var before = hexStart
            if before - 2 >= from, line[before - 1] == 0x78, line[before - 2] == 0x30 {
                before -= 2
            }
            guard before > from, [UInt8(0x20), 0x09, 0x2C].contains(line[before - 1]),
                  let address = AsmListingParser.hexValue(line, hexStart, hexEnd) else { return nil }
            return (address, line.string(open + 1, nameEnd))
        }

        mutating func finish(lineCount: Int) {
            listing.lineCount = lineCount
            // Without raw bytes, a size is the distance to the next address in the section.
            let instructions = listing.instructions
            for i in instructions.indices where instructions[i].size == 0 && i + 1 < instructions.count {
                let next = instructions[i + 1]
                if next.section == instructions[i].section, next.pc > instructions[i].pc, next.pc - instructions[i].pc <= 8 {
                    listing.instructions[i].size = Int(next.pc - instructions[i].pc)
                }
            }
            listing.buildTables()
        }
    }
}

/// Whether a text is objdump output, by its content (a `.dis`, `.lst`, `.dump`, `.txt`, or a `.s` that is really
/// a listing): an objdump header or section line, or at least 8 instruction lines, in its first 200 lines.
public enum AsmListingDetector {
    public static func isListing(_ text: String) -> Bool {
        var head = Substring(text)
        var lines: [Substring] = []
        while lines.count < 200, !head.isEmpty {
            if let newline = head.firstIndex(of: "\n") {
                lines.append(head[..<newline])
                head = head[head.index(after: newline)...]
            } else {
                lines.append(head)
                head = ""
            }
        }
        let prefix = lines.joined(separator: "\n")
        for line in lines {
            if line.hasPrefix("Disassembly of section ") { return true }
            if line.range(of: #"^\S.*:\s+file format \S+\s*$"#, options: .regularExpression) != nil { return true }
        }
        let listing = AsmListingParser.parse(prefix)
        return listing.instructions.filter { $0.encoding != nil }.count >= 8
    }
}
