import Foundation

/// The state machine pane's answers per waveform and dump path (WaveformFSMEngines), and the
/// engine runs making them. Opening or reloading a waveform drops its answers and starts a new
/// generation: a run started before is neither kept nor shown, and doesn't hold off a request made
/// after (verify F2).
public struct FsmAnswerCache<Answer> {
    public struct Ticket: Hashable, Sendable {
        let waveform: String
        let path: String
        let generation: Int
    }

    private var generations: [String: Int] = [:]
    private var answers: [String: [String: Answer]] = [:]
    private var running: Set<Ticket> = []

    public init() {}

    /// `waveform` was opened or reloaded.
    public mutating func opened(_ waveform: String) {
        generations[waveform, default: 0] += 1
        answers[waveform] = nil
        running = running.filter { $0.waveform != waveform }
    }

    public func answer(_ waveform: String, _ path: String) -> Answer? {
        answers[waveform]?[path]
    }

    /// A run for `path`, or nil when one for the current generation is running.
    public mutating func start(_ waveform: String, _ path: String) -> Ticket? {
        let ticket = Ticket(waveform: waveform, path: path, generation: generations[waveform, default: 0])
        guard running.insert(ticket).inserted else { return nil }
        return ticket
    }

    /// The run ended with `answer`. Whether to show it: false when its waveform was opened again
    /// since it started. It's kept for the next request only when current and `keep`.
    public mutating func finish(_ ticket: Ticket, _ answer: Answer, keep: Bool) -> Bool {
        running.remove(ticket)
        guard ticket.generation == generations[ticket.waveform, default: 0] else { return false }
        if keep { answers[ticket.waveform, default: [:]][ticket.path] = answer }
        return true
    }
}

extension FsmPipeline.Result {
    /// An engine failed in a way a retry may not (ssh, a busy licence, a crash): not kept.
    /// A missing database, engine or machine is the answer until the waveform changes.
    public var hasTransientFailure: Bool {
        notes.contains { note in
            switch note {
            case .verdi(let reason, _): return reason == "failed" || reason == "licence"
            case .yosys(.failed(let detail)): return !detail.isEmpty
            case .yosys(.notFound): return false
            }
        }
    }
}
