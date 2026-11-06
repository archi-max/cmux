import Testing
@testable import CmuxSettings

/// Trace X to Root: Ctrl+Shift+T on a waveform row follows its x back to where it was made. It
/// runs where Trace Driver runs (a waveform has focus, never a browser or the sidebar).
@Suite("Trace X to Root shortcut")
struct TraceWaveformXRootShortcutTests {
    @Test func defaultsToControlShiftT() {
        let effective = ShortcutAction.traceWaveformXRoot.effectivePersistedShortcut(nil)
        #expect(effective?.first.key == "t")
        #expect(effective?.first.control == true && effective?.first.shift == true)
        #expect(effective?.first.command == false && effective?.first.option == false)
    }

    @Test func controlShiftTIsAccepted() {
        let stroke = StoredShortcut(first: ShortcutStroke(key: "t", shift: true, control: true))
        #expect(ShortcutAction.traceWaveformXRoot.shortcutBindingPolicyResult(for: stroke) == .accepted)
    }

    @Test func runsWhereTraceDriverRuns() {
        #expect(ShortcutAction.traceWaveformXRoot.defaultFocusWhenClause == ShortcutAction.traceWaveformDriver.defaultFocusWhenClause)
        #expect(ShortcutAction.traceWaveformXRoot.group == ShortcutAction.traceWaveformDriver.group)
    }

    @Test func hasALabel() {
        #expect(ShortcutAction.traceWaveformXRoot.displayName == "Trace X to Root")
        #expect(ShortcutAction.traceWaveformXRoot.rawValue == "traceWaveformXRoot")
    }

    @Test func noOtherDefaultIsControlShiftT() {
        for action in ShortcutAction.allCases where action != .traceWaveformXRoot {
            let effective = action.effectivePersistedShortcut(nil)
            let clash = effective?.first.key == "t" && effective?.first.control == true && effective?.first.shift == true
                && effective?.first.command == false && effective?.first.option == false && effective?.second == nil
            #expect(!clash, "\(action) also defaults to Ctrl+Shift+T")
        }
    }
}
