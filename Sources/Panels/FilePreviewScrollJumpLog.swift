import AppKit
#if DEBUG
import CMUXDebugLog
#endif

/// Debug builds only, off by default: logs every move of the editor's clip
/// origin larger than `threshold` points, with the call stack, to the debug
/// event log. A jump the user sees can then be traced to its caller.
///
/// Turn it on with `CMUX_FILE_PREVIEW_SCROLL_LOG=1` or
/// `defaults write <bundle id> cmux.debug.file-preview-scroll-jumps -bool YES`,
/// then open the file again.
@MainActor
final class FilePreviewScrollJumpLog {
    static let defaultsKey = "cmux.debug.file-preview-scroll-jumps"
    static let threshold: CGFloat = 200

    #if DEBUG
    private var observer: ObserverToken?
    private var lastY: CGFloat

    private init(clipView: NSClipView, textView: NSTextView, fileName: String) {
        lastY = clipView.bounds.minY
        clipView.postsBoundsChangedNotifications = true
        observer = ObserverToken(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self, weak clipView, weak textView] _ in
            // Capture the stack here, on the posting call, before any hop.
            let stack = Thread.callStackSymbols
            MainActor.assumeIsolated {
                guard let self, let clipView else { return }
                self.clipDidMove(clipView, textView: textView, fileName: fileName, stack: stack)
            }
        })
    }

    /// Removes the observer when the log goes away.
    private final class ObserverToken {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }

    private func clipDidMove(_ clipView: NSClipView, textView: NSTextView?, fileName: String, stack: [String]) {
        let y = clipView.bounds.minY
        let from = lastY
        lastY = y
        guard abs(y - from) > Self.threshold else { return }
        let caret = textView?.selectedRange().location ?? -1
        let height = textView?.frame.height ?? 0
        let frames = stack.dropFirst(1).map(Self.symbol)
            .filter { !$0.contains("Notification") && !$0.contains("CFXRegistration") && !$0.contains("CFXNotification") }
            .prefix(40).joined(separator: " < ")
        logDebugEvent(
            "filePreview.scrollJump file=\(fileName) from=\(Int(from)) to=\(Int(y)) " +
                "docH=\(Int(height)) caret=\(caret) stack=\(frames)"
        )
    }

    /// The symbol part of a `callStackSymbols` line.
    private static func symbol(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        return parts.count > 3 ? parts[3...].joined(separator: " ") : line
    }
    #endif

    /// A log for `scrollView`'s clip view when the flag is on; nil otherwise and in release builds.
    static func installIfEnabled(on scrollView: NSScrollView, textView: NSTextView, filePath: String) -> FilePreviewScrollJumpLog? {
        #if DEBUG
        let enabled = ProcessInfo.processInfo.environment["CMUX_FILE_PREVIEW_SCROLL_LOG"] == "1"
            || UserDefaults.standard.bool(forKey: defaultsKey)
        guard enabled else { return nil }
        return FilePreviewScrollJumpLog(
            clipView: scrollView.contentView,
            textView: textView,
            fileName: (filePath as NSString).lastPathComponent
        )
        #else
        return nil
        #endif
    }
}
