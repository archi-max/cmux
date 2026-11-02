import AppKit

/// Where a waveform debugger command came from, and what it acts on.
///
/// A raw key (F5, F10, …) typed while one of the viewer's text fields (the
/// netlist search, the Sequences search, a value field) has focus is typing,
/// so it goes to the field when it types text. A function key types nothing,
/// so it still runs. The View menu and the command palette are explicit: they
/// run on the focused viewer whatever has focus inside it, and when there is
/// no viewer to act on they say so instead of only beeping.
enum WaveformDebuggerInvocation {
    enum Source: Equatable {
        /// A shortcut key; `typesText` when the key would type into a text field.
        case key(typesText: Bool)
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
            if case .key(typesText: true) = source, viewerFieldFocused { return .passKey }
            return .perform(focusedViewer)
        }
        if let editorViewer { return .perform(editorViewer) }
        if case .key = source { return .passKey }
        if let workspaceViewer { return .perform(workspaceViewer) }
        return .unavailable
    }

    /// Whether a key event's characters type text into a field: function keys
    /// (U+F700–U+F8FF, AppKit's NSF1FunctionKey and so on) and control characters
    /// (Esc, Return, Tab) don't.
    static func typesText(_ characters: String?) -> Bool {
        guard let characters else { return false }
        return characters.unicodeScalars.contains { scalar in
            !(0xF700...0xF8FF).contains(scalar.value) && !CharacterSet.controlCharacters.contains(scalar)
        }
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

    /// Shows `message` over `view` (the key window's content view), replacing a
    /// notice already there. Returns the label shown, or nil without a view.
    @discardableResult
    static func show(_ message: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        view.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message)
        label.identifier = identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
        label.drawsBackground = true
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.setAccessibilityRole(.staticText)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
        ])
        NSAccessibility.post(element: label, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak label] in label?.removeFromSuperview() }
        return label
    }

    /// The notice in the key (else main) window, with a beep when there is no window.
    static func showUnavailable(in window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) {
        if show(WaveformDebuggerInvocation.unavailableMessage, in: window?.contentView) == nil { NSSound.beep() }
    }
}
