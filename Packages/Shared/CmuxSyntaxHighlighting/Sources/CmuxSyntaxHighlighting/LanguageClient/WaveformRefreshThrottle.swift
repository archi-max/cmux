import Foundation

/// When an editor's waveform values refresh after the marker moves.
///
/// A debounce that restarts on every move never fires while the debugger
/// plays (the marker moves faster than the wait), and cancelling a refresh in
/// flight throws its work away. Instead a move while a refresh waits changes
/// nothing (it reads the newest marker when it runs), and a move while one
/// runs queues exactly one more after it. A refresh that has run for
/// `stuckAfter` seconds no longer holds moves back (a page or server call that
/// never returns must not freeze the values).
public struct WaveformRefreshThrottle: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case waiting
        case running
    }

    public static let stuckAfter: TimeInterval = 10

    public private(set) var phase: Phase = .idle
    private var serial = 0
    private var again = false
    private var startedAt = Date.distantPast

    public init() {}

    /// A refresh was scheduled, replacing any pending one. Returns its serial.
    public mutating func scheduled() -> Int {
        serial += 1
        phase = .waiting
        again = false
        return serial
    }

    /// The refresh `serial` stopped waiting and started.
    public mutating func started(_ serial: Int, at now: Date = Date()) {
        guard serial == self.serial else { return }
        phase = .running
        startedAt = now
    }

    /// The refresh `serial` ended. True when the marker moved meanwhile, so another should run now.
    public mutating func finished(_ serial: Int) -> Bool {
        guard serial == self.serial, phase == .running else { return false }
        phase = .idle
        defer { again = false }
        return again
    }

    /// The pending refresh was cancelled without a replacement.
    public mutating func cleared() {
        phase = .idle
        again = false
    }

    /// The marker moved. True when a refresh has to be scheduled for it.
    public mutating func markerMoved(at now: Date = Date()) -> Bool {
        switch phase {
        case .idle:
            return true
        case .waiting:
            return false
        case .running:
            if now.timeIntervalSince(startedAt) >= Self.stuckAfter { return true }
            again = true
            return false
        }
    }
}
