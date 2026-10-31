import Testing
@testable import CmuxSettings

/// The waveform debugger's keys are bare function keys (F10 steps, ⇧F10 steps back, F5 continues to
/// a breakpoint or plays, ⇧F5 reverse-continues, F9 toggles a
/// breakpoint), so the binding policy must let each run its default, as the diff viewer's bare keys do.
@Suite("Waveform debugger shortcut defaults")
struct WaveformDebuggerShortcutDefaultsTests {
    @Test func eachDebuggerKeyRunsItsDefault() {
        for (action, key, shift) in [
            (ShortcutAction.stepWaveformCycleForward, "f10", false),
            (.stepWaveformCycleBack, "f10", true),
            (.toggleWaveformPlayback, "f5", false),
            (.reverseContinueWaveform, "f5", true),
            (.toggleWaveformBreakpoint, "f9", false),
        ] {
            #expect(action.shortcutBindingPolicyResult(for: StoredShortcut(first: ShortcutStroke(key: key, shift: shift))) == .accepted, "\(action)")
            let effective = action.effectivePersistedShortcut(nil)
            #expect(effective?.first.key == key && effective?.first.shift == shift, "\(action): \(String(describing: effective))")
        }
    }
}
