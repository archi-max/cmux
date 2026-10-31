import Foundation

/// Asks slang-server where a file's lines sit in the design, one probe identifier at a time.
public enum DesignInstanceProbe {
    /// The instances the first probe that finds any gives ([] when the probes answered and
    /// none found any). Nil when nothing was learned, so it is no miss to remember: cancelled,
    /// or a lookup failed. A failure is the server's (compiling, timed out), not the probe's,
    /// so the rest aren't asked to wait out the same; but a path slang can't resolve at that
    /// position (a macro, a type or a package name) is that probe finding nothing, and the next
    /// is asked. `lookup` gives one probe's instances.
    /// A file with no design unit may be an `include`d fragment, or only a header of parameters
    /// and typedefs that sits in a package: until slang shows an includer it is asked cheaply,
    /// and finding none says nothing.
    public static let fragmentProbeLimit = 2
    /// Seconds slang-server may walk the design for a fragment's includer, per probe.
    public static let fragmentSearchTimeLimit: TimeInterval = 2

    /// Whether finding no instance is shown as "isn't placed in the design" (with its fix).
    /// `designHasTops` false: the design has no top level at all, so the hint how to set one up
    /// is shown for a fragment too.
    public static func reportsNotPlaced(isFragment: Bool, designHasTops: Bool? = nil) -> Bool {
        !isFragment || designHasTops == false
    }

    /// Whether the design has a top level, from getScope("") after a fragment found nowhere
    /// (`scopeKinds`: its items' kinds, nil when it failed; packages are no top). Cancelled
    /// (a scroll, an edit) or failed, it is no answer: what was known stays.
    public static func designHasTops(scopeKinds: [String]?, cancelled: Bool, current: Bool?) -> Bool? {
        guard !cancelled, let scopeKinds else { return current }
        return scopeKinds.contains { $0 != "Package" }
    }

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
            let instances: [String]
            do {
                instances = try await lookup(probe)
            } catch where LanguageServerSession.isUnresolvedPath(error) {
                if Task.isCancelled { return nil }
                continue
            } catch {
                return nil
            }
            if Task.isCancelled { return nil }
            if !instances.isEmpty { return instances }
        }
        return Task.isCancelled ? nil : []
    }
}
