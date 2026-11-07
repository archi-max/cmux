#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Trace Driver from a waveform row with the dump's KDB model (what VCS elaborated, the dump's own
/// names): the KDB says what exists and maps the row to slang's design exactly, by instance names
/// and modules; slang's statements still evaluate it. A row slang lacks, or has as another module,
/// is the compiled design's only: its writes, not evaluated. No KDB: today's resolve.
@MainActor
@Suite struct SVModelResolveKDBTests {
    /// A slang design: instance models (with their modules), by path.
    struct Design {
        var models: [String: [String: Any]]
        var tops: [String]

        func lookup(_ path: String) -> (instance: String, name: String)? {
            var best = ""
            var index = path.startIndex
            while true {
                let next = path[index...].firstIndex(of: ".") ?? path.endIndex
                let prefix = String(path[..<next])
                if models[prefix] != nil { best = prefix }
                guard next < path.endIndex else { break }
                index = path.index(after: next)
            }
            guard !best.isEmpty else { return nil }
            return (best, best.count < path.count ? String(path.dropFirst(best.count + 1)) : "")
        }

        var instances: [String] { models.keys.sorted() }
    }

    static func inst(_ module: String, _ signals: [String]) -> [String: Any] {
        ["module": module, "params": [String: Any](), "signals": Dictionary(uniqueKeysWithValues: signals.map { ($0, ["width": 1, "kind": "var"] as [String: Any]) })]
    }

    /// A KDB model: (path, module, parent, signals, writes {name: line}) in `file`.
    static func kdb(_ instances: [(String, String, String?, [String], [String: Int])], file: String = "/work/rtl/soc.sv") -> KDBDesignModel {
        var models: [String: Any] = [:]
        for (path, module, parent, signals, writes) in instances {
            models[path] = [
                "path": path, "module": module, "parent": parent as Any, "ports": [], "files": [file], "params": [String: Any](),
                "signals": Dictionary(uniqueKeysWithValues: signals.map { ($0, ["width": 1, "kind": "var", "msb": 0, "lsb": 0] as [String: Any]) }),
                "writes": writes.mapValues { [["kind": "nb", "loc": [0, $0, 0]]] },
                "children": instances.filter { $0.2 == path }.map { ["path": $0.0, "name": String($0.0.dropFirst(path.count + 1)), "module": $0.1] },
            ] as [String: Any]
        }
        let tops = instances.filter { $0.2 == nil }.map(\.0)
        let data = try! JSONSerialization.data(withJSONObject: ["tops": tops, "instances": models, "compiled": 1, "overrides": [String]()])
        return KDBDesignModel(json: data)!
    }

    /// The mapping a resolve made (these tests are about the mapping; whether the compiled design
    /// and slang's agree on it is KDBAgreementTests'): an approximate row as its signal.
    func mapping(_ outcome: SVModelResolve.Outcome) -> SVModelResolve.Outcome {
        guard case .approximate(let designPath, let designPrefix, let dumpPrefix, _) = outcome else { return outcome }
        return .signal(designPath: designPath, designPrefix: designPrefix, dumpPrefix: dumpPrefix)
    }

    func resolve(_ row: String, design: Design, dump: [String: [HierarchyNode]] = [:], kdb: KDBDesignModel?,
                 loadMessages: [String] = [], log: @escaping (String) -> Void = { _ in }) async throws -> SVModelResolve.Outcome {
        try await SVModelResolve.resolve(
            dumpPath: HierarchyPathMapping.segments(row),
            mapping: HierarchyPathMapping(),
            loadMessages: loadMessages,
            lookup: { design.lookup($0) },
            model: { design.models[$0] },
            designRoots: { await SVModelResolve.designRoots(tops: design.tops, instances: design.instances, model: { design.models[$0] }) },
            dumpChildren: { dump[HierarchyPathMapping.join($0)] },
            kdb: kdb,
            instances: { design.instances },
            sourceTimes: { [:] },
            log: log
        )
    }

    func today(_ row: String, design: Design, dump: [String: [HierarchyNode]] = [:], loadMessages: [String] = []) async throws -> SVModelResolve.Outcome {
        try await SVModelResolve.resolve(
            dumpPath: HierarchyPathMapping.segments(row),
            mapping: HierarchyPathMapping(),
            loadMessages: loadMessages,
            lookup: { design.lookup($0) },
            model: { design.models[$0] },
            designRoots: { await SVModelResolve.designRoots(tops: design.tops, instances: design.instances, model: { design.models[$0] }) },
            dumpChildren: { dump[HierarchyPathMapping.join($0)] }
        )
    }

