import Foundation

/// One request at a time, newest wish wins: a value asked for while a request
/// is in flight is sent once that one finishes (unless it is what was sent).
/// The waveform debugger's Locals follows the caret with it.
public struct LatestRequestCoalescer<Value: Equatable & Sendable>: Sendable {
    private var inFlight: Value?
    private var wanted: Value?

    public init() {}

    /// Asks for `value`. Returns what to send now, or nil while a request is in flight.
    public mutating func want(_ value: Value) -> Value? {
        wanted = value
        guard inFlight == nil else { return nil }
        inFlight = value
        return value
    }

    /// The request in flight finished. Returns the next one to send, if the wish changed meanwhile.
    public mutating func finished() -> Value? {
        let sent = inFlight
        inFlight = nil
        guard let wanted, wanted != sent else { return nil }
        inFlight = wanted
        return wanted
    }
}
