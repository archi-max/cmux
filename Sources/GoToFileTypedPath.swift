import Foundation

/// A Go to File query that names a file by path (`~/.bashrc`, `/etc/hosts`,
/// `./tb/top.sv`, `../notes.md`) instead of searching the listed root, so a
/// file outside the Files root, or one the listing leaves out, still opens.
enum GoToFileTypedPath {
    /// The path a query names, trimmed, or nil when it isn't one.
    /// Placeholder until the fix: no query names a path.
    static func parse(_ query: String) -> String? {
        nil
    }

    /// Whether `typed` needs the host's home directory to resolve.
    static func needsHome(_ typed: String) -> Bool {
        typed.hasPrefix("~/")
    }

    /// The absolute path `typed` names: `~/` against `home` (the host's
    /// `$HOME`, never expanded by a shell here), `./` and `../` against
    /// `root`; `.` and `..` components folded. Nil when it needs a home
    /// that isn't an absolute path.
    /// Placeholder until the fix: never resolves.
    static func resolve(_ typed: String, root: String, home: String?) -> String? {
        nil
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

    /// The kept value for `key`, else `load()`'s.
    /// Placeholder until the fix: always loads.
    func value(for key: Key, load: () async throws -> Value) async throws -> Value {
        try await load()
    }

    /// Drops every kept value (a Files refresh).
    func invalidateAll() {
        entries.removeAll()
    }
}
