import Foundation

/// What a SystemVerilog file builds its design from (stub: the per-file profile API, not built yet).
public enum SlangProfileChoice: Codable, Equatable, Hashable, Sendable {
    case buildFile(String)
    case topLevel(String)
    case explore
    case configured

    public init(_ state: LanguageServerSession.SlangCompilationState) {
        self = .configured
    }

    public var state: LanguageServerSession.SlangCompilationState {
        .init(target: nil, isExplore: false)
    }

    public var path: String? { nil }
}

/// The profiles of one server root (stub).
public struct SlangProfileAssignments: Codable, Equatable, Sendable {
    public struct FileChoice: Codable, Equatable, Sendable {
        public var choice: SlangProfileChoice
        public var at: Date
    }

    public static let maxFiles = 256
    public private(set) var lastSet: SlangProfileChoice?
    public private(set) var files: [String: FileChoice] = [:]
    public private(set) var updatedAt: Date = .distantPast

    public init() {}

    public mutating func choose(_ choice: SlangProfileChoice, file: String?, at date: Date = Date()) {}
    public mutating func setLastSet(_ choice: SlangProfileChoice?, at date: Date = Date()) {}
    public func choice(forFile file: String) -> SlangProfileChoice? { nil }
    public func ownChoice(forFile file: String) -> SlangProfileChoice? { nil }
    public mutating func forgetFile(_ file: String) {}
    public mutating func profileWasRemoved(_ path: String) {}
    public mutating func pathWasMoved(from old: String, to new: String) {}
}

/// Every root's assignments in user defaults (stub).
public struct SlangProfileAssignmentStore {
    public static let defaultsKey = "slangProfile.assignments"
    public static let maxRoots = 32

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultsKey) {}
    public func load() -> [String: SlangProfileAssignments] { [:] }
    public func load(root: String) -> SlangProfileAssignments { SlangProfileAssignments() }
    public func save(_ assignments: SlangProfileAssignments, root: String) {}
}

/// Makes a server compile the active file's profile (stub: never switches).
@MainActor
public final class SlangProfileFollower {
    public enum ApplyResult: Sendable, Equatable {
        case applied
        case failed
        case missing
    }

    public struct Hooks {
        public var wanted: @MainActor () -> SlangProfileChoice?
        public var current: @MainActor () async -> LanguageServerSession.SlangCompilationState
        public var isBusy: @MainActor () -> Bool
        public var apply: @MainActor (SlangProfileChoice) async -> ApplyResult
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

    public init(
        debounce: Duration = .milliseconds(250),
        busyRetry: Duration = .milliseconds(300),
        maxBusyWait: Duration = .seconds(20),
        hooks: Hooks
    ) {}

    public func activeFileChanged() {}
    public func waitUntilIdle() async {}
}
