import Foundation

/// The state machine pane's answers per waveform and dump path (WaveformFSMEngines), and the
/// engine runs making them. Opening or reloading a waveform drops its answers and starts a new
/// generation: a run started before is neither kept nor shown, and doesn't hold off a request made
/// after (verify F2). Answers are kept until then, or until the design opens or changes
/// (`designChanged`): a Show or reload doesn't rerun an engine, Verdi over ssh above all (verify G2).
public struct FsmAnswerCache<Answer> {
    public struct Ticket: Hashable, Sendable {
        let waveform: String
        let path: String
        let generation: Int
    }
    /// A run's ticket and the design epoch it started in.
    public struct Run: Sendable {
        let ticket: Ticket
        let designEpoch: Int
    }

    private var generations: [String: Int] = [:]
    private var answers: [String: [String: Answer]] = [:]
    private var running: Set<Ticket> = []
    private var designEpoch = 0

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

    /// A SystemVerilog design was opened or changed (an editor's server started, a save, a new top):
    /// every answer may be out of date. Runs going on are still shown, not kept.
    public mutating func designChanged() {
        designEpoch += 1
        answers = [:]
    }

    /// A run for `path`, or nil when one for the current generation is running.
    public mutating func start(_ waveform: String, _ path: String) -> Run? {
        let ticket = Ticket(waveform: waveform, path: path, generation: generations[waveform, default: 0])
        guard running.insert(ticket).inserted else { return nil }
        return Run(ticket: ticket, designEpoch: designEpoch)
    }

    /// The run ended with `answer`. Whether to show it: false when its waveform was opened again
    /// since it started. It's kept for the next request only when `keep` and no design change came while it ran.
    public mutating func finish(_ run: Run, _ answer: Answer, keep: Bool) -> Bool {
        let ticket = run.ticket
        running.remove(ticket)
        guard ticket.generation == generations[ticket.waveform, default: 0] else { return false }
        if keep, run.designEpoch == designEpoch { answers[ticket.waveform, default: [:]][ticket.path] = answer }
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
