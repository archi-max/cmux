import AppKit

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        let changed = textContainer.widthTracksTextView != wrap
        let visibleWidth = scrollView.contentSize.width
        let wrapWidth = max(0, visibleWidth - 2 * textContainerInset.width)
        // A reflow re-lays out every line, and the numeric clip origin then
        // points at other text; keep the character at the viewport top instead.
        let reflows = changed || (wrap && visibleWidth > 0 && textContainer.size.width != wrapWidth)
        let viewportAnchor = reflows ? FilePreviewViewportAnchor.capture(in: self) : nil
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            if visibleWidth > 0 {
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
                if textContainer.size.width != wrapWidth {
                    textContainer.size = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
                }
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        // Reflow the existing storage. Selection, affinity, and undo history
        // remain untouched; only the viewport is placed again.
        guard let viewportAnchor else { return }
        scrollView.layoutSubtreeIfNeeded()
        viewportAnchor.restoreCharacter(in: self)
    }

    /// Applies the editor’s shared text padding without changing its content.
    func applyFilePreviewTextEditorInsets() {
        let targetInset = FilePreviewTextEditorLayout.textContainerInset
        if textContainerInset.width != targetInset.width || textContainerInset.height != targetInset.height {
            textContainerInset = targetInset
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

