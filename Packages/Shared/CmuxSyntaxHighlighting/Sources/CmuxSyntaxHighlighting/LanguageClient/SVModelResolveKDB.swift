import Foundation

/// A waveform row's design path with the dump's KDB model (KDBDesignModel: what VCS elaborated, under
/// the dump's own names). The KDB decides what exists and how the row maps to slang's design; slang's
/// statements still evaluate it (until the KDB's statements are exported).
extension SVModelResolve {
    /// `resolve` with the dump's KDB model (nil: exactly `resolve`'s answer).
    ///
    /// A row the KDB has (a signal, or one without a range as wide as it) maps to slang's design by
    /// instance names and modules: going down the row's instance chain from its top, the first dump
    /// scope with a slang instance of its module whose path below it has slang instances of the same
    /// modules (the KDB's) as the dump's is the rule (design prefix -> dump prefix).
    /// - One such slang instance: the row under that rule, as slang's signal (evaluated).
    /// - Several: no unique answer; today's (inferred) rule, and `log` says why.
    /// - None: the compiled design's row only (`.compiledOnly`, its KDB writes, not evaluated):
    ///   `.otherModule` when slang has the dump's own path as other modules, else `.notInSlang`.
    /// A row the KDB lacks: today's answer.
    public static func resolve(
        dumpPath: [String],
        mapping: HierarchyPathMapping,
        loadMessages: [String] = [],
        lookup: Lookup,
        model: Model,
        designRoots: () async throws -> [String: [HierarchyNode]],
        dumpChildren: HierarchyPrefixInference.Children,
        kdb: KDBDesignModel?,
        instances: @escaping () async throws -> [String],
        log: (String) -> Void = { _ in },
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        func today() async throws -> Outcome {
            try await resolve(dumpPath: dumpPath, mapping: mapping, loadMessages: loadMessages, lookup: lookup, model: model,
                              designRoots: designRoots, dumpChildren: dumpChildren, instances: instances)
        }
        guard let kdb, let (rowSegments, row) = kdbRow(dumpPath, in: kdb), let (instance, name) = kdb.lookup(row), !name.isEmpty else {
            return try await today()
        }
        // The row's instance chain, top first.
        var chain: [String] = []
        var next: String? = instance
        while let path = next, chain.count < 512 {
            chain.insert(path, at: 0)
            next = kdb.instance(path)?["parent"] as? String
        }
        let slang = try await instances()
        let known = Set(slang)
        let tops = slang.filter { !$0.contains(".") }
        var modules: [String: String] = [:]
        func module(_ path: String) async -> String? {
            if let known = modules[path] { return known }
            let found = await model(path)?["module"] as? String
            if let found { modules[path] = found }
            return found
        }
        func below(_ path: String, _ prefix: String) -> String { path == prefix ? "" : String(path.dropFirst(prefix.count + 1)) }
        var otherModule = false
        for (level, prefix) in chain.enumerated() {
            let suffix = below(instance, prefix)
            // Slang instances standing where the dump's scope `prefix` does: those with the same path below.
            let candidates: [String] = suffix.isEmpty
                ? Array(Set(tops + (known.contains(prefix) ? [prefix] : [])))
                : slang.compactMap { $0.hasSuffix("." + suffix) ? String($0.dropLast(suffix.count + 1)) : nil }.filter { known.contains($0) }
            var matched: [String] = []
            for candidate in candidates.sorted() {
                var same = true
                for path in chain[level...] {
                    let rest = below(path, prefix)
                    let there = rest.isEmpty ? candidate : candidate + "." + rest
                    guard let theirs = await module(there), theirs == kdb.instance(path)?["module"] as? String else {
                        same = false
                        break
                    }
                }
                if same {
                    matched.append(candidate)
                } else if candidate == prefix {
                    // slang has the dump's own path, as other modules: never evaluated with its statements.
                    otherModule = true
                }
            }
            if otherModule {
                return .compiledOnly(dumpPath: row, reason: .otherModule, writes: kdb.writes(of: row))
            }
            if matched.count > 1 {
                log("KDB mapping of \(row): \(matched.joined(separator: ", ")) are all \(prefix)'s modules; the inferred rule instead")
                return try await today()
            }
            guard let designPrefix = matched.first else { continue }
            let rest = below(row, prefix)
            let designPath = designPrefix + "." + rest
            let designInstance = below(instance, prefix).isEmpty ? designPrefix : designPrefix + "." + below(instance, prefix)
            if let found = await lookup(designPath), found.instance == designInstance,
               let instanceModel = await model(found.instance), SVModelLoad.isSignal(found.name, inModel: instanceModel) {
                return result(designPath: designPath, dumpPath: rowSegments)
            }
            return .compiledOnly(dumpPath: row, reason: .notInSlang, writes: kdb.writes(of: row))
        }
        return .compiledOnly(dumpPath: row, reason: .notInSlang, writes: kdb.writes(of: row))
    }

    /// The row as the KDB's signal: as it is, else without a trailing `[msb:lsb]` as wide as it.
    private static func kdbRow(_ dumpPath: [String], in kdb: KDBDesignModel) -> ([String], String)? {
        let row = HierarchyPathMapping.join(dumpPath)
        if kdb.hasSignal(row) { return (dumpPath, row) }
        guard let last = dumpPath.last, let (base, width) = rangeSuffix(last) else { return nil }
        let segments = Array(dumpPath.dropLast()) + [base]
        let stripped = HierarchyPathMapping.join(segments)
        guard kdb.hasSignal(stripped), let (instance, name) = kdb.lookup(stripped),
              let signal = (kdb.instance(instance)?["signals"] as? [String: Any])?[name] as? [String: Any],
              signal["width"] as? Int == width else { return nil }
        return (segments, stripped)
    }
}
