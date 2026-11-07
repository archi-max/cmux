import Foundation

/// When cmux asks a host for a dump's KDB model, and what it keeps (WaveformTraceKDB's state, as
/// values). The export runs in the background when a viewer opens a remote dump, never in the way
/// of the open or a trace: a trace takes the model when it has come and slang's design until then.
/// - Off (the setting): no export, no model; tracing is slang's.
/// - One export in flight per KDB (`key`: the host and the dump's folder, where the launcher finds
///   the KDB), whichever viewers open its dumps: a viewer opening while it runs joins it. That
///   export may have read the KDB before a rerun rewrote it, so its answer is dropped and it runs
///   once more when it ends (`pending` stays true; the host's cache answers an unchanged KDB).
/// - An export that fails says so in one log line per KDB (until one gives a model), and its
///   KDB keeps slang's design; the host does not try that KDB again until it changes (npi-model.sh
///   answers `tried`), so a viewer opening it later costs no seat.
/// - The newest `maxModels` KDBs' models are kept. A viewer (re)opening a dump drops its KDB's
///   model until the export answers: a reload after another simulation may come with another KDB,
///   and a trace in between uses slang's design, not the old compile's.
public struct KDBExportSchedule: Sendable {
    public enum Opened: Equatable, Sendable {
        /// The setting is off: no export.
        case off
        /// An export of this KDB is in flight: wait for it.
        case join
        /// Start one (the host's cache answers a KDB it has a model of).
        case start
    }

    private let maxModels: Int
    private var running: Set<String> = []
    /// Running exports an open joined: their answer is dropped and they run once more.
    private var superseded: Set<String> = []
    private var models: [String: KDBDesignModel] = [:]
    /// KDBs whose failure was logged (until one gives a model).
    private var said: Set<String> = []
    /// KDBs by last use, oldest first.
    private var order: [String] = []

    public init(maxModels: Int = 4) {
        self.maxModels = max(1, maxModels)
    }

    /// The KDB a remote dump's export is for: the launcher takes the KDB in the dump's folder.
    public static func key(host: String, dumpPath: String) -> String {
        let folder = dumpPath.lastIndex(of: "/").map { String(dumpPath[..<$0]) } ?? "."
        return host + "|" + folder
    }

    /// A viewer opened (or reopened) a dump of this KDB.
    public mutating func opened(_ key: String, enabled: Bool) -> Opened {
        guard enabled else { return .off }
        use(key)
        models[key] = nil
        guard running.insert(key).inserted else {
            superseded.insert(key)
            return .join
        }
        return .start
    }

    /// Whether an export of this KDB is in flight (a trace uses slang's design until it answers).
    public func pending(_ key: String) -> Bool {
        running.contains(key)
    }

    /// The export ended: its model is kept, or the log line for its failure (nil: none to say
    /// again). An export an open joined is dropped and stays `pending`: the caller runs it again.
    public mutating func finished(_ key: String, _ outcome: KDBModelLaunch.Outcome) -> String? {
        if superseded.remove(key) != nil, running.contains(key) { return nil }
        running.remove(key)
        switch outcome {
        case .model(let model, _):
            models[key] = model
            said.remove(key)
            use(key)
            for gone in order.dropLast(maxModels) where !running.contains(gone) {
                models[gone] = nil
                said.remove(gone)
            }
            order.removeAll { models[$0] == nil && !running.contains($0) && !said.contains($0) }
            return nil
        case .unavailable(let code, let message):
            models[key] = nil
            guard said.insert(key).inserted else { return nil }
            return "KDB model unavailable (\(code)\(message.isEmpty ? "" : ": " + message)); tracing uses slang's design"
        }
    }

    /// The KDB's model, when an export gave one (now: never waits).
    public func model(_ key: String) -> KDBDesignModel? {
        models[key]
    }

    private mutating func use(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Whether slang's port aliases go to a viewer's helper: only when the setting allows them (off
    /// by default; the helper uses a pair once sampled windows of both match, and drops it on any
    /// difference) and the KDB gave no model (its aliases are the compiled design's).
    public static func sendsSlangAliases(enabled: Bool, model: KDBDesignModel?) -> Bool {
        enabled && model == nil
    }
}
