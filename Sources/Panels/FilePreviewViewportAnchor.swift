import AppKit

/// The line at the top of a text view's viewport, so a whole-buffer
/// replacement (a reload, format on save) can show the same lines afterward,
/// and the character there, so a reflow of the same text (word wrap turned on
/// or off, a new wrap width) can.
///
/// The editor uses non-contiguous layout: heights of lines that were never
/// laid out are estimates, and replacing the buffer re-estimates them. The
/// clip view's old numeric origin then points at different text, so restoring
/// it moves the visible lines by several rows. Anchoring to a line and laying
/// that line out before scrolling keeps the view where it was.
/// A text view that ignores AppKit's own scroll-to-visible calls while
/// `suppressesAutomaticScrolling` is set (see `keepingViewport`).
@MainActor
protocol FilePreviewAutomaticScrollSuppressing: NSTextView {
    var suppressesAutomaticScrolling: Bool { get set }
}

struct FilePreviewViewportAnchor: Equatable {
    /// Zero-based line shown at the top of the viewport; nil when captured
    /// without counting lines (a reflow of the same text needs only `character`).
    let line: Int?
    /// How far the viewport top sits below that line's top, in points.
    let offset: CGFloat
    /// Horizontal clip origin, kept as is.
    let x: CGFloat
    /// First character of the line fragment at the viewport top.
    var character: Int = 0
    /// How far the viewport top sits below that fragment's top, in points.
    var characterOffset: CGFloat = 0

