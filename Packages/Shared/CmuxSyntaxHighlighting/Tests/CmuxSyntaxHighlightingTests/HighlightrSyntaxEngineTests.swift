@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("Highlightr syntax engine")
struct HighlightrSyntaxEngineTests {
    @Test("Policy rejection returns nil without coloring")
    func policyRejectionReturnsNil() async {
        let engine = HighlightrSyntaxEngine()
        let highlighted = await engine.highlight(
            text: #"{"a":1}"#,
            language: nil,
            theme: .light
        )
        #expect(highlighted == nil)
    }

#if canImport(AppKit)
    @Test("SQL containing Jinja delimiters still highlights SQL tokens")
    func sqlContainingJinjaDelimitersStillHighlightsTokens() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        select id, name
        from {{ ref('users') }}
        where active = true
        """

        let highlighted = try #require(
            await engine.highlight(text: source, language: "sql", theme: .dark)
        )
        let selectRange = (highlighted.value.string as NSString).range(of: "select")
        #expect(selectRange.location != NSNotFound)
        let color = highlighted.value.attribute(
            .foregroundColor,
            at: selectRange.location,
            effectiveRange: nil
        )
        #expect(
            HighlightColorRemapper(theme: .dark).hexKey(from: color as Any) == "0091FF"
        )
    }

    @Test("SystemVerilog keywords are colored by the bundled verilog grammar")
    func systemVerilogKeywordsAreColored() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        module top (input logic clk);
          always_ff @(posedge clk) begin end
        endmodule
        """
        let highlighted = try #require(
            await engine.highlight(text: source, language: "verilog", theme: .dark)
        )
        let text = highlighted.value.string as NSString
        let keyword = text.range(of: "module")
        let identifier = text.range(of: "top")
        let keywordColor = highlighted.value.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil)
        let identifierColor = highlighted.value.attribute(.foregroundColor, at: identifier.location, effectiveRange: nil)
        let remapper = HighlightColorRemapper(theme: .dark)
        #expect(keywordColor != nil)
        #expect(remapper.hexKey(from: keywordColor as Any) != remapper.hexKey(from: identifierColor as Any))
    }
#endif

}
