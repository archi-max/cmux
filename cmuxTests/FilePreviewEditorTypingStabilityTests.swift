import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The SystemVerilog editor's automatic completion and the editor's viewport
/// across whole-buffer replacements.
@MainActor
@Suite("File preview editor typing stability", .serialized)
struct FilePreviewEditorTypingStabilityTests {
    // MARK: - Completion never types a candidate by itself

    /// AppKit's completion list calls `insertCompletion(isFinal: false)` for the
    /// highlighted candidate as soon as it opens, and a final call with
    /// "other" movement when the list closes because the user typed on. Both
    /// must leave the typed prefix alone.
    @Test("an automatic completion list does not change the buffer until a candidate is chosen")
    func completionListLeavesTypedTextAlone() {
        let textView = Self.completionTextView(text: "  fo\n")
        let prefix = NSRange(location: 2, length: 2)

        textView.insertCompletion("foo_bar", forPartialWordRange: prefix, movement: NSTextMovement.other.rawValue, isFinal: false)
        #expect(textView.string == "  fo\n")

        textView.insertCompletion("foo_baz", forPartialWordRange: prefix, movement: NSTextMovement.other.rawValue, isFinal: false)
        #expect(textView.string == "  fo\n")

        // Typing on (or the list closing by itself) ends the list with "other" movement.
        textView.insertCompletion("foo_baz", forPartialWordRange: prefix, movement: NSTextMovement.other.rawValue, isFinal: true)
        #expect(textView.string == "  fo\n")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("Escape on the completion list keeps the typed prefix")
    func completionCancelKeepsPrefix() {
        let textView = Self.completionTextView(text: "  fo\n")
        let prefix = NSRange(location: 2, length: 2)
        textView.insertCompletion("foo_bar", forPartialWordRange: prefix, movement: NSTextMovement.other.rawValue, isFinal: false)
        textView.insertCompletion("fo", forPartialWordRange: prefix, movement: NSTextMovement.cancel.rawValue, isFinal: true)
        #expect(textView.string == "  fo\n")
    }

    @Test("Return or Tab inserts the chosen candidate")
    func completionReturnAndTabInsert() {
        for movement in [NSTextMovement.return, .tab] {
            let textView = Self.completionTextView(text: "  fo\n")
            let prefix = NSRange(location: 2, length: 2)
            textView.insertCompletion("foo_bar", forPartialWordRange: prefix, movement: NSTextMovement.other.rawValue, isFinal: false)
            textView.insertCompletion("foo_bar", forPartialWordRange: prefix, movement: movement.rawValue, isFinal: true)
            #expect(textView.string == "  foo_bar\n")
            #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
        }
    }

    private static func completionTextView(text: String) -> SavingTextView {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        return textView
    }

    // MARK: - The viewport survives a whole-buffer replacement

    /// A reload replaces the whole buffer. With non-contiguous layout the
    /// heights of lines never laid out are estimates, so the clip view's old
    /// numeric origin points at other lines afterward; the shown lines must stay.
    @Test("a reload keeps the lines that were on screen")
    func reloadKeepsViewport() throws {
        let lines = (0..<3000).map { "  assign sig_\($0) = foo_\($0) & bar_\($0); // line \($0)" }
        let panel = TypingStabilityPanel(text: lines.joined(separator: "\n"))
        let host = NSHostingView(rootView: FilePreviewTextEditor(
            panel: panel,
            isVisibleInUI: true,
            themeBackgroundColor: .textBackgroundColor,
            themeForegroundColor: .textColor,
            drawsBackground: true,
            gutterBackgroundColor: .textBackgroundColor,
            wordWrap: false,
            filePath: "/tmp/typing-stability.txt"
        ))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // Never ordered in: nothing is shown on screen.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(Self.firstSubview(of: NSScrollView.self, in: host))
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.string == panel.textContent)

        let marker = "sig_1500 "
        let start = (textView.string as NSString).range(of: marker).location
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let before = Self.viewportY(of: marker, in: textView)

        // An external edit: one line added at the top and one at the end.
        panel.reload((["// header"] + lines + ["// footer"]).joined(separator: "\n"))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.displayIfNeeded()
        #expect(textView.string == panel.textContent)

        // The viewport keeps its top line number, so this line (one lower now) sits one line further down.
        let font = try #require(textView.font)
        let lineHeight = try #require(textView.layoutManager).defaultLineHeight(for: font)
        let after = Self.viewportY(of: marker, in: textView)
        #expect(abs(after - (before + lineHeight)) <= 1, "line moved from \(before) to \(after)")
    }

    /// The marker's line top, measured from the viewport top.
    private static func viewportY(of marker: String, in textView: NSTextView) -> CGFloat {
        let layoutManager = textView.layoutManager!
        let character = (textView.string as NSString).range(of: marker).location
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: character),
            effectiveRange: nil
        )
        let clipTop = textView.enclosingScrollView!.contentView.bounds.minY
        return fragment.minY + textView.textContainerOrigin.y - clipTop
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class TypingStabilityPanel: ObservableObject, FilePreviewTextEditingPanel {
    @Published private(set) var textContent: String
    private(set) var textContentRevision = 1

    init(text: String) {
        textContent = text
    }

    func reload(_ text: String) {
        textContent = text
        textContentRevision += 1
    }

    func attachTextView(_: NSTextView) {}
    func retryPendingFocus() {}
    func updateTextContent(_ nextContent: String) {
        guard nextContent != textContent else { return }
        textContent = nextContent
        textContentRevision += 1
    }

    func saveTextContent() -> Task<Void, Never>? { nil }
}
