import Foundation

/// Which cmux-tui terminals need their directory asked for, and what the answer was.
///
/// A terminal's graph `cwd` follows `cd` only when its shell reports the directory
/// (OSC 7). Until a terminal does, its graph `cwd` stays the spawn directory. This
/// keeps one live query per such terminal at a time, started by a graph event (the
/// terminal appearing in a pane, or its title changing), never by a timer.
public struct CloudTerminalDirectoryFallback: Sendable {
    /// One query to run after `delay` seconds. Pass it back to `finish(_:answer:now:)`.
    public struct Probe: Hashable, Sendable {
        public let terminalID: String
        public let delay: TimeInterval
        let token: UInt64
    }

    /// What one query found.
    public enum Answer: Equatable, Sendable {
        /// The foreground process's directory.
        case directory(String)
        /// The query failed or timed out.
        case failed
        /// Not asked, or the answer cannot be the shell's directory.
        case skipped

        public init(foregroundDirectory: String?, foregroundExecutable: String?) {
            if let foregroundDirectory { self = .directory(foregroundDirectory) } else { self = .failed }
        }
    }

    /// Query starts for one terminal are at least this far apart.
    public static let minimumProbeSpacing: TimeInterval = 1

    /// A terminal whose queries keep failing is not asked again.
    public static let maximumFailedProbes = 3

    private struct Entry: Sendable {
        /// The graph `cwd` when first seen; a different one means the shell reports.
        var spawnDirectory: String?
        var title: String
        var reports = false
        var running: UInt64?
        var rerunQueued = false
        var failures = 0
        var directory: String?
    }

    private var entries: [String: Entry] = [:]
    private var nextToken: UInt64 = 0

    public init() {}

    /// Records the accepted graph's terminals. Returns the queries to start now.
    public mutating func observe(_ terminals: [CloudVMTerminalState], projected: Set<String>, now: TimeInterval) -> [Probe] {
        let present = Set(terminals.map(\.id))
        entries = entries.filter { present.contains($0.key) && projected.contains($0.key) }
        var probes: [Probe] = []
        for terminal in terminals where projected.contains(terminal.id) {
            guard var entry = entries[terminal.id] else {
                entries[terminal.id] = Entry(spawnDirectory: terminal.cwd, title: terminal.title)
                if let probe = start(terminal.id) { probes.append(probe) }
                continue
            }
            if entry.reports { continue }
            if terminal.cwd != entry.spawnDirectory {
                entry.reports = true
                entry.running = nil
                entry.rerunQueued = false
                entry.directory = nil
                entries[terminal.id] = entry
                continue
            }
            guard terminal.title != entry.title else { continue }
            entry.title = terminal.title
            entries[terminal.id] = entry
            if entry.running != nil {
                entries[terminal.id]?.rerunQueued = true
            } else if let probe = start(terminal.id) {
                probes.append(probe)
            }
        }
        return probes
    }

    /// Records a query's answer. `directoryChanged` says whether `directory(forTerminal:)`
    /// changed; `next` is the one query queued while this one ran.
    public mutating func finish(_ probe: Probe, answer: Answer, now: TimeInterval) -> (directoryChanged: Bool, next: Probe?) {
        let directory: String? = if case .directory(let found) = answer { found } else { nil }
        guard var entry = entries[probe.terminalID], entry.running == probe.token else { return (false, nil) }
        entry.running = nil
        var changed = false
        if let directory {
            entry.failures = 0
            changed = entry.directory != directory
            entry.directory = directory
        } else {
            entry.failures += 1
        }
        let rerun = entry.rerunQueued
        entry.rerunQueued = false
        entries[probe.terminalID] = entry
        return (changed, rerun ? start(probe.terminalID) : nil)
    }

    /// The live directory for a terminal that does not report its own.
    public func directory(forTerminal id: String) -> String? {
        guard let entry = entries[id], !entry.reports else { return nil }
        return entry.directory
    }

    private mutating func start(_ id: String) -> Probe? {
        guard var entry = entries[id], !entry.reports, entry.running == nil,
              entry.failures < Self.maximumFailedProbes else { return nil }
        nextToken &+= 1
        entry.running = nextToken
        entries[id] = entry
        return Probe(terminalID: id, delay: 0, token: nextToken)
    }
}
