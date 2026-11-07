import Foundation

/// A waveform row's design path for Trace Driver (WaveformTrace.resolve), from the design model
/// sidecar's answers: its `lookup` (the deepest instance on a path and the rest below it) and
/// `instance` models. The rest is a signal only if the instance model has it: `lookup` names
/// a rest for any path, also one below a module the design left out.
public enum SVModelResolve {
    public enum Outcome: Equatable, Sendable {
        /// The design path, and the prefixes the page maps fan-in paths back with.
        case signal(designPath: String, designPrefix: String, dumpPrefix: String)
        /// The row lies below `instance`, which the design model lacks (slang's UnknownModule:
        /// a module the editor's slang target does not bring in).
        case notElaborated(instance: String)
        case notInDesign
    }

    /// `lookup`'s answer for a design path: nil when no top starts it.
    public typealias Lookup = (String) async -> (instance: String, name: String)?
    /// An instance's model (the sidecar's `instance` reply), nil when there is none.
    public typealias Model = (String) async -> [String: Any]?

    /// `dumpPath` (a row's netlist path) mapped by `mapping`, else by a rule inferred against
    /// `designRoots` (each design top and its children). A row keeping a range as wide as its
    /// signal (FSDB's `x[0:0]` for a 1-bit vector) is the signal without it, as host.js
    /// `withoutRange` reads rows.
    public static func resolve(
        dumpPath: [String],
        mapping: HierarchyPathMapping,
        lookup: Lookup,
        model: Model,
        designRoots: () async throws -> [String: [HierarchyNode]],
        dumpChildren: HierarchyPrefixInference.Children,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        guard !dumpPath.isEmpty else { return .notInDesign }
        var mapping = mapping
        let dump = HierarchyPathMapping.join(dumpPath)
        let mappedPath = mapping.designPath(forDumpPath: dump)
        if let found = await signal(dumpPath, mapping: mapping, lookup: lookup, model: model) { return found }
        if let rule = await HierarchyPrefixInference.designRule(
            forDumpPath: dump,
            designRoots: try await designRoots(),
            dumpChildren: dumpChildren
        ) {
            mapping.addInferredRule(designPrefix: rule.designPrefix, dumpPrefix: rule.dumpPrefix)
            if let found = await signal(dumpPath, mapping: mapping, lookup: lookup, model: model) { return found }
        }
        // The path as the mapping gives it (the dump's own hierarchy): inference may have moved it.
        if let found = await lookup(mappedPath), let instanceModel = await model(found.instance),
           let missing = SVModelLoad.missingInstance(below: found.instance, name: found.name, inModel: instanceModel) {
            return .notElaborated(instance: missing)
        }
        return .notInDesign
    }

    /// The row as a signal of the design under `mapping`: as it is, else without a trailing
    /// `[msb:lsb]` as wide as the design's signal of that name.
    private static func signal(
        _ dumpPath: [String],
        mapping: HierarchyPathMapping,
        lookup: Lookup,
        model: Model,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Outcome? {
        let designPath = mapping.designPath(forDumpPath: HierarchyPathMapping.join(dumpPath))
        if let found = await lookup(designPath), let instanceModel = await model(found.instance),
           SVModelLoad.isSignal(found.name, inModel: instanceModel) {
            return result(designPath: designPath, dumpPath: dumpPath)
        }
        guard let last = dumpPath.last, let (base, width) = rangeSuffix(last) else { return nil }
        let rowPath = Array(dumpPath.dropLast()) + [base]
        let strippedPath = mapping.designPath(forDumpPath: HierarchyPathMapping.join(rowPath))
        guard let found = await lookup(strippedPath), let instanceModel = await model(found.instance),
              SVModelLoad.isSignal(found.name, inModel: instanceModel),
              SVModelLoad.width(of: found.name, inModel: instanceModel) == width else { return nil }
        // The page finds the row from the stripped name as host.js does.
        return result(designPath: strippedPath, dumpPath: rowPath)
    }

    private static func result(designPath: String, dumpPath: [String]) -> Outcome {
        let prefixes = SVModelLoad.prefixes(dumpPath: dumpPath, designPath: HierarchyPathMapping.segments(designPath))
        return .signal(designPath: designPath, designPrefix: prefixes.designPrefix, dumpPrefix: prefixes.dumpPrefix)
    }

    /// Each design top and its children (child instances, then its signals), for inference:
    /// `tops` and `instances` as the sidecar's `instances` answers them.
    public static func designRoots(
        tops: [String],
        instances: [String],
        model: Model,
        isolation: isolated (any Actor)? = #isolation
    ) async -> [String: [HierarchyNode]] {
        var roots: [String: [HierarchyNode]] = [:]
        for top in tops {
            var children = instances
                .filter { $0.hasPrefix(top + ".") && !$0.dropFirst(top.count + 1).contains(".") }
                .map { HierarchyNode(name: String($0.dropFirst(top.count + 1)), isScope: true) }
            if let signals = await model(top)?["signals"] as? [String: Any] {
                children += signals.keys.sorted().map { HierarchyNode(name: $0, isScope: false) }
            }
            roots[top] = children
        }
        return roots
    }

    /// `name`'s trailing `[msb:lsb]`: the name before it and the bits it spans.
    static func rangeSuffix(_ name: String) -> (base: String, width: Int)? {
        guard !name.hasPrefix("\\"), name.hasSuffix("]"), let open = name.lastIndex(of: "["), open > name.startIndex else { return nil }
        let parts = name[name.index(after: open)..<name.index(before: name.endIndex)].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let msb = Int(parts[0]), let lsb = Int(parts[1]) else { return nil }
        return (String(name[..<open]), abs(msb - lsb) + 1)
    }
}
