import Foundation

/// What a slang `.f` build file (command file) says, as far as cmux needs:
/// its top modules (`--top`), source files and nested command files.
/// Options cmux does not use are skipped with their values.
public struct SlangBuildFile: Equatable, Sendable {
    public var tops: [String] = []
    /// Source files as written (relative ones resolve against `baseDirectory`).
    public var sources: [String] = []
    /// Nested `-f` / `-F` command files as written.
    public var commandFiles: [String] = []

    public init(tops: [String] = [], sources: [String] = [], commandFiles: [String] = []) {
        self.tops = tops
        self.sources = sources
        self.commandFiles = commandFiles
    }

    /// Options whose value is the next word (slang's driver options cmux skips).
    private static let optionsWithValue: Set<String> = [
        "--top", "-top", "-f", "-F", "-C", "-I", "--include-directory", "--isystem", "-D", "--define-macro",
        "-U", "--undefine-macro", "-y", "--libdir", "-Y", "--libext", "-v", "--libfile", "-G", "-T",
        "--timing", "--timescale", "--std", "--compat", "-W", "--max-errors", "--error-limit", "-j", "--threads",
        "--suppress-warnings", "--suppress-macro-warnings", "--translate-off-format", "-L", "--defaultLibName",
        "--map-keyword-version", "--max-include-depth", "--max-parse-depth", "--max-lexer-errors",
    ]

    public static func parse(_ text: String) -> SlangBuildFile {
        var result = SlangBuildFile()
        let words = self.words(in: text)
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word.hasPrefix("+") { continue } // +define+, +incdir+, +libext+
            if let equals = word.firstIndex(of: "="), word.hasPrefix("-") {
                let option = String(word[..<equals])
                let value = String(word[word.index(after: equals)...])
                if option == "--top" || option == "-top" { result.tops.append(value) }
                if option == "-f" || option == "-F" { result.commandFiles.append(value) }
                continue
            }
            if word.hasPrefix("-") {
                guard optionsWithValue.contains(word), index < words.count else { continue }
                let value = words[index]
                index += 1
                if word == "--top" || word == "-top" { result.tops.append(value) }
                if word == "-f" || word == "-F" { result.commandFiles.append(value) }
                continue
            }
            result.sources.append(word)
        }
        return result
    }

    /// Source files (absolute, resolved against `baseDirectory`) that are not under `root`:
    /// a build file of another checkout or worktree.
    public func sources(outside root: String, baseDirectory: String) -> [String] {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return sources.compactMap { source in
            let absolute = source.hasPrefix("/") ? source : (baseDirectory as NSString).appendingPathComponent(source)
            let path = (absolute as NSString).standardizingPath
            return path.hasPrefix(prefix) || path == root ? nil : path
        }
    }

    /// Words of a command file: `//`, `#` and `/* */` comments dropped, quotes grouping words,
    /// a backslash escaping the next character (so `\"` stays a quote inside a define).
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var quote: Character?
        var chars = Array(text)
        chars.append("\n")
        var index = 0
        func finish() {
            if hasWord { words.append(current) }
            current = ""
            hasWord = false
        }
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if let open = quote {
                if char == "\\", let next { current.append(next); index += 2; continue }
                if char == open { quote = nil } else { current.append(char) }
                index += 1
                continue
            }
            if (char == "/" && next == "/") || (char == "#" && !hasWord) {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                finish()
                continue
            }
            if char == "/", next == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
                finish()
                continue
            }
            if char.isWhitespace {
                finish()
                index += 1
                continue
            }
            if char == "\\", let next {
                // A backslash at the end of a line continues it.
                if next == "\n" || next == "\r" || next == "\r\n" {
                    finish()
                    index += 2
                    continue
                }
                current.append(next)
                hasWord = true
                index += 2
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                hasWord = true
                index += 1
                continue
            }
            current.append(char)
            hasWord = true
            index += 1
        }
        return words
    }
}

/// A `.f` build file offered as a slang-server profile.
public struct SlangProfile: Equatable, Sendable {
    /// Path on the host (remote for SSH workspaces).
    public var path: String
    public var buildFile: SlangBuildFile

    public init(path: String, buildFile: SlangBuildFile) {
        self.path = path
        self.buildFile = buildFile
    }

    /// The file name without `.f`.
    public var name: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// Where profiles live and how to find them: `<root>/.slang/*.f`,
/// `~/.config/cmux-slang/<project>/*.f` and `~/.config/cmux-slang/<project>.f`
/// (`<project>` is the root folder's name), plus `.f` files in the workspace
/// a few levels deep (slang-server's own default build pattern takes every
/// `.f`). A remote host is listed with one shell command.
public enum SlangProfileCatalog {
    /// Workspace `.f` files are looked for this deep, and at most this many are listed.
    public static let workspaceSearchDepth = 4
    public static let workspaceSearchLimit = 40
    /// Bytes read of each `.f`.
    public static let readLimit = 65536

    public static func projectName(ofRoot root: String) -> String {
        (root as NSString).lastPathComponent
    }

    /// The user's profile folder for the project, under the host's home.
    public static func userProfileDirectory(root: String, home: String) -> String {
        (home as NSString).appendingPathComponent(".config/cmux-slang/" + projectName(ofRoot: root))
    }

    public static func repoProfileDirectory(root: String) -> String {
        (root as NSString).appendingPathComponent(".slang")
    }

    private static let marker = "@@cmux-slang-"

