public import Foundation

/// A host path a terminal link may name, with the editor location it carried.
public struct RemoteFileReference: Equatable, Sendable {
    /// An absolute host path, or `~`/`~/…` for the host to expand.
    public var path: String
    /// The 1-based line of a `path:line[:column]` link.
    public var line: Int?
    /// The 1-based column of a `path:line:column` link.
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// Builds remote path candidates without consulting the local filesystem or home directory.
public struct RemoteTerminalPathResolver: Sendable {
    /// Creates a remote terminal path resolver.
    public init() {}

    /// Extracts candidate spellings at the clicked column using the terminal's shared token rules.
    /// - Parameters:
    ///   - line: The visible terminal line.
    ///   - column: The zero-based character column under the pointer.
    /// - Returns: Candidate tokens in preferred order.
    public func tokens(in line: String, column: Int) -> [String] {
        line.pathTokenCandidates(containingColumn: column)
    }

    /// Reports whether a token can name a file rather than a web or custom-scheme URL.
    /// - Parameter token: A terminal token or explicit file URL.
    /// - Returns: Whether the token is a path or file URL.
    public func isFileReference(_ token: String) -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\0"), !token.contains("\n"), !token.contains("\r") else { return false }
        guard let scheme = URL(string: token.unquotedShellToken() ?? token)?.scheme else { return true }
        return scheme.lowercased() == "file"
    }

    /// Whether a ⌘-clicked token can name a file: a path, a file URL, or a
    /// name with an editor location. Foundation reads `alu.sv:42` as a URL
    /// with the scheme `alu.sv`; with its `:line` dropped it is a plain name.
    public func isClickedFileCandidate(_ token: String) -> Bool {
        if isFileReference(token) { return true }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.pathResolutionCandidates().contains { spelling in
            guard let location = Self.locationSuffix(of: spelling) else { return false }
            return isFileReference(location.path)
        }
    }

    /// Whether resolving `tokens` needs the terminal's working directory.
    public func needsWorkingDirectory(tokens: [String]) -> Bool {
        tokens.contains { raw in
            raw.pathResolutionCandidates().contains { spelling in
                let token = plainToken(spelling, remoteHost: "") ?? spelling
                return !token.hasPrefix("/") && !token.hasPrefix("~")
            }
        }
    }

    /// Candidate host paths for `tokens`, in probe order, each with the editor
    /// location its spelling carried.
    ///
    /// Every spelling is tried as written first (a file may really be named
    /// `report:42`), then without a trailing `:line` or `:line:column`.
    /// Candidates retain `..` because collapsing it locally changes the meaning
    /// of remote symlinks; the caller verifies them on the host, in order.
    /// Named-user tildes are unsupported; `~` always means the authenticated
    /// remote user's home.
    /// - Parameters:
    ///   - tokens: Candidate terminal tokens or file URLs.
    ///   - workingDirectory: The source terminal's remote directory, when known.
    ///   - homeDirectory: The home reported by the SSH connection, when known.
    ///   - remoteHost: The configured SSH host, used to validate explicit file URL authorities.
    ///   - expandsHomeOnHost: Without a known home, keep `~` and `~/…` for the
    ///     host to expand (in the same round trip as the download).
    public func references(
        tokens: [String],
        workingDirectory: String?,
        homeDirectory: String?,
        remoteHost: String,
        expandsHomeOnHost: Bool = false
    ) -> [RemoteFileReference] {
        var references: [RemoteFileReference] = []
        func append(_ token: String, line: Int?, column: Int?) {
            guard !token.isEmpty else { return }
            let path: String
            if token == "~" || token.hasPrefix("~/") {
                if let homeDirectory, homeDirectory.hasPrefix("/") {
                    path = token == "~" ? homeDirectory : homeDirectory
                        + (homeDirectory.hasSuffix("/") ? "" : "/") + String(token.dropFirst(2))
                } else if expandsHomeOnHost {
                    path = token
                } else {
                    return
                }
            } else if token.hasPrefix("~") {
                return
            } else if token.hasPrefix("/") {
                path = token
            } else {
                guard let workingDirectory, workingDirectory.hasPrefix("/") else { return }
                path = workingDirectory + (workingDirectory.hasSuffix("/") ? "" : "/") + token
            }
            guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
                  !references.contains(where: { $0.path == path }) else { return }
            references.append(RemoteFileReference(path: path, line: line, column: column))
        }
        for raw in tokens where isClickedFileCandidate(raw) {
            for spelling in raw.pathResolutionCandidates() {
                guard let token = plainToken(spelling, remoteHost: remoteHost) else { continue }
                append(token, line: nil, column: nil)
                if let location = Self.locationSuffix(of: token),
                   let path = plainToken(location.path, remoteHost: remoteHost) {
                    append(path, line: location.line, column: location.column)
                }
            }
        }
        return references
    }

    /// Resolves candidate spellings using only remote directory metadata:
    /// ``references(tokens:workingDirectory:homeDirectory:remoteHost:expandsHomeOnHost:)``
    /// without the locations.
    public func candidates(
        tokens: [String],
        workingDirectory: String?,
        homeDirectory: String?,
        remoteHost: String
    ) -> [String] {
        references(
            tokens: tokens, workingDirectory: workingDirectory, homeDirectory: homeDirectory, remoteHost: remoteHost
        ).map(\.path)
    }

    /// A spelling as a host path token: a file URL's path (when its authority
    /// is this host), the spelling itself when it isn't a URL or is a name
    /// with a location (`alu.sv:42`), nil for any other URL.
    private func plainToken(_ spelling: String, remoteHost: String) -> String? {
        guard let url = URL(string: spelling), let scheme = url.scheme else { return spelling }
        guard scheme.lowercased() == "file" else {
            guard let location = Self.locationSuffix(of: spelling),
                  URL(string: location.path)?.scheme == nil else { return nil }
            return spelling
        }
        guard url.user == nil, url.password == nil, url.port == nil,
              url.host == nil || url.host?.isEmpty == true ||
                url.host?.lowercased() == "localhost" ||
                url.host?.lowercased() == remoteHost.lowercased() else { return nil }
        return url.path
    }

    /// A positive trailing `:line` or `:line:column`, as the local resolver reads it.
    static func locationSuffix(of token: String) -> (path: String, line: Int, column: Int?)? {
        func positive(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.allSatisfy(\.isASCII), let value = Int(text), value > 0 else { return nil }
            return value
        }
        guard let lastColon = token.lastIndex(of: ":"),
              let last = positive(token[token.index(after: lastColon)...]) else { return nil }
        let head = token[..<lastColon]
        if let lineColon = head.lastIndex(of: ":"), let line = positive(head[head.index(after: lineColon)...]) {
            let path = String(head[..<lineColon])
            return path.isEmpty ? nil : (path, line, last)
        }
        return head.isEmpty ? nil : (String(head), last, nil)
    }
}
