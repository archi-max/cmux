import Foundation

/// Parses the output of ``SSHFileSearchCommand/contentSearch(query:rootPath:remoteTimeoutSeconds:watchdog:)``.
///
/// The first line is the tool marker; ripgrep lines are `--json` events and grep
/// lines are `<path>NUL<line>:<text>`. Lines without a NUL in grep mode, such as
/// an old grep's `Binary file x matches`, are ignored.
struct SSHFileSearchLineParser: Sendable {
    enum Format: Equatable, Sendable {
        case unknown
        case ripgrep
        case grep
    }

    /// Previews are cut to the width the local search asks ripgrep for.
    static let maxPreviewCharacters = 300

    let rootPath: String
    let query: String
    private(set) var format: Format = .unknown

    init(rootPath: String, query: String) {
        self.rootPath = rootPath
        self.query = query
    }

    /// Parses one output line without its trailing newline.
    mutating func parse(line: Data) -> FileSearchResult? {
        switch format {
        case .unknown:
            // A suffix match tolerates a banner printed without a newline.
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix(SSHFileSearchCommand.ripgrepMarker) {
                format = .ripgrep
            } else if text.hasSuffix(SSHFileSearchCommand.grepMarker) {
                format = .grep
            }
            return nil
        case .ripgrep:
            guard let result = FileSearchRipgrepParser.parseMatchLine(
                String(decoding: line, as: UTF8.self),
                rootPath: rootPath
            ) else {
                return nil
            }
            return FileSearchResult(
                path: result.path,
                relativePath: Self.remoteRelativePath(result.path, rootPath: rootPath),
                lineNumber: result.lineNumber,
                columnNumber: result.columnNumber,
                preview: Self.clippedPreview(result.preview)
            )
        case .grep:
            return parseGrepLine(line)
        }
    }

