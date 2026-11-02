import CmuxSyntaxHighlighting
import Foundation

/// The host side of opening a file from a terminal link or `cmux open`, in
/// one ssh run: try each candidate spelling in order (`~` expanded on the
/// host), and for the first regular readable file print one header line,
/// then stream its bytes.
///
/// It replaces one ssh run per spelling (each failing spelling cost a full
/// round trip), a separate `$HOME` lookup for `~` and, for `cmux open`, a
/// separate `stat` before the download. The header names the host path and
/// its stamp, so the preview knows the remote file it shows and can save
/// back with the same conflict check the Files panel uses.
///
/// Output: anything a login shell prints first, then
/// `cmux-probe:<index> <mtime> <size> <base64 path>\n`, then the file.
/// Exit 0 found, ``noFileStatus`` when no spelling is a regular file,
/// ``tooLargeStatus`` (header only) when a capped probe's file is too big.
enum RemoteFileProbe {
    struct Header: Equatable, Sendable {
        /// Which candidate named the file.
        var index: Int
        /// The host path read, `~` expanded.
        var path: String
        var modificationTime: Int64
        var size: Int64
    }

    enum Failure: Error, Equatable {
        /// No candidate is a regular readable file.
        case noFile
        /// The file is larger than the cap; nothing of it was sent.
        case tooLarge
        /// No header line: not this script's output.
        case malformedOutput
    }

    static let noFileStatus: Int32 = 3
    static let tooLargeStatus: Int32 = 4
    static let marker = "cmux-probe:"

    /// The POSIX `sh` script. Candidates travel base64-encoded, so no path
    /// byte reaches the shell's parser.
    static func script(candidates: [String], maxBytes: Int64?) -> String {
        let words = candidates.map { Data($0.utf8).base64EncodedString() }
        guard !words.isEmpty else { return "exit \(noFileStatus)" }
        let header = #"printf '\#(marker)%s %s %s %s\n' "$i" "$1" "$2" "$(printf %s "$p" | base64 | tr -d '\n')""#
        let send: String
        if let maxBytes {
            let cap = max(0, maxBytes)
            send = "[ \"$2\" -le \(cap) ] || { \(header); exit \(tooLargeStatus); }; \(header); exec head -c \(cap + 1) < \"$p\""
        } else {
            send = "\(header); exec cat < \"$p\""
        }
        return [
            #"st() { stat -L -c "%Y %s" -- "$1" 2>/dev/null || stat -L -f "%m %z" -- "$1" 2>/dev/null; }"#,
            #"dec() { printf %s "$1" | base64 -d 2>/dev/null || printf %s "$1" | base64 -D 2>/dev/null; }"#,
            "i=0",
            "for e in \(words.joined(separator: " ")); do",
            #"  if p=$(dec "$e") && [ -n "$p" ]; then"#,
            #"    case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac"#,
            #"    if [ -f "$p" ] && [ -r "$p" ] && s=$(st "$p"); then"#,
            "      set -- $s",
            "      \(send)",
            "    fi",
            "  fi",
            "  i=$((i + 1))",
            "done",
            "exit \(noFileStatus)",
        ].joined(separator: "\n")
    }

    /// The command for ssh: ``script(candidates:maxBytes:)`` wrapped so any
    /// login shell (sh, bash, zsh, csh/tcsh, fish) runs it the same way.
    static func command(candidates: [String], maxBytes: Int64?) -> String {
        SlangWorkspaceRoot.posixShellCommand(script(candidates: candidates, maxBytes: maxBytes))
    }

    /// Reads the header out of `raw` (the probe's stdout) and writes the file
    /// bytes after it to `destination`.
    static func extract(from raw: URL, to destination: URL) throws -> Header {
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        let window = try input.read(upToCount: 1 << 20) ?? Data()
        let (header, contentStart) = try parseHeader(in: window)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(contentStart))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        return header
    }

    /// The header line of a probe's output, and the offset of the file bytes.
    static func parseHeader(in data: Data) throws -> (Header, Int) {
        let marker = Data(Self.marker.utf8)
        var searchFrom = data.startIndex
        while let found = data.range(of: marker, in: searchFrom..<data.endIndex) {
            // Only at the start of a line: banners end with a newline.
            if found.lowerBound == data.startIndex || data[found.lowerBound - 1] == 0x0A {
                guard let end = data[found.upperBound...].firstIndex(of: 0x0A),
                      let line = String(data: data[found.upperBound..<end], encoding: .utf8) else { break }
                let fields = line.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count == 4,
                      let index = Int(fields[0]), index >= 0,
                      let modificationTime = Int64(fields[1]),
                      let size = Int64(fields[2]),
                      let pathData = Data(base64Encoded: String(fields[3])),
                      let path = String(data: pathData, encoding: .utf8), path.hasPrefix("/") else { break }
                return (Header(index: index, path: path, modificationTime: modificationTime, size: size),
                        end + 1 - data.startIndex)
            }
            searchFrom = found.upperBound
        }
        throw Failure.malformedOutput
    }
}

