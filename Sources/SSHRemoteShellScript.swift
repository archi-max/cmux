import Foundation

/// Builds a command line that runs a POSIX `sh` script on an SSH host,
/// whatever the user's login shell is (bash, zsh, fish, csh/tcsh).
///
/// The script goes inside single quotes after `sh -c`, so it must never
/// contain `'`, `\`, `!` or a newline: those are the characters that some
/// login shell still interprets inside single quotes. Values such as paths
/// and queries are passed with ``assign(_:_:)``, which base64-encodes them;
/// the remote `sh` decodes them, so quotes, `$`, a leading `-` and non-ASCII
/// (NFC) text arrive unchanged.
enum SSHRemoteShellScript {
    /// Exit status when a value can't be decoded on the host (no usable base64).
    static let decodeFailedStatus: Int32 = 65

    /// `sh -c '<lines joined by "; ">'`.
    ///
    /// With `watchdog`, the script first starts a background reader on the
    /// ssh channel's stdin. When the client goes away (a cancelled search
    /// terminates ssh, which closes the channel), the reader sees EOF and
    /// kills the script's process group, so `rg`, `grep`, `git` or `find`
    /// stop at once instead of running until their next write. sshd starts
    /// each command in its own session, so the group is only this command.
    /// A body line that runs a command in the background would be killed too.
    /// The client must keep ssh's stdin open (a pipe it never writes to).
    /// Never use the watchdog for a command run locally on this Mac.
    static func command(lines: [String], watchdog: Bool = false) -> String {
        var all = [decoder]
        if watchdog {
            // `$!` is off limits (csh expands `!`), so the reader isn't
            // stopped on normal completion. It has no stdout or stderr, so it
            // doesn't hold the session open; when sshd closes the channel it
            // sees EOF and its `kill 0` finds an otherwise empty group.
            all += [
                "exec 3<&0",
                // "& ;" is a syntax error, so the next statement shares the line.
                "{ cat >/dev/null 2>&1; kill 0; } <&3 >/dev/null 2>&1 & exec 3<&- 0</dev/null",
            ]
        }
        all += lines
        let script = all.joined(separator: "; ")
        precondition(
            !script.contains("'") && !script.contains("\\") && !script.contains("!") && !script.contains("\n"),
            "SSH scripts must stay literal inside single quotes in every login shell"
        )
        return "sh -c '\(script)'"
    }

    /// Sets `variable` to `value`, exiting with ``decodeFailedStatus`` if it can't be decoded.
    static func assign(_ variable: String, _ value: String) -> String {
        let encoded = Data(value.utf8).base64EncodedString()
        return "\(variable)=$(d \(encoded)); [ -n \"$\(variable)\" ] || exit \(decodeFailedStatus)"
    }

    /// GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
    /// -D is the older macOS short flag.
    static let decoder = "d() { "
        + ["--decode", "-d", "-D"]
            .map { "printf %s \"$1\" | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        + "; }"

    /// Sets `w` to a coreutils or BusyBox `timeout` prefix, or empty when the host has none.
    ///
    /// GNU `timeout` puts its child in a process group of its own unless
    /// given `--foreground`. GNU forwards a SIGTERM to that child, but a
    /// `timeout` that doesn't would hide the tool from the watchdog's
    /// `kill 0`, so the `--foreground` form comes first. BusyBox before 1.30 only accepts
    /// `timeout -t N`.
    static func timeoutPrefix(seconds: Int) -> String {
        let seconds = max(1, seconds)
        return "w=; if timeout --foreground 5 true >/dev/null 2>&1; then w=\"timeout --foreground \(seconds)\"; "
            + "elif timeout 5 true >/dev/null 2>&1; then w=\"timeout \(seconds)\"; "
            + "elif timeout -t 5 true >/dev/null 2>&1; then w=\"timeout -t \(seconds)\"; fi"
    }
}