    /// A POSIX shell command printing each profile and the root's `.slang/server.json` and
    /// `.slang/local/server.json` (their first `readLimit` bytes), each after a
    /// `@@cmux-slang-profile <path>` or `@@cmux-slang-config <path>` line.
    public static func listingCommand(root: String) -> String {
        let quotedRoot = SlangWorkspaceRoot.shellQuote(root)
        let project = SlangWorkspaceRoot.shellQuote(projectName(ofRoot: root))
        return SlangWorkspaceRoot.posixShellCommand("r=\(quotedRoot); p=\(project); "
            + "{ for f in \"$r\"/.slang/*.f \"$HOME/.config/cmux-slang/$p\"/*.f \"$HOME/.config/cmux-slang/$p.f\"; do [ -f \"$f\" ] && printf '%s\\n' \"$f\"; done; "
            + "find \"$r\" -mindepth 1 -maxdepth \(workspaceSearchDepth) \\( -name '.*' -o -name node_modules \\) -prune -o -type f -name '*.f' -print 2>/dev/null | head -n \(workspaceSearchLimit); } "
            + "| awk '!seen[$0]++' | while IFS= read -r f; do printf '\\n\(marker)profile %s\\n' \"$f\"; head -c \(readLimit) \"$f\"; done; "
            + "for f in \"$r/.slang/server.json\" \"$r/.slang/local/server.json\"; do [ -f \"$f\" ] && { printf '\\n\(marker)config %s\\n' \"$f\"; head -c \(readLimit) \"$f\"; }; done; true")
    }

    /// What `listingCommand` printed: the profiles, and the config files with their text.
    public struct Listing: Equatable, Sendable {
        public var profiles: [SlangProfile] = []
        public var configs: [SlangServerConfigFile.Found] = []

        public init(profiles: [SlangProfile] = [], configs: [SlangServerConfigFile.Found] = []) {
            self.profiles = profiles
            self.configs = configs
        }
    }

    public static func parseListing(_ output: String) -> Listing {
        var listing = Listing()
        let separator = "\n" + marker
        var rest = Substring("\n" + output)
        while let start = rest.range(of: separator) {
            rest = rest[start.upperBound...]
            let headerEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            let header = rest[..<headerEnd]
            rest = headerEnd < rest.endIndex ? rest[rest.index(after: headerEnd)...] : ""
            let bodyEnd = rest.range(of: separator)?.lowerBound ?? rest.endIndex
            let body = String(rest[..<bodyEnd])
            rest = rest[bodyEnd...]
            guard let space = header.firstIndex(of: " ") else { continue }
            let path = String(header[header.index(after: space)...])
            switch header[..<space] {
            case "profile": listing.profiles.append(SlangProfile(path: path, buildFile: SlangBuildFile.parse(body)))
            case "config": listing.configs.append(.init(path: path, health: SlangServerConfigFile.health(of: Data(body.utf8))))
            default: break
            }
        }
        return listing
    }

    /// The same listing from the local disk.
    public static func localListing(root: String, home: String = NSHomeDirectory()) -> Listing {
        let configs = [SlangServerConfigFile.path(inWorkspace: root, relativePath: ".slang/server.json"), SlangServerConfigFile.path(inWorkspace: root)]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { SlangServerConfigFile.Found(path: $0, health: SlangServerConfigFile.health(of: FileManager.default.contents(atPath: $0))) }
        return Listing(profiles: localProfiles(root: root, home: home), configs: configs)
    }

    static func localProfiles(root: String, home: String) -> [SlangProfile] {
        let manager = FileManager.default
        var paths: [String] = []
        func add(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            if !paths.contains(standardized) { paths.append(standardized) }
        }
        for directory in [repoProfileDirectory(root: root), userProfileDirectory(root: root, home: home)] {
            for name in ((try? manager.contentsOfDirectory(atPath: directory)) ?? []).sorted() where name.hasSuffix(".f") {
                add((directory as NSString).appendingPathComponent(name))
            }
        }
        let single = userProfileDirectory(root: root, home: home) + ".f"
        if manager.fileExists(atPath: single) { add(single) }
        var found = 0
        if let enumerator = manager.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if enumerator.level > workspaceSearchDepth || url.lastPathComponent == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "f", found < workspaceSearchLimit else { continue }
                found += 1
                add(url.path)
            }
        }
        return paths.compactMap { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: readLimit)) ?? Data()
            return SlangProfile(path: path, buildFile: SlangBuildFile.parse(String(decoding: data, as: UTF8.self)))
        }
    }

    /// The profile whose `--top` names one of the waveform's top scopes, or a scope just
    /// below one (a simulator wrapper such as `TOP`). Nil when none or several match equally.
    public static func profile(matchingDumpTops tops: [String], children: [String: [String]], in profiles: [SlangProfile]) -> SlangProfile? {
        for names in [tops, tops.flatMap { children[$0] ?? [] }] {
            let matches = profiles.filter { !Set($0.buildFile.tops).isDisjoint(with: names) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                // Prefer the ones cmux and the repo keep as profiles over stray workspace .f files.
                let preferred = matches.filter { $0.path.contains("/.slang/") || $0.path.contains("/.config/cmux-slang/") }
                return preferred.count == 1 ? preferred[0] : nil
            }
        }
        return nil
    }
}

extension SlangServerConfigFile {
    /// What a `server.json` holds, for the editor's warning.
    public enum Health: Equatable, Sendable {
        case missing
        /// 0 bytes or only white space: slang-server fails on it without saying so.
        case empty
        /// Not a JSON object.
        case invalid
        case valid
    }

    /// A config file found in a workspace.
    public struct Found: Equatable, Sendable {
        public var path: String
        public var health: Health

        public init(path: String, health: Health) {
            self.path = path
            self.health = health
        }
    }

    /// slang-server reads its configs with comments and trailing commas allowed; JSON5 covers both.
    public static func health(of data: Data?) -> Health {
        guard let data else { return .missing }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .empty }
        guard (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) is [String: Any] else { return .invalid }
        return .valid
    }
}