    /// Reads the anchor of `textView`'s viewport; nil outside a scroll view.
    /// `countingLines: false` skips the line number, which costs a scan of
    /// the text up to the viewport: `restoreCharacter` does not use it.
    @MainActor
    static func capture(in textView: NSTextView, countingLines: Bool = true) -> FilePreviewViewportAnchor? {
        guard let clipView = textView.enclosingScrollView?.contentView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let text = Self.characters(of: textView)
        guard text.length > 0 else {
            return FilePreviewViewportAnchor(line: 0, offset: clipView.bounds.minY, x: clipView.bounds.minX)
        }
        let origin = textView.textContainerOrigin
        // Laying out lines can re-estimate the lines above them, and AppKit then
        // moves the clip origin to keep the shown text still. Read the origin
        // only once a pass leaves it where it was.
        var anchor = FilePreviewViewportAnchor(line: 0, offset: 0, x: clipView.bounds.minX)
        for _ in 0..<4 {
            layoutManager.ensureLayout(
                forBoundingRect: clipView.bounds.offsetBy(dx: -origin.x, dy: -origin.y),
                in: container
            )
            let visibleTop = clipView.bounds.minY
            let point = NSPoint(x: 0, y: max(0, visibleTop - origin.y))
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let character = min(layoutManager.characterIndexForGlyph(at: glyph), text.length - 1)
            let lineStart = text.lineRange(for: NSRange(location: character, length: 0)).location
            let lineTop = Self.top(ofCharacterAt: lineStart, in: textView)
            var fragmentGlyphs = NSRange(location: 0, length: 0)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
            let fragmentCharacter = min(layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location), text.length - 1)
            anchor = FilePreviewViewportAnchor(
                line: countingLines ? Self.lineNumber(at: lineStart, in: text) : nil,
                offset: visibleTop - lineTop,
                x: clipView.bounds.minX,
                character: fragmentCharacter,
                characterOffset: visibleTop - (fragment.minY + origin.y)
            )
            if abs(clipView.bounds.minY - visibleTop) < 0.5 { break }
        }
        return anchor
    }

    /// The character anchor of the line fragment shown at the viewport top,
    /// read from the layout as it is, or nil when that line is not laid out.
    /// `capture` lays the viewport out first, which can fill estimated lines
    /// above it and make AppKit move the clip view before the edit even runs.
    @MainActor
    private static func captureShown(in textView: NSTextView) -> FilePreviewViewportAnchor? {
        guard let clipView = textView.enclosingScrollView?.contentView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let visibleTop = clipView.bounds.minY
        let topRow = NSRect(x: 0, y: max(0, visibleTop - origin.y), width: container.size.width, height: 1)
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: topRow, in: container)
        guard glyphs.length > 0 else { return nil }
        var fragmentGlyphs = NSRange(location: 0, length: 0)
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphs.location,
            effectiveRange: &fragmentGlyphs,
            withoutAdditionalLayout: true
        )
        let top = visibleTop - origin.y
        // After invalidateLayout with no layout since, the call answers with an
        // estimated fragment about 0.001 pt wide that belongs to another line.
        guard fragment.width >= 1, fragment.height > 0,
              fragment.minY <= top + 0.5, fragment.maxY > top else { return nil }
        let characterOffset = top - fragment.minY
        return FilePreviewViewportAnchor(
            line: nil,
            offset: characterOffset,
            x: clipView.bounds.minX,
            character: min(layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location), length - 1),
            characterOffset: characterOffset
        )
    }

    /// Scrolls `textView` so its anchored line is back at the viewport top.
    @MainActor
    func restore(in textView: NSTextView) {
        guard let line else {
            restoreCharacter(in: textView)
            return
        }
        let text = Self.characters(of: textView)
        scroll(textView, toTopOf: Self.offset(ofLine: line, in: text), plus: offset)
    }

    /// Runs `edit`, an attribute edit over much of the buffer (a theme or font
    /// change), with AppKit's own scrolling held off, then puts the character
    /// at the viewport top back. Re-laying out every line makes AppKit
    /// re-anchor through `scrollRangeToVisible` of estimated rects, which
    /// moved the clip view thousands of points away and back.
    @MainActor
    static func keepingViewport(of textView: NSTextView, _ edit: () -> Void) {
        let anchor = captureShown(in: textView) ?? capture(in: textView, countingLines: false)
        let suppressing = textView as? FilePreviewAutomaticScrollSuppressing
        let wasSuppressing = suppressing?.suppressesAutomaticScrolling ?? false
        suppressing?.suppressesAutomaticScrolling = true
        edit()
        // AppKit re-anchors again while the restore lays lines out; keep it off.
        anchor?.restoreCharacter(in: textView)
        suppressing?.suppressesAutomaticScrolling = wasSuppressing
    }

    /// Scrolls `textView` so its anchored character is back at the viewport
    /// top, for a reflow that kept the text: the line may wrap differently now.
    @MainActor
    func restoreCharacter(in textView: NSTextView) {
        let length = Self.characters(of: textView).length
        let character = min(character, max(0, length - 1))
        var offset = characterOffset
        if length > 0, let layoutManager = textView.layoutManager {
            // The fragment may be shorter now (wrap turned off joins rows).
            _ = Self.top(ofCharacterAt: character, in: textView)
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            let height = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height
            offset = min(max(0, offset), max(0, height - 1))
        }
        scroll(textView, toTopOf: character, plus: offset)
    }

    @MainActor
    private func scroll(_ textView: NSTextView, toTopOf character: Int, plus offset: CGFloat) {
        guard let scrollView = textView.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let text = Self.characters(of: textView)
        // Laying out the target region can re-estimate the lines above it and
        // move the anchored line. Lay it out until it holds still, then scroll
        // once, so the clip view goes straight to where it ends up.
        var lineTop: CGFloat = 0
        for _ in 0..<6 {
            lineTop = text.length == 0 ? 0 : Self.top(ofCharacterAt: character, in: textView)
            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                let origin = textView.textContainerOrigin
                let target = NSRect(origin: NSPoint(x: x, y: lineTop + offset), size: clipView.bounds.size)
                layoutManager.ensureLayout(
                    forBoundingRect: target.offsetBy(dx: -origin.x, dy: -origin.y),
                    in: container
                )
            }
            let settled = text.length == 0 ? 0 : Self.top(ofCharacterAt: character, in: textView)
            if abs(settled - lineTop) < 0.5 { break }
        }
        for _ in 0..<3 {
            scrollView.layoutSubtreeIfNeeded()
            let target = NSRect(origin: NSPoint(x: x, y: lineTop + offset), size: clipView.bounds.size)
            clipView.scroll(to: clipView.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clipView)
            let settled = text.length == 0 ? 0 : Self.top(ofCharacterAt: character, in: textView)
            if abs(settled - lineTop) < 0.5 { return }
            lineTop = settled
        }
    }

    /// The text view's characters without a copy: `NSTextView.string` bridges
    /// the mutable storage into a new Swift string, 40 ms for a million lines.
    @MainActor
    private static func characters(of textView: NSTextView) -> NSString {
        textView.textStorage?.mutableString ?? (textView.string as NSString)
    }

    /// The text-view y of the line fragment holding `index`, laid out first.
    @MainActor
    private static func top(ofCharacterAt index: Int, in textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length, length > 0 else { return 0 }
        let character = min(index, length - 1)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minY + textView.textContainerOrigin.y
    }

    /// Zero-based line of `index`: the line breaks that end at or before it.
    /// Breaks are those of `NSString.lineRange`: \n, \r\n, \r, U+0085, U+2028, U+2029.
    static func lineNumber(at index: Int, in text: NSString) -> Int {
        var count = 0
        forEachLineEnd(in: text, through: min(index, text.length)) { _ in
            count += 1
            return true
        }
        return count
    }

    /// UTF-16 offset where zero-based `line` starts; the last line's start when beyond the end.
    static func offset(ofLine line: Int, in text: NSString) -> Int {
        guard line > 0 else { return 0 }
        var location = 0
        var remaining = line
        forEachLineEnd(in: text, through: text.length) { end in
            location = end
            remaining -= 1
            return remaining > 0
        }
        return location
    }

    /// Calls `body` with the end offset of each line break that ends at or
    /// before `limit`, in order, until it returns false. Reads the UTF-16
    /// units in chunks: one `lineRange` call per line took 115 ms for a
    /// million lines.
    private static func forEachLineEnd(in text: NSString, through limit: Int, _ body: (Int) -> Bool) {
        let length = text.length
        guard limit > 0, length > 0 else { return }
        let chunk = 16_384
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var start = 0
        // A \r whose \n may be the first unit of the next chunk.
        var pendingCR = false
        while start < length {
            let count = min(chunk, length - start)
            text.getCharacters(buffer, range: NSRange(location: start, length: count))
            var offset = 0
            if pendingCR {
                pendingCR = false
                // \r\n ends after the \n; a lone \r ended right after itself.
                let end = buffer[0] == 0x0A ? start + 1 : start
                if end > limit || !body(end) { return }
                if buffer[0] == 0x0A { offset = 1 }
            }
            while offset < count {
                let unit = buffer[offset]
                // Most units are neither \n, \r nor U+0085/2028/2029.
                if unit > 0x0D, unit != 0x85, unit < 0x2028 || unit > 0x2029 {
                    offset += 1
                    continue
                }
                let position = start + offset
                switch unit {
                case 0x0D:
                    if offset + 1 < count {
                        let crlf = buffer[offset + 1] == 0x0A
                        let end = position + (crlf ? 2 : 1)
                        if end > limit || !body(end) { return }
                        if crlf { offset += 1 }
                    } else if position + 1 == length {
                        if position + 1 > limit || !body(position + 1) { return }
                    } else {
                        pendingCR = true
                    }
                case 0x0A, 0x85, 0x2028, 0x2029:
                    if position + 1 > limit || !body(position + 1) { return }
                default:
                    break
                }
                offset += 1
            }
            if start + count >= limit, !pendingCR { return }
            start += count
        }
    }
}
