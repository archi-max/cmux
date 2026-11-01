// Stand-ins for the app types WaveformDebuggerAsmBreakpoints.swift talks to, so the real file runs
// here on real (windowless) NSTextViews. Each records what it was asked; main.swift sets what it answers.
import AppKit

@MainActor final class FilePreviewWaveformSession {
    var calls: [(function: String, argument: [String: Any])] = []
    /// What the page answers, by function.
    var answers: [String: Any] = [:]
    func callDebugger(_ function: String, argument: Any? = nil) async -> Any? {
        calls.append((function, argument as? [String: Any] ?? [:]))
        return answers[function]
    }
}

@MainActor final class NativeViewSessions { let waveform = FilePreviewWaveformSession() }

@MainActor final class FilePreviewPanel {
    enum PreviewMode { case text, waveform }
    var workspaceId: UUID
    let filePath: String
    var isClosed = false
    var previewMode: PreviewMode
    let nativeViewSessions = NativeViewSessions()
    init(workspaceId: UUID, filePath: String, previewMode: PreviewMode = .waveform) {
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.previewMode = previewMode
    }
}

final class SavingTextView: NSTextView {
    var panel: FilePreviewPanel?
}

@MainActor final class Workspace { var panels: [UUID: Any] = [:] }

@MainActor final class AppDelegate {
    static var shared: AppDelegate? = AppDelegate()
    var focused: SavingTextView?
    var workspaces: [UUID: Workspace] = [:]
    func shortcutFocusedSavingTextView(in window: NSWindow?) -> SavingTextView? { focused }
    func workspaceFor(tabId: UUID) -> Workspace? { workspaces[tabId] }
}

@MainActor final class FilePreviewLineNumberGutterView {
    enum BreakpointMark { case enabled, conditional, disabled, lost }
}

/// The prompt of WaveformDebuggerEvaluate (the real one needs the app).
@MainActor enum WaveformDebuggerEvaluate {
    static var prompted: [String?] = []
    static var promptAnswer: String?
    static func promptCondition(current: String?, for label: String, window: NSWindow?) -> String? {
        prompted.append(current)
        return promptAnswer
    }
}
