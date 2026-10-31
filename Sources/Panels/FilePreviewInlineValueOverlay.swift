import AppKit
import SwiftUI

/// Draws waveform values after the lines of a text view (`pc 0004  pc_next 0008`),
/// like an editor's inlay hints but without changing the text. Sits on top of
/// the text view, scrolls with it and never takes mouse events.
@MainActor
final class FilePreviewInlineValueOverlay: NSView {
    struct Annotation: Equatable {
        /// Where the text starts, in the text view's coordinates.
        var origin: NSPoint
        var pairs: [(name: String, value: String)]
        /// Why there are no values, drawn instead of them.
        var note: String?

        static func == (lhs: Annotation, rhs: Annotation) -> Bool {
            lhs.origin == rhs.origin && lhs.note == rhs.note && lhs.pairs.map(\.name) == rhs.pairs.map(\.name)
                && lhs.pairs.map(\.value) == rhs.pairs.map(\.value)
        }
    }

    private var annotations: [Annotation] = []
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    /// Dims the values while newer ones are on their way (the marker moved, the layout changed).
    var isStale = false {
        didSet { if isStale != oldValue, !annotations.isEmpty { needsDisplay = true } }
    }

    var hasAnnotations: Bool { !annotations.isEmpty }

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
        let wasStale = isStale
        isStale = false
        guard annotations != self.annotations || font != self.font || wasStale else { return }
        self.annotations = annotations
        self.font = font
        needsDisplay = true
    }

    func clear() {
        isStale = false
        guard !annotations.isEmpty else { return }
        annotations = []
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isStale ? 0.4 : 1
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(alpha),
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.systemTeal.withAlphaComponent(alpha),
        ]
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
            .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(alpha),
        ]
        for annotation in annotations {
            let text = NSMutableAttributedString()
            for (index, pair) in annotation.pairs.enumerated() {
                text.append(NSAttributedString(string: (index == 0 ? "" : "  ") + pair.name + " ", attributes: nameAttributes))
                text.append(NSAttributedString(string: pair.value, attributes: valueAttributes))
            }
            if let note = annotation.note {
                text.append(NSAttributedString(string: note, attributes: noteAttributes))
            }
            let rect = NSRect(origin: annotation.origin, size: text.size())
            guard rect.intersects(dirtyRect) else { continue }
            text.draw(at: annotation.origin)
        }
    }
}

/// View > Show FSDB Values for Signals Not in the Waveform. Off by default: for
/// an FSDB (often on an SSH host) each such signal's changes are read on the host.
struct WaveformInlineValuesMenu: View {
    @AppStorage(WaveformInlineValueSettings.unshownFSDBValuesKey) private var isOn = false

    var body: some View {
        Toggle(
            String(localized: "menu.view.unshownFSDBValues", defaultValue: "Show FSDB Values for Signals Not in the Waveform"),
            isOn: Binding(get: { isOn }, set: { newValue in
                isOn = newValue
                WaveformSourceLink.inlineValueSettingsChanged()
            })
        )
    }
}
