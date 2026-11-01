import AppKit
import CmuxFilePreviewCore
import CmuxSyntaxHighlighting

/// TextKit 1 line-number ruler. Draws only fragments that intersect the viewport.
///
/// Fills with the editor surface so numbers sit in the margin instead of on
/// AppKit's default contrasting ruler strip.
///
/// The line index is maintained incrementally from text-storage edit
/// notifications (`NSText.didProcessEditingNotification`) so typing never
/// rescans the whole buffer; a keystroke splices a few line-start offsets
/// instead of walking up to 16 MB of text on the main actor.
final class FilePreviewLineNumberGutterView: NSRulerView {
    var tokenTheme: TokenTheme = .dark {
        didSet { needsDisplay = true }
    }
    var editorBackgroundColor: NSColor = .clear {
        didSet { applySurfaceFill() }
    }
    var drawsEditorBackground = true {
        didSet { applySurfaceFill() }
    }
    private static let horizontalPadding: CGFloat = 10

    /// A breakpoint dot in the gutter (cmux's waveform debugger).
    enum BreakpointMark { case enabled, conditional, disabled, lost }
    /// Dots by line start offset; nil for a text view that takes no breakpoints (no dot column).
    static var breakpointMarks: (@MainActor (NSTextView) -> [Int: BreakpointMark]?)? = {
        WaveformDebuggerLineBreakpoints.styles(in: $0) ?? WaveformDebuggerAsmBreakpoints.styles(in: $0)
    }
    /// A click on the line starting at the offset; true when it was taken.
    static var breakpointClicked: (@MainActor (NSTextView, Int) -> Bool)? = {
        WaveformDebuggerLineBreakpoints.gutterClicked($0, lineStart: $1) || WaveformDebuggerAsmBreakpoints.gutterClicked($0, lineStart: $1)
    }
    /// The menu for a right-click on the line starting at the offset.
    static var breakpointMenu: (@MainActor (NSTextView, Int) -> NSMenu?)? = {
        WaveformDebuggerLineBreakpoints.gutterMenu($0, lineStart: $1) ?? WaveformDebuggerAsmBreakpoints.gutterMenu($0, lineStart: $1)
    }
    /// The line start of the current instruction (an arrow), in an assembly listing.
    static var currentInstruction: (@MainActor (NSTextView) -> Int?)? = { WaveformDebuggerAsmBreakpoints.currentLineStart(in: $0) }
    private static let breakpointColumn: CGFloat = 12

    private var lineIndex = FilePreviewLineIndex(string: "")
    /// Set when edits were skipped (ruler hidden) and the index must be
    /// rebuilt before its next use.
    private var needsFullRebuild = true
    private var observedStorage: NSTextStorage?
    private var storageObserver: (any NSObjectProtocol)?

    override var isOpaque: Bool {
        drawsEditorBackground && editorBackgroundColor.alphaComponent >= 0.999
    }

    override var wantsUpdateLayer: Bool { false }

    override var clientView: NSView? {
        didSet { observeStorage(of: clientView) }
    }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 36
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        wantsLayer = true
        applySurfaceFill()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    /// Reconciles the index against `string`.
    ///
    /// While storage observation is live, per-edit increments keep the index
    /// exact and this is a no-op scan; a full rebuild happens only after
    /// skipped edits (ruler hidden) or on first attach.
    func reloadLineIndex(from string: String, textFont: NSFont?) {
        if needsFullRebuild || observedStorage == nil {
            lineIndex = FilePreviewLineIndex(string: string)
            needsFullRebuild = false
        }
        updateRuleThickness(for: textFont)
        needsDisplay = true
    }

