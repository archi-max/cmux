// Stand-ins for the app types WaveformEnumLink.swift talks to, so the real file runs here:
// a language server session that answers scope reads as main.swift scripts them, and
// recorders for the editors' refreshes. Nothing here draws or opens a window.
import Foundation

@MainActor final class LanguageServerSession {
    /// What the next scope reads answer.
    var answer: Result<[String: SlangEnumSignal], Error> = .success([:])
    /// Scope reads asked, in order.
    var reads: [String] = []
    func slangEnumSignals(inScope hierPath: String, cache: SlangEnumTypeCache,
                          maxMemberHovers: Int = SlangEnumValues.defaultMaxMemberHovers) async throws -> [String: SlangEnumSignal] {
        reads.append(hierPath)
        try await Task.sleep(for: .milliseconds(20))
        return try answer.get()
    }
    /// Clean buffers reloaded from disk, in order (their texts).
    var reloads: [String] = []
    func reloadedFromDisk(uri: URL, text: String, version: Int) async { reloads.append(text) }
}

@MainActor enum FilePreviewLanguageFeatures {
    static var refreshes = 0
    static func enumTypesMayHaveChanged(session: LanguageServerSession) { refreshes += 1 }
}

@MainActor final class FilePreviewWaveformSession {
    func callEnums(_ function: String, argument: Any? = nil) async -> Any? { nil }
}

@MainActor final class NativeViewSessions { let waveform = FilePreviewWaveformSession() }

@MainActor final class FilePreviewPanel { let nativeViewSessions = NativeViewSessions() }

@MainActor enum WaveformSourceLink {
    static func dumpPath(fromPage value: Any?) -> [String]? { value as? [String] }
    static func designLookup(for waveform: FilePreviewPanel) async -> (session: LanguageServerSession, mapping: HierarchyPathMapping)? { nil }
}
