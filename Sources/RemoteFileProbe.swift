import CmuxSyntaxHighlighting
import Foundation

/// PLACEHOLDER (red commit): the one-round-trip probe follows in the fix.
enum RemoteFileProbe {
    struct Header: Equatable, Sendable {
        var index: Int
        var path: String
        var modificationTime: Int64
        var size: Int64
    }

    enum Failure: Error, Equatable {
        case noFile
        case tooLarge
        case malformedOutput
    }

    static let noFileStatus: Int32 = 3
    static let tooLargeStatus: Int32 = 4

    static func script(candidates: [String], maxBytes: Int64?) -> String { "exit 3" }

    static func command(candidates: [String], maxBytes: Int64?) -> String {
        SlangWorkspaceRoot.posixShellCommand(script(candidates: candidates, maxBytes: maxBytes))
    }

    static func extract(from raw: URL, to destination: URL) throws -> Header {
        throw Failure.malformedOutput
    }
}

/// PLACEHOLDER (red commit).
enum RemotePreviewOpenRules {
    static func workingDirectory(
        needsDirectory: Bool,
        live: @Sendable () async -> String?,
        snapshot: String?
    ) async -> String? {
        snapshot
    }

    static func downloadMayOpen(
        isSelected: Bool,
        isRetired: Bool,
        sourceUnchanged: Bool,
        configurationUnchanged: Bool,
        sourceIsFocused: Bool,
        windowIsKey: Bool
    ) -> Bool {
        isSelected && !isRetired && sourceUnchanged && configurationUnchanged && sourceIsFocused && windowIsKey
    }
}
