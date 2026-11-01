import Foundation

/// A read-only remote command for Find in Files and Go to File on an SSH workspace.
///
/// Scripts are built with ``SSHRemoteShellScript``, so bash, zsh, fish and
/// csh/tcsh login shells all pass them to `sh` unchanged. The query, the root
/// and the `!` of every negated glob travel base64-encoded and are decoded by
/// the remote `sh`, which also keeps non-ASCII text in NFC (`Process` would
/// otherwise decompose it).
///
/// A marker line names the tool that ran (``ripgrepMarker``, ``gitGrepMarker`` or ``grepMarker``;
/// ``gitListMarker`` or ``findListMarker``). Anything a login shell prints
/// before it is ignored, and output without it means the tool never ran.
struct SSHFileSearchCommand: Equatable, Sendable {
    static let ripgrepMarker = "cmux-search:rg"
    static let grepMarker = "cmux-search:grep"
    static let gitGrepMarker = "cmux-search:gitgrep"
    static let gitListMarker = "cmux-files:git"
    static let findListMarker = "cmux-files:find"
    /// Exit status when the root is not a readable directory on the host.
    static let missingRootStatus: Int32 = 66
    /// Exit status of coreutils `timeout` when the remote deadline passes.
    static let remoteTimeoutStatus: Int32 = 124

    /// Directories the local search excludes with its `!**/<name>/**` globs.
    static let excludedDirectoryNames = [".git", "node_modules", "dist", "build", "DerivedData"]
    /// Also skipped by the plain grep fallback, which has no .gitignore to
    /// leave out virtualenvs and caches (rg and git grep honour it).
    static let grepOnlyExcludedDirectoryNames = [".venv", "venv", "__pycache__", ".cache"]

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

    /// True only in a work tree: in a bare repository or inside `.git`,
    /// rev-parse prints `false` and still exits 0.
    private static let insideWorkTree = "[ \"$($g rev-parse --is-inside-work-tree 2>/dev/null)\" = true ]"

    /// Prints the marker on a line of its own, even after a login shell's
    /// unterminated banner.
    private static func marker(_ text: String) -> String {
        "echo; echo \(text)"
    }

    /// Searches file contents under `rootPath` for the literal `query`.
    ///
    /// Uses `rg --json` when the host has ripgrep, with the local search's
    /// options. Without it, a root inside a Git work tree is searched with
    /// `git grep` (tracked and untracked files, minus ignored ones, as rg
    /// would: a gitignored virtualenv must not fill the result cap), run
    /// from the root with the same hardening as ``fileList`` and with user
    /// config that would change its output (color, full names, columns)
    /// turned off. A root that is itself ignored (even one holding tracked
    /// files, which rg searches when given that folder but git grep skips), or
    /// that holds a submodule or a nested repository (which git grep treats as
    /// one opaque entry), is searched with grep instead. Elsewhere GNU/BSD `grep -rnIF --null`, which skips binary
    /// files and separates the path with a NUL so colons in names stay
    /// unambiguous.
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
        // grep's --exclude-dir also skips a command-line directory with that name,
        // so a root such as .venv or build would search nothing: drop its own name.
        let rootName = rootPath.split(separator: "/").last.map(String.init)
        let excludeDirs = (excludedDirectoryNames + grepOnlyExcludedDirectoryNames)
            .filter { $0 != rootName }
            .map { "--exclude-dir=\($0)" }.joined(separator: " ")
        // git grep never searches .git itself.
        let excludePathspecs = excludedDirectoryNames.filter { $0 != ".git" }
            .map { "\":(exclude,glob)**/\($0)/**\"" }.joined(separator: " ")
        return Self(lines: [
            SSHRemoteShellScript.assign("q", query),
            SSHRemoteShellScript.assign("r", rootPath),
            SSHRemoteShellScript.assign("x", "!"),
            // tr's NUL and newline escapes: the script itself never holds a backslash.
            SSHRemoteShellScript.assign("z", "\\000"),
            SSHRemoteShellScript.assign("l", "\\n"),
            "[ -d \"$r\" ] || exit \(missingRootStatus)",
            SSHRemoteShellScript.timeoutPrefix(seconds: remoteTimeoutSeconds),
            "g=\"git -c core.fsmonitor= -c core.untrackedCache=false\"",
            "if command -v rg >/dev/null 2>&1; then \(marker(ripgrepMarker)); "
                + "printf %s \"$q\" | $w nice -n 10 rg --json --line-number --column --smart-case --fixed-strings "
                + "--max-columns 300 --max-columns-preview --color never --hidden --line-buffered "
                + "\(globs) --file - -- \"$r\"; "
                + "elif command -v git >/dev/null 2>&1 && cd -- \"$r\" 2>/dev/null && \(insideWorkTree) "
                // An ignored root, or a submodule or nested repository below it:
                // git grep wouldn't look inside them, so grep searches.
                // --no-index: a root .gitignore lists still counts as ignored when
                // it holds tracked files, which git grep --exclude-standard skips too.
                + "&& [ -z \"$($g check-ignore --no-index . 2>/dev/null)\" ] "
                + "&& [ -z \"$(nice -n 10 $g ls-files -s -- . 2>/dev/null | LC_ALL=C grep ^160000 | head -n 1)\" ] "
                // -z: git quotes names with a quote, a backslash or a control characters otherwise,
                // so a nested repository's line would not end in /.
                // LC_ALL=C: in a UTF-8 locale GNU grep prints nothing for a line that
                // isn't valid UTF-8 (a Latin-1 name) and BSD tr stops at it, so that entry would be missed.
                + "&& [ -z \"$(nice -n 10 $g ls-files -z -o --exclude-standard -- . 2>/dev/null "
                + "| LC_ALL=C tr \"$z\" \"$l\" | LC_ALL=C grep /$ | head -n 1)\" ]; then \(marker(gitGrepMarker)); "
                + "$w nice -n 10 $g -c color.grep=false -c grep.fullName=false -c grep.column=false "
                + "grep -nIF -z --untracked --exclude-standard\(caseFlag) -e \"$q\" -- . \(excludePathspecs); "
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
    ///
    /// The tool is `exec`ed so stopping the shell stops it too. Git runs
    /// with `core.fsmonitor` (empty: off on every version) and the untracked cache off: a folder's own
    /// `.git/config` must not get to run a hook just because it was listed.
    /// - Parameter watchdog: Only for ssh; never for a listing run on this Mac.
    static func fileList(rootPath: String, maxDepth: Int, remoteTimeoutSeconds: Int, watchdog: Bool) -> Self {
        let prunes = excludedDirectoryNames.map { "-type d -name \($0) -prune -o" }.joined(separator: " ")
        return Self(lines: [
            SSHRemoteShellScript.assign("r", rootPath),
            "cd -- \"$r\" 2>/dev/null || exit \(missingRootStatus)",
            SSHRemoteShellScript.timeoutPrefix(seconds: remoteTimeoutSeconds),
            "g=\"git -c core.fsmonitor= -c core.untrackedCache=false\"",
            "if command -v git >/dev/null 2>&1 && \(insideWorkTree); then "
                + "\(marker(gitListMarker)); exec $w nice -n 10 $g ls-files -co --exclude-standard -z; "
                + "else \(marker(findListMarker)); "
                + "exec $w nice -n 10 find . -maxdepth \(max(1, maxDepth)) \(prunes) -type f -print0; fi",
        ], watchdog: watchdog)
    }
}
