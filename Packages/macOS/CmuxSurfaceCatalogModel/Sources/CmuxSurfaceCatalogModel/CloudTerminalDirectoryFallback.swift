import Foundation

/// Which cmux-tui terminals need their directory asked for, and what the answer was.
///
/// A terminal's graph `cwd` follows `cd` only when its shell reports the directory
/// (OSC 7). Until a terminal does, its graph `cwd` stays the spawn directory. This
/// keeps one live query per such terminal at a time, started by a graph event (the
/// terminal appearing in a pane, or its title changing), never by a timer.
public struct CloudTerminalDirectoryFallback: Sendable {
    /// One query to run. Pass it back to `finish(_:directory:)`.
    public struct Probe: Hashable, Sendable {
        public let terminalID: String
        let token: UInt64
    }

    /// A terminal whose queries keep failing is not asked again.
    public static let maximumFailedProbes = 3

    public init() {}

    /// Records the accepted graph's terminals. Returns the queries to start now.
    public mutating func observe(_ terminals: [CloudVMTerminalState], projected: Set<String>) -> [Probe] {
        []
    }

    /// Records a query's answer. `directoryChanged` says whether `directory(forTerminal:)`
    /// changed; `next` is the one query queued while this one ran.
    public mutating func finish(_ probe: Probe, directory: String?) -> (directoryChanged: Bool, next: Probe?) {
        (false, nil)
    }

    /// The live directory for a terminal that does not report its own.
    public func directory(forTerminal id: String) -> String? {
        nil
    }
}
