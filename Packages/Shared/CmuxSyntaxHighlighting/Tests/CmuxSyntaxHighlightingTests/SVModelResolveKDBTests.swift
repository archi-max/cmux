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
        ["module": module, "signals": Dictionary(uniqueKeysWithValues: signals.map { ($0, ["width": 1, "kind": "var"] as [String: Any]) })]
    }

    /// A KDB model: (path, module, parent, signals, writes {name: line}) in `file`.
    static func kdb(_ instances: [(String, String, String?, [String], [String: Int])], file: String = "/work/rtl/soc.sv") -> KDBDesignModel {
        var models: [String: Any] = [:]
        for (path, module, parent, signals, writes) in instances {
            models[path] = [
                "path": path, "module": module, "parent": parent as Any, "ports": [], "files": [file],
                "signals": Dictionary(uniqueKeysWithValues: signals.map { ($0, ["width": 1, "kind": "var", "msb": 0, "lsb": 0] as [String: Any]) }),
                "writes": writes.mapValues { [["kind": "nb", "loc": [0, $0, 0]]] },
                "children": instances.filter { $0.2 == path }.map { ["path": $0.0, "name": String($0.0.dropFirst(path.count + 1)), "module": $0.1] },
            ] as [String: Any]
        }
        let tops = instances.filter { $0.2 == nil }.map(\.0)
        let data = try! JSONSerialization.data(withJSONObject: ["tops": tops, "instances": models])
        return KDBDesignModel(json: data)!
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
        #expect(try await resolve("tb.clk", design: tbOnly, kdb: Self.socKDB, loadMessages: unknown)
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
        #expect(try await resolve("tb.u_soc.u_mbox.rdata", design: twoTops, dump: dump, kdb: Self.socKDB)
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
            let exact = try await resolve(row, design: dutTop, dump: dump, kdb: Self.socKDB)
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
