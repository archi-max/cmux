import Foundation

/// Asks slang-server where a file's lines sit in the design, one probe identifier at a time.
public enum DesignInstanceProbe {
    /// The instances the first probe that finds any gives ([] when none does); nil when
    /// cancelled, as nothing was learned (not a miss to remember). `lookup` gives one
    /// probe's instances; a probe whose lookup fails goes on to the next.
    public static func firstFound<Probe: Sendable>(
        _ probes: [Probe],
        isolation: isolated (any Actor)? = #isolation,
        _ lookup: (Probe) async throws -> [String]
    ) async -> [String]? {
        for probe in probes {
            let instances = try? await lookup(probe)
            if Task.isCancelled { return nil }
            if let instances, !instances.isEmpty { return instances }
        }
        return Task.isCancelled ? nil : []
    }
}
