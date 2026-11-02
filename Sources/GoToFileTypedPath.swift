import Foundation

/// A Go to File query that names a file by path (`~/.bashrc`, `/etc/hosts`,
/// `./tb/top.sv`, `../notes.md`) instead of searching the listed root, so a
/// file outside the Files root, or one the listing leaves out, still opens.
enum GoToFileTypedPath {
    /// The path a query names, trimmed, or nil when it isn't one: it starts
    /// with `~/`, `/`, `./` or `../` and doesn't end in `/`. A bare dotfile
    /// name (`.gitignore`) stays a search; `~user` is never looked up.
    static func parse(_ query: String) -> String? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.contains(where: { $0.isNewline || $0 == "\0" }),
              ["~/", "/", "./", "../"].contains(where: { typed.hasPrefix($0) }),
              !typed.hasSuffix("/") else { return nil }
        return typed
    }

    /// Whether `typed` needs the host's home directory to resolve.
    static func needsHome(_ typed: String) -> Bool {
        typed.hasPrefix("~/")
    }

    /// The absolute path `typed` names: `~/` against `home` (the host's
    /// `$HOME`, never expanded by a shell here), `./` and `../` against
    /// `root`; `.` and `..` components folded. Nil when it needs a home
    /// that isn't an absolute path.
    /// How Go to File opens for a workspace: listing its Files root, or,
    /// with no Files root but a terminal on an SSH host, typed paths only.
    /// Nil: nothing to open against.
    /// Placeholder until the fix: without a Files root there is nothing.
    static func paletteMode(hasFilesRoot: Bool, hasTerminalOnHost: Bool) -> GoToFilePaletteMode? {
        hasFilesRoot ? .listing : nil
    }

    /// The directory `./` and `../` resolve against: the terminal's live
    /// directory when it reported an absolute one, else `fallback`.
    /// Placeholder until the fix: always the fallback.
    static func relativeRoot(live: String?, fallback: String?) -> String? {
        fallback
    }

    static func resolve(_ typed: String, root: String, home: String?) -> String? {
        let joined: String
        if needsHome(typed) {
            guard let home, home.hasPrefix("/") else { return nil }
            joined = home + "/" + typed.dropFirst(2)
        } else if typed.hasPrefix("/") {
            joined = typed
        } else {
            joined = root + "/" + typed
        }
        var components: [Substring] = []
        for component in joined.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}

/// Values kept for `lifetime` per key, for listings worth reusing across
/// palette sessions. Only successful loads are kept.
@MainActor
final class ExpiringValueCache<Key: Hashable, Value> {
    private let lifetime: Duration
    private let now: () -> ContinuousClock.Instant
    private var entries: [Key: (value: Value, storedAt: ContinuousClock.Instant)] = [:]

    init(lifetime: Duration, now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.lifetime = lifetime
        self.now = now
    }

    /// The kept value for `key` while it is younger than the lifetime, else
    /// `load()`'s, which is kept when it succeeds.
    func value(for key: Key, load: () async throws -> Value) async throws -> Value {
        if let entry = entries[key], entry.storedAt.advanced(by: lifetime) > now() { return entry.value }
        let value = try await load()
        entries[key] = (value, now())
        return value
    }

    /// Drops every kept value (a Files refresh).
    func invalidateAll() {
        entries.removeAll()
    }
}

/// How a Go to File session opens.
enum GoToFilePaletteMode: Equatable, Sendable {
    /// Lists the Files root and ranks it; typed paths too.
    case listing
    /// No Files root: typed paths only, against a terminal on the host.
    case typedPathsOnly
}
