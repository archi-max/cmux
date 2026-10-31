import AppKit

/// Draws waveform values after the lines of a text view (`pc 0004  pc_next 0008`),
/// like an editor's inlay hints but without changing the text. Sits on top of
/// the text view, scrolls with it and never takes mouse events.
@MainActor
final class FilePreviewInlineValueOverlay: NSView {
    struct Annotation: Equatable {
        /// Where the text starts, in the text view's coordinates.
        var origin: NSPoint
        var pairs: [(name: String, value: String)]

        static func == (lhs: Annotation, rhs: Annotation) -> Bool {
            lhs.origin == rhs.origin && lhs.pairs.map(\.name) == rhs.pairs.map(\.name)
                && lhs.pairs.map(\.value) == rhs.pairs.map(\.value)
        }
    }

    private var annotations: [Annotation] = []
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Adds the overlay to `textView` if needed and shows `annotations` in `font`.
    func show(_ annotations: [Annotation], font: NSFont, in textView: NSTextView) {
        if superview !== textView {
            removeFromSuperview()
            frame = textView.bounds
            autoresizingMask = [.width, .height]
            textView.addSubview(self)
        }
        frame = textView.bounds
        guard annotations != self.annotations || font != self.font else { return }
        self.annotations = annotations
        self.font = font
        needsDisplay = true
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        annotations = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemTeal]
        for annotation in annotations {
            let text = NSMutableAttributedString()
            for (index, pair) in annotation.pairs.enumerated() {
                text.append(NSAttributedString(string: (index == 0 ? "" : "  ") + pair.name + " ", attributes: nameAttributes))
                text.append(NSAttributedString(string: pair.value, attributes: valueAttributes))
            }
            let rect = NSRect(origin: annotation.origin, size: text.size())
            guard rect.intersects(dirtyRect) else { continue }
            text.draw(at: annotation.origin)
        }
    }
}
