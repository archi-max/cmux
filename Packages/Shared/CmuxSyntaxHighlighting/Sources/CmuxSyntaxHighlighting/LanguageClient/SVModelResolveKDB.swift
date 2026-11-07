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
    /// A mapped row is `.signal` (exact) only when the compiled design and slang's agree on it
    /// (KDBAgreement: parameters down its chain, its shape, ports and write lines, no source newer
    /// than the compile, by `sourceTimes`: slang's source files and their times, nil: unknown);
    /// otherwise `.approximate` with what differs. `kdbChecked` gets slang's instance paths the
    /// agreement covered (the row's chain from the matched level down), for a mapped row.
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
        sourceTimes: (() async -> [String: Int64]?)? = nil,
        kdbSameFiles: Bool = false,
        kdbChecked: ((Set<String>) -> Void)? = nil,
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
        var models: [String: [String: Any]] = [:]
        func slangModel(_ path: String) async -> [String: Any]? {
            if let known = models[path] { return known }
            let found = await model(path)
            if let found { models[path] = found }
            return found
        }
        func module(_ path: String) async -> String? { await slangModel(path)?["module"] as? String }
        func below(_ path: String, _ prefix: String) -> String { path == prefix ? "" : String(path.dropFirst(prefix.count + 1)) }
        // slang's instance chain for the row from `candidate` (standing for chain[level]) down: each
        // level under the same relative name as the KDB's, with the KDB's module. Where slang lacks
        // that name, the one child of the KDB's module stands for it when the KDB's parent also has
        // exactly one child of that module (slang u_dut for the KDB's dut: matched by unique module
        // type, `renamed`). `reason`: nil when the chain is complete, else .otherModule (an
        // instance of another module) or .notInSlang (one missing, or no unique stand-in).
        func chainWalk(from level: Int, at candidate: String) async -> (paths: [String], reason: CompiledOnlyReason?, renamed: [KDBDifference]) {
            var paths: [String] = []
            var renamed: [KDBDifference] = []
            for (i, path) in chain[level...].enumerated() {
                let kdbModule = kdb.instance(path)?["module"] as? String
                var here = candidate
                if i > 0 { here = paths[i - 1] + "." + below(path, chain[level + i - 1]) }
                guard let theirs = await module(here) else {
                    guard i > 0, let kdbModule else { return (paths, .notInSlang, renamed) }
                    let parent = chain[level + i - 1], slangParent = paths[i - 1]
                    let kdbSame = kdb.instancePaths.filter { kdb.instance($0)?["parent"] as? String == parent && kdb.instance($0)?["module"] as? String == kdbModule }
                    var slangSame: [String] = []
                    for p in slang where p.hasPrefix(slangParent + ".") {
                        // slang's child instances of the parent (none of the parent's instances in between).
                        var segments = HierarchyPathMapping.segments(p)
                        var up: String?
                        while segments.count > 1 {
                            segments.removeLast()
                            let q = HierarchyPathMapping.join(segments)
                            if known.contains(q) { up = q; break }
                        }
                        if up == slangParent, await module(p) == kdbModule { slangSame.append(p) }
                    }
                    guard kdbSame.count == 1, slangSame.count == 1 else { return (paths, .notInSlang, renamed) }
                    renamed.append(.matchedByModuleType(compiled: path, slang: slangSame[0]))
                    paths.append(slangSame[0])
                    continue
                }
                if theirs != kdbModule { return (paths, .otherModule, renamed) }
                paths.append(here)
            }
            return (paths, nil, renamed)
        }
        // today()'s answer only where its instance chain, from its rule's prefixes down, has the
        // KDB's modules (the row's instance and each above it, up to the dump prefix); else the
        // compiled design's row (never another module's statements).
        func checkedToday() async throws -> Outcome {
            let answer = try await today()
            guard case .signal(_, let designPrefix, let dumpPrefix) = answer else { return answer }
            for path in chain where dumpPrefix.isEmpty || path == dumpPrefix || path.hasPrefix(dumpPrefix + ".") {
                let rest = dumpPrefix.isEmpty ? path : below(path, dumpPrefix)
                let there = rest.isEmpty ? designPrefix : designPrefix.isEmpty ? rest : designPrefix + "." + rest
                if await module(there) != kdb.instance(path)?["module"] as? String {
                    log("KDB mapping of \(row): the inferred rule's \(there) is not \(path)'s module; the compiled design's row")
                    return .compiledOnly(dumpPath: row, reason: .otherModule, writes: kdb.writes(of: row))
                }
            }
            return answer
        }
        // slang's instance above `path` (nil: a top).
        func slangParent(_ path: String) -> String? {
            var segments = HierarchyPathMapping.segments(path)
            while segments.count > 1 {
                segments.removeLast()
                let parent = HierarchyPathMapping.join(segments)
                if known.contains(parent) { return parent }
            }
            return nil
        }
        // Where a candidate for chain[level] starts in slang: up slang's instances above it while
        // each is the module of the KDB's instance above (slang's counterpart of that scope). Below
        // the highest, only the same relative names stand for the KDB's (u_fifo[0] is no stand-in
        // for u_fifo[1] under a counterpart of their parent).
        func anchored(_ level: Int, _ candidate: String) async -> (level: Int, at: String) {
            var (k, at) = (level, candidate)
            while k > 0, let parent = slangParent(at), let theirs = await module(parent),
                  theirs == kdb.instance(chain[k - 1])?["module"] as? String {
                k -= 1
                at = parent
            }
            return (k, at)
        }
        let topSet = Set(tops)
        for (level, prefix) in chain.enumerated() {
            let suffix = below(instance, prefix)
            let kdbModule = kdb.instance(prefix)?["module"] as? String
            // Slang instances standing where the dump's scope `prefix` does: slang's instance of the
            // dump's own path, those with the same path below, and (slang's counterpart, whatever is
            // below it) those with the same child instance below.
            var candidates: Set<String> = known.contains(prefix) ? [prefix] : []
            var sameBelow: Set<String> = []
            if suffix.isEmpty {
                candidates.formUnion(tops)
            } else {
                sameBelow = Set(slang.compactMap { $0.hasSuffix("." + suffix) ? String($0.dropLast(suffix.count + 1)) : nil }.filter { known.contains($0) })
                let child = below(chain[level + 1], prefix)
                candidates.formUnion(sameBelow)
                candidates.formUnion(slang.compactMap { $0.hasSuffix("." + child) ? String($0.dropLast(child.count + 1)) : nil }.filter { known.contains($0) })
            }
            // Each candidate of the scope's module from where it starts in slang (`anchored`):
            // matched when slang's chain from there has the KDB's modules under the same relative
            // names, else a counterpart whose chain differs (slang has another module or nothing
            // where the dump does). A candidate of another module at the dump's own path or with
            // its whole path below (not a top: a testbench of its own) is slang's scope as another
            // module. The shallowest start decides: a counterpart there whose chain differs is the
            // compiled design's row, never a stand-in found deeper (a sibling, another index or
            // another top of the same module).
            var entries: [(level: Int, at: String, reason: CompiledOnlyReason?, paths: [String], renamed: [KDBDifference])] = []
            for candidate in candidates.sorted() {
                guard await module(candidate) == kdbModule else {
                    let here = candidate == prefix || sameBelow.contains(candidate)
                    if here, suffix.isEmpty ? candidate == prefix : !topSet.contains(candidate) {
                        entries.append((level, candidate, .otherModule, [], []))
                    }
                    continue
                }
                let start = await anchored(level, candidate)
                let walk = await chainWalk(from: start.level, at: start.at)
                var reason = walk.reason
                // Where slang's chain starts below a scope that is not the dump's (another testbench),
                // it starts under the dump's own instance name relative to the parent (tb_soc.dut for
                // tb.dut), else at a top (soc): a renamed instance (dut_r) is no stand-in either.
                // The whole name below the parent is compared (g[1].dut is no stand-in for g[0].dut).
                if reason == nil, !topSet.contains(start.at) {
                    let kdbParent = kdb.instance(chain[start.level])?["parent"] as? String
                    let theirs = slangParent(start.at).map { below(start.at, $0) } ?? start.at
                    let ours = kdbParent.map { below(chain[start.level], $0) } ?? chain[start.level]
                    if theirs != ours { reason = .notInSlang }
                }
                if !entries.contains(where: { $0.level == start.level && $0.at == start.at }) { entries.append((start.level, start.at, reason, walk.paths, walk.renamed)) }
            }
            guard let shallowest = entries.map(\.level).min() else { continue }
            let decisive = entries.filter { $0.level == shallowest }
            let matched = decisive.filter { $0.reason == nil }
            if matched.isEmpty {
                return .compiledOnly(dumpPath: row, reason: decisive.contains { $0.reason == .otherModule } ? .otherModule : .notInSlang,
                                     writes: kdb.writes(of: row))
            }
            if matched.count > 1 {
                log("KDB mapping of \(row): \(matched.map(\.at).joined(separator: ", ")) are all \(chain[shallowest])'s modules; the inferred rule instead")
                return try await checkedToday()
            }
            let (level, paths, renamed) = (shallowest, matched[0].paths, matched[0].renamed)
            guard let designInstance = paths.last else { continue }
            let designPath = designInstance + "." + name
            if let found = await lookup(designPath), found.instance == designInstance,
               let instanceModel = await slangModel(found.instance), SVModelLoad.isSignal(found.name, inModel: instanceModel) {
                let mapped = result(designPath: designPath, dumpPath: rowSegments)
                var levels: [KDBAgreement.Level] = []
                var paired: [(slangPath: String, level: KDBAgreement.Level)] = []
                var lost = false
                for (path, slangPath) in zip(chain[level...], paths) {
                    guard let compiled = kdb.instance(path), let slang = await slangModel(slangPath) else {
                        lost = true
                        continue
                    }
                    let one = KDBAgreement.Level(path: path, compiled: compiled, slang: slang)
                    levels.append(one)
                    paired.append((slangPath, one))
                }
                kdbChecked?(KDBAgreement.agreed(levels: paired, overrides: kdb.overrides, sameFiles: kdbSameFiles))
                let times = await sourceTimes?()
                var differences = KDBAgreement.differences(chain: levels, signal: name, compiledAt: kdb.compiledAt, sourceTimes: times,
                                                           overrides: kdb.overrides, sameFiles: kdbSameFiles)
                if lost, !differences.contains(.notChecked(.chain)) { differences.append(.notChecked(.chain)) }
                // Matched by unique module type: evaluated, never exact.
                differences = renamed + differences
                guard !differences.isEmpty, case .signal(let p, let dp, let up) = mapped else { return mapped }
                log("KDB mapping of \(row): approximate (\(differences.map(\.kind).joined(separator: ", ")))")
                return .approximate(designPath: p, designPrefix: dp, dumpPrefix: up, differences: differences)
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
