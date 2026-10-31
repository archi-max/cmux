import Foundation

/// Asks slang-server where a file's lines sit in the design, one probe identifier at a time.
public enum DesignInstanceProbe {
    /// The instances the first probe that finds any gives ([] when the probes answered and
    /// none found any). Nil when nothing was learned, so it is no miss to remember: cancelled,
    /// or a lookup failed. A failure is the server's (compiling, timed out), not the probe's,
    /// so the rest aren't asked to wait out the same. `lookup` gives one probe's instances.
    /// A file with no design unit may be an `include`d fragment, or only a header of parameters
    /// and typedefs that sits in a package: until slang shows an includer it is asked cheaply,
    /// and finding none says nothing.
    public static let fragmentProbeLimit = 2
    /// Seconds slang-server may walk the design for a fragment's includer, per probe.
    public static let fragmentSearchTimeLimit: TimeInterval = 2

    /// Whether finding no instance is shown as "isn't placed in the design" (with its fix).
    public static func reportsNotPlaced(isFragment: Bool, designHasTops: Bool? = nil) -> Bool { !isFragment }

    /// Seconds before a module's instances are asked again: after `failures` lookups in a row
    /// no probe answered (the server busy), 2 s doubling to 30 s; else after `misses` lookups
    /// in a row that found none, 10 s doubling to 5 min.
    public static func retryDelay(misses: Int, failures: Int) -> TimeInterval {
        if failures > 0 { return min(30, 2 * pow(2, Double(failures - 1))) }
        return min(300, 10 * pow(2, Double(max(0, misses - 1))))
    }

    public static func firstFound<Probe: Sendable>(
        _ probes: [Probe],
        isolation: isolated (any Actor)? = #isolation,
        _ lookup: (Probe) async throws -> [String]
    ) async -> [String]? {
        for probe in probes {
            let instances = try? await lookup(probe)
            if Task.isCancelled { return nil }
            guard let instances else { return nil }
            if !instances.isEmpty { return instances }
        }
        return Task.isCancelled ? nil : []
    }
}
