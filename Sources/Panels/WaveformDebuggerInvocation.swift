import AppKit

/// Where a waveform debugger command came from, and what it acts on.
///
/// A raw key typed while one of the viewer's text fields (the netlist search,
/// the Sequences search, a value field) has focus goes to the field when the
/// field uses it: every key but F1–F35, and no Command or Control chord. So the
/// default F5/F10 bindings still run. The View menu and the command palette are explicit: they
/// run on the focused viewer whatever has focus inside it, and when there is
/// no viewer to act on they say so instead of only beeping.
enum WaveformDebuggerInvocation {
    enum Source: Equatable {
        /// A shortcut key; `fieldUsesKey` when a focused text field would use it.
        case key(fieldUsesKey: Bool)
        case menu
        case palette
    }

    enum Decision<Panel: AnyObject> {
        /// Run the command on this viewer.
        case perform(Panel)
        /// The key isn't the debugger's here: it goes on (to the field, or to another view).
        case passKey
        /// An explicit command with no viewer to act on: tell the user why.
        case unavailable
    }

    /// What a command from `source` does, given the focused viewer (its web view holds
    /// the window's first responder), whether one of its text fields has focus, the
    /// viewer next to a focused SystemVerilog editor, and the viewer for the workspace's
    /// focused panel whatever holds the responder (`workspaceViewer`: the menu and the
    /// palette act on it; a key doesn't, so it goes on to the view that has it).
    static func decide<Panel: AnyObject>(
        source: Source, focusedViewer: Panel?, viewerFieldFocused: Bool, editorViewer: Panel?,
        workspaceViewer: Panel? = nil
    ) -> Decision<Panel> {
        if let focusedViewer {
            if case .key(fieldUsesKey: true) = source, viewerFieldFocused { return .passKey }
            return .perform(focusedViewer)
        }
        if let editorViewer { return .perform(editorViewer) }
        if case .key = source { return .passKey }
        if let workspaceViewer { return .perform(workspaceViewer) }
        return .unavailable
    }

    /// Whether a focused text field uses a key (`characters` is the event's
    /// charactersIgnoringModifiers). F1–F35 (U+F704–U+F726) aren't a field's, and
    /// neither is a Command or Control chord. Every other key is: letters, arrows,
    /// Home/End, Page Up/Down, Forward Delete, Return, Tab, Backspace and Esc.
    static func fieldUsesKey(_ characters: String?, modifierFlags: NSEvent.ModifierFlags = []) -> Bool {
        guard let characters, !characters.isEmpty else { return false }
        if !modifierFlags.intersection([.command, .control]).isEmpty { return false }
        let functionKeys = UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)
        return !characters.unicodeScalars.allSatisfy { functionKeys.contains($0.value) }
    }

    /// The message for an explicit command with no viewer to act on.
    static var unavailableMessage: String {
        String(
            localized: "waveformDebugger.noViewer",
            defaultValue: "Focus a waveform viewer, or a SystemVerilog editor next to one."
        )
    }
}

/// A short notice at the top of a window's content (no focus change, gone after a
/// moment): what a menu or palette command couldn't do.
@MainActor
enum WaveformDebuggerNotice {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.waveformDebugger.notice")
    static var duration: TimeInterval = 2.5
    /// Posts the VoiceOver announcement (a seam for the harness).
    static var post: (Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]) -> Void = {
        NSAccessibility.post(element: $0, notification: $1, userInfo: $2)
    }

    /// Shows `message` in `container`, at the top centre of `reference` (the window's
    /// content; `container` itself by default), replacing a notice already there.
    /// The window's terminal and browser portals are siblings above the content
    /// (`isForeground`), so the notice goes just above the topmost of them, and below
    /// later foreground controls such as the palette. Returns the label shown, or nil
    /// without a container.
    @discardableResult
    static func show(
        _ message: String, in container: NSView?, reference: NSView? = nil,
        isForeground: (NSView) -> Bool = { _ in false }
    ) -> NSTextField? {
        guard let container else { return nil }
        container.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }
        let reference = reference.flatMap { $0.superview != nil && $0.isDescendant(of: container) ? $0 : nil }
        let label = NSTextField(labelWithString: message)
        label.identifier = identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
        label.drawsBackground = true
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.setAccessibilityRole(.staticText)

        let area = reference.map { container.convert($0.bounds, from: $0) } ?? container.bounds
        let size = label.fittingSize
        let width = min(ceil(size.width) + 16, max(area.width - 24, 0)), height = ceil(size.height) + 6
        let top = container.isFlipped ? area.minY + 12 : area.maxY - 12 - height
        label.frame = NSRect(x: area.midX - width / 2, y: top, width: width, height: height)
        label.autoresizingMask = [.minXMargin, .maxXMargin, container.isFlipped ? .maxYMargin : .minYMargin]
        if let foreground = container.subviews.last(where: isForeground) ?? reference.flatMap({ ref in
            container.subviews.first { ref === $0 || ref.isDescendant(of: $0) }
        }) {
            container.addSubview(label, positioned: .above, relativeTo: foreground)
        } else {
            container.addSubview(label)
        }
        // VoiceOver: through the app at high priority, as the app's other notices
        // (a label that has only just joined the tree may be dropped).
        if let application = NSApp {
            post(application, .announcementRequested,
                 [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak label] in label?.removeFromSuperview() }
        return label
    }
}
