import AppKit
import CmuxCommandPalette
import SwiftUI

extension WaveformDebugger.Command {
    /// The commands of View > Waveform Debugger and the command palette, in menu order.
    static let all: [WaveformDebugger.Command] = [
        .step(1), .step(-1), .first, .last, .continueToBreakpoint(1), .continueToBreakpoint(-1), .toggleLineBreakpoint,
        .togglePlay, .faster, .slower, .useSelectedAsClock, .defaultClock, .stop, .evaluateExpression, .addWatch,
        .addInstructionBreakpoint, .showInstructionInListing,
        .toggleMachineState, .loadELF,
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
            return String(localized: "shortcut.toggleWaveformPlayback.label", defaultValue: "Play or Pause Waveform")
        case .continueToBreakpoint(let direction):
            return direction < 0 ? KeyboardShortcutSettings.Action.reverseContinueWaveform.label
                : String(localized: "waveformDebugger.command.continue", defaultValue: "Continue to Next Breakpoint")
        case .continueOrTogglePlay:
            return KeyboardShortcutSettings.Action.toggleWaveformPlayback.label
        case .toggleLineBreakpoint:
            return KeyboardShortcutSettings.Action.toggleWaveformBreakpoint.label
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
        case .evaluateExpression:
            return String(localized: "waveformDebugger.command.evaluate", defaultValue: "Evaluate Expression…")
        case .addWatch:
            return String(localized: "waveformDebugger.command.addWatch", defaultValue: "Add Watch…")
        case .addInstructionBreakpoint:
            return String(localized: "waveformDebugger.command.addInstructionBreakpoint", defaultValue: "Add Instruction Breakpoint…")
        case .showInstructionInListing:
            return String(localized: "waveformDebugger.command.showInstructionInListing", defaultValue: "Show Instruction in Listing")
        case .toggleMachineState:
            return String(localized: "waveformDebugger.command.toggleMachineState", defaultValue: "Show or Hide Machine State")
        case .loadELF:
            return String(localized: "waveformDebugger.command.loadELF", defaultValue: "Load ELF for Machine State…")
        }
    }

    var paletteCommandId: String {
        switch self {
        case .step(let by): return by < 0 ? "palette.waveformDebugger.stepBack" : "palette.waveformDebugger.stepForward"
        case .first: return "palette.waveformDebugger.first"
        case .last: return "palette.waveformDebugger.last"
        case .togglePlay: return "palette.waveformDebugger.togglePlay"
        case .continueToBreakpoint(let direction):
            return direction < 0 ? "palette.waveformDebugger.reverseContinue" : "palette.waveformDebugger.continue"
        case .continueOrTogglePlay: return "palette.waveformDebugger.continueOrTogglePlay"
        case .toggleLineBreakpoint: return "palette.waveformDebugger.toggleLineBreakpoint"
        case .faster: return "palette.waveformDebugger.faster"
        case .slower: return "palette.waveformDebugger.slower"
        case .useSelectedAsClock: return "palette.waveformDebugger.useSelectedAsClock"
        case .defaultClock: return "palette.waveformDebugger.defaultClock"
        case .stop: return "palette.waveformDebugger.stop"
        case .evaluateExpression: return "palette.waveformDebugger.evaluate"
        case .addWatch: return "palette.waveformDebugger.addWatch"
        case .addInstructionBreakpoint: return "palette.waveformDebugger.addInstructionBreakpoint"
        case .showInstructionInListing: return "palette.waveformDebugger.showInstructionInListing"
        case .toggleMachineState: return "palette.waveformDebugger.toggleMachineState"
        case .loadELF: return "palette.waveformDebugger.loadELF"
        }
    }

    var keywords: [String] {
        let common = ["waveform", "debugger", "cycle", "clock", "simulation"]
        switch self {
        case .step(let by): return common + (by < 0 ? ["step", "back", "previous"] : ["step", "forward", "next"])
        case .first: return common + ["first", "start", "beginning"]
        case .last: return common + ["last", "end"]
        case .togglePlay: return common + ["play", "pause", "timelapse", "animate"]
        case .continueToBreakpoint(let direction):
            return common + ["breakpoint", "continue", "run"] + (direction < 0 ? ["reverse", "back", "previous"] : ["next", "forward"])
        case .continueOrTogglePlay: return common + ["breakpoint", "continue", "play", "pause"]
        case .toggleLineBreakpoint: return common + ["breakpoint", "line", "toggle", "gutter"]
        case .faster: return common + ["faster", "speed", "rate"]
        case .slower: return common + ["slower", "speed", "rate"]
        case .useSelectedAsClock: return common + ["selected", "signal", "choose"]
        case .defaultClock: return common + ["default", "clk", "reset"]
        case .stop: return common + ["stop", "exit", "locals"]
        case .evaluateExpression: return common + ["evaluate", "expression", "value", "print"]
        case .addWatch: return common + ["watch", "expression", "add"]
        case .addInstructionBreakpoint:
            return common + ["breakpoint", "instruction", "pc", "address", "commit", "write", "watchpoint", "register", "memory", "riscv"]
        case .showInstructionInListing: return common + ["instruction", "listing", "objdump", "disassembly", "pc", "reveal", "riscv"]
        case .toggleMachineState: return common + ["machine", "registers", "memory", "riscv", "rvfi", "commit", "instruction"]
        case .loadELF: return common + ["elf", "program", "image", "symbols", "memory", "riscv"]
        }
    }
}

extension WaveformDebugger {
    /// The shortcut a palette command shows, for the commands that have one.
    static func shortcutAction(forPaletteCommandId commandId: String) -> KeyboardShortcutSettings.Action? {
        // F5 runs continueOrTogglePlay, which the palette lists as Continue to Next Breakpoint.
        let id = commandId == Command.continueToBreakpoint(1).paletteCommandId
            ? Command.continueOrTogglePlay.paletteCommandId : commandId
        return shortcutCommands.first { $0.1.paletteCommandId == id }?.0
    }
}

/// View > Waveform Debugger. Like the menu's other waveform items it has no key
/// equivalents and no `.disabled` (SwiftUI can't observe the focused panel):
/// a command beeps when neither a waveform viewer nor a SystemVerilog editor next to one has focus.
struct WaveformDebuggerMenu: View {
    @AppStorage(WaveformDebuggerRTLStatus.waitForEditorKey) private var waitsForEditor = true

    var body: some View {
        Menu(String(localized: "menu.view.waveformDebugger", defaultValue: "Waveform Debugger")) {
            ForEach(Array(WaveformDebugger.Command.all.enumerated()), id: \.offset) { index, command in
                if index == 4 || index == 7 || index == 10 || index == 12 || index == 13 || index == 15 { Divider() }
                Button(command.title) {
                    if !WaveformDebugger.performFromShortcut(command, window: NSApp.keyWindow ?? NSApp.mainWindow) {
                        NSSound.beep()
                    }
                }
            }
            Divider()
            Toggle(
                String(localized: "waveformDebugger.waitForEditor", defaultValue: "Play Waits for the Editor"),
                // The setter tells the stepping viewers (onChange may not run inside .commands).
                isOn: Binding(
                    get: { waitsForEditor },
                    set: { value in
                        waitsForEditor = value
                        WaveformDebugger.waitForEditorChanged()
                    }
                )
            )
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
