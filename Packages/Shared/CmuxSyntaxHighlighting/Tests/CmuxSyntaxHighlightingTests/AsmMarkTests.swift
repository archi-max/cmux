import Foundation
import Testing
@testable import CmuxSyntaxHighlighting

/// Assembly-listing breakpoints (marks keyed by PC): following code across a rebuild, and checking a
/// listing against the instructions a dump committed.
@Suite("Assembly listing marks")
struct AsmMarkTests {
    static func parse(_ name: String) throws -> AsmListing {
        try AsmListingTests.parse(name)
    }

    static func mark(at pc: UInt64, in listing: AsmListing) throws -> AsmMark {
        let inst = try #require(listing.instruction(forPC: pc))
        return AsmMark(listing: listing, instruction: inst)
    }

    @Test func aMarkRemembersItsInstruction() throws {
        let rv32 = try Self.parse("gnu-rv32-code.dis")
        let mark = try Self.mark(at: 0x8000_005a, in: rv32)
        #expect(mark.pc == 0x8000_005a && mark.symbol == "sum" && mark.offset == 0xc)
        #expect(mark.text == "lw a3,0(a1)")
        #expect(mark.encoding == 0x4194)
        #expect(mark.enabled && !mark.lost)
    }

    @Test func textKeysIgnoreAddressesThatMoveWithTheCode() {
        #expect(AsmMark.textKey("bnez\tt0,80000008 <_start+0x8>") == "bnez t0,<_start>")
        #expect(AsmMark.textKey("addi\ta1,a1,26 # 80000068 <table>") == "addi a1,a1,26 # <table>")
        #expect(AsmMark.textKey("bnez\tt0, 0x80000008 <_start+0x8>") == "bnez t0, <_start>")
        #expect(AsmMark.textKey("lb\tzero,0(zero) # 0 <_start-0x80000000>") == "lb zero,0(zero) # <_start>")
        #expect(AsmMark.textKey("addi\ta0,a0,-1") == "addi a0,a0,-1")
        #expect(AsmMark.textKey("jal\t8000004e <sum>") == AsmMark.textKey("jal\t80000052 <sum>"))
        #expect(AsmMark.textKey("lw  a3,0(a1)") == "lw a3,0(a1)")
    }

    @Test func followsItsSymbolAcrossARebuild() throws {
        // rv64's `li sp` is two instructions, so everything after it moved; sum+0xc is still `lw a3,0(a1)`.
        let rv32 = try Self.parse("gnu-rv32-code.dis")
        let rv64 = try Self.parse("gnu-rv64-code.dis")
        let mark = try Self.mark(at: 0x8000_005a, in: rv32)
        let placed = mark.resolved(in: rv64)
        let expected = try #require(rv64.instruction(symbol: "sum", offset: 0xc))
        #expect(placed.mark.pc == expected.pc && placed.mark.pc != mark.pc)
        #expect(placed.line == expected.line)
        #expect(placed.how == .symbol)
        #expect(!placed.mark.lost)
        // A branch whose target address moved still matches (its `<sym+off>` did not).
        let bnez = try Self.mark(at: 0x8000_000c, in: rv32)
        let placedBnez = bnez.resolved(in: rv64)
        // It moved inside _start (+0xc to +0xe): found by its text, nearest its old offset.
        #expect(placedBnez.how == .moved && placedBnez.mark.symbol == "_start" && placedBnez.mark.offset == 0xe)
        #expect(rv64.instruction(forPC: placedBnez.mark.pc)?.text.hasPrefix("bnez") == true)
    }

    @Test func theNearestOfSeveralSameTextsWins() throws {
        // `li a0,0`-like twins: three `nop`s in f; a mark at f+8 whose code moved by 2 lands on the one at 0xa.
        let text = """
        Disassembly of section .text:

        00000000 <f>:
           0:\t0001                \tnop
           2:\t0001                \tnop
           4:\t4501                \tli\ta0,0
           6:\t4501                \tli\ta0,0
           8:\t4501                \tli\ta0,0
           a:\t0001                \tnop
           c:\t4501                \tli\ta0,0
        """
        let listing = AsmListingParser.parse(text)
        let mark = AsmMark(pc: 0x9, symbol: "f", offset: 0x9, encoding: 0x0001, text: "nop")
        let placed = mark.resolved(in: listing)
        #expect(placed.how == .moved && placed.mark.pc == 0xa)
    }

