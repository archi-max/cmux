import Foundation

/// A read-only remote command for Find in Files and Go to File on an SSH workspace.
///
/// Scripts are built with ``SSHRemoteShellScript``, so bash, zsh, fish and
/// csh/tcsh login shells all pass them to `sh` unchanged. The query, the root
/// and the `!` of every negated glob travel base64-encoded and are decoded by
/// the remote `sh`, which also keeps non-ASCII text in NFC (`Process` would
/// otherwise decompose it).
///
/// A marker line names the tool that ran (``ripgrepMarker`` or ``grepMarker``;
/// ``gitListMarker`` or ``findListMarker``). Anything a login shell prints
/// before it is ignored, and output without it means the tool never ran.
struct SSHFileSearchCommand: Equatable, Sendable {
    static let ripgrepMarker = "cmux-search:rg"
    static let grepMarker = "cmux-search:grep"
    static let gitListMarker = "cmux-files:git"
    static let findListMarker = "cmux-files:find"
    /// Exit status when the root is not a readable directory on the host.
    static let missingRootStatus: Int32 = 66
    /// Exit status of coreutils `timeout` when the remote deadline passes.
    static let remoteTimeoutStatus: Int32 = 124

    /// Directories the local search excludes with its `!**/<name>/**` globs.
    static let excludedDirectoryNames = [".git", "node_modules", "dist", "build", "DerivedData"]

    /// The command line handed to `ssh`, parsed by the remote login shell.
    let command: String

    private init(lines: [String], watchdog: Bool) {
        command = SSHRemoteShellScript.command(lines: lines, watchdog: watchdog)
    }

    /// Whether a query searches case-insensitively, by ripgrep's `--smart-case` rule:
    /// only a query with an uppercase letter is case-sensitive.
    static func isCaseInsensitive(query: String) -> Bool {
        !query.contains { $0.isUppercase }
    }

    /// Prints the marker on a line of its own, even after a login shell's
    /// unterminated banner.
    private static func marker(_ text: String) -> String {
        "echo; echo \(text)"
    }

    /// Searches file contents under `rootPath` for the literal `query`.
    ///
    /// Uses `rg --json` when the host has ripgrep, with the local search's
    /// options; otherwise GNU/BSD `grep -rnIF --null`, which skips binary files
    /// and separates the path with a NUL so colons in names stay unambiguous.
    /// - Parameters:
    ///   - remoteTimeoutSeconds: Passed to `timeout` when the host has it,
    ///     so an abandoned search cannot outlive the client by long.
    ///   - watchdog: Kill the search when ssh's stdin closes; see
    ///     ``SSHRemoteShellScript/command(lines:watchdog:)``.
    static func contentSearch(query: String, rootPath: String, remoteTimeoutSeconds: Int, watchdog: Bool = true) -> Self {
        let caseFlag = isCaseInsensitive(query: query) ? " -i" : ""
        // `${x}`: `$xnode_modules` would name another variable.
        let globs = excludedDirectoryNames
            .flatMap { ["--glob \"${x}\($0)/**\"", "--glob \"${x}**/\($0)/**\""] }
            .joined(separator: " ")
        let excludeDirs = excludedDirectoryNames.map { "--exclude-dir=\($0)" }.joined(separator: " ")
        return Self(lines: [
            SSHRemoteShellScript.assign("q", query),
            SSHRemoteShellScript.assign("r", rootPath),
            SSHRemoteShellScript.assign("x", "!"),
            "[ -d \"$r\" ] || exit \(missingRootStatus)",
            SSHRemoteShellScript.timeoutPrefix(seconds: remoteTimeoutSeconds),
            "if command -v rg >/dev/null 2>&1; then \(marker(ripgrepMarker)); "
                + "printf %s \"$q\" | $w nice -n 10 rg --json --line-number --column --smart-case --fixed-strings "
                + "--max-columns 300 --max-columns-preview --color never --hidden --line-buffered "
                + "\(globs) --file - -- \"$r\"; "
                + "else \(marker(grepMarker)); "
                + "lb=--line-buffered; echo x | grep $lb -q x >/dev/null 2>&1 || lb=; "
                + "$w nice -n 10 grep -rnIsF --null $lb\(caseFlag) \(excludeDirs) -e \"$q\" -- \"$r\"; fi",
        ], watchdog: watchdog)
    }

    /// Lists files under `rootPath` for Go to File, NUL-separated and relative to it.
    ///
    /// Inside a Git work tree this is `git ls-files -co --exclude-standard`
    /// (tracked plus untracked, minus ignored). Elsewhere it is `find` limited
    /// to `maxDepth`, pruning the same directories as Find in Files.
    /// - Parameter watchdog: Only for ssh; never for a listing run on this Mac.
    static func fileList(rootPath: String, maxDepth: Int, remoteTimeoutSeconds: Int, watchdog: Bool) -> Self {
        let prunes = excludedDirectoryNames.map { "-type d -name \($0) -prune -o" }.joined(separator: " ")
        return Self(lines: [
            SSHRemoteShellScript.assign("r", rootPath),
            "cd -- \"$r\" 2>/dev/null || exit \(missingRootStatus)",
            SSHRemoteShellScript.timeoutPrefix(seconds: remoteTimeoutSeconds),
            "if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then "
                + "\(marker(gitListMarker)); $w nice -n 10 git ls-files -co --exclude-standard -z; "
                + "else \(marker(findListMarker)); "
                + "$w nice -n 10 find . -maxdepth \(max(1, maxDepth)) \(prunes) -type f -print0; fi",
        ], watchdog: watchdog)
    }
}
