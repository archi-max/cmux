import AppKit
import CmuxCommandPalette
import SwiftUI

extension WaveformDebugger.Command {
    /// The commands of View > Waveform Debugger and the command palette, in menu order.
    static let all: [WaveformDebugger.Command] = [
        .step(1), .step(-1), .first, .last, .togglePlay, .faster, .slower, .useSelectedAsClock, .defaultClock, .stop,
    ]

    var title: String {
        switch self {
        case .step(let by):
            return by < 0 ? KeyboardShortcutSettings.Action.stepWaveformCycleBack.label
                : KeyboardShortcutSettings.Action.stepWaveformCycleForward.label
        case .first:
            return String(localized: "waveformDebugger.command.first", defaultValue: "Go to First Cycle")
        case .last:
            return String(localized: "waveformDebugger.command.last", defaultValue: "Go to Last Cycle")
        case .togglePlay:
            return KeyboardShortcutSettings.Action.toggleWaveformPlayback.label
        case .faster:
            return String(localized: "waveformDebugger.command.faster", defaultValue: "Play Faster")
        case .slower:
            return String(localized: "waveformDebugger.command.slower", defaultValue: "Play Slower")
        case .useSelectedAsClock:
            return String(localized: "waveformDebugger.command.useSelectedAsClock", defaultValue: "Use Selected Signal as Clock")
        case .defaultClock:
            return String(localized: "waveformDebugger.command.defaultClock", defaultValue: "Use Default Clock")
        case .stop:
            return String(localized: "waveformDebugger.command.stop", defaultValue: "Stop Debugging")
        }
    }

    var paletteCommandId: String {
        switch self {
        case .step(let by): return by < 0 ? "palette.waveformDebugger.stepBack" : "palette.waveformDebugger.stepForward"
        case .first: return "palette.waveformDebugger.first"
        case .last: return "palette.waveformDebugger.last"
        case .togglePlay: return "palette.waveformDebugger.togglePlay"
        case .faster: return "palette.waveformDebugger.faster"
        case .slower: return "palette.waveformDebugger.slower"
        case .useSelectedAsClock: return "palette.waveformDebugger.useSelectedAsClock"
        case .defaultClock: return "palette.waveformDebugger.defaultClock"
        case .stop: return "palette.waveformDebugger.stop"
        }
    }

    var keywords: [String] {
        let common = ["waveform", "debugger", "cycle", "clock", "simulation"]
        switch self {
        case .step(let by): return common + (by < 0 ? ["step", "back", "previous"] : ["step", "forward", "next"])
        case .first: return common + ["first", "start", "beginning"]
        case .last: return common + ["last", "end"]
        case .togglePlay: return common + ["play", "pause", "timelapse", "animate"]
        case .faster: return common + ["faster", "speed", "rate"]
        case .slower: return common + ["slower", "speed", "rate"]
        case .useSelectedAsClock: return common + ["selected", "signal", "choose"]
        case .defaultClock: return common + ["default", "clk", "reset"]
        case .stop: return common + ["stop", "exit", "locals"]
        }
    }
}

extension WaveformDebugger {
    /// The shortcut a palette command shows, for the commands that have one.
    static func shortcutAction(forPaletteCommandId commandId: String) -> KeyboardShortcutSettings.Action? {
        shortcutCommands.first { $0.1.paletteCommandId == commandId }?.0
    }
}

/// View > Waveform Debugger. Like the menu's other waveform items it has no key
/// equivalents and no `.disabled` (SwiftUI can't observe the focused panel):
/// a command beeps when neither a waveform viewer nor a SystemVerilog editor next to one has focus.
struct WaveformDebuggerMenu: View {
    var body: some View {
        Menu(String(localized: "menu.view.waveformDebugger", defaultValue: "Waveform Debugger")) {
            ForEach(Array(WaveformDebugger.Command.all.enumerated()), id: \.offset) { index, command in
                if index == 4 || index == 7 || index == 9 { Divider() }
                Button(command.title) {
                    if !WaveformDebugger.performFromShortcut(command, window: NSApp.keyWindow ?? NSApp.mainWindow) {
                        NSSound.beep()
                    }
                }
            }
        }
    }
}

extension ContentView {
    /// Palette context key: the focused panel is a waveform viewer, or a SystemVerilog editor next to one.
    static let commandPaletteWaveformDebuggerKey = CommandPaletteContextKeys(rawValue: "waveformDebugger.available")

    static func commandPaletteWaveformDebuggerAvailable(focusedPanel: Any) -> Bool {
        WaveformDebugger.target(for: focusedPanel as? FilePreviewPanel) != nil
    }

    static func commandPaletteWaveformDebuggerContributions() -> [CommandPaletteCommandContribution] {
        let subtitle = String(localized: "menu.view.waveformDebugger", defaultValue: "Waveform Debugger")
        return WaveformDebugger.Command.all.map { command in
            CommandPaletteCommandContribution(
                commandId: command.paletteCommandId,
                title: { _ in command.title },
                subtitle: { _ in subtitle },
                keywords: command.keywords,
                when: { $0.bool(Self.commandPaletteWaveformDebuggerKey) }
            )
        }
    }

    func registerWaveformDebuggerCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for command in WaveformDebugger.Command.all {
            registry.register(commandId: command.paletteCommandId) {
                let workspace = tabManager.selectedWorkspace
                let panel = workspace?.focusedPanelId.flatMap { workspace?.panels[$0] } as? FilePreviewPanel
                if !WaveformDebugger.perform(command, for: panel) {
                    NSSound.beep()
                }
            }
        }
    }
}
