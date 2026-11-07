import Testing
@testable import CmuxSettings

/// Trace Loads: Ctrl+L on a waveform row (or a SystemVerilog editor's signal) lists the signal's
/// readers at the marker. It runs where Trace Driver runs (never a browser or the sidebar).
@Suite("Trace Loads shortcut")
struct TraceWaveformLoadsShortcutTests {
    @Test func defaultsToControlL() {
        let effective = ShortcutAction.traceWaveformLoads.effectivePersistedShortcut(nil)
        #expect(effective?.first.key == "l")
        #expect(effective?.first.control == true && effective?.first.shift == false)
        #expect(effective?.first.command == false && effective?.first.option == false)
    }

    @Test func controlLIsAccepted() {
        let stroke = StoredShortcut(first: ShortcutStroke(key: "l", control: true))
        #expect(ShortcutAction.traceWaveformLoads.shortcutBindingPolicyResult(for: stroke) == .accepted)
    }

    @Test func runsWhereTraceDriverRuns() {
        #expect(ShortcutAction.traceWaveformLoads.defaultFocusWhenClause == ShortcutAction.traceWaveformDriver.defaultFocusWhenClause)
        #expect(ShortcutAction.traceWaveformLoads.group == ShortcutAction.traceWaveformDriver.group)
    }

    @Test func hasALabel() {
        #expect(ShortcutAction.traceWaveformLoads.displayName == "Trace Loads")
        #expect(ShortcutAction.traceWaveformLoads.rawValue == "traceWaveformLoads")
    }

    @Test func noOtherDefaultIsControlL() {
        for action in ShortcutAction.allCases where action != .traceWaveformLoads {
            let effective = action.effectivePersistedShortcut(nil)
            let clash = effective?.first.key == "l" && effective?.first.control == true && effective?.first.shift == false
                && effective?.first.command == false && effective?.first.option == false && effective?.second == nil
            #expect(!clash, "\(action) also defaults to Ctrl+L")
        }
    }
}
