import Foundation

/// A zero-based position in a text document.
///
/// `character` counts UTF-16 code units, which is the LSP default position
/// encoding and matches `NSString` offsets.
public struct LSPPosition: Sendable, Equatable, Hashable {
    /// Zero-based line number.
    public var line: Int
    /// Zero-based UTF-16 offset within the line.
    public var character: Int

    /// Creates a position.
    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A half-open range between two positions in a text document.
public struct LSPRange: Sendable, Equatable, Hashable {
    /// Inclusive start position.
    public var start: LSPPosition
    /// Exclusive end position.
    public var end: LSPPosition

    /// Creates a range.
    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// A range inside a specific document.
public struct LSPLocation: Sendable, Equatable {
    /// Document URI. For remote (ssh) servers this is a `file://` URL of a remote path.
    public var uri: URL
    /// Range inside the document.
    public var range: LSPRange

    /// Creates a location.
    public init(uri: URL, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// Severity of a published diagnostic.
public enum LSPDiagnosticSeverity: Int, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

/// One diagnostic (lint error, warning, ...) reported by a language server.
public struct LSPDiagnostic: Sendable, Equatable {
    /// Range the diagnostic applies to.
    public var range: LSPRange
    /// Severity; servers that omit it are treated as `.error`.
    public var severity: LSPDiagnosticSeverity
    /// Human-readable message.
    public var message: String
    /// Diagnostic code, stringified when the server sends a number.
    public var code: String?
    /// Producer of the diagnostic, such as `"slang"`.
    public var source: String?

    /// Creates a diagnostic.
    public init(
        range: LSPRange,
        severity: LSPDiagnosticSeverity,
        message: String,
        code: String? = nil,
        source: String? = nil
    ) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
        self.source = source
    }
}

/// One completion candidate.
public struct LSPCompletionItem: Sendable, Equatable {
    /// Text shown in the completion list.
    public var label: String
    /// Extra detail such as a type signature.
    public var detail: String?
    /// Text to insert; falls back to `textEdit.newText` from the server. `nil` means insert `label`.
    public var insertText: String?
    /// Raw LSP `CompletionItemKind` value.
    public var kind: Int?

    /// Creates a completion item.
    public init(label: String, detail: String? = nil, insertText: String? = nil, kind: Int? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.kind = kind
    }
}

/// Errors thrown by `LanguageServerSession` and `LanguageServerPool`.
public enum LanguageServerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The session has not been started, or its process has exited.
    case notRunning
    /// Language servers cannot be launched on this platform (iOS).
    case unsupportedPlatform
    /// The process could not be spawned.
    case launchFailed(String)
    /// The request did not get a response in time.
    case timeout(method: String)
    /// The server answered with a JSON-RPC error.
    case responseError(code: Int, message: String)
    /// The process exited while the request was pending. `stderr` holds its last lines.
    case processExited(status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .notRunning:
            return "Language server is not running"
        case .unsupportedPlatform:
            return "Language servers are not supported on this platform"
        case .launchFailed(let message):
            return "Failed to launch language server: \(message)"
        case .timeout(let method):
            return "Language server request \(method) timed out"
        case .responseError(let code, let message):
            return "Language server error \(code): \(message)"
        case .processExited(let status, let stderr):
            return "Language server exited with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        }
    }
}
