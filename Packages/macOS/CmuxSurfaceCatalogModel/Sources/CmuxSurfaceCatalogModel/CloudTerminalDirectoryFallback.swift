import Foundation

/// Which cmux-tui terminals need their directory asked for, and what the answer was.
///
/// A terminal's graph `cwd` follows `cd` only when its shell reports the directory
/// (OSC 7). Until a terminal does, its graph `cwd` stays the spawn directory. This
/// keeps one live query per such terminal at a time, started by an event (the terminal
/// appearing in a pane, or its title changing), never by a timer, and starts
/// a terminal's queries at least `minimumProbeSpacing` apart.
///
/// The query reads the foreground process's directory. That is the shell's own for a
/// shell that never reports (fish, a configured command), but not inside tmux: there
/// it is the tmux client's, which never moves, so a tmux answer is skipped.
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
        /// Not asked (no connected link), or the answer is not the shell's directory.
        /// It does not count as a failure.
        case skipped

        public init(foregroundDirectory: String?, foregroundExecutable: String?) {
            if let foregroundExecutable, Self.isTmux(foregroundExecutable) {
                self = .skipped
            } else if let foregroundDirectory {
                self = .directory(foregroundDirectory)
            } else {
                self = .failed
            }
        }

        /// `tmux`, a path to it, or the client's process title `tmux: client`.
        private static func isTmux(_ executable: String) -> Bool {
            let name = executable.split(separator: "/").last.map(String.init) ?? executable
            return name.split(whereSeparator: { $0 == ":" || $0 == " " }).first == "tmux"
        }
    }

    /// A terminal whose queries keep failing is not asked again.
    public static let maximumFailedProbes = 3
    /// Query starts for one terminal are at least this far apart, in seconds.
    public static let minimumProbeSpacing: TimeInterval = 1

    private struct Entry: Sendable {
        /// The graph `cwd` when first seen; a different one means the shell reports.
        var spawnDirectory: String?
        /// The graph's title.
        var title: String
        /// The last title the terminal's own output set, as the Mac shows it.
        var terminalTitle: String?
        var reports = false
        var running: UInt64?
        var rerunQueued = false
        var failures = 0
        var lastStart: TimeInterval?
        var directory: String?
    }

    private var entries: [String: Entry] = [:]
    private var nextToken: UInt64 = 0

    public init() {}

    /// Records the accepted graph's terminals at monotonic time `now`. Returns the
    /// queries to start.
    public mutating func observe(_ terminals: [CloudVMTerminalState], projected: Set<String>, now: TimeInterval) -> [Probe] {
        let present = Set(terminals.map(\.id))
        entries = entries.filter { present.contains($0.key) && projected.contains($0.key) }
        var probes: [Probe] = []
        for terminal in terminals where projected.contains(terminal.id) {
            guard var entry = entries[terminal.id] else {
                entries[terminal.id] = Entry(spawnDirectory: terminal.cwd, title: terminal.title)
                if let probe = start(terminal.id, now: now) { probes.append(probe) }
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
            } else if let probe = start(terminal.id, now: now) {
                probes.append(probe)
            }
        }
        return probes
    }

    /// Records a title the terminal itself set (OSC 0/2), as the Mac's own view of the
    /// terminal shows it, at monotonic time `now`. Returns the query to start, if any.
    ///
    /// The daemon's graph keeps the title it had when the terminal last changed for
    /// another reason: a title change alone publishes no graph event. So this, not
    /// `observe`, is what follows a shell's prompt title (`user@host: ~/dir`). Only a
    /// terminal `observe` already tracks (shown, not reporting) is asked.
    public mutating func terminalTitleChanged(_ title: String, terminalID: String, now: TimeInterval) -> Probe? {
        guard var entry = entries[terminalID], !entry.reports, entry.terminalTitle != title else { return nil }
        entry.terminalTitle = title
        entries[terminalID] = entry
        if entry.running != nil {
            entries[terminalID]?.rerunQueued = true
            return nil
        }
        return start(terminalID, now: now)
    }

    /// Records a query's answer at monotonic time `now`. `directoryChanged` says whether
    /// `directory(forTerminal:)` changed; `next` is the one query queued while this one ran.
    public mutating func finish(_ probe: Probe, answer: Answer, now: TimeInterval) -> (directoryChanged: Bool, next: Probe?) {
        guard var entry = entries[probe.terminalID], entry.running == probe.token else { return (false, nil) }
        entry.running = nil
        var changed = false
        switch answer {
        case .directory(let directory):
            entry.failures = 0
            changed = entry.directory != directory
            entry.directory = directory
        case .failed:
            entry.failures += 1
        case .skipped:
            break
        }
        let rerun = entry.rerunQueued
        entry.rerunQueued = false
        entries[probe.terminalID] = entry
        return (changed, rerun ? start(probe.terminalID, now: now) : nil)
    }

    /// The live directory for a terminal that does not report its own.
    public func directory(forTerminal id: String) -> String? {
        guard let entry = entries[id], !entry.reports else { return nil }
        return entry.directory
    }

    private mutating func start(_ id: String, now: TimeInterval) -> Probe? {
        guard var entry = entries[id], !entry.reports, entry.running == nil,
              entry.failures < Self.maximumFailedProbes else { return nil }
        let earliest = entry.lastStart.map { $0 + Self.minimumProbeSpacing } ?? now
        let delay = max(0, earliest - now)
        nextToken &+= 1
        entry.running = nextToken
        entry.lastStart = now + delay
        entries[id] = entry
        return Probe(terminalID: id, delay: delay, token: nextToken)
    }
}