    /// Subscribes to the client text view's storage edits.
    private func observeStorage(of view: NSView?) {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        storageObserver = nil
        observedStorage = nil
        guard let textView = view as? NSTextView,
              let storage = textView.textStorage else {
            needsFullRebuild = true
            return
        }
        observedStorage = storage
        if scrollView?.rulersVisible == true {
            lineIndex = FilePreviewLineIndex(string: textView.string)
            needsFullRebuild = false
        } else {
            // Keep the index lazy while line numbers are disabled. A large
            // hidden preview should not allocate line metadata it cannot draw.
            needsFullRebuild = true
        }
        updateRuleThickness(for: textView.font)
        // `queue: nil` delivers synchronously on the posting (main) thread, so
        // the index is exact before the next layout/draw pass reads it.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyStorageEdit(from: notification)
            }
        }
    }

    /// Applies one storage edit to the index. Skips maintenance while the
    /// ruler is hidden (the index is unread then) and flags a rebuild for the
    /// next time it becomes visible.
    private func applyStorageEdit(from notification: Notification) {
        guard scrollView?.rulersVisible == true else {
            needsFullRebuild = true
            return
        }
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let range = storage.editedRange
        let replacement = (storage.string as NSString).substring(with: range)
        lineIndex.applyEdit(
            atUTF16Location: range.location,
            replacingUTF16Length: range.length - storage.changeInLength,
            replacement: replacement
        )
        updateRuleThickness(for: (clientView as? NSTextView)?.font)
        needsDisplay = true
    }

    private func updateRuleThickness(for textFont: NSFont?) {
        let font = labelFont(for: textFont)
        let digits = max(2, String(lineIndex.lineCount).count)
        let labelWidth = (String(repeating: "8", count: digits) as NSString).size(
            withAttributes: [.font: font]
        ).width
        let takesBreakpoints = (clientView as? NSTextView).flatMap { Self.breakpointMarks?($0) } != nil
        let nextThickness = ceil(labelWidth) + Self.horizontalPadding + (takesBreakpoints ? Self.breakpointColumn : 0)
        if abs(ruleThickness - nextThickness) > 0.5 {
            ruleThickness = nextThickness
        }
    }

    private func labelFont(for textFont: NSFont?) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (textFont?.pointSize ?? 13) * 0.78),
            weight: .regular
        )
    }

    private func applySurfaceFill() {
        wantsLayer = true
        layer?.backgroundColor = drawsEditorBackground
            ? editorBackgroundColor.cgColor
            : NSColor.clear.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Do not call super — NSRulerView paints a system control strip
        // that reads as a second background next to the editor.
        if drawsEditorBackground {
            editorBackgroundColor.setFill()
            bounds.fill()
        } else {
            NSColor.clear.setFill()
            bounds.fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphQueryRect = visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: glyphQueryRect, in: textContainer)
        let font = labelFont(for: textView.font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let selected = textView.selectedRange()
        let currentLine = selected.length == 0
            ? lineIndex.lineNumber(containingUTF16Offset: selected.location)
            : nil
        let lineCount = lineIndex.lineCount
        var drewTrailingLine = false
        let breakpoints = Self.breakpointMarks?(textView) ?? [:]
        let arrowAt = Self.currentInstruction?(textView)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let lineNumber = self.lineIndex.lineNumber(
                containingUTF16Offset: characterRange.location
            )
            guard self.lineIndex.offset(forLine: lineNumber) == characterRange.location else {
                return
            }
            if let mark = breakpoints[characterRange.location] {
                self.drawBreakpoint(mark, atTextViewY: usedRect.minY + textView.textContainerOrigin.y, height: usedRect.height, in: textView)
            }
            if characterRange.location == arrowAt {
                self.drawCurrentInstruction(atTextViewY: usedRect.minY + textView.textContainerOrigin.y, height: usedRect.height, in: textView)
            }
            self.drawLineNumber(
                lineNumber,
                atTextViewY: usedRect.minY + textView.textContainerOrigin.y,
                height: usedRect.height,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
            drewTrailingLine = drewTrailingLine || lineNumber == lineCount
        }

        let string = textView.string as NSString
        if layoutManager.numberOfGlyphs == 0, string.length == 0 {
            // An empty document has a valid logical line but no glyph fragment
            // for TextKit to enumerate. Paint its first line directly without
            // asking `lineFragmentRect` for an invalid glyph.
            self.drawLineNumber(
                1,
                atTextViewY: textView.textContainerOrigin.y,
                height: textView.font?.boundingRectForFont.height ?? 16,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
        } else if !drewTrailingLine, Self.endsWithLineBreak(string) {
            // The final empty line after a newline has no glyph of its own.
            // TextKit exposes its actual visual position through the extra
            // line fragment; this remains correct when the preceding logical
            // line wraps into multiple visual fragments.
            let fallbackHeight = max(textView.font?.boundingRectForFont.height ?? 16, 1)
            let extra = layoutManager.extraLineFragmentRect
            let trailingRect: NSRect?
            if Self.isUsableLineRect(extra) {
                trailingRect = extra
            } else if layoutManager.numberOfGlyphs > 0 {
                // A non-contiguous layout may not have populated the extra
                // rect yet. Use the last realized fragment if available; do
                // not force a potentially huge synchronous layout in draw.
                var lastRange = NSRange()
                let lastFragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.numberOfGlyphs - 1,
                    effectiveRange: &lastRange,
                    withoutAdditionalLayout: true
                )
                trailingRect = Self.isUsableLineRect(lastFragment)
                    ? NSRect(
                        x: lastFragment.minX,
                        y: lastFragment.maxY,
                        width: lastFragment.width,
                        height: max(lastFragment.height, fallbackHeight)
                    )
                    : nil
            } else {
                trailingRect = nil
            }

            if let trailingRect {
                let y = trailingRect.minY + textView.textContainerOrigin.y
                let viewRect = textView.visibleRect
                let visibleTrailingRect = NSRect(
                    x: viewRect.minX,
                    y: y,
                    width: max(1, viewRect.width),
                    height: max(trailingRect.height, fallbackHeight)
                )
                if NSIntersectsRect(visibleTrailingRect, viewRect) {
                    self.drawLineNumber(
                        lineCount,
                        atTextViewY: y,
                        height: max(trailingRect.height, fallbackHeight),
                        in: textView,
                        font: font,
                        paragraphStyle: paragraphStyle,
                        currentLine: currentLine
                    )
                }
            }
        }
    }

    private func drawBreakpoint(_ mark: BreakpointMark, atTextViewY y: CGFloat, height: CGFloat, in textView: NSTextView) {
        let top = convert(NSPoint(x: 0, y: y), from: textView).y
        let size: CGFloat = 8
        let dot = NSRect(x: 3, y: top + max(0, (height - size) / 2), width: size, height: size)
        let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
        let red = NSColor.systemRed
        switch mark {
        case .enabled:
            red.setFill()
            path.fill()
        case .conditional:
            // A conditional breakpoint: the dot with an equals sign.
            red.setFill()
            path.fill()
            NSColor.white.setFill()
            NSRect(x: dot.minX + 2, y: dot.midY - 2, width: dot.width - 4, height: 1).fill()
            NSRect(x: dot.minX + 2, y: dot.midY + 1, width: dot.width - 4, height: 1).fill()
        case .disabled:
            red.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .lost:
            NSColor.systemGray.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// The current instruction's arrow, over the dot column (a debugger's program-counter arrow).
    private func drawCurrentInstruction(atTextViewY y: CGFloat, height: CGFloat, in textView: NSTextView) {
        let top = convert(NSPoint(x: 0, y: y), from: textView).y
        let size: CGFloat = 9
        let box = NSRect(x: 2, y: top + max(0, (height - size) / 2), width: size, height: size)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: box.minX, y: box.minY + 2))
        arrow.line(to: NSPoint(x: box.midX, y: box.minY + 2))
        arrow.line(to: NSPoint(x: box.midX, y: box.minY))
        arrow.line(to: NSPoint(x: box.maxX, y: box.midY))
        arrow.line(to: NSPoint(x: box.midX, y: box.maxY))
        arrow.line(to: NSPoint(x: box.midX, y: box.maxY - 2))
        arrow.line(to: NSPoint(x: box.minX, y: box.maxY - 2))
        arrow.close()
        NSColor.systemGreen.setFill()
        arrow.fill()
    }

    /// The start offset of the line at a click, or nil off the text.
    private func lineStart(at event: NSEvent) -> Int? {
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
        guard layoutManager.numberOfGlyphs > 0, inContainer.y >= 0,
              inContainer.y <= layoutManager.usedRect(for: container).maxY else { return nil }
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return lineIndex.offset(forLine: lineIndex.lineNumber(containingUTF16Offset: character))
    }

    override func mouseDown(with event: NSEvent) {
        if let textView = clientView as? NSTextView, Self.breakpointMarks?(textView) != nil,
           let start = lineStart(at: event), Self.breakpointClicked?(textView, start) == true {
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let textView = clientView as? NSTextView, let start = lineStart(at: event),
           let menu = Self.breakpointMenu?(textView, start) {
            return menu
        }
        return super.menu(for: event)
    }

    private static func isUsableLineRect(_ rect: NSRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.height > 0
    }

    private static func endsWithLineBreak(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        let last = string.character(at: string.length - 1)
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        atTextViewY y: CGFloat,
        height: CGFloat,
        in textView: NSTextView,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        currentLine: Int?
    ) {
        let documentPoint = NSPoint(x: 0, y: y)
        let rulerPoint = convert(documentPoint, from: textView)
        let labelRect = NSRect(
            x: 4,
            y: rulerPoint.y,
            width: max(0, ruleThickness - 10),
            height: max(height, font.capHeight + 4)
        )
        let color = currentLine == lineNumber
            ? tokenTheme.gutterCurrentLineColor
            : tokenTheme.gutterDefaultColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: String(lineNumber)).draw(in: labelRect, withAttributes: attributes)
    }
}
