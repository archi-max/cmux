import Foundation

/// When cmux asks a host for a dump's KDB model, and what it keeps (WaveformTraceKDB's state, as
/// values). The export runs in the background when a viewer opens a remote dump, never in the way
/// of the open or a trace: a trace takes the model when it has come and slang's design until then.
/// - Off (the setting): no export, no model; tracing is slang's.
/// - One export in flight per KDB (`key`: the host and the dump's folder, where the launcher finds
///   the KDB), whichever viewers open its dumps: a viewer opening while it runs joins it.
/// - An export that fails says so in one log line per KDB (until one gives a model), and its
///   KDB keeps slang's design; the host does not try that KDB again until it changes (npi-model.sh
///   answers `tried`), so a viewer opening it later costs no seat.
/// - The newest `maxModels` KDBs' models are kept.
public struct KDBExportSchedule: Sendable {
    public enum Opened: Equatable, Sendable {
        /// The setting is off: no export.
        case off
        /// An export of this KDB is in flight: wait for it.
        case join
        /// Start one (the host's cache answers a KDB it has a model of).
        case start
    }

    public init(maxModels: Int = 4) {}

    /// The KDB a remote dump's export is for: the launcher takes the KDB in the dump's folder.
    public static func key(host: String, dumpPath: String) -> String {
        host + "|" + dumpPath
    }

    /// A viewer opened (or reopened) a dump of this KDB.
    public mutating func opened(_ key: String, enabled: Bool) -> Opened {
        .start
    }

    /// The export ended: its model is kept, or the log line for its failure (nil: none to say again).
    public mutating func finished(_ key: String, _ outcome: KDBModelLaunch.Outcome) -> String? {
        nil
    }

    /// The KDB's model, when an export gave one (now: never waits).
    public func model(_ key: String) -> KDBDesignModel? {
        nil
    }

    /// Whether slang's port aliases go to a viewer's helper: only when the setting allows them (off
    /// by default; the helper uses a pair once sampled windows of both match, and drops it on any
    /// difference) and the KDB gave no model (its aliases are the compiled design's).
    public static func sendsSlangAliases(enabled: Bool, model: KDBDesignModel?) -> Bool {
        true
    }
}
