import Foundation

/// What a SystemVerilog file builds its design from: a slang profile (`.f` build file), a
/// file as the top level, explore mode, or what the server's config says (no choice made).
/// Paths are server paths: the remote path for an SSH file, the real path for a local one.
public enum SlangProfileChoice: Codable, Equatable, Hashable, Sendable {
    case buildFile(String)
    case topLevel(String)
    case explore
    /// The config's build (`.slang/server.json`), else explore mode: what Reset Top Level and
    /// Clear Build File go back to.
    case configured

    public init(_ state: LanguageServerSession.SlangCompilationState) {
        switch state.target {
        case .buildFile(let path)?: self = .buildFile(path)
        case .topLevel(let path)?: self = .topLevel(path)
        case nil: self = state.isExplore ? .explore : .configured
        }
    }

    public var state: LanguageServerSession.SlangCompilationState {
        switch self {
        case .buildFile(let path): return .init(target: .buildFile(path), isExplore: false)
        case .topLevel(let path): return .init(target: .topLevel(path), isExplore: false)
        case .explore: return .init(target: nil, isExplore: true)
        case .configured: return .init(target: nil, isExplore: false)
        }
    }

    /// The build file or top-level file the choice names.
    public var path: String? {
        switch self {
        case .buildFile(let path), .topLevel(let path): return path
        case .explore, .configured: return nil
        }
    }

    /// The same choice with its path (or a path below a moved folder) moved to `new`.
    func moving(from old: String, to new: String) -> SlangProfileChoice {
        switch self {
        case .buildFile(let path): return .buildFile(SlangProfileAssignments.moved(path, from: old, to: new))
        case .topLevel(let path): return .topLevel(SlangProfileAssignments.moved(path, from: old, to: new))
        case .explore, .configured: return self
        }
    }
}

/// The profiles of one server root: the one each file last chose while it was the active file,
/// and the one set last, which files with no choice of their own follow.
public struct SlangProfileAssignments: Codable, Equatable, Sendable {
    public struct FileChoice: Codable, Equatable, Sendable {
        public var choice: SlangProfileChoice
        public var at: Date
    }

    /// Files kept per root; the ones chosen longest ago are dropped first.
    public static let maxFiles = 256

    public private(set) var lastSet: SlangProfileChoice?
    public private(set) var files: [String: FileChoice] = [:]
    /// When anything was last chosen (the store drops the roots unused longest).
    public private(set) var updatedAt: Date = .distantPast

    public init() {}

    /// `choice` was set while `file` was the active file (nil: no file, e.g. from the Files
    /// panel with no editor): it is the file's from now on and the root's last-set profile.
    public mutating func choose(_ choice: SlangProfileChoice, file: String?, at date: Date = Date()) {
        lastSet = choice
        updatedAt = date
        if let file {
            files[file] = FileChoice(choice: choice, at: date)
            prune()
        }
    }

    /// The last-set profile alone changed (the waveform picked one, or its Undo): no file's own choice.
    public mutating func setLastSet(_ choice: SlangProfileChoice?, at date: Date = Date()) {
        lastSet = choice
        updatedAt = date
    }

    /// The file's own choice, else the last-set profile; nil when nothing was ever chosen.
    public func choice(forFile file: String) -> SlangProfileChoice? {
        files[file]?.choice ?? lastSet
    }

    /// The choice the file made itself.
    public func ownChoice(forFile file: String) -> SlangProfileChoice? {
        files[file]?.choice
    }

    /// The file follows the last-set profile again.
    public mutating func forgetFile(_ file: String) {
        files[file] = nil
    }

    /// A profile (or top-level file) at `path` is gone: its files follow the last-set profile,
    /// and when it was the last-set profile, nothing is set.
    public mutating func profileWasRemoved(_ path: String) {
        files = files.filter { $0.value.choice.path != path }
        if lastSet?.path == path { lastSet = nil }
    }

    /// A file or folder was renamed or moved from `old` to `new`: files and profiles below it follow.
    public mutating func pathWasMoved(from old: String, to new: String) {
        guard old != new else { return }
        var moved: [String: FileChoice] = [:]
        for (file, entry) in files {
            var entry = entry
            entry.choice = entry.choice.moving(from: old, to: new)
            let key = Self.moved(file, from: old, to: new)
            // A file already at the new path keeps its own (newer) choice.
            if let existing = moved[key], existing.at >= entry.at { continue }
            moved[key] = entry
        }
        files = moved
        lastSet = lastSet?.moving(from: old, to: new)
    }

