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
        /// The row is the compiled design's (its KDB model's) only: slang's design lacks its instance,
        /// or has it as another module. Its writes (driving statements), not evaluated.
        case compiledOnly(dumpPath: String, reason: CompiledOnlyReason, writes: [KDBDesignModel.Write])
        /// A row the KDB mapped to slang's design (as `signal`) where the compiled design and slang's
        /// differ, or could not be checked (KDBAgreement): slang's statements evaluate it all the
        /// same, so its steps are approximate.
        case approximate(designPath: String, designPrefix: String, dumpPrefix: String, differences: [KDBDifference])
    }

    public enum CompiledOnlyReason: String, Equatable, Sendable {
        /// slang's design has no instance for the row (a module its target leaves out).
        case notInSlang
        /// slang's design has the instance, as another module.
        case otherModule
    }

    /// `lookup`'s answer for a design path: nil when no top starts it.
    public typealias Lookup = (String) async -> (instance: String, name: String)?
    /// An instance's model (the sidecar's `instance` reply), nil when there is none.
    public typealias Model = (String) async -> [String: Any]?

    /// `dumpPath` (a row's netlist path) mapped by `mapping`, else by a rule inferred against
    /// `designRoots` (each design top and its children). A row keeping a range as wide as its
    /// signal (FSDB's `x[0:0]` for a 1-bit vector) is the signal without it, as host.js
    /// `withoutRange` reads rows. `loadMessages`: slang's errors loading the design (the sidecar's
    /// `messages`); a row below a scope the design lacks is `.notElaborated` only with some.
    /// `instances`: the design's instance paths (the sidecar's `instances`).
    public static func resolve(
        dumpPath: [String],
        mapping: HierarchyPathMapping,
        loadMessages: [String] = [],
        lookup: Lookup,
        model: Model,
        designRoots: () async throws -> [String: [HierarchyNode]],
        dumpChildren: HierarchyPrefixInference.Children,
        instances: (() async throws -> [String])? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        guard !dumpPath.isEmpty else { return .notInDesign }
        var mapping = mapping
        let dump = HierarchyPathMapping.join(dumpPath)
        let mappedPath = mapping.designPath(forDumpPath: dump)
        if let found = await signal(dumpPath, mapping: mapping, lookup: lookup, model: model) { return found }
        let roots = try await designRoots()
        let anchored = await anchor(dumpPath, mapping: mapping, lookup: lookup, roots: roots)
        func infer(_ roots: [String: [HierarchyNode]]) async -> HierarchyPathMapping.Rule? {
            await HierarchyPrefixInference.designRule(forDumpPath: dump, designRoots: roots, dumpChildren: dumpChildren,
                                                      ties: .ambiguous, signalsListed: false)
        }
        var inferred = await infer(within(anchored))
        // An anchor that holds nothing named like the dump's scope below it (a top that only shares
        // the testbench's name) is no anchor: all roots, when it gave no rule.
        if inferred == nil, let instances, let at = anchored.anchor, let length = anchored.length,
           await isCoincidental(anchor: at, below: Array(dumpPath.prefix(length + 1)), instances: try await instances(), dumpChildren: dumpChildren) {
            inferred = await infer(roots)
        }
        if let rule = inferred {
            mapping.addInferredRule(designPrefix: rule.designPrefix, dumpPrefix: rule.dumpPrefix)
            if let found = await signal(dumpPath, mapping: mapping, lookup: lookup, model: model) { return found }
        }
        // The path as the mapping gives it (the dump's own hierarchy): inference may have moved it.
        // Only a load with errors (slang's UnknownModule) leaves a module out: in a clean design a
        // scope the model lacks is a named block, a task, or a name the dump gives differently.
        if !loadMessages.isEmpty, let found = await lookup(mappedPath), let instanceModel = await model(found.instance),
           let missing = SVModelLoad.missingInstance(below: found.instance, name: found.name, inModel: instanceModel) {
            return .notElaborated(instance: missing)
        }
        return .notInDesign
    }

    /// The deepest scope above the row that the design has as it is (`tb` of `tb.dut.q` for a design `tb.u_dut`), when
    /// it is a root with scopes (a renamed child: the row's place in the design is below it), with the roots.
    private static func anchor(
        _ dumpPath: [String],
        mapping: HierarchyPathMapping,
        lookup: Lookup,
        roots: [String: [HierarchyNode]],
        isolation: isolated (any Actor)? = #isolation
    ) async -> (anchor: String?, length: Int?, roots: [String: [HierarchyNode]]) {
        for length in stride(from: dumpPath.count - 1, through: 1, by: -1) {
            let path = mapping.designPath(forDumpPath: HierarchyPathMapping.join(Array(dumpPath.prefix(length))))
            guard roots[path]?.contains(where: \.isScope) == true else { continue }
            if let found = await lookup(path), found.instance == path, found.name.isEmpty { return (path, length, roots) }
        }
        return (nil, nil, roots)
    }

    /// Whether `anchor` (a design instance the dump has by the same path) shares only its name
    /// with the dump's: the dump's scope `below` it on the row (`top.dut`) has child scopes, and no
    /// instance in the design under the anchor is named like any of them. A scope without child
    /// scopes is no evidence either way: the anchor stays.
    private static func isCoincidental(
        anchor: String,
        below: [String],
        instances: [String],
        dumpChildren: HierarchyPrefixInference.Children,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        let scopes = Set((await dumpChildren(below) ?? []).filter(\.isScope).map(\.name))
        guard !scopes.isEmpty else { return false }
        for path in instances where path.hasPrefix(anchor + ".") {
            let segments = HierarchyPathMapping.segments(String(path.dropFirst(anchor.count + 1)))
            if segments.contains(where: scopes.contains) { return false }
        }
        return true
    }

    /// The roots inside `anchor` (all without one): an extra top (a module nothing instantiates) whose names
    /// happen to match is no answer for a row below a scope the design has.
    private static func within(_ found: (anchor: String?, length: Int?, roots: [String: [HierarchyNode]])) -> [String: [HierarchyNode]] {
        guard let anchor = found.anchor else { return found.roots }
        return found.roots.filter { $0.key == anchor || $0.key.hasPrefix(anchor + ".") }
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

    static func result(designPath: String, dumpPath: [String]) -> Outcome {
        let prefixes = SVModelLoad.prefixes(dumpPath: dumpPath, designPath: HierarchyPathMapping.segments(designPath))
        return .signal(designPath: designPath, designPrefix: prefixes.designPrefix, dumpPrefix: prefixes.dumpPrefix)
    }

    /// Instances below the tops kept as roots, at most.
    static let maxInstanceRoots = 512

    /// The design's roots for inference (`HierarchyPrefixInference.designRule`): each top with
    /// its children (its scopes, then its signals), and each instance below the tops with its
    /// scopes only (no model is fetched for them; two scopes at least), so a dump scope named for a deeper instance
    /// (dump `tb.dut`, design `tb.u_dut`) can match by its child instances. A scope is a child
    /// instance's or generate block's first segment below the root (`g[0]` of `g[0].u_sub`,
    /// `g_blk` of the signal `g_blk.x`), listed once. `tops` and `instances` as the sidecar's
    /// `instances` answers them.
    public static func designRoots(
        tops: [String],
        instances: [String],
        model: Model,
        isolation: isolated (any Actor)? = #isolation
    ) async -> [String: [HierarchyNode]] {
        // Each instance's scopes, in one pass: every instance path names a scope below each instance on it.
        let known = Set(instances).union(tops)
        var below: [String: Set<String>] = [:]
        for path in instances {
            let parts = HierarchyPathMapping.segments(path)
            guard parts.count >= 2 else { continue }
            for k in 1..<parts.count where !parts[k].isEmpty {
                let prefix = HierarchyPathMapping.join(Array(parts[..<k]))
                if known.contains(prefix) { below[prefix, default: []].insert(parts[k]) }
            }
        }
        func scopes(below root: String) -> [String] { Array(below[root] ?? []) }
        var roots: [String: [HierarchyNode]] = [:]
        for top in tops {
            var scopeNames = Set(scopes(below: top))
            var signalNames: [String] = []
            for name in ((await model(top)?["signals"] as? [String: Any]) ?? [:]).keys {
                let parts = HierarchyPathMapping.segments(name)
                if parts.count > 1 { scopeNames.insert(parts[0]) } else { signalNames.append(name) }
            }
            roots[top] = scopeNames.sorted().map { HierarchyNode(name: $0, isScope: true) }
                + signalNames.sorted().map { HierarchyNode(name: $0, isScope: false) }
        }
        let topSet = Set(tops)
        // One shared scope name (a u_fifo) is too weak a match for an instance known by its scopes alone.
        var kept = 0
        for path in instances where !topSet.contains(path) && kept < maxInstanceRoots {
            let names = scopes(below: path)
            guard names.count >= 2 else { continue }
            roots[path] = names.sorted().map { HierarchyNode(name: $0, isScope: true) }
            kept += 1
        }
        return roots
    }

    /// The load error to show with `.notElaborated`: the first UnknownModule, else the first.
    public static func loadDetail(_ messages: [String]) -> String? {
        messages.first { $0.hasSuffix("UnknownModule") } ?? messages.first
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
