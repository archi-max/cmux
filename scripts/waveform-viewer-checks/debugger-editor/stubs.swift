// Stand-ins for the app types WaveformDebuggerEditorHighlights.swift talks to,
// so the real file runs here on a real (windowless) NSTextView. Each records
// what the highlights asked for; main.swift sets what they answer.
import AppKit

enum PreviewMode { case text, waveform }

@MainActor final class FilePreviewWaveformSession {
    /// Marker time -> the posedge before its cycle's (cycleAt's previousTime).
    var previousTimes: [Int64: Int64] = [:]
    /// How long cycleAt takes to answer.
    var delay: UInt64 = 0
    var highlightCalls: [[[String]]] = []
    func callDebugger(_ function: String, argument: Any? = nil) async -> Any? {
        switch function {
        case "cycleAt":
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            let time = ((argument as? [String: Any])?["time"] as? NSNumber)?.int64Value ?? -1
            var cycle: [String: Any] = ["time": time]
            cycle["previousTime"] = previousTimes[time]
            return cycle
        case "highlightRows":
            highlightCalls.append((argument as? [String: Any])?["paths"] as? [[String]] ?? [])
            return highlightCalls.last?.count
        default: return nil
        }
    }
}

@MainActor final class NativeViewSessions { let waveform = FilePreviewWaveformSession() }

@MainActor final class FilePreviewPanel {
    let workspaceId = UUID()
    let nativeViewSessions = NativeViewSessions()
}

final class LanguageServerSession: @unchecked Sendable {
    var cones: [String: [SlangConeEntry]] = [:]
    var failing: Set<String> = []
    var asked: [String] = []
    struct NotCompiled: Error {}
    func slangDriverCone(_ path: String) async throws -> [SlangConeEntry] {
        asked.append(path)
        if failing.contains(path) { throw NotCompiled() }
        return cones[path] ?? []
    }
}

@MainActor final class FilePreviewLanguageFeatures {
    static var all: [FilePreviewLanguageFeatures] = []
    let textView: NSTextView
    let session = LanguageServerSession()
    let path: String
    init(textView: NSTextView, path: String) { self.textView = textView; self.path = path }
    static func linkables(inWorkspace workspaceId: UUID) -> [FilePreviewLanguageFeatures] { all }
    static func linkable(showingDocumentPath path: String, like editor: FilePreviewLanguageFeatures) -> FilePreviewLanguageFeatures? {
        all.first { $0.path == path }
    }
    var linkPanel: FilePreviewPanel? { nil }
    var linkSession: (session: LanguageServerSession, documentURI: URL)? { (session, URL(fileURLWithPath: path)) }
    var debuggerTextView: NSTextView? { textView }
}

@MainActor enum WaveformDebugger {
    static var stepping = true
    static func isStepping(_ waveform: FilePreviewPanel) -> Bool { stepping }
    static func updateLocals(from editor: FilePreviewLanguageFeatures) {}
}

@MainActor enum WaveformSourceLink {
    static var waveform: FilePreviewPanel?
    /// Values per time, by dump path.
    static var values: [Int64: [String: String]] = [:]
    static func waveformPanel(near panel: FilePreviewPanel?) -> FilePreviewPanel? { waveform }
    static func inlineValues(names: [String], dumpInstance: String, waveform: FilePreviewPanel, time: Int64) async -> [String?] {
        names.map { values[time]?[dumpInstance + "." + $0] }
    }
}

/// Like the app's: UTF-16 offsets of LSP positions.
struct FilePreviewLSPLineIndex {
    let starts: [Int]
    init(_ text: String) {
        var starts = [0]
        let units = Array(text.utf16)
        for (i, u) in units.enumerated() where u == 0x0A { starts.append(i + 1) }
        self.starts = starts
    }
    func offset(for position: LSPPosition) -> Int {
        guard starts.indices.contains(position.line) else { return starts.last ?? 0 }
        return starts[position.line] + position.character
    }
}
