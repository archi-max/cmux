import Foundation

/// One remote command the SSH file explorer runs to change the filesystem.
///
/// Every command runs its script under `sh -c`, so it behaves the same whatever
/// the user's login shell is (bash, zsh, fish, csh). The script never contains
/// `'`, `\`, `!` or a newline, which keeps it literal inside single quotes in
/// all of those shells. Paths travel base64-encoded and are decoded by the
/// remote `sh`, so names with quotes, `$`, a leading `-` or non-ASCII (NFC)
/// bytes reach the filesystem unchanged.
///
/// Scripts exit with ``alreadyExistsStatus`` when the target name is taken and
/// ``permissionDeniedStatus`` when the parent directory is not writable.
struct SSHFileExplorerMutationCommand: Equatable, Sendable {
    /// Exit status for "an item with that name already exists" (`EX_CANTCREAT`).
    static let alreadyExistsStatus: Int32 = 73
    /// Exit status for "the parent directory is not writable" (`EX_NOPERM`).
    static let permissionDeniedStatus: Int32 = 77
    /// Exit status for "the file changed since its stamp was read" (`EX_TEMPFAIL`).
    static let remoteChangedStatus: Int32 = 75

    /// The command line handed to `ssh`, parsed by the remote login shell.
    let command: String

    private init(script: String) {
        precondition(
            !script.contains("'") && !script.contains("\\") && !script.contains("!") && !script.contains("\n"),
            "SSH mutation scripts must stay literal inside single quotes in every login shell"
        )
        command = "sh -c '\(script)'"
    }

