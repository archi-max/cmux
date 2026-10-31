import Foundation

/// Asks slang-server where a file's lines sit in the design, one probe identifier at a time.
public enum DesignInstanceProbe {
    /// The instances the first probe that finds any gives ([] when the probes answered and
    /// none found any). Nil when nothing was learned, so it is no miss to remember: cancelled,
    /// or no probe got an answer. `lookup` gives one probe's instances; a probe whose lookup
    /// fails goes on to the next.
    // (Not yet implemented: the checks compile against these.)
    public static let fragmentProbeLimit = 4
    public static let fragmentSearchTimeLimit: TimeInterval = 10
    public static func reportsNotPlaced(isFragment: Bool) -> Bool { true }
    public static func retryDelay(misses: Int, failures: Int) -> TimeInterval {
        failures > 0 ? 2 : min(300, 10 * pow(2, Double(max(0, misses - 1))))
    }

    public static func firstFound<Probe: Sendable>(
        _ probes: [Probe],
        isolation: isolated (any Actor)? = #isolation,
        _ lookup: (Probe) async throws -> [String]
    ) async -> [String]? {
        var answered = false
        for probe in probes {
            let instances = try? await lookup(probe)
            if Task.isCancelled { return nil }
            guard let instances else { continue }
            answered = true
            if !instances.isEmpty { return instances }
        }
        return answered && !Task.isCancelled ? [] : nil
    }
}
