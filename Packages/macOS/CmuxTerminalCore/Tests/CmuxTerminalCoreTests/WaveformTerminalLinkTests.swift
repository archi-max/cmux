import CmuxTerminalCore
import Foundation
import Testing

@Suite struct WaveformTerminalLinkTests {
    /// The link under the first character of `target` in `line`.
    private func link(
        _ line: String, at target: String, tops: [String] = ["top", "tb"], instancePaths: Bool = true
    ) -> WaveformTerminalLink? {
        let column = (line as NSString).range(of: target).location
        return WaveformTerminalLink.detect(in: line, column: column, topScopes: tops, instancePaths: instancePaths)
    }

    @Test func upstreamExamples() {
        #expect(link("UVM_INFO @ 50000: reporter", at: "50000") == .time(50000, units: nil))
        #expect(link("error at 1,250 ns in", at: "250") == .time(1250, units: "ns"))
        #expect(link("at 3.5us done", at: "3.5") == .time(3.5, units: "us"))
        #expect(link("at 12.5 μs done", at: "12.5") == .time(12.5, units: "us"))
        #expect(link("at 12.5 µs done", at: "µs") == .time(12.5, units: "us"))
        #expect(link("signal top.core.alu.acc[15:0] bad", at: "core") == .instancePath("top.core.alu.acc[15:0]"))
        #expect(link("signal top.a.b[3:0] bad", at: "a.b") == .instancePath("top.a.b[3:0]"))
        #expect(link("tb.dut.pc: mismatch", at: "dut") == .instancePath("tb.dut.pc"))
    }

    @Test func fileNamesAreNotInstancePaths() {
        #expect(link("Error: tb.sv:42: syntax error", at: "tb.sv") == nil)
        #expect(link("vlog rtl/top.sv rtl/top_pkg.sv", at: "top.sv") == nil)
        #expect(link("Compiling top.v", at: "top.v") == nil)
        #expect(link("/tmp/top.core.a", at: "core") == nil)
        #expect(link("~/top.core.a", at: "core") == nil)
        #expect(link("see xtop.core.a", at: "core") == nil)
        #expect(link("see foo.top.core.a", at: "core") == nil)
        #expect(link("open main.sv now", at: "main") == nil)
    }

    @Test func signalsNamedLikeExtensionsAndMultiDimIndexes() {
        #expect(link("mismatch on tb.dut.c now", at: "dut") == .instancePath("tb.dut.c"))
        #expect(link("check tb.u_fifo.do here", at: "u_fifo") == .instancePath("tb.u_fifo.do"))
        #expect(link("read tb.mem[3][2] =", at: "mem") == .instancePath("tb.mem[3][2]"))
        #expect(link("at tb.dut.pc.", at: "dut") == .instancePath("tb.dut.pc"))
        // Not a prefix of a longer word: the path runs on into `/x`.
        #expect(link("see top.core.alu/x", at: "core") == nil)
    }

    @Test func instancePathsFollowTheSettingAndTopScopes() {
        #expect(link("signal top.core.acc", at: "core", instancePaths: false) == nil)
        #expect(link("signal top.core.acc", at: "core", tops: ["dut"]) == nil)
        #expect(link("signal top.core.acc", at: "core", tops: []) == nil)
    }

    @Test func timesNeverStartInsideAWordOrFileName() {
        #expect(link("vcs -f files.f -o sim_100ns", at: "100ns") == nil)
        #expect(link("tests/test_10ms.py::test_ok PASSED", at: "10ms") == nil)
        #expect(link("run_5us.log", at: "5us") == nil)
        #expect(link("1. s", at: "1") == nil)
        #expect(link("took items", at: "items") == nil)
        #expect(link("a .s b", at: ".s") == nil)
    }

    @Test func nonFiniteTimesAreNotLinks() {
        let huge = String(repeating: "9", count: 400) + " ns"
        #expect(WaveformTerminalLink.detect(in: huge, column: 0, topScopes: [], instancePaths: false) == nil)
        // The scan window cuts the digit run; the cut piece is not a time.
        #expect(WaveformTerminalLink.detect(in: huge, column: 399, topScopes: [], instancePaths: false) == nil)
    }

    @Test func longLinesStayFast() {
        for filler in ["1", ".", ","] {
            let line = String(repeating: filler, count: 50_000)
            let start = Date()
            for column in [0, 25_000, 49_999] {
                _ = WaveformTerminalLink.detect(in: line, column: column, topScopes: ["top"], instancePaths: true)
            }
            // Quadratic scanning took about a minute here; linear is milliseconds,
            // so this bound holds in a debug build on a loaded CI machine.
            #expect(Date().timeIntervalSince(start) < 3)
        }
        let line = String(repeating: "top.a ", count: 10_000) + "@ 5"
        #expect(WaveformTerminalLink.detect(
            in: line, column: (line as NSString).length - 1, topScopes: ["top"], instancePaths: true
        ) == .time(5, units: nil))
    }

    @Test func columnsAreCharactersMappedToUTF16() {
        #expect(WaveformTerminalLink.utf16Offset(ofCharacter: 3, in: "é→x@") == 3)
        #expect(WaveformTerminalLink.utf16Offset(ofCharacter: 2, in: "😀a@") == 3)
        #expect(WaveformTerminalLink.utf16Offset(ofCharacter: 9, in: "abc") == 3)
    }
}
