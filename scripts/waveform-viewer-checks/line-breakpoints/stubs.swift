// Stand-ins for the app types WaveformDebuggerLineBreakpoints.swift talks to, so the real file
// runs here on real (windowless) NSTextViews. Each records what it was asked; main.swift sets
// what it answers.
import AppKit

@MainActor final class FilePreviewWaveformSession {
    var calls: [(function: String, argument: [String: Any])] = []
    func callDebugger(_ function: String, argument: Any? = nil) async -> Any? {
        calls.append((function, argument as? [String: Any] ?? [:]))
        return nil
    }
}

@MainActor final class NativeViewSessions { let waveform = FilePreviewWaveformSession() }

@MainActor final class FilePreviewPanel {
    var workspaceId: UUID
    let nativeViewSessions = NativeViewSessions()
    init(workspaceId: UUID) { self.workspaceId = workspaceId }
}

final class SavingTextView: NSTextView {
    var languageFeatures: FilePreviewLanguageFeatures?
}

@MainActor final class FilePreviewLanguageFeatures {
    static var all: [FilePreviewLanguageFeatures] = []
    let textView: SavingTextView
    let filePath: String
    var linkWorkspaceId: UUID?
    var linkPanel: FilePreviewPanel?
    /// module -> (shown, all)
    var instances: [String: (shown: String?, all: [String])] = [:]
    init(textView: SavingTextView, path: String, workspace: UUID) {
        self.textView = textView
        filePath = path
        linkWorkspaceId = workspace
        textView.languageFeatures = self
    }
    static func isSupported(filePath: String) -> Bool { filePath.hasSuffix(".sv") }
    static func linkables(inWorkspace workspaceId: UUID) -> [FilePreviewLanguageFeatures] { all.filter { $0.linkWorkspaceId == workspaceId } }
    var debuggerTextView: NSTextView? { textView }
    func breakpointInstances(ofModule module: String) -> (shown: String?, all: [String]) { instances[module] ?? (nil, []) }
    func breakpointLine(at offset: Int) -> SystemVerilogInlineScan.Line? {
        let text = textView.string
        return SystemVerilogInlineScan.lines(in: text, range: NSRange(location: offset, length: 0)).first
    }
}

@MainActor enum WaveformSourceLink {
    static var waveform: FilePreviewPanel?
    static func waveformPanel(near panel: FilePreviewPanel?) -> FilePreviewPanel? { waveform }
}

@MainActor final class AppDelegate {
    static var shared: AppDelegate? = AppDelegate()
    var focused: SavingTextView?
    func shortcutFocusedSavingTextView(in window: NSWindow?) -> SavingTextView? { focused }
}

@MainActor final class FilePreviewLineNumberGutterView {
    enum BreakpointMark { case enabled, disabled, lost }
}
