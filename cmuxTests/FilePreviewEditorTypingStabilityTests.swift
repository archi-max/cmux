import AppKit
import CmuxSyntaxHighlighting
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

    /// The movements AppKit's list reports (seen under lldb with the real
    /// NSTextViewCompletionWindow): only a final Return or Tab chooses a
    /// candidate. A double-click on a row arrives as a final Return; a single
    /// click is non-final; a click anywhere else, scrolling or typing on ends
    /// the list with a final "other" or "right" call.
    @Test("only a final Return or Tab inserts a completion")
    func completionInsertionDecision() {
        let other = NSTextMovement.other.rawValue
        let returnKey = NSTextMovement.return.rawValue
        let tab = NSTextMovement.tab.rawValue
        let right = NSTextMovement.right.rawValue
        let cancel = NSTextMovement.cancel.rawValue
        let up = NSTextMovement.up.rawValue
        let down = NSTextMovement.down.rawValue
        for movement in [returnKey, tab] {
            #expect(SavingTextView.completionInsertionIsChosen(isFinal: true, movement: movement))
        }
        // Typing on (word character, `,`, space, `"`), Escape, a click outside the list, scroll, focus loss.
        for movement in [other, right, cancel] {
            #expect(!SavingTextView.completionInsertionIsChosen(isFinal: true, movement: movement))
        }
        // Opening, arrows and a single click on a row only highlight.
        for movement in [other, up, down, returnKey, tab] {
            #expect(!SavingTextView.completionInsertionIsChosen(isFinal: false, movement: movement))
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

    // MARK: - Restyling after a keystroke keeps the viewport still

    /// Every keystroke restyles the buffer. An attribute edit over the whole
    /// buffer re-lays out every line, and while non-contiguous layout re-estimates
    /// the heights AppKit re-anchors the clip view: in this 3000-line file it went
    /// about 1800 points (110 lines) up and back inside the one restyle call. In a
    /// file of a few hundred lines that is the top of the file.
    @Test("restyling after a keystroke does not move the viewport")
    func restyleAfterKeystrokeKeepsViewport() throws {
        let editor = Self.offscreenEditor(text: Self.systemVerilogText(lines: 3000))
        defer { editor.window.close() }
        let textView = editor.textView
        let clipView = editor.scrollView.contentView
        let styler = FilePreviewSyntaxStyler()
        styler.applyHighlightedText(Self.highlighted(textView.string), to: textView, defaultColor: .textColor)

        // The caret on a new line in the middle of the file, scrolled into view.
        let marker = (textView.string as NSString).range(of: "data_1503 <=").location
        try #require(marker != NSNotFound)
        textView.setSelectedRange(NSRange(location: marker, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        editor.settle()
        textView.insertText("$", replacementRange: textView.selectedRange())
        editor.settle()

        let before = clipView.bounds.minY
        let origins = ClipOriginLog(clipView: clipView)
        styler.applyHighlightedText(Self.highlighted(textView.string), to: textView, defaultColor: .textColor)
        editor.settle()
        origins.stop()

        let lineHeight = try #require(textView.layoutManager).defaultLineHeight(for: try #require(textView.font))
        let worst = origins.values.map { abs($0 - before) }.max() ?? 0
        #expect(worst <= lineHeight, "clip origin went \(origins.values) from \(before)")
        #expect(abs(clipView.bounds.minY - before) <= 1)
    }

    // MARK: - A restyle of every run (theme, font size) keeps the viewport

    /// A theme change (or the system light/dark switch) changes every run, so
    /// the restyle edits the whole buffer and AppKit's re-anchoring moved the
    /// clip view about 2700 points away and back inside the call. The line
    /// heights above the viewport are re-estimated, so the origin may end at a
    /// new number; it must go there in one move, keeping the same top line.
    @Test("a theme change does not move the viewport")
    func themeChangeKeepsViewport() throws {
        let editor = Self.offscreenEditor(text: Self.systemVerilogText(lines: 3000))
        defer { editor.window.close() }
        let textView = editor.textView
        let clipView = editor.scrollView.contentView
        let styler = FilePreviewSyntaxStyler()
        styler.applyHighlightedText(Self.highlighted(textView.string), to: textView, defaultColor: .textColor)
        let marker = (textView.string as NSString).range(of: "data_1503 <=").location
        try #require(marker != NSNotFound)
        textView.setSelectedRange(NSRange(location: marker, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        editor.settle()

        let before = clipView.bounds.minY
        let topBefore = Self.viewportY(of: "data_1503 <=", in: textView)
        let origins = ClipOriginLog(clipView: clipView)
        styler.applyHighlightedText(Self.highlighted(textView.string, otherTheme: true), to: textView, defaultColor: .textColor)
        editor.settle()
        origins.stop()

        let final = clipView.bounds.minY
        let strays = origins.values.filter { abs($0 - final) > 1 }
        #expect(strays.isEmpty, "clip origin went \(origins.values) from \(before) to \(final)")
        #expect(abs(Self.viewportY(of: "data_1503 <=", in: textView) - topBefore) <= 1)
        // The new theme was applied.
        let color = try #require(textView.textStorage?.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? NSColor)
        #expect(abs(color.redComponent - 0.1) < 0.01)
    }

    /// Zooming the font rewrites the font of every character; the character at
    /// the viewport top must stay there, and every zoom step must move the clip
    /// view once, straight to where it ends. Repeated zooms leave estimated
    /// lines above the viewport, and reading the anchor used to lay them out
    /// and let AppKit overshoot (9226 -> 10868 -> 9229 at 18 pt).
    @Test("zooming the font keeps the top line and moves the clip view once per step")
    func fontZoomKeepsTopLine() throws {
        let editor = Self.offscreenEditor(text: Self.systemVerilogText(lines: 3000))
        defer { editor.window.close() }
        let textView = editor.textView
        let scrollView = editor.scrollView
        let clipView = scrollView.contentView
        FilePreviewSyntaxStyler().applyHighlightedText(Self.highlighted(textView.string), to: textView, defaultColor: .textColor)
        let marker = "data_1503 <="
        let lineTop = Self.viewportY(of: marker, in: textView) + clipView.bounds.minY
        clipView.scroll(to: NSPoint(x: 0, y: lineTop))
        scrollView.reflectScrolledClipView(clipView)
        editor.settle()
        try #require(abs(Self.viewportY(of: marker, in: textView)) <= 1)

        for step in 1...4 {
            let origins = ClipOriginLog(clipView: clipView)
            #expect(textView.zoomPreviewFontIn())
            editor.settle()
            origins.stop()
            let final = clipView.bounds.minY

            let lineHeight = try #require(textView.layoutManager).defaultLineHeight(for: try #require(textView.font))
            #expect(abs(Self.viewportY(of: marker, in: textView)) <= lineHeight, "zoom step \(step)")
            let strays = origins.values.filter { abs($0 - final) > 1 }
            #expect(strays.isEmpty, "zoom step \(step): clip origin went \(origins.values), ending at \(final)")
        }
    }

    /// Word wrap captures an anchor on every live-resize tick; only reloads
    /// need the line number, so a character anchor must not count lines.
    @Test("a character anchor does not count lines")
    func characterAnchorSkipsLineNumber() throws {
        let editor = Self.offscreenEditor(text: Self.systemVerilogText(lines: 300))
        defer { editor.window.close() }
        let counted = try #require(FilePreviewViewportAnchor.capture(in: editor.textView))
        #expect(counted.line != nil)
        let uncounted = try #require(FilePreviewViewportAnchor.capture(in: editor.textView, countingLines: false))
        #expect(uncounted.line == nil)
        #expect(uncounted.character == counted.character)
    }

    // MARK: - Turning word wrap on or off keeps the top line

    /// Toggling wrap re-lays out every line, and the old numeric clip origin
    /// then points at other text: the wrapped document is much taller.
    @Test("toggling word wrap keeps the line at the viewport top")
    func wordWrapToggleKeepsTopLine() throws {
        // Lines long enough to wrap in an 800-point editor.
        let lines = (0..<2000).map { "  assign sig_\($0) = " + String(repeating: "foo_\($0) & ", count: 12) + "bar_\($0);" }
        let editor = Self.offscreenEditor(text: lines.joined(separator: "\n"))
        defer { editor.window.close() }
        let textView = editor.textView
        let scrollView = editor.scrollView

        let marker = "sig_1000 "
        let lineTop = Self.viewportY(of: marker, in: textView) + scrollView.contentView.bounds.minY
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: lineTop))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        editor.settle()
        #expect(abs(Self.viewportY(of: marker, in: textView)) <= 1)

        let lineHeight = try #require(textView.layoutManager).defaultLineHeight(for: try #require(textView.font))
        for wrap in [true, false] {
            textView.applyFilePreviewWordWrap(wrap, scrollView: scrollView)
            editor.settle()
            #expect(textView.textContainer?.widthTracksTextView == wrap)
            let y = Self.viewportY(of: marker, in: textView)
            #expect(abs(y) <= lineHeight, "wrap \(wrap): the top line moved to \(y)")
        }
    }

    private struct OffscreenEditor {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: SavingTextView

        func settle() {
            scrollView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
        }
    }

    /// The editor's text view in a scroll view, configured like `makeNSView`,
    /// in a window that is never ordered in.
    private static func offscreenEditor(text: String) -> OffscreenEditor {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = text
        scrollView.documentView = textView
        textView.applyFilePreviewWordWrap(false, scrollView: scrollView)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        let editor = OffscreenEditor(window: window, scrollView: scrollView, textView: textView)
        editor.settle()
        return editor
    }

    /// An adapter_tb.sv-like testbench.
    private static func systemVerilogText(lines count: Int) -> String {
        var lines = ["`timescale 1ns/1ps", "module adapter_tb;"]
        for index in 0..<count {
            switch index % 6 {
            case 0: lines.append("  logic [31:0] data_\(index);")
            case 1: lines.append("  always @(posedge clk) begin")
            case 2: lines.append("    if (valid_\(index)) $display(\"t=%0t data=%h\", $time, data_\(index));")
            case 3: lines.append("    data_\(index) <= data_\(index - 1) + 1;")
            case 4: lines.append("  end")
            default: lines.append("")
            }
        }
        lines.append("endmodule")
        return lines.joined(separator: "\n")
    }

    /// A highlighter result for `text`: bold blue keywords, red strings, on
    /// light-gray text; `otherTheme` changes the plain text color of every run.
    private static func highlighted(_ text: String, otherTheme: Bool = false) -> HighlightedText {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let plain = otherTheme ? 0.1 : 0.9
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: plain, green: plain, blue: plain, alpha: 1),
        ])
        let full = NSRange(location: 0, length: (text as NSString).length)
        let keywords = try! NSRegularExpression(pattern: #"\b(?:module|endmodule|logic|always|posedge|begin|end|if)\b"#)
        for match in keywords.matches(in: text, range: full) {
            result.setAttributes([.font: bold, .foregroundColor: NSColor(srgbRed: 0.2, green: 0.4, blue: otherTheme ? 0.5 : 1, alpha: 1)], range: match.range)
        }
        let strings = try! NSRegularExpression(pattern: #""[^"\n]*""#)
        for match in strings.matches(in: text, range: full) {
            result.setAttributes([.font: font, .foregroundColor: NSColor(srgbRed: otherTheme ? 0.5 : 1, green: 0.3, blue: 0.3, alpha: 1)], range: match.range)
        }
        return HighlightedText(result)
    }

    // MARK: - Line counting for the viewport anchor

    /// `lineNumber(at:)` and `offset(ofLine:)` agree with NSString's own
    /// line ranges for every line ending it knows.
    @Test("the viewport anchor counts lines like NSString.lineRange")
    func viewportAnchorLineCounting() {
        let samples = [
            "", "a", "a\n", "\n\n", "a\nb", "a\r\nb\r\n", "a\rb\r", "a\r\n\r\nb",
            "a\u{2028}b\u{2029}c\u{0085}d", "x\r", "\r\n",
            String(repeating: "line\r\n", count: 5000) + "tail",
            // A CR LF split across the scanner's 16K-character chunk boundary.
            String(repeating: "a", count: 16383) + "\r\nb",
        ]
        for sample in samples {
            let text = sample as NSString
            var starts = [0]
            var location = 0
            while location < text.length {
                let next = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                starts.append(next)
                location = next
            }
            // The end of an unterminated last line starts no line of its own.
            let lineStarts = text.length > 0 && starts.last == text.length && !Self.endsWithLineBreak(text)
                ? Array(starts.dropLast()) : starts
            // Expected line of every index: the line starts at or before it.
            // Long samples: the first indices, both sides of the first and last
            // line starts, and the end.
            var indexSet = Set<Int>(0...min(text.length, 200))
            indexSet.insert(text.length)
            let boundaryStarts: [Int] = Array(lineStarts.prefix(50)) + Array(lineStarts.suffix(50))
            for lineStart in boundaryStarts {
                for index in (lineStart - 2)...(lineStart + 1) where index >= 0 && index <= text.length {
                    indexSet.insert(index)
                }
            }
            let indices = indexSet.sorted()
            for index in indices {
                let expected = lineStarts.dropFirst().filter { $0 <= index }.count
                #expect(FilePreviewViewportAnchor.lineNumber(at: index, in: text) == expected,
                        "lineNumber(\(index)) in \(sample.debugDescription.prefix(40))")
            }
            // The start of every line, and past the last line its start.
            for line in 0..<(lineStarts.count + 2) {
                let expected = lineStarts[min(line, lineStarts.count - 1)]
                #expect(FilePreviewViewportAnchor.offset(ofLine: line, in: text) == expected,
                        "offset(ofLine: \(line)) in \(sample.debugDescription.prefix(40))")
            }
        }
        let long = String(repeating: "line\r\n", count: 5000) + "tail" as NSString
        #expect(FilePreviewViewportAnchor.lineNumber(at: long.length, in: long) == 5000)
        #expect(FilePreviewViewportAnchor.offset(ofLine: 4999, in: long) == 4999 * 6)
    }

    private static func endsWithLineBreak(_ text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        return [0x0A, 0x0D, 0x2028, 0x2029, 0x85].contains(text.character(at: text.length - 1))
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

/// Every clip-view origin from `init` until `stop()`.
@MainActor
private final class ClipOriginLog {
    private(set) var values: [CGFloat] = []
    private var observer: NSObjectProtocol?

    init(clipView: NSClipView) {
        clipView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self, weak clipView] _ in
            MainActor.assumeIsolated {
                guard let clipView else { return }
                self?.values.append(clipView.bounds.minY)
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
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