    /// tb > u_soc (soc) > u_mbox (mbox), as VCS compiled it.
    static let socKDB = kdb([
        ("tb", "tb", nil, ["clk"], ["clk": 5]),
        ("tb.u_soc", "soc", "tb", ["clk", "irq"], ["irq": 30]),
        ("tb.u_soc.u_mbox", "mbox", "tb.u_soc", ["rdata", "box"], ["rdata": 40]),
    ])

    // (a) The single-file slang target: slang has the testbench only (soc is in another file).
    @Test func aModuleSlangLeftOutIsTheCompiledDesignsWithItsWriteLine() async throws {
        let tbOnly = Design(models: ["tb": Self.inst("tb", ["clk"])], tops: ["tb"])
        let unknown = ["rtl/tb.sv:19: UnknownModule"]
        // Today: the module slang left out.
        #expect(try await today("tb.u_soc.u_mbox.rdata", design: tbOnly, loadMessages: unknown) == .notElaborated(instance: "tb.u_soc"))
        // With the KDB: the compiled design's writes, no error.
        let got = try await resolve("tb.u_soc.u_mbox.rdata", design: tbOnly, kdb: Self.socKDB, loadMessages: unknown)
        #expect(got == .compiledOnly(dumpPath: "tb.u_soc.u_mbox.rdata", reason: .notInSlang,
                                     writes: [KDBDesignModel.Write(kind: "nb", file: "/work/rtl/soc.sv", line: 40)]))
        // A signal slang has stays slang's (exact mapping, evaluated).
        #expect(mapping(try await resolve("tb.clk", design: tbOnly, kdb: Self.socKDB, loadMessages: unknown))
                == .signal(designPath: "tb.clk", designPrefix: "", dumpPrefix: ""))
        // A row the KDB lacks too: as today.
        #expect(try await resolve("tb.nothing", design: tbOnly, kdb: Self.socKDB, loadMessages: unknown)
                == today("tb.nothing", design: tbOnly, loadMessages: unknown))
    }

    // (b) Two slang tops alike by name (a soc and a soc_lite with the same children): inference ties,
    // the KDB's modules pick the one the dump is.
    @Test func theKDBsModulesPickTheTopInferenceTiesOn() async throws {
        let twoTops = Design(models: [
            "soc_a": Self.inst("soc", ["clk", "irq"]), "soc_a.u_mbox": Self.inst("mbox", ["rdata", "box"]),
            "soc_b": Self.inst("soc_lite", ["clk", "irq"]), "soc_b.u_mbox": Self.inst("mbox", ["rdata", "box"]),
        ], tops: ["soc_a", "soc_b"])
        let dump: [String: [HierarchyNode]] = [
            "tb": [HierarchyNode(name: "u_soc", isScope: true), HierarchyNode(name: "clk", isScope: false)],
            "tb.u_soc": [HierarchyNode(name: "u_mbox", isScope: true), HierarchyNode(name: "clk", isScope: false), HierarchyNode(name: "irq", isScope: false)],
        ]
        #expect(try await today("tb.u_soc.u_mbox.rdata", design: twoTops, dump: dump) == .notInDesign)
        #expect(mapping(try await resolve("tb.u_soc.u_mbox.rdata", design: twoTops, dump: dump, kdb: Self.socKDB))
                == .signal(designPath: "soc_a.u_mbox.rdata", designPrefix: "soc_a", dumpPrefix: "tb.u_soc"))
    }

    // (b) A renamed top: the KDB's exact rule and today's inferred one agree.
    @Test func aRenamedTopMapsAsInferenceDoes() async throws {
        let dutTop = Design(models: ["soc": Self.inst("soc", ["clk", "irq"]), "soc.u_mbox": Self.inst("mbox", ["rdata", "box"])], tops: ["soc"])
        let dump: [String: [HierarchyNode]] = [
            "tb": [HierarchyNode(name: "u_soc", isScope: true), HierarchyNode(name: "clk", isScope: false)],
            "tb.u_soc": [HierarchyNode(name: "u_mbox", isScope: true), HierarchyNode(name: "clk", isScope: false), HierarchyNode(name: "irq", isScope: false)],
        ]
        for row in ["tb.u_soc.u_mbox.rdata", "tb.u_soc.irq"] {
            let exact = mapping(try await resolve(row, design: dutTop, dump: dump, kdb: Self.socKDB))
            #expect(exact == (try await today(row, design: dutTop, dump: dump)), "\(row)")
            if case .signal(_, let designPrefix, let dumpPrefix) = exact { #expect(designPrefix == "soc" && dumpPrefix == "tb.u_soc") } else { Issue.record("\(row): \(exact)") }
        }
    }

    // Same instance name, another module: the compiled design's, never slang's statements.
    @Test func anInstanceOfAnotherModuleInSlangIsTheCompiledDesigns() async throws {
        let other = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_soc": Self.inst("soc_v2", ["clk", "irq"]),
            "tb.u_soc.u_mbox": Self.inst("mbox", ["rdata", "box"]),
        ], tops: ["tb"])
        let got = try await resolve("tb.u_soc.u_mbox.rdata", design: other, kdb: Self.socKDB)
        #expect(got == .compiledOnly(dumpPath: "tb.u_soc.u_mbox.rdata", reason: .otherModule,
                                     writes: [KDBDesignModel.Write(kind: "nb", file: "/work/rtl/soc.sv", line: 40)]))
    }

    // Two slang instances alike by name and module: no unique answer, so today's rule, and why is logged.
    @Test func aTieFallsBackToTodaysRuleAndSaysWhy() async throws {
        let twins = Design(models: [
            "soc_a": Self.inst("soc", ["clk", "irq"]), "soc_a.u_mbox": Self.inst("mbox", ["rdata", "box"]),
            "soc_b": Self.inst("soc", ["clk", "irq"]), "soc_b.u_mbox": Self.inst("mbox", ["rdata", "box"]),
        ], tops: ["soc_a", "soc_b"])
        var logged: [String] = []
        let got = try await resolve("tb.u_soc.u_mbox.rdata", design: twins, kdb: Self.socKDB, log: { logged.append($0) })
        #expect(got == (try await today("tb.u_soc.u_mbox.rdata", design: twins)))
        #expect(logged.count == 1 && logged[0].contains("soc_a") && logged[0].contains("soc_b"), "\(logged)")
    }

    /// A real design (env KDB_MODEL: npi-model.py's export; SLANG_MODEL: cmux-sv-model's `--once '*'`
    /// of the same design; skipped without them): every signal row of the KDB maps to slang's same path
    /// (exact or approximate: the coverage line counts each).
    @Test func aRealDesignsRowsMapAsTheyAre() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let kdbPath = env["KDB_MODEL"], let slangPath = env["SLANG_MODEL"] else { return }
        let kdb = try #require(KDBDesignModel(json: try Data(contentsOf: URL(fileURLWithPath: kdbPath))))
        let slangObject = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: slangPath))) as? [String: Any])
        let design = Design(models: try #require(slangObject["instances"] as? [String: [String: Any]]), tops: slangObject["tops"] as? [String] ?? [])
        var rows = 0, same = 0, other: [String] = []
        var coverage = KDBCoverage()
        for path in kdb.instancePaths {
            for name in ((kdb.instance(path)?["signals"] as? [String: Any]) ?? [:]).keys.sorted() {
                let row = path + "." + name
                guard design.models[path].map({ ($0["signals"] as? [String: Any])?[name] != nil }) == true else { continue }
                rows += 1
                let got = try await resolve(row, design: design, kdb: kdb)
                coverage.add(got)
                if case .signal(let designPath, _, _) = got, designPath == row {
                    same += 1
                } else if case .approximate(let designPath, _, _, _) = got, designPath == row {
                    same += 1
                } else if other.count < 5 {
                    other.append("\(row): \(got)")
                }
            }
        }
        print("[kdb resolve] \(rows) rows, \(same) as they are; \(coverage.summary)")
        #expect(rows > 0 && same == rows, "\(other)")
    }

    // The review's probe E with the dump's KDB: tb `top` (module tb) > dut (soc) > u_a, u_b (blk);
    // slang has an unrelated top `top` (module harness) and soc as a top of its own.
    @Test func aTopNamedLikeTheDumpsTestbenchMapsExactlyWithTheKDB() async throws {
        let design = Design(models: [
            "top": Self.inst("harness", ["clk"]), "top.u_x": Self.inst("blk_x", ["a"]), "top.u_y": Self.inst("blk_x", ["a"]),
            "soc": Self.inst("soc", ["clk"]), "soc.u_a": Self.inst("blk", ["x"]), "soc.u_b": Self.inst("blk", ["x"]),
        ], tops: ["soc", "top"])
        let kdb = Self.kdb([
            ("top", "tb", nil, ["clk"], [:]),
            ("top.dut", "soc", "top", ["clk"], [:]),
            ("top.dut.u_a", "blk", "top.dut", ["x"], ["x": 12]),
            ("top.dut.u_b", "blk", "top.dut", ["x"], ["x": 12]),
        ])
        #expect(mapping(try await resolve("top.dut.u_a.x", design: design, kdb: kdb)) == .signal(designPath: "soc.u_a.x", designPrefix: "soc", dumpPrefix: "top.dut"))
        #expect(mapping(try await resolve("top.dut.clk", design: design, kdb: kdb)) == .signal(designPath: "soc.clk", designPrefix: "soc", dumpPrefix: "top.dut"))
        // The testbench's own signal: slang's `top` is another module (harness), so not evaluated.
        #expect(try await resolve("top.clk", design: design, kdb: kdb) == .compiledOnly(dumpPath: "top.clk", reason: .otherModule, writes: []))
    }

    // (d) slang's design differs from what VCS compiled (Refs T2a round 3): the KDB never maps a row
    // to another instance (a sibling, another index or top) nor evaluates it where slang's module
    // differs; compiledOnly instead.

    /// slang lacks tb.u_dut; tb's one child of module dut (u_other) stands for it, as the KDB's tb
    /// has one too: matched by unique module type, evaluated, never exact.
    @Test func aLoneChildOfTheModuleMatchesByModuleType() async throws {
        let design = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_other": Self.inst("dut", ["clk"]), "tb.u_other.u_core": Self.inst("core", ["x"]),
        ], tops: ["tb"])
        let kdb = Self.kdb([
            ("tb", "tb", nil, ["clk"], [:]), ("tb.u_dut", "dut", "tb", ["clk"], [:]), ("tb.u_dut.u_core", "core", "tb.u_dut", ["x"], ["x": 9]),
        ])
        let got = try await resolve("tb.u_dut.u_core.x", design: design, kdb: kdb)
        guard case .approximate(let path, _, _, let differences) = got else {
            Issue.record("not evaluated: \(got)")
            return
        }
        #expect(path == "tb.u_other.u_core.x")
        #expect(differences.contains(.matchedByModuleType(compiled: "tb.u_dut", slang: "tb.u_other")), "\(differences)")
    }

    /// slang lacks tb.u_dut and has two children of module dut: neither stands for it (the
    /// reviewer's sibling case); nor when the KDB's tb has two.
    @Test func twoSameTypeSiblingsAreNoStandIn() async throws {
        let design = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_other": Self.inst("dut", ["clk"]), "tb.u_other.u_core": Self.inst("core", ["x"]),
            "tb.u_spare": Self.inst("dut", ["clk"]), "tb.u_spare.u_core": Self.inst("core", ["x"]),
        ], tops: ["tb"])
        let kdb = Self.kdb([
            ("tb", "tb", nil, ["clk"], [:]), ("tb.u_dut", "dut", "tb", ["clk"], [:]), ("tb.u_dut.u_core", "core", "tb.u_dut", ["x"], ["x": 9]),
        ])
        #expect(try await resolve("tb.u_dut.u_core.x", design: design, kdb: kdb) == .compiledOnly(dumpPath: "tb.u_dut.u_core.x", reason: .notInSlang, writes: Self.writes(kdb, "tb.u_dut.u_core.x")))
        let lone = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_other": Self.inst("dut", ["clk"]), "tb.u_other.u_core": Self.inst("core", ["x"]),
        ], tops: ["tb"])
        let twoCompiled = Self.kdb([
            ("tb", "tb", nil, ["clk"], [:]), ("tb.u_dut", "dut", "tb", ["clk"], [:]), ("tb.u_dut.u_core", "core", "tb.u_dut", ["x"], ["x": 9]),
            ("tb.u_dut2", "dut", "tb", ["clk"], [:]),
        ])
        #expect(try await resolve("tb.u_dut.u_core.x", design: lone, kdb: twoCompiled) == .compiledOnly(dumpPath: "tb.u_dut.u_core.x", reason: .notInSlang, writes: Self.writes(twoCompiled, "tb.u_dut.u_core.x")))
    }

    /// VCS elaborated g[0..3]; slang only g[0]: g[3] is not g[0], for every row of it.
    @Test func anotherGenerateIndexIsNoStandIn() async throws {
        var models: [String: [String: Any]] = ["tb": Self.inst("tb", ["clk"]), "tb.g[0].u_dut": Self.inst("dut", ["clk"]), "tb.g[0].u_dut.u_core": Self.inst("core", ["x"])]
        models["tb"]!["signals"] = ["clk": ["width": 1, "kind": "var"]]
        let design = Design(models: models, tops: ["tb"])
        var compiled: [(String, String, String?, [String], [String: Int])] = [("tb", "tb", nil, ["clk"], [:])]
        for k in 0..<4 { compiled += [("tb.g[\(k)].u_dut", "dut", "tb", ["clk"], [:]), ("tb.g[\(k)].u_dut.u_core", "core", "tb.g[\(k)].u_dut", ["x"], ["x": 9])] }
        let kdb = Self.kdb(compiled)
        #expect(try await resolve("tb.g[3].u_dut.u_core.x", design: design, kdb: kdb) == .compiledOnly(dumpPath: "tb.g[3].u_dut.u_core.x", reason: .notInSlang, writes: Self.writes(kdb, "tb.g[3].u_dut.u_core.x")))
        #expect(try await resolve("tb.g[3].u_dut.clk", design: design, kdb: kdb) == .compiledOnly(dumpPath: "tb.g[3].u_dut.clk", reason: .notInSlang, writes: []))
        #expect(mapping(try await resolve("tb.g[0].u_dut.u_core.x", design: design, kdb: kdb)) == .signal(designPath: "tb.g[0].u_dut.u_core.x", designPrefix: "", dumpPrefix: ""))
    }

    /// slang's testbench is another module (tbx) with only g[0].dut: the KDB's tb.g[1].dut is no
    /// stand-in for it. The whole name below the parent is compared (g[1].dut, not g[0].dut), not
    /// its last segment (dut). With slang's own g[1], it maps there: dut and below are the KDB's
    /// modules, only the testbench's differs (red: under tb, the g[0] decoy's tie sent it to the
    /// fallback and otherModule; under tbx, notInDesign).
    @Test func anotherTestbenchsOtherGenerateIndexIsNoStandIn() async throws {
        var compiled: [(String, String, String?, [String], [String: Int])] = [("tb", "tb", nil, ["clk"], [:])]
        for k in 0..<2 { compiled += [("tb.g[\(k)].dut", "dut", "tb", ["clk"], [:]), ("tb.g[\(k)].dut.u_core", "core", "tb.g[\(k)].dut", ["x"], ["x": 9])] }
        let kdb = Self.kdb(compiled)
        for top in ["tb", "tbx"] {
            var models: [String: [String: Any]] = [top: Self.inst("tbx", ["clk"]), "\(top).g[0].dut": Self.inst("dut", ["clk"]), "\(top).g[0].dut.u_core": Self.inst("core", ["x"])]
            let row = "tb.g[1].dut.u_core.x"
            let got = try await resolve(row, design: Design(models: models, tops: [top]), kdb: kdb)
            if case .compiledOnly(row, _, _) = got {} else { Issue.record("\(top): \(got)") }
            models["\(top).g[1].dut"] = Self.inst("dut", ["clk"])
            models["\(top).g[1].dut.u_core"] = Self.inst("core", ["x"])
            let both = mapping(try await resolve(row, design: Design(models: models, tops: [top]), kdb: kdb))
            #expect(both == .signal(designPath: "\(top).g[1].dut.u_core.x", designPrefix: top == "tb" ? "" : top, dumpPrefix: top == "tb" ? "" : "tb"), "\(top) with g[1]: \(both)")
        }
    }

    /// slang's tb.u_dut is another module; a spare sibling of the right one is no stand-in for
    /// anything below it.
    @Test func belowAnotherModuleNothingIsEvaluated() async throws {
        let design = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_dut": Self.inst("dut_v2", ["clk"]),
            "tb.u_spare": Self.inst("dut", ["clk"]), "tb.u_spare.u_core": Self.inst("core", ["x"]),
        ], tops: ["tb"])
        let kdb = Self.kdb([
            ("tb", "tb", nil, ["clk"], [:]), ("tb.u_dut", "dut", "tb", ["clk"], [:]), ("tb.u_dut.u_core", "core", "tb.u_dut", ["x"], ["x": 9]),
        ])
        #expect(try await resolve("tb.u_dut.clk", design: design, kdb: kdb) == .compiledOnly(dumpPath: "tb.u_dut.clk", reason: .otherModule, writes: []))
        #expect(try await resolve("tb.u_dut.u_core.x", design: design, kdb: kdb) == .compiledOnly(dumpPath: "tb.u_dut.u_core.x", reason: .otherModule, writes: Self.writes(kdb, "tb.u_dut.u_core.x")))
    }

    static func writes(_ kdb: KDBDesignModel, _ row: String) -> [KDBDesignModel.Write] { kdb.writes(of: row) }

    /// The reviewer's sweep: InferenceSweepTests' designs with modules, a KDB of the true design under
    /// the dump's names, and slang's design perturbed: p0 none, p1 a subtree removed, p2 an
    /// instance's module changed, p3 an instance renamed. With the KDB no row maps to another design
    /// path (wrong) and none is evaluated where slang's module differs. `KDB_SWEEP_N` designs per mode
    /// and perturbation (default 12), seeds from `KDB_SWEEP_START` (default 90000).
    @Test func perturbedDesignsNeverMapToAnotherInstanceOrModule() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["KDB_SWEEP_N"] ?? "") ?? 12, start = Int(env["KDB_SWEEP_START"] ?? "") ?? 90000
        for p in 0..<4 { for mode in 0..<6 {
            var rows = 0, wrong = 0, other = 0, wrongToday = 0, lost = 0, byType = 0
            var bad: [String] = []
            for i in start..<(start + n) {
                let seed = UInt64(i) &* 0x9E3779B97F4A7C15 &+ 777
                let o = try await Self.sweepOne(seed: seed, mode: mode, perturbation: p)
                rows += o.rows; wrong += o.wrong; other += o.other; wrongToday += o.wrongToday; lost += o.lost; byType += o.byType
                if bad.count < 8 { bad += o.samples.prefix(8 - bad.count) }
            }
            print("KDB SWEEP p\(p) mode \(mode): rows \(rows) wrong \(wrong) otherModule evaluated \(other) | without the KDB: wrong \(wrongToday) | lost (right without the KDB, not evaluated with it) \(lost) | matched by unique module type \(byType)")
            #expect(wrong == 0 && other == 0, "p\(p) mode \(mode): \(wrong) wrong, \(other) evaluated in another module: \(bad)")
        } }
    }

    struct SweepOut { var rows = 0, wrong = 0, other = 0, wrongToday = 0, lost = 0, byType = 0; var samples: [String] = [] }

    static func sweepOne(seed: UInt64, mode: Int, perturbation: Int) async throws -> SweepOut {
        let g = InferenceSweepTests.generate(seed: seed, mode: mode)
        // The KDB: every dumped design instance under its dump path, plus the dump's own scopes
        // above the DUT (tb, top_tb, top_tb.wrap), each with its module and parent.
        var compiled: [String: (module: String, signals: [String])] = [:]
        for (design, path) in g.dumpOf {
            compiled[path] = (g.modules[design] ?? "?", ((g.models[design]?["signals"] as? [String: Any]) ?? [:]).keys.sorted())
        }
        for scope in ["tb", "top_tb", "top_tb.wrap"] where g.dump[scope] != nil && compiled[scope] == nil {
            compiled[scope] = (String(scope.split(separator: ".").last!), (g.dump[scope] ?? []).filter { !$0.isScope }.map(\.name))
        }
        func parent(_ path: String) -> String? {
            var segs = HierarchyPathMapping.segments(path)
            while segs.count > 1 { segs.removeLast(); let p = HierarchyPathMapping.join(segs); if compiled[p] != nil { return p } }
            return nil
        }
        let kdb = Self.kdb(compiled.keys.sorted().map { ($0, compiled[$0]!.module, parent($0), compiled[$0]!.signals, [:]) })
        // slang's design, with modules, perturbed at one dumped non-top instance.
        var models = g.models
        for (path, module) in g.modules where models[path] != nil { models[path]!["module"] = module }
        var r = InferenceSweepTests.RNG(s: (seed ^ UInt64(perturbation &* 7919 &+ 1)) | 1)
        let picks = g.dumpOf.keys.filter { $0.contains(".") && models[$0] != nil }.sorted()
        var changed = ""
        if perturbation > 0, !picks.isEmpty {
            changed = picks[r.int(picks.count)]
            let under = models.keys.filter { $0 == changed || $0.hasPrefix(changed + ".") }
            switch perturbation {
            case 1: under.forEach { models[$0] = nil }
            case 2: models[changed]!["module"] = "mX"
            default:
                for old in under { models[changed + "_r" + old.dropFirst(changed.count)] = models.removeValue(forKey: old) }
            }
        }
        let design = Design(models: models, tops: g.tops)
        var o = SweepOut()
        for leaf in g.leaves {
            o.rows += 1
            func run(_ kdb: KDBDesignModel?) async throws -> SVModelResolve.Outcome {
                try await SVModelResolve.resolve(
                    dumpPath: HierarchyPathMapping.segments(leaf.dump), mapping: .init(), loadMessages: [],
                    lookup: { design.lookup($0) }, model: { design.models[$0] },
                    designRoots: { await SVModelResolve.designRoots(tops: design.tops, instances: design.instances, model: { design.models[$0] }) },
                    dumpChildren: { g.dump[HierarchyPathMapping.join($0)] }, kdb: kdb, instances: { design.instances }, kdbSameFiles: true)
            }
            func evaluated(_ outcome: SVModelResolve.Outcome) -> String? {
                switch outcome {
                case .signal(let p, _, _), .approximate(let p, _, _, _): return p
                default: return nil
                }
            }
            let outcome = try await run(kdb)
            let withKDB = evaluated(outcome)
            var labelled = false
            if case .approximate(_, _, _, let differences) = outcome {
                labelled = differences.contains { if case .matchedByModuleType = $0 { return true } else { return false } }
            }
            if labelled { o.byType += 1 }
            // p3: the renamed instance is the design's own (slang names it changed_r): evaluated there
            // only when labelled as matched by unique module type.
            let renamedPath = perturbation == 3 && leaf.design.hasPrefix(changed + ".") ? changed + "_r" + leaf.design.dropFirst(changed.count) : nil
            if let p = withKDB, labelled, p == renamedPath {
                // right
            } else if let p = withKDB {
                if perturbation == 2, p == leaf.design, leaf.design.hasPrefix(changed + ".") {
                    o.other += 1
                    if o.samples.count < 3 { o.samples.append("OTHER MODULE seed \(seed) mode \(mode) p\(perturbation): \(leaf.dump) -> \(p) (\(changed) is mX)") }
                } else if p != leaf.design {
                    o.wrong += 1
                    if o.samples.count < 3 { o.samples.append("WRONG seed \(seed) mode \(mode) p\(perturbation): \(leaf.dump) -> \(p), not \(leaf.design) (\(changed))") }
                }
            }
            let without = evaluated(try await run(nil))
            if let p = without, p != leaf.design { o.wrongToday += 1 }
            if without == leaf.design, withKDB == nil { o.lost += 1 }
        }
        return o
    }

    // (c) No KDB: exactly today's answers.
    @Test func withoutAKDBTheAnswersAreTodays() async throws {
        let whole = Design(models: [
            "tb": Self.inst("tb", ["clk"]), "tb.u_soc": Self.inst("soc", ["clk", "irq"]), "tb.u_soc.u_mbox": Self.inst("mbox", ["rdata", "box"]),
        ], tops: ["tb"])
        let tbOnly = Design(models: ["tb": Self.inst("tb", ["clk"])], tops: ["tb"])
        for (design, messages) in [(whole, [String]()), (tbOnly, ["rtl/tb.sv:19: UnknownModule"])] {
            for row in ["tb.clk", "tb.u_soc.irq", "tb.u_soc.u_mbox.rdata", "tb.u_soc.u_mbox.box[3]", "tb.nothing", "other.x"] {
                #expect(try await resolve(row, design: design, kdb: nil, loadMessages: messages)
                        == (try await today(row, design: design, loadMessages: messages)), "\(row)")
            }
        }
    }
}
#endif
