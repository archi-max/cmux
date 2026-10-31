import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ctrl+W (Add Signal to Waveform) and Opt+Shift+D (Show Waveform Signal in
/// Source) are everyday terminal keys. Only their focus-scoped keyDown
/// routers may claim them; a static menu key equivalent would swallow them
/// while a terminal is focused.
@MainActor
@Suite(.serialized)
struct WaveformLinkShortcutRoutingTests {
    @Test
    func waveformLinkActionsHaveNoMenuKeyEquivalent() {
        #expect(KeyboardShortcutSettings.menuShortcut(for: .addSignalToWaveform).isUnbound)
        #expect(KeyboardShortcutSettings.menuShortcut(for: .revealWaveformSignalInSource).isUnbound)
    }

#if DEBUG
    @Test
    func controlWReachesAFocusedTerminal() throws {
        let appDelegate = try #require(AppDelegate.shared)
        appDelegate.debugResetShortcutRoutingStateForTesting()

        let fixture = try TerminalFocusTestFixture()
        defer {
            fixture.tearDown()
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }
        appDelegate.debugSetShortcutRoutingFocusedWindowForTesting(fixture.window)

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber,
                context: nil,
                characters: "\u{17}",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            )
        )
        #expect(
            !appDelegate.debugHandleCustomShortcut(event: event),
            "The shortcut router must leave Ctrl+W to the focused terminal"
        )
        let claimingItems = Self.menuItems(in: NSApp.mainMenu).filter { item in
            item.keyEquivalent.lowercased() == "w"
                && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.control]
        }
        #expect(claimingItems.isEmpty, "No menu item may take Ctrl+W: \(claimingItems.map(\.title))")
    }
#endif

    private static func menuItems(in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { [$0] + menuItems(in: $0.submenu) }
    }
}
