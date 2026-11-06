import Testing
@testable import CmuxSettings

/// Trace Driver (driver tracing, phase P1): Ctrl+T on a waveform row or in a SystemVerilog
/// editor next to a waveform. Like Show Waveform Signal in Source, it runs where a waveform or
/// an SV editor has focus, never in a browser or the sidebar; elsewhere Ctrl+T keeps its
/// meaning (the shell's and AppKit's transpose).
@Suite("Trace Driver shortcut")
struct TraceWaveformDriverShortcutTests {
    @Test func defaultsToControlT() {
        let effective = ShortcutAction.traceWaveformDriver.effectivePersistedShortcut(nil)
        #expect(effective?.first.key == "t")
        #expect(effective?.first.control == true)
        #expect(effective?.first.command == false && effective?.first.shift == false && effective?.first.option == false)
    }

    @Test func controlTIsAccepted() {
        let stroke = StoredShortcut(first: ShortcutStroke(key: "t", control: true))
        #expect(ShortcutAction.traceWaveformDriver.shortcutBindingPolicyResult(for: stroke) == .accepted)
    }

    @Test func runsWhereTheWaveformLinkRuns() {
        #expect(ShortcutAction.traceWaveformDriver.defaultFocusWhenClause == ShortcutAction.revealWaveformSignalInSource.defaultFocusWhenClause)
        #expect(ShortcutAction.traceWaveformDriver.group == ShortcutAction.revealWaveformSignalInSource.group)
    }

    @Test func hasALabel() {
        #expect(ShortcutAction.traceWaveformDriver.displayName == "Trace Driver")
        #expect(ShortcutAction.traceWaveformDriver.rawValue == "traceWaveformDriver")
    }

    @Test func noOtherDefaultIsControlT() {
        for action in ShortcutAction.allCases where action != .traceWaveformDriver {
            let effective = action.effectivePersistedShortcut(nil)
            let clash = effective?.first.key == "t" && effective?.first.control == true && effective?.first.command == false
                && effective?.first.option == false && effective?.first.shift == false && effective?.second == nil
            #expect(!clash, "\(action) also defaults to a Ctrl+T")
        }
    }
}
