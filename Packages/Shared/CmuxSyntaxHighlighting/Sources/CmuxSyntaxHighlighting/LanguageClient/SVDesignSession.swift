import Foundation

/// One design loaded in a cmux-sv-model sidecar, and the answers kept for it, bound to the design
/// they came from: the sidecar's design generation (SVModelSidecar.designGeneration), which a
/// load of other text (an edited source, include or file list; the command line and its defines
/// and parameters are in the fingerprint too) or of unknown provenance makes new. A caller asks
/// with the generation it began in: an answer of another one throws `designChanged` instead of
/// mixing two designs, and the kept answers of an older one are dropped. A design whose load
/// can't say what it read (no fingerprint) is never used: `noProvenance`.
public final class SVDesignSession: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// The load did not say which sources it read (no fingerprint): its answers can't be bound to them.
        case noProvenance
        /// The sidecar's design is not the one the caller began with (an edit loaded, a restart onto changed sources).
        case designChanged
    }

    /// A load's outcome: its generation, fingerprint, tops and slang's messages.
    public struct Loaded: Sendable {
        public let generation: Int
        public let fingerprint: String
        public let tops: [String]
        public let messages: [String]
    }

    public let sidecar: SVModelSidecar
    public let args: [String]
    public let cwd: String
    /// Instance models kept per design at most (the sidecar builds each anew; a top's is large).
    public static let maxModels = 16

    private let lock = NSLock()
    /// The generation the kept answers belong to.
    private var keptGeneration = 0
    private var keptHierarchy: (tops: [String], instances: [String])?
    private var keptModels: [String: [String: Any]] = [:]
    private var keptMessages: [String] = []
    private var keptSourceTimes: [String: Int64]?

    public init(sidecar: SVModelSidecar, args: [String], cwd: String) {
        self.sidecar = sidecar
        self.args = args
        self.cwd = cwd
    }

    /// The generation of the design the sidecar holds now.
    public var generation: Int { sidecar.designGeneration }

    /// slang's messages from loading the current design (its errors first).
    public var loadMessages: [String] {
        if let last = sidecar.lastLoadReply { take(last.design) }
        return lock.withLock { keptMessages }
    }

    /// Loads the design (the sidecar elaborates it anew).
    @discardableResult
    public func load() async throws -> Loaded {
        let reply = try await sidecar.request(["cmd": "load", "args": args, "cwd": cwd])
        take(reply.design)
        guard let fingerprint = reply["fingerprint"] as? String, !fingerprint.isEmpty else { throw Failure.noProvenance }
        return Loaded(generation: reply.design, fingerprint: fingerprint,
                      tops: reply["tops"] as? [String] ?? [], messages: reply["messages"] as? [String] ?? [])
    }

    /// Whether a file the design was loaded from changed on disk (the sidecar's `stale`); if one
    /// did, the design is loaded again (a new generation unless its text is the same).
    @discardableResult
    public func refresh() async throws -> Bool {
        let reply = try await sidecar.request(["cmd": "stale"])
        guard reply["changed"] as? Bool == true else {
            try provenance(reply.design)
            return false
        }
        try await load()
        return true
    }

    /// The design's instance paths and tops, kept per design.
    public func hierarchy(generation: Int) async throws -> (tops: [String], instances: [String]) {
        if let known = try kept(generation, { $0.keptHierarchy }) { return known }
        let reply = try await request(["cmd": "instances"], generation: generation)
        let hierarchy = (tops: reply["tops"] as? [String] ?? [], instances: reply["instances"] as? [String] ?? [])
        keep(generation) { $0.keptHierarchy = hierarchy }
        return hierarchy
    }

    /// An instance's model (nil: no such instance), kept per design.
    public func model(_ path: String, generation: Int) async throws -> [String: Any]? {
        if let known = try kept(generation, { $0.keptModels[path] }) { return known }
        let reply: SVModelSidecar.Reply
        do {
            reply = try await request(["cmd": "instance", "path": path], generation: generation)
        } catch SVModelSidecar.Failure.request(code: "noInstance", message: _) {
            return nil
        }
        guard let model = reply["model"] as? [String: Any] else { return nil }
        keep(generation) { session in
            if session.keptModels.count >= Self.maxModels { session.keptModels.removeAll() }
            session.keptModels[path] = model
        }
        return model
    }

    /// The files the design was loaded from and their modification times (ms since 1970), kept per
    /// design; nil when the sidecar can't say.
    public func sourceTimes(generation: Int) async throws -> [String: Int64]? {
        if let known = try kept(generation, { $0.keptSourceTimes }) { return known }
        let reply: SVModelSidecar.Reply
        do {
            reply = try await request(["cmd": "sources"], generation: generation)
        } catch SVModelSidecar.Failure.request {
            return nil
        }
        var times: [String: Int64] = [:]
        for entry in reply["sources"] as? [[String: Any]] ?? [] {
            if let path = entry["path"] as? String, let time = (entry["mtime"] as? NSNumber)?.int64Value { times[path] = time }
        }
        keep(generation) { $0.keptSourceTimes = times }
        return times
    }

    /// The deepest instance of the design on `path` and the rest below it (nil: none).
    public func lookup(_ path: String, generation: Int) async throws -> (instance: String, name: String)? {
        let reply: SVModelSidecar.Reply
        do {
            reply = try await request(["cmd": "lookup", "path": path], generation: generation)
        } catch SVModelSidecar.Failure.request(code: "noInstance", message: _) {
            return nil
        }
        guard let instance = reply["instance"] as? String, let name = reply["name"] as? String else { return nil }
        return (instance, name)
    }

    /// A request answered in `generation`'s design, else `designChanged` (or `noProvenance`
    /// when the design now loaded can't say what it read).
    public func request(_ object: [String: any Sendable], generation: Int) async throws -> SVModelSidecar.Reply {
        let reply = try await sidecar.request(object)
        take(reply.design)
        guard reply.design == generation else { throw Failure.designChanged }
        try provenance(reply.design)
        return reply
    }

    // MARK: Kept answers

    /// Moves the kept answers to a newer generation (dropping the older one's).
    private func take(_ generation: Int) {
        let messages = sidecar.lastLoadReply.flatMap { $0.design == generation ? $0["messages"] as? [String] : nil }
        lock.withLock {
            guard generation > keptGeneration else { return }
            keptGeneration = generation
            keptHierarchy = nil
            keptModels = [:]
            keptSourceTimes = nil
            keptMessages = messages ?? []
        }
    }

    /// Throws `noProvenance` when the design of `generation` came from a load without a fingerprint.
    private func provenance(_ generation: Int) throws {
        guard let last = sidecar.lastLoadReply, last.design == generation else { return }
        if (last["fingerprint"] as? String ?? "").isEmpty { throw Failure.noProvenance }
    }

    /// A kept answer of `generation` (nil: none kept); `designChanged` when the answers kept are a newer design's.
    private func kept<T>(_ generation: Int, _ read: (SVDesignSession) -> T?) throws -> T? {
        try lock.withLock {
            if keptGeneration > generation { throw Failure.designChanged }
            return keptGeneration == generation ? read(self) : nil
        }
    }

    private func keep(_ generation: Int, _ write: (SVDesignSession) -> Void) {
        lock.withLock {
            guard keptGeneration == generation else { return }
            write(self)
        }
    }
}
