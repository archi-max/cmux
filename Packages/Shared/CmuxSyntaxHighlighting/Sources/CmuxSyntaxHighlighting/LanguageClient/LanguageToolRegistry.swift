import Foundation

/// How to start a language server or formatter: a local executable, or a command run over ssh.
public enum LanguageToolLaunch: Sendable, Equatable, Hashable {
    /// Runs `executablePath` directly with `arguments`.
    case local(executablePath: String, arguments: [String])
    /// Runs `/usr/bin/ssh -o BatchMode=yes -T <sshOptions> <destination> <remoteCommand>`.
    ///
    /// `remoteCommand` is interpreted by the remote login shell.
    case ssh(destination: String, sshOptions: [String], remoteCommand: String)

    /// Whether this launch runs on another host, so document paths are remote paths.
    public var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }

    /// Executable and argument vector to spawn locally.
    var commandLine: (executable: String, arguments: [String]) {
        switch self {
        case .local(let executablePath, let arguments):
            return (executablePath, arguments)
        case .ssh(let destination, let sshOptions, let remoteCommand):
            return ("/usr/bin/ssh", ["-o", "BatchMode=yes", "-T"] + sshOptions + [destination, remoteCommand])
        }
    }
}

/// Locates the language server and formatter for a language.
///
/// GUI apps do not inherit the login shell `PATH`, so local lookup searches
/// `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin` before `PATH`.
public enum LanguageToolRegistry {
    /// slang-server for languageId "verilog" (covers .sv/.svh/.v/.vh); nil for other languages or when not found locally.
    /// When remoteDestination is non-nil, returns .ssh(...) that runs `PATH="$HOME/.local/bin:$PATH" exec slang-server` on that host.
    public static func languageServer(forLanguage languageId: String, remoteDestination: String?) -> LanguageToolLaunch? {
        guard languageId == "verilog" else { return nil }
        return tool(named: "slang-server", arguments: [], remoteDestination: remoteDestination)
    }

    /// verible-verilog-format reading stdin (`verible-verilog-format -`) for "verilog"; same local/remote rules.
    ///
    /// Passes `--failsafe_success=false` so syntax errors exit nonzero instead
    /// of echoing the input back with status 0.
    public static func formatter(forLanguage languageId: String, remoteDestination: String?) -> LanguageToolLaunch? {
        guard languageId == "verilog" else { return nil }
        return tool(named: "verible-verilog-format", arguments: ["--failsafe_success=false", "-"], remoteDestination: remoteDestination)
    }

    /// Directories searched, in order, for local executables.
    public static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        var directories = [
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in path.split(separator: ":").map(String.init) where !entry.isEmpty && !directories.contains(entry) {
            directories.append(entry)
        }
        return directories
    }

    /// Returns the first executable named `name` in `searchDirectories`.
    public static func findExecutable(named name: String) -> String? {
        for directory in searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func tool(named name: String, arguments: [String], remoteDestination: String?) -> LanguageToolLaunch? {
        if let remoteDestination {
            let command = (["PATH=\"$HOME/.local/bin:$PATH\"", "exec", name] + arguments).joined(separator: " ")
            return .ssh(destination: remoteDestination, sshOptions: [], remoteCommand: command)
        }
        #if os(macOS)
        guard let path = findExecutable(named: name) else { return nil }
        return .local(executablePath: path, arguments: arguments)
        #else
        return nil
        #endif
    }
}
