import Foundation

/// A read-only remote command for Find in Files and Go to File on an SSH workspace.
///
/// Built like ``SSHFileExplorerMutationCommand``: the script runs under `sh -c`
/// inside single quotes and never contains `'`, `\`, `!` or a newline, so bash,
/// zsh, fish and csh/tcsh login shells all pass it to `sh` unchanged. The query,
/// the root and every `!`-prefixed glob travel base64-encoded and are decoded by
/// the remote `sh`, which also keeps non-ASCII text in NFC (`Process` would
/// otherwise decompose it).
///
/// The first output line names the tool that ran (``ripgrepMarker`` or
/// ``grepMarker``; ``gitListMarker`` or ``findListMarker``), so the parser
/// knows the format of the rest.
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

    private init(lines: [String]) {
        let script = lines.joined(separator: "; ")
        precondition(
            !script.contains("'") && !script.contains("\\") && !script.contains("!") && !script.contains("\n"),
            "SSH search scripts must stay literal inside single quotes in every login shell"
        )
        command = "sh -c '\(script)'"
    }

    /// Whether a query searches case-insensitively, by ripgrep's `--smart-case` rule:
    /// only a query with an uppercase letter is case-sensitive.
    static func isCaseInsensitive(query: String) -> Bool {
        !query.contains { $0.isUppercase }
    }

    /// Searches file contents under `rootPath` for the literal `query`.
    ///
    /// Uses `rg --json` when the host has ripgrep, with the local search's
    /// options; otherwise GNU/BSD `grep -rnIF --null`, which skips binary files
    /// and separates the path with a NUL so colons in names stay unambiguous.
    /// - Parameter remoteTimeoutSeconds: Passed to `timeout` when the host has it,
    ///   so an abandoned search cannot outlive the client by long.
    static func contentSearch(query: String, rootPath: String, remoteTimeoutSeconds: Int, watchdog: Bool = true) -> Self {
        let caseFlag = isCaseInsensitive(query: query) ? " -i" : ""
        let globs = excludedDirectoryNames
            .flatMap { ["--glob \"${x}\($0)/**\"", "--glob \"${x}**/\($0)/**\""] }
            .joined(separator: " ")
        let excludeDirs = excludedDirectoryNames.map { "--exclude-dir=\($0)" }.joined(separator: " ")
        return Self(lines: [
            decoder,
            assign("q", query),
            assign("r", rootPath),
            assign("x", "!"),
            "[ -d \"$r\" ] || exit \(missingRootStatus)",
            timeoutPrefix(seconds: remoteTimeoutSeconds),
            "if command -v rg >/dev/null 2>&1; then echo \(ripgrepMarker); "
                + "printf %s \"$q\" | $w nice -n 10 rg --json --line-number --column --smart-case --fixed-strings "
                + "--max-columns 300 --max-columns-preview --color never --hidden --line-buffered "
                + "\(globs) --file - -- \"$r\"; "
                + "else echo \(grepMarker); "
                + "lb=--line-buffered; echo x | grep $lb -q x >/dev/null 2>&1 || lb=; "
                + "$w nice -n 10 grep -rnIsF --null $lb\(caseFlag) \(excludeDirs) -e \"$q\" -- \"$r\"; fi",
        ])
    }

    /// Lists files under `rootPath` for Go to File, NUL-separated and relative to it.
    ///
    /// Inside a Git work tree this is `git ls-files -co --exclude-standard`
    /// (tracked plus untracked, minus ignored). Elsewhere it is `find` limited
    /// to `maxDepth`, pruning the same directories as Find in Files.
    static func fileList(rootPath: String, maxDepth: Int, remoteTimeoutSeconds: Int, watchdog: Bool) -> Self {
        let prunes = excludedDirectoryNames.map { "-name \($0) -prune -o" }.joined(separator: " ")
        return Self(lines: [
            decoder,
            assign("r", rootPath),
            "cd -- \"$r\" 2>/dev/null || exit \(missingRootStatus)",
            timeoutPrefix(seconds: remoteTimeoutSeconds),
            "if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then "
                + "echo \(gitListMarker); $w nice -n 10 git ls-files -co --exclude-standard -z; "
                + "else echo \(findListMarker); "
                + "$w nice -n 10 find . -maxdepth \(max(1, maxDepth)) \(prunes) -type f -print0; fi",
        ])
    }

    /// Sets `w` to a `timeout` prefix when the host has coreutils `timeout`.
    private static func timeoutPrefix(seconds: Int) -> String {
        "w=; if command -v timeout >/dev/null 2>&1; then w=\"timeout \(max(1, seconds))\"; fi"
    }

    /// GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
    /// -D is the older macOS short flag.
    private static let decoder = "d() { "
        + ["--decode", "-d", "-D"]
            .map { "printf %s \"$1\" | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        + "; }"

    private static func assign(_ variable: String, _ value: String) -> String {
        let encoded = Data(value.utf8).base64EncodedString()
        return "\(variable)=$(d \(encoded)); [ -n \"$\(variable)\" ] || exit 2"
    }
}