    private func parseGrepLine(_ line: Data) -> FileSearchResult? {
        guard let nul = line.firstIndex(of: 0) else { return nil }
        let pathData = line[line.startIndex..<nul]
        let rest = line[line.index(after: nul)...]
        guard !pathData.isEmpty,
              let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let numberText = String(decoding: rest[rest.startIndex..<colon], as: UTF8.self)
        guard let lineNumber = Int(numberText), lineNumber > 0 else { return nil }
        let lineBytes = rest[rest.index(after: colon)...]
        let lineText = String(decoding: lineBytes, as: UTF8.self)
        let path = String(decoding: pathData, as: UTF8.self)
        return FileSearchResult(
            path: path,
            relativePath: Self.remoteRelativePath(path, rootPath: rootPath),
            lineNumber: lineNumber,
            columnNumber: Self.columnNumber(of: query, in: lineText),
            preview: Self.clippedPreview(lineText.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    /// One-based UTF-8 byte column of the first match, like ripgrep's submatch start.
    static func columnNumber(of query: String, in lineText: String) -> Int {
        let options: String.CompareOptions = SSHFileSearchCommand.isCaseInsensitive(query: query)
            ? [.caseInsensitive]
            : []
        guard !query.isEmpty, let range = lineText.range(of: query, options: options) else { return 1 }
        return lineText.utf8.distance(from: lineText.startIndex, to: range.lowerBound) + 1
    }

    /// Path relative to the remote root. Remote paths are not standardized
    /// against this Mac's filesystem (no `/private` rewrites or symlink checks).
    static func remoteRelativePath(_ path: String, rootPath: String) -> String {
        var root = rootPath
        while root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        if path == root { return "." }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private static func clippedPreview(_ text: String) -> String {
        guard text.count > maxPreviewCharacters else { return text }
        return String(text.prefix(maxPreviewCharacters)) + "\u{2026}"
    }
}

/// Collects streamed SSH search output into ``FileSearchPipelineUpdate`` values.
///
/// It caps results at `maxResults` (asking the caller to stop ssh), throttles
/// intermediate snapshots, and maps the remote exit status to a final state.
struct SSHFileSearchAccumulator: Sendable {
    private var parser: SSHFileSearchLineParser
    private let maxResults: Int
    private let snapshotInterval: TimeInterval
    /// Longer lines (a minified file through grep) are skipped, not buffered.
    static let maxLineBytes = 1 << 20

    private var buffer = Data()
    /// Bytes of `buffer` already known to hold no newline.
    private var scannedBytes = 0
    private var skippingLongLine = false
    private var stderrBuffer = Data()
    private(set) var results: [FileSearchResult] = []
    private var lastEmission = Date.distantPast
    private var terminalUpdate: FileSearchPipelineUpdate?
    private(set) var didTimeOut = false

    init(rootPath: String, query: String, maxResults: Int, snapshotInterval: TimeInterval) {
        parser = SSHFileSearchLineParser(rootPath: rootPath, query: query)
        self.maxResults = max(1, maxResults)
        self.snapshotInterval = snapshotInterval
    }

    var format: SSHFileSearchLineParser.Format { parser.format }

    /// Consumes a stdout chunk; a partial last line waits for the next chunk.
    mutating func consume(_ data: Data, now: Date = Date()) -> FileSearchPipelineUpdate? {
        guard terminalUpdate == nil else { return nil }
        buffer.append(data)
        var changed = false
        var lineStart = buffer.startIndex
        var searchFrom = buffer.startIndex + scannedBytes
        while let newline = buffer[searchFrom...].firstIndex(of: 10) {
            defer {
                lineStart = buffer.index(after: newline)
                searchFrom = lineStart
            }
            if skippingLongLine {
                skippingLongLine = false
                continue
            }
            guard let result = parser.parse(line: Data(buffer[lineStart..<newline])) else { continue }
            if let update = append(result) { return update }
            changed = true
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)
        if buffer.count > Self.maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
            skippingLongLine = true
        }
        scannedBytes = buffer.count
        guard changed, now.timeIntervalSince(lastEmission) >= snapshotInterval else { return nil }
        lastEmission = now
        return FileSearchPipelineUpdate(results: results, status: .searching, isSearching: true, shouldStopProcess: false)
    }

    /// Adds a result; at the cap, returns the terminal "limited" update.
    private mutating func append(_ result: FileSearchResult) -> FileSearchPipelineUpdate? {
        results.append(result)
        guard results.count >= maxResults else { return nil }
        let update = FileSearchPipelineUpdate(
            results: results,
            status: .limited(maxResults),
            isSearching: false,
            shouldStopProcess: true
        )
        terminalUpdate = update
        return update
    }

    mutating func consumeStderr(_ data: Data) {
        guard terminalUpdate == nil else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeSubrange(0..<(stderrBuffer.count - 8_192))
        }
    }

    /// Records that the local deadline passed; ``finish(status:)`` then reports a timeout.
    mutating func markTimedOut() {
        didTimeOut = true
    }

    /// The final state after ssh exits with `status`.
    mutating func finish(status: Int32) -> FileSearchPipelineUpdate {
        if let terminalUpdate { return terminalUpdate }
        if !buffer.isEmpty, !skippingLongLine {
            let line = buffer
            buffer.removeAll()
            if let result = parser.parse(line: line), let update = append(result) { return update }
        }
        let finalStatus = finalStatus(for: status)
        let update = FileSearchPipelineUpdate(
            results: results,
            status: finalStatus,
            isSearching: false,
            shouldStopProcess: false
        )
        terminalUpdate = update
        return update
    }

    private func finalStatus(for status: Int32) -> FileSearchSnapshot.Status {
        if didTimeOut || status == SSHFileSearchCommand.remoteTimeoutStatus {
            return .failed(SSHFileSearchMessages.timedOut)
        }
        let diagnosis = SSHRemoteStderr.diagnosis(
            String(decoding: stderrBuffer, as: UTF8.self),
            toolRan: parser.format != .unknown
        )
        let toolRan = parser.format != .unknown
        switch status {
        case 0 where toolRan, 1 where toolRan:
            return results.isEmpty ? .noMatches : .matches
        case 0, 1:
            // A shell that exits cleanly without the marker never ran the search.
            return .failed(SSHFileSearchMessages.didNotRun)
        case SSHRemoteShellScript.decodeFailedStatus:
            return .failed(SSHFileSearchMessages.decodeFailed)
        case 2 where toolRan && (!results.isEmpty || diagnosis == nil):
            // Unreadable files make rg and grep exit 2 even when others matched.
            return results.isEmpty ? .noMatches : .matches
        case SSHFileSearchCommand.missingRootStatus:
            return .failed(SSHFileSearchMessages.folderNotFound)
        default:
            return .failed(diagnosis ?? SSHFileSearchMessages.exited(status: status))
        }
    }
}

/// Picks the stderr lines worth showing from a remote command.
///
/// A login shell's rc files may print warnings on every ssh command (EWS's
/// ~/.bashrc does), so once the tool has started only lines the tools
/// themselves write are kept. Before that, everything is ssh's diagnosis.
enum SSHRemoteStderr {
    static let toolPrefixes = [
        "rg:", "grep:", "find:", "git:", "fatal:", "error:", "timeout:", "nice:", "sh:", "base64:",
        "ssh:", "client_loop:", "Connection ", "kex_exchange_identification:", "Host key verification failed",
    ]

    /// The text to report, or nil when nothing relevant was printed.
    static func diagnosis(_ stderr: String, toolRan: Bool) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let toolLines = lines.filter { line in toolPrefixes.contains { line.hasPrefix($0) } }
        if !toolLines.isEmpty { return toolLines.joined(separator: "\n") }
        guard !toolRan, !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

enum SSHFileSearchMessages {
    static var timedOut: String {
        String(localized: "fileExplorer.search.sshTimedOut", defaultValue: "The host took too long to answer")
    }

    static var didNotRun: String {
        String(localized: "fileExplorer.search.sshDidNotRun", defaultValue: "The host’s shell did not run the search")
    }

    static var decodeFailed: String {
        String(localized: "fileExplorer.search.sshDecodeFailed", defaultValue: "The host has no working base64 command")
    }

    static var folderNotFound: String {
        String(localized: "fileExplorer.search.sshFolderNotFound", defaultValue: "Folder not found on the host")
    }

    static func exited(status: Int32) -> String {
        // An exit code, not a count, so it is formatted as text.
        String(
            format: String(
                localized: "fileExplorer.search.sshExited",
                defaultValue: "Remote search failed (exit status %@)"
            ),
            String(status)
        )
    }
}