    /// `path` with `old` (the path itself or a folder above it) replaced by `new`.
    static func moved(_ path: String, from old: String, to new: String) -> String {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return path }
        return (new.hasSuffix("/") ? new : new + "/") + path.dropFirst(prefix.count)
    }

    private mutating func prune() {
        guard files.count > Self.maxFiles else { return }
        let kept = files.sorted { $0.value.at > $1.value.at }.prefix(Self.maxFiles)
        files = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// Every root's `SlangProfileAssignments`, kept in user defaults across launches. A root key
/// names the host too (`local|/path`, or the SSH route then the remote path).
public struct SlangProfileAssignmentStore {
    public static let defaultsKey = "slangProfile.assignments"
    /// Roots kept; the ones unused longest are dropped first.
    public static let maxRoots = 32

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: SlangProfileAssignments] {
        guard let data = defaults.data(forKey: key),
              let roots = try? JSONDecoder().decode([String: SlangProfileAssignments].self, from: data) else { return [:] }
        return roots
    }

    public func load(root: String) -> SlangProfileAssignments {
        load()[root] ?? SlangProfileAssignments()
    }

    /// Writes `assignments` for `root` (an empty one removes the root).
    public func save(_ assignments: SlangProfileAssignments, root: String) {
        var roots = load()
        if assignments.lastSet == nil, assignments.files.isEmpty {
            roots[root] = nil
        } else {
            roots[root] = assignments
        }
        if roots.count > Self.maxRoots {
            let kept = roots.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.maxRoots)
            roots = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        if roots.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(roots) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Makes a server compile the active file's profile: once focus has stayed on a file for a
/// moment (switching tabs quickly compiles nothing in between), only when the profile differs
/// from what the server compiles, and after a top-level or build change already running.
@MainActor
public final class SlangProfileFollower {
    public enum ApplyResult: Sendable, Equatable {
        case applied
        /// Nothing elaborated (the server went back to what it compiled before).
        case failed
        /// The profile's file no longer exists.
        case missing
    }

    public struct Hooks {
        /// The active file's profile, read when the debounce ends; nil: nothing chosen, leave the server.
        public var wanted: @MainActor () -> SlangProfileChoice?
        /// What the server compiles now.
        public var current: @MainActor () async -> LanguageServerSession.SlangCompilationState
        /// Another change is running on the server.
        public var isBusy: @MainActor () -> Bool
        public var apply: @MainActor (SlangProfileChoice) async -> ApplyResult
        /// The profile is gone: drop it, so `wanted` falls back to the last-set profile.
        public var missing: @MainActor (SlangProfileChoice) -> Void

        public init(
            wanted: @escaping @MainActor () -> SlangProfileChoice?,
            current: @escaping @MainActor () async -> LanguageServerSession.SlangCompilationState,
            isBusy: @escaping @MainActor () -> Bool,
            apply: @escaping @MainActor (SlangProfileChoice) async -> ApplyResult,
            missing: @escaping @MainActor (SlangProfileChoice) -> Void
        ) {
            self.wanted = wanted
            self.current = current
            self.isBusy = isBusy
            self.apply = apply
            self.missing = missing
        }
    }

    private let debounce: Duration
    private let busyRetry: Duration
    private let maxBusyWait: Duration
    private let hooks: Hooks
    private var pending: Task<Void, Never>?
    private var running: Task<Void, Never>?

    public init(
        debounce: Duration = .milliseconds(250),
        busyRetry: Duration = .milliseconds(300),
        maxBusyWait: Duration = .seconds(20),
        hooks: Hooks
    ) {
        self.debounce = debounce
        self.busyRetry = busyRetry
        self.maxBusyWait = maxBusyWait
        self.hooks = hooks
    }

    /// A file became the active one (or its profile changed): compile its profile once focus settles.
    public func activeFileChanged() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard let debounce = self?.debounce else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.follow()
        }
    }

    /// Returns once no switch is pending or running (for tests).
    public func waitUntilIdle() async {
        while true {
            if let task = pending {
                await task.value
                if pending == task { pending = nil }
            } else if let task = running {
                await task.value
                if running == task { running = nil }
            } else {
                return
            }
        }
    }

    private func follow() async {
        // One switch at a time: a later focus waits for the one going on, then decides afresh.
        if let running { await running.value }
        guard !Task.isCancelled else { return }
        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.switchIfNeeded()
        }
        running = task
        pending = nil
        await task.value
        if running == task { running = nil }
    }

    private func switchIfNeeded() async {
        var waited: Duration = .zero
        // At most twice: a missing profile, then the last-set profile it falls back to.
        for _ in 0..<2 {
            while hooks.isBusy() {
                guard waited < maxBusyWait else { return }
                try? await Task.sleep(for: busyRetry)
                waited += busyRetry
                if pending != nil { return }
            }
            // A newer focus is waiting for its debounce: it decides.
            if pending != nil { return }
            guard let wanted = hooks.wanted() else { return }
            let current = await hooks.current()
            guard SlangProfileChoice(current) != wanted else { return }
            guard await hooks.apply(wanted) == .missing else { return }
            hooks.missing(wanted)
        }
    }
}
