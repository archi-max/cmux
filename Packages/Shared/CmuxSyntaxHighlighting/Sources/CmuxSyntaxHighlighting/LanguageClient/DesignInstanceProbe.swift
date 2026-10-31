import Foundation

/// Asks slang-server where a file's lines sit in the design, one probe identifier at a time.
public enum DesignInstanceProbe {
    /// The instances the first probe that finds any gives ([] when none does).
    /// `lookup` gives one probe's instances.
    public static func firstFound<Probe: Sendable>(
        _ probes: [Probe],
        isolation: isolated (any Actor)? = #isolation,
        _ lookup: (Probe) async throws -> [String]
    ) async -> [String]? {
        for probe in probes {
            guard let instances = try? await lookup(probe), !Task.isCancelled else { return [] }
            if !instances.isEmpty { return instances }
        }
        return []
    }
}