    /// Creates an empty file and never truncates an existing one.
    static func createFile(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            rejectExisting("t"),
            requireWritable("dir"),
            // noclobber makes the redirection itself fail if the file appears
            // between the check above and this line.
            "set -C",
            ": > \"$t\"",
        ].joined(separator: "; "))
    }

    /// Creates a directory; fails if any item already has that name.
    static func createDirectory(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            rejectExisting("t"),
            requireWritable("dir"),
            "mkdir -- \"$t\"",
        ].joined(separator: "; "))
    }

    /// Renames within one directory without replacing an existing item.
    ///
    /// A case-only rename (`Readme.md` to `README.md`) goes through a temporary
    /// name, because on a case-insensitive volume the destination test matches
    /// the source itself.
    /// - Parameter temporaryName: The intermediate name for a case-only rename.
    static func rename(
        path: String,
        to destinationPath: String,
        temporaryName: String = ".cmux-rename-\(UUID().uuidString)"
    ) -> Self {
        let directory = parent(of: path)
        var lines = [
            decoder,
            assign("s", path),
            assign("t", destinationPath),
            assign("dir", directory),
            requireWritable("dir"),
        ]
        if path != destinationPath, path.lowercased() == destinationPath.lowercased() {
            lines += [
                assign("m", (directory as NSString).appendingPathComponent(temporaryName)),
                // The destination may only exist as the source under another case.
                "if \(exists("t")); then [ \"$s\" -ef \"$t\" ] || exit \(alreadyExistsStatus); fi",
                "mv -n -- \"$s\" \"$m\" || exit 1",
                "if \(exists("s")); then exit 1; fi",
                "mv -n -- \"$m\" \"$t\"",
                // Put the item back under its old name if the second step failed.
                "if \(exists("m")); then mv -n -- \"$m\" \"$s\"; exit 1; fi",
            ]
        } else {
            lines += [
                // Without this, a destination directory would receive the source as a child.
                rejectExisting("t"),
                // `mv -n` silently keeps a destination created after the check;
                // the source still being present reports that collision.
                "mv -n -- \"$s\" \"$t\" || exit 1",
                "if \(exists("s")); then exit \(alreadyExistsStatus); fi",
            ]
        }
        return Self(script: lines.joined(separator: "; "))
    }

    /// Permanently removes a file or directory tree.
    static func delete(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            "if \(exists("t")); then :; else exit 74; fi",
            requireWritable("dir"),
            "rm -rf -- \"$t\"",
        ].joined(separator: "; "))
    }

    /// Permanently removes each item in order in one run, with the same checks
    /// and exit statuses as ``delete(path:)``. It stops at the first failure,
    /// and prints ``removedMarker(nonce:)`` with the index of every item it
    /// removed, so a caller knows which are gone when a later one fails.
    ///
    /// `nonce` must be fresh for each run and letters or digits only: login
    /// dotfiles print to the same stdout, and can't guess it.
    static func delete(paths: [String], nonce: String) -> Self {
        precondition(!nonce.isEmpty && nonce.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        return Self(script: ([decoder] + paths.enumerated().flatMap { index, path in deleteSteps(path, index: index, nonce: nonce) })
            .joined(separator: "; "))
    }

    /// The prefix of the line ``delete(paths:nonce:)`` prints after removing `paths[i]`.
    static func removedMarker(nonce: String) -> String { "cmux-removed-\(nonce):" }

    /// The indices ``delete(paths:nonce:)`` reported removed in `output`.
    static func removedIndices(in output: String, nonce: String) -> [Int] {
        let marker = removedMarker(nonce: nonce)
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix(marker) ? Int(line.dropFirst(marker.count)) : nil
        }
    }

    /// `paths` in order, split into runs of at most `maxCount` items whose
    /// ``delete(paths:nonce:)`` command stays within `maxCommandBytes`.
    ///
    /// sshd hands the command to the login shell as one argument, and Linux caps
    /// one argument at 128 KiB, so a count alone can't bound long paths. A
    /// single path over the budget still gets a run of its own.
    static func deleteBatches(_ paths: [String], maxCount: Int = 200, maxCommandBytes: Int = 64 * 1024) -> [[String]] {
        // The fixed cost: `sh -c '...'`, the decoder and a full-length nonce.
        let fixed = delete(paths: [], nonce: String(repeating: "f", count: 32)).command.utf8.count
        var batches: [[String]] = []
        var batch: [String] = []
        var bytes = fixed
        for path in paths {
            let cost = 2 + deleteSteps(path, index: batch.count, nonce: String(repeating: "f", count: 32))
                .reduce(0) { $0 + $1.utf8.count + 2 }
            if !batch.isEmpty, batch.count >= maxCount || bytes + cost > maxCommandBytes {
                batches.append(batch)
                batch = []
                bytes = fixed
            }
            batch.append(path)
            bytes += cost
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private static func deleteSteps(_ path: String, index: Int, nonce: String) -> [String] {
        [
            assign("t", path),
            assign("dir", parent(of: path)),
            "if \(exists("t")); then :; else exit 74; fi",
            requireWritable("dir"),
            "rm -rf -- \"$t\" || exit 1",
            "echo \(removedMarker(nonce: nonce))\(index)",
        ]
    }

    /// Copies a file or directory tree to a destination that must not exist.
    static func copy(path: String, to destinationPath: String) -> Self {
        Self(script: [
            decoder,
            assign("s", path),
            assign("t", destinationPath),
            assign("dir", parent(of: destinationPath)),
            // `cp -R` into an existing directory would nest the copy inside it.
            rejectExisting("t"),
            requireWritable("dir"),
            "cp -R -p -- \"$s\" \"$t\"",
        ].joined(separator: "; "))
    }

    /// Prints a regular file's modification time and size as `<mtime> <size>`.
    static func fileStamp(path: String) -> Self {
        Self(script: [
            decoder,
            statHelpers,
            assign("t", path),
            "[ -f \"$t\" ] || exit 74",
            "st \"$t\"",
        ].joined(separator: "; "))
    }

    /// Replaces a file's contents with stdin, then prints its new stamp.
    ///
    /// The data goes to a temporary file in the same directory that is renamed
    /// over the target, so readers never see a partial file; the target's mode
    /// is copied first. A symlink is written through to the file it names.
    /// When `expectedStamp` is set and the file's stamp differs, or the file is
    /// gone, nothing is written and the script exits with ``remoteChangedStatus``.
    static func writeFile(path: String, expectedStamp: SSHRemoteFileStamp?) -> Self {
        Self(script: [
            decoder,
            statHelpers,
            assign("t", path),
            "if [ -L \"$t\" ]; then t=$(readlink -f -- \"$t\"); [ -n \"$t\" ] || exit 1; fi",
            "dir=$(dirname -- \"$t\")",
            "e=\"\(expectedStamp?.statOutput ?? "")\"",
            "m=",
            "if [ -e \"$t\" ]; then [ -f \"$t\" ] || exit 1; [ -w \"$t\" ] || exit \(permissionDeniedStatus); "
                + "c=$(st \"$t\") || exit 1; if [ -n \"$e\" ]; then [ \"$c\" = \"$e\" ] || exit \(remoteChangedStatus); fi; "
                + "m=$(md \"$t\") || exit 1; "
                + "elif [ -n \"$e\" ]; then exit \(remoteChangedStatus); "
                + "else m=$(printf %o $(( 0666 & ~0$(umask) ))); fi",
            // A read-only directory still allows rewriting a writable file in place.
            "if [ -w \"$dir\" ]; then tmp=$(mktemp \"$dir/.cmux-save.XXXXXX\") || exit 1; "
                + "if cat > \"$tmp\" && chmod \"$m\" \"$tmp\" && mv -f -- \"$tmp\" \"$t\"; then :; "
                + "else rm -f -- \"$tmp\"; exit 1; fi; "
                + "elif [ -e \"$t\" ]; then cat > \"$t\" || exit 1; "
                + "else exit \(permissionDeniedStatus); fi",
            "st \"$t\"",
        ].joined(separator: "; "))
    }

    /// `st` prints `<mtime> <size>` and `md` the octal mode, with GNU `stat`
    /// first and BSD `stat` as the fallback.
    private static let statHelpers = "st() { stat -L -c \"%Y %s\" -- \"$1\" 2>/dev/null || stat -L -f \"%m %z\" -- \"$1\"; }; "
        + "md() { stat -L -c %a -- \"$1\" 2>/dev/null || stat -L -f %Lp -- \"$1\"; }"

    /// GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
    /// -D is the older macOS short flag.
    private static let decoder = "d() { "
        + ["--decode", "-d", "-D"]
            .map { "printf %s \"$1\" | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        + "; }"

    private static func assign(_ variable: String, _ path: String) -> String {
        let encoded = Data(path.utf8).base64EncodedString()
        // `$(...)` drops trailing newlines, which can be part of a name; the
        // sentinel dot keeps them and is stripped after.
        return "\(variable)=$(d \(encoded); echo .); \(variable)=${\(variable)%.}; [ -n \"$\(variable)\" ] || exit 1"
    }

    private static func exists(_ variable: String) -> String {
        "[ -e \"$\(variable)\" ] || [ -L \"$\(variable)\" ]"
    }

    private static func rejectExisting(_ variable: String) -> String {
        "if \(exists(variable)); then exit \(alreadyExistsStatus); fi"
    }

    private static func requireWritable(_ variable: String) -> String {
        "[ -w \"$\(variable)\" ] || exit \(permissionDeniedStatus)"
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
