import AppKit
import CmuxCommandPalette
import Foundation

extension CommandPaletteContextKeys {
    /// Whether the focused panel is a SystemVerilog editor with a slang language server.
    static let panelIsSystemVerilogEditor = CommandPaletteContextKeys(rawValue: "panel.isSystemVerilogEditor")
}

/// Command palette entries for the SystemVerilog editor's slang menu. Each runs the same
/// `SlangCompilationActions` function as the editor's header and context menu. No default
/// keyboard shortcut.
enum SlangCommandPalette {
    enum Command: String, CaseIterable {
        case switchProfile = "palette.slang.switchProfile"
        case setCurrentFileAsTop = "palette.slang.setCurrentFileAsTop"
        case exploreMode = "palette.slang.exploreMode"
        case editProfiles = "palette.slang.editProfiles"
        case restartLanguageServer = "palette.slang.restartLanguageServer"

        var title: String {
            switch self {
            case .switchProfile:
                return String(localized: "command.slang.switchProfile.title", defaultValue: "SystemVerilog: Switch slang Profile…")
            case .setCurrentFileAsTop:
                return String(localized: "command.slang.setCurrentFileAsTop.title", defaultValue: "SystemVerilog: Set Current File as Top Level")
            case .exploreMode:
                return String(localized: "command.slang.exploreMode.title", defaultValue: "SystemVerilog: Explore Mode (No Top)")
            case .editProfiles:
                return String(localized: "command.slang.editProfiles.title", defaultValue: "SystemVerilog: Edit slang Profiles…")
            case .restartLanguageServer:
                return String(localized: "command.slang.restartLanguageServer.title", defaultValue: "SystemVerilog: Restart Language Server")
            }
        }

        var keywords: [String] {
            let common = ["systemverilog", "verilog", "slang", "language server", "lsp"]
            switch self {
            case .switchProfile: return common + ["profile", "build", "file", ".f", "switch"]
            case .setCurrentFileAsTop: return common + ["top", "level", "module", "elaborate"]
            case .exploreMode: return common + ["explore", "no top", "reset"]
            case .editProfiles: return common + ["profile", "edit", "new", ".f"]
            case .restartLanguageServer: return common + ["restart", "reload", "server"]
            }
        }
    }

    @MainActor
    static func setContext(panel: (any Panel)?, in snapshot: inout CommandPaletteContextSnapshot) {
        let filePreview = panel as? FilePreviewPanel
        snapshot.setBool(
            CommandPaletteContextKeys.panelIsSystemVerilogEditor,
            filePreview?.previewMode == .text && filePreview?.slangHeader != nil
        )
    }

    static func contributions() -> [CommandPaletteCommandContribution] {
        Command.allCases.map { command in
            CommandPaletteCommandContribution(
                commandId: command.rawValue,
                title: { _ in command.title },
                subtitle: { _ in String(localized: "command.slang.subtitle", defaultValue: "SystemVerilog") },
                keywords: command.keywords,
                when: { $0.bool(CommandPaletteContextKeys.panelIsSystemVerilogEditor) }
            )
        }
    }

    @MainActor
    static func registerHandlers(_ registry: inout CommandPaletteHandlerRegistry, focusedPanel: @escaping @MainActor () -> (any Panel)?) {
        for command in Command.allCases {
            registry.register(commandId: command.rawValue) {
                guard let panel = focusedPanel() as? FilePreviewPanel,
                      let editor = (panel.textView as? SavingTextView)?.languageFeatures,
                      editor.linkSession != nil else {
                    NSSound.beep()
                    return
                }
                // Let the palette close and the editor take focus before a menu pops up at its caret.
                DispatchQueue.main.async {
                    run(command, editor: editor)
                }
            }
        }
    }

    @MainActor
    private static func run(_ command: Command, editor: FilePreviewLanguageFeatures) {
        switch command {
        case .switchProfile: editor.showSlangMenu(atCaret: true)
        case .setCurrentFileAsTop: SlangCompilationActions.setCurrentFileAsTop(editor: editor)
        case .exploreMode: SlangCompilationActions.exploreMode(editor: editor)
        case .editProfiles: SlangCompilationActions.editProfiles(editor: editor)
        case .restartLanguageServer: SlangCompilationActions.restartLanguageServer(editor: editor)
        }
    }
}
