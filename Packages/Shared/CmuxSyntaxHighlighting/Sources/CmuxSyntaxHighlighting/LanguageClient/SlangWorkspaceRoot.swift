import Foundation

/// Picks the folder slang-server should treat as a SystemVerilog file's
/// workspace root when the user has not pinned one: the nearest ancestor with
/// `.slang/server.json` (so its config and build file apply), else the nearest
/// with `.git` (a folder, or a file in a worktree), else the file's folder.
/// The home folder and top-level folders (`/tmp`, `/home`) never count:
/// `~/.slang/server.json` is slang's per-user config, a stray `/tmp/.git`
/// exists on shared hosts, and such a workspace would index everything.
///
/// Remote hosts are probed with one shell command (`probeCommand`) whose
/// output `parseProbe` reads.
public enum SlangWorkspaceRoot {
    public struct Markers: Equatable, Sendable {
        /// Folders that hold `.slang/server.json`.
        public var config: Set<String> = []
        /// Folders that hold `.git`.
        public var git: Set<String> = []
        /// The host's home folder, when known.
        public var home: String?

        public init(config: Set<String> = [], git: Set<String> = [], home: String? = nil) {
            self.config = config
            self.git = git
            self.home = home
        }
    }

    /// The file's folder, then each parent up to (not including) `/`.
    public static func ancestors(ofFile path: String) -> [String] {
        var folders: [String] = []
        var folder = (standardized(path) as NSString).deletingLastPathComponent
        while !folder.isEmpty, folder != "/" {
            folders.append(folder)
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder { break }
            folder = parent
        }
        return folders
    }

    /// The root for `filePath` from `markers`; nil when no ancestor has either marker.
    public static func root(forFile filePath: String, markers: Markers) -> String? {
        let home = markers.home.map(standardized)
        let candidates = ancestors(ofFile: filePath).filter {
            $0 != home && $0.split(separator: "/").count >= 2
        }
        return candidates.first(where: markers.config.contains) ?? candidates.first(where: markers.git.contains)
    }

    /// Reads the markers of `filePath`'s ancestors from the local disk.
    public static func localMarkers(forFile filePath: String, home: String = NSHomeDirectory()) -> Markers {
        var markers = Markers(home: home)
        let manager = FileManager.default
        for folder in ancestors(ofFile: filePath) {
            if manager.fileExists(atPath: folder + "/.slang/server.json") { markers.config.insert(folder) }
            if manager.fileExists(atPath: folder + "/.git") { markers.git.insert(folder) }
        }
        return markers
    }

    /// A POSIX shell command printing `H <home>`, then `S <folder>` for each
    /// ancestor with `.slang/server.json` and `G <folder>` for each with `.git`.
    public static func probeCommand(forFile filePath: String) -> String {
        let words = ancestors(ofFile: filePath).map(shellQuote).joined(separator: " ")
        return posixShellCommand("printf 'H %s\\n' \"$HOME\"; for d in \(words); do "
            + "[ -e \"$d/.slang/server.json\" ] && printf 'S %s\\n' \"$d\"; "
            + "[ -e \"$d/.git\" ] && printf 'G %s\\n' \"$d\"; "
            + "done; true")
    }

    /// `script` (POSIX `sh`) as a command any login shell runs the same way: sh, bash, zsh,
    /// csh/tcsh or fish. The script travels base64-encoded inside single quotes, which none of
    /// them expand, and `sh` decodes and runs it with the command's stdin.
    public static func posixShellCommand(_ script: String) -> String {
        // Already a wrapper (of a probe or listing): the same command, not one wrapped twice.
        let prefix = "sh -c 'eval \"$(printf %s "
        if script.hasPrefix(prefix),
           let end = script.dropFirst(prefix.count).firstIndex(of: " "),
           let decoded = Data(base64Encoded: String(script[script.index(script.startIndex, offsetBy: prefix.count)..<end])),
           let inner = String(data: decoded, encoding: .utf8),
           wrap(inner) == script {
            return script
        }
        return wrap(script)
    }

    private static func wrap(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        // GNU and BusyBox take -d, older macOS -D.
        return "sh -c 'eval \"$(printf %s \(encoded) | base64 -d 2>/dev/null || printf %s \(encoded) | base64 -D)\"'"
    }

    public static func parseProbe(_ output: String) -> Markers {
        var markers = Markers()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.count > 2, line.dropFirst().first == " " else { continue }
            let value = String(line.dropFirst(2))
            switch line.first {
            case "H": markers.home = value
            case "S": markers.config.insert(value)
            case "G": markers.git.insert(value)
            default: break
            }
        }
        return markers
    }

    /// Collapses `//`, `/./` and a trailing `/` (no symlink or `/private` rewriting: paths may be remote).
    private static func standardized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
