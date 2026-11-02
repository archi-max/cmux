// Stand-ins for the app types WaveformDebuggerLineBreakpoints.swift talks to, so the real file
// runs here on real (windowless) NSTextViews. Each records what it was asked; main.swift sets
// what it answers.
import AppKit

@MainActor final class FilePreviewWaveformSession {
    var calls: [(function: String, argument: [String: Any])] = []
    /// What the page does while it handles a call, before it replies (posts to cmux, say).
    var onCall: ((String) -> Void)?
    func callDebugger(_ function: String, argument: Any? = nil) async -> Any? {
        calls.append((function, argument as? [String: Any] ?? [:]))
        onCall?(function)
        return nil
    }
}

@MainActor final class NativeViewSessions { let waveform = FilePreviewWaveformSession() }

@MainActor final class FilePreviewPanel {
    var workspaceId: UUID
    let filePath: String
    let nativeViewSessions = NativeViewSessions()
    init(workspaceId: UUID, filePath: String = "/w/a.vcd") {
        self.workspaceId = workspaceId
        self.filePath = filePath
    }
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
    /// A file too large to scan: no line (as FilePreviewLanguageFeatures past backgroundScanThreshold).
    var tooLargeToScan = false
    func breakpointLine(at offset: Int) -> SystemVerilogInlineScan.Line? {
        guard !tooLargeToScan else { return nil }
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
    enum BreakpointMark { case enabled, conditional, disabled, lost }
}

/// The prompt of WaveformDebuggerEvaluate (the real one needs the app).
@MainActor enum WaveformDebuggerEvaluate {
    /// The condition prompt: what it was shown, what it answers (nil: cancelled).
    static var prompted: [String?] = []
    static var promptAnswer: String?
    static func promptCondition(current: String?, for label: String, window: NSWindow?) -> String? {
        prompted.append(current)
        return promptAnswer
    }
}