    @Test func fallsBackToItsPCThenIsLost() throws {
        let rv32 = try Self.parse("gnu-rv32-code.dis")
        var mark = try Self.mark(at: 0x8000_0004, in: rv32)
        // The symbol's instruction changed (another text there): the PC is kept when it is still an instruction.
        mark.text = "addi a0,a0,1"
        let byPC = mark.resolved(in: rv32)
        #expect(byPC.how == .pc && byPC.mark.pc == 0x8000_0004 && byPC.line == rv32.line(forPC: 0x8000_0004))
        // Neither its symbol nor its PC is in the listing any more: lost, but kept (it may come back).
        mark.symbol = "gone"
        mark.pc = 0x9000_0000
        let lost = mark.resolved(in: rv32)
        #expect(lost.how == .lost && lost.mark.lost && lost.line == nil && lost.mark.pc == 0x9000_0000)
        // ...and found again by a later listing that has it.
        var back = lost.mark
        back.pc = 0x8000_0004
        #expect(!back.resolved(in: rv32).mark.lost)
    }

    @Test func aMarkWithoutASymbolUsesItsPC() throws {
        let text = "Disassembly of section .text:\n\n   0:\t00000013          \tnop\n   4:\t00000013          \tnop\n"
        let listing = AsmListingParser.parse(text)
        let inst = try #require(listing.instruction(forPC: 4))
        let mark = AsmMark(listing: listing, instruction: inst)
        #expect(mark.symbol == nil)
        #expect(mark.resolved(in: listing).how == .pc)
    }

    @Test func marksSurviveTheSessionEncoding() throws {
        let rv32 = try Self.parse("gnu-rv32-code.dis")
        var mark = try Self.mark(at: 0x8000_0010, in: rv32)
        mark.condition = "$a0 == 0"
        mark.channel = 1
        let data = try JSONEncoder().encode(mark)
        #expect(try JSONDecoder().decode(AsmMark.self, from: data) == mark)
        // A mark from an older build without the optional fields.
        let older = try JSONDecoder().decode(AsmMark.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","listingPath":"/a.dis","pc":16,"offset":0,"text":"nop","enabled":true}"#.utf8))
        #expect(older.symbol == nil && older.condition == nil && !older.lost)
    }

    // MARK: listing vs dump

    @Test func matchRateComparesCommittedEncodings() throws {
        let rv32 = try Self.parse("gnu-rv32-code.dis")
        let good: [(pc: UInt64, insn: UInt64)] = [(0x8000_0000, 0x8000_4137), (0x8000_0004, 0x4501), (0x8000_005a, 0x4194)]
        let all = rv32.match(committed: good)
        #expect(all.checked == 3 && all.matched == 3 && all.firstMismatch == nil && all.notInListing == 0)
        // A 16-bit instruction is compared on its 16 bits (a core's insn may hold the next parcel above).
        let rvc = rv32.match(committed: [(0x8000_0004, 0x1234_4501)])
        #expect(rvc.matched == 1)
        let bad = rv32.match(committed: good + [(0x8000_0010, 0x0000_0013), (0x7000_0000, 0x13)])
        #expect(bad.checked == 4 && bad.matched == 3 && bad.notInListing == 1)
        #expect(bad.firstMismatch?.pc == 0x8000_0010 && bad.firstMismatch?.listing == 0x283d)
        #expect(!bad.agrees)
        #expect(all.agrees)
        // At most `limit` distinct PCs are checked.
        let many = (0..<5000).map { _ in (pc: UInt64(0x8000_0000), insn: UInt64(0x8000_4137)) }
        #expect(rv32.match(committed: many).checked == 1)
        let distinct = (0..<5000).map { (pc: UInt64($0), insn: UInt64(0)) }
        #expect(rv32.match(committed: distinct, limit: 1000).notInListing == 1000)
    }

    @Test func cp3ListingMatchesItsCommits() throws {
        guard let dir = ProcessInfo.processInfo.environment["ASM_LISTING_CP3_DIR"] else { return }
        let base = URL(fileURLWithPath: dir)
        let listing = AsmListingParser.parse(try String(contentsOf: base.appendingPathComponent("program.dis"), encoding: .utf8))
        let pairs = try String(contentsOf: base.appendingPathComponent("commit-pcs.txt"), encoding: .utf8)
            .split(separator: "\n").compactMap { line -> (pc: UInt64, insn: UInt64)? in
                let f = line.split(separator: " ")
                guard f.count == 2, let pc = UInt64(f[0].dropFirst(2), radix: 16), let insn = UInt64(f[1].dropFirst(3).dropLast(), radix: 16) else { return nil }
                return (pc, insn)
            }
        let result = listing.match(committed: pairs)
        #expect(result.checked == 1000 && result.matched == 1000 && result.agrees)
    }
}