/// What decides how a terminal link or `cmux open` download opens, kept
/// free of app types so it can be tested on its own.
enum RemotePreviewOpenRules {
    /// The directory a click's relative links resolve against: the shell's
    /// live directory when the terminal can report it (`live`, a cmux-tui
    /// process query), else the last reported one. A cmux-tui terminal's
    /// snapshot `cwd` is its spawn directory and stays stale after a `cd`.
    /// Nothing is asked when no link is relative.
    static func workingDirectory(
        needsDirectory: Bool,
        live: @Sendable () async -> String?,
        snapshot: String?
    ) async -> String? {
        guard needsDirectory else { return snapshot }
        if let live = await live(), live.hasPrefix("/") { return live }
        return snapshot
    }

    /// How a finished download opens, or nil when it is dropped. It is
    /// dropped only when its source is gone: the workspace was closed, or
    /// the terminal or its connection changed. Focus moves to the preview
    /// only while the user is still on the source terminal in the key
    /// window; a download that lands after they moved on (a few hundred ms
    /// to seconds) opens beside it without taking their keystrokes, and one
    /// whose workspace was left opens there, unfocused, with a notification.
    static func placement(
        isSelected: Bool,
        isRetired: Bool,
        sourceUnchanged: Bool,
        configurationUnchanged: Bool,
        sourceIsFocused: Bool,
        windowIsKey: Bool
    ) -> RemotePreviewPlacement? {
        guard !isRetired, sourceUnchanged, configurationUnchanged else { return nil }
        guard isSelected else { return .unfocusedInAnotherWorkspace }
        return sourceIsFocused && windowIsKey ? .focused : .unfocused
    }

    /// Runs `prepare` (an await, such as moving the download into the
    /// lease cache) and returns its value with the placement that holds
    /// after it, so the open never uses a gate read before the await.
    @MainActor
    static func openAfter<Value>(
        _ prepare: @MainActor () async -> Value?,
        placement: @MainActor () -> RemotePreviewPlacement?
    ) async -> (Value, RemotePreviewPlacement)? {
        guard let value = await prepare(), let after = placement() else { return nil }
        return (value, after)
    }

    /// Which leased viewer a ⌘-clicked host file opens in, or nil when no
    /// cmux viewer takes it. Every clicked file opens in the native preview
    /// under a lease, like `cmux open` and the Files panel, so the header
    /// names the host path and Save writes to the host. Markdown starts on
    /// its rendered view when Markdown routing is on (the Markdown viewer
    /// reads a local file and could only show the cache copy). HTML opens as
    /// its source: a host page is never loaded as a local web page.
    static func clickViewer(
        isMarkdown: Bool,
        routesMarkdown: Bool,
        routesSupportedFile: Bool
    ) -> RemoteClickViewer? {
        if isMarkdown && routesMarkdown { return .renderedMarkdown }
        return routesSupportedFile ? .source : nil
    }
}

/// Where a finished download opens relative to the user's focus.
enum RemotePreviewPlacement: Equatable, Sendable {
    /// The user is still on the source terminal in the key window: the preview takes focus.
    case focused
    /// The workspace is on screen but the user moved on: open beside the terminal, keep focus where it is.
    case unfocused
    /// Another workspace is selected: open unfocused in the source workspace and say so in a notification.
    case unfocusedInAnotherWorkspace

    /// Whether the open moves keyboard focus to the preview. Every remote
    /// open reads this: a download, an already-open file `cmux open` shows
    /// again, and a dump the waveform viewer reads in place.
    var takesFocus: Bool { self == .focused }

    /// Whether the open posts an "Opened … in …" notification: it landed
    /// in a workspace that isn't on screen.
    var announcesOpen: Bool { self == .unfocusedInAnotherWorkspace }
}

/// The leased viewer of a ⌘-clicked host file.
enum RemoteClickViewer: Equatable, Sendable {
    /// The editable source in the native file preview.
    case source
    /// The native file preview on its rendered Markdown view.
    case renderedMarkdown
}
