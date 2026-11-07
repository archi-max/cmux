#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Trace Driver from a waveform row: the row's netlist path to a design path, through the
/// resolve WaveformTrace uses, against a design answering as the sidecar does (`lookup`: the
/// deepest instance on the path and the rest below it, for any path below a top).
@MainActor
@Suite struct SVModelResolveTests {
    /// A design: its instances' models, by path.
    struct FakeDesign {
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

        /// The design's instances, as the sidecar's `instances` lists them (sorted).
        var instances: [String] { models.keys.sorted() }
    }

    /// The dump's hierarchy: each scope path's children.
    typealias FakeDump = [String: [HierarchyNode]]

    func resolve(_ row: String, design: FakeDesign, dump: FakeDump = [:], mapping: HierarchyPathMapping = .init(), loadMessages: [String] = []) async throws -> SVModelResolve.Outcome {
        try await SVModelResolve.resolve(
            dumpPath: HierarchyPathMapping.segments(row),
            mapping: mapping,
            loadMessages: loadMessages,
            lookup: { design.lookup($0) },
            model: { design.models[$0] },
            designRoots: { await SVModelResolve.designRoots(tops: design.tops, instances: design.instances, model: { design.models[$0] }) },
            dumpChildren: { dump[HierarchyPathMapping.join($0)] }
        )
    }

    static func signals(_ list: [String: Any]) -> [String: Any] { ["signals": list] }
    static let bit: [String: Any] = ["width": 1, "kind": "var"]
    static let word32: [String: Any] = ["width": 32, "kind": "var"]

    /// The user's design with the testbench file alone as slang's target: bigsoc_top (in another
    /// file) is an unknown module, so tb_bigsoc has no instances under it.
    static let tbOnly = FakeDesign(models: ["tb_bigsoc": signals(["clk": bit, "rst_n": bit])], tops: ["tb_bigsoc"])

    static let whole = FakeDesign(models: [
        "tb_bigsoc": signals(["clk": bit, "rst_n": bit]),
        "tb_bigsoc.u_soc": signals(["clk": bit, "dfp_read": bit, "mmio_rdata": word32]),
        "tb_bigsoc.u_soc.u_mbox": signals([
            "box": ["width": 0, "kind": "var", "array": ["lo": 0, "hi": 63, "elemWidth": 32]],
            "rdata": word32,
        ]),
    ], tops: ["tb_bigsoc"])

    @Test func aRowBelowAModuleTheDesignLacksNamesIt() async throws {
        // Was: lookup stopped at tb_bigsoc with the rest `u_soc.…`, taken as a signal, and the
        // page said "This is not a signal of its instance."
        for row in ["tb_bigsoc.u_soc.g_cl[0].u_cluster.g_tile[1].u_tile.mmio_rdata", "tb_bigsoc.u_soc.u_mbox.box[8]", "tb_bigsoc.u_soc.mmio_rdata"] {
            #expect(try await resolve(row, design: Self.tbOnly, loadMessages: Self.unknownModule) == .notElaborated(instance: "tb_bigsoc.u_soc"), "\(row)")
        }
    }

    /// What the real sidecar says loading tb_bigsoc.sv alone.
    static let unknownModule = ["rtl/tb_bigsoc.sv:19: UnknownModule"]

    @Test func aCleanLoadsRowBelowAScopeTheModelLacksIsNotInTheDesign() async throws {
        // Hotfix review M1: with no load errors, a scope the model has no instance for (a named
        // block's locals, a task, a child instance the dump names differently) is a mapping or
        // modelling gap, not a module slang left out: the path-mapping hint, not the profile one.
        let clean = FakeDesign(models: ["tb": Self.signals(["clk": Self.bit])], tops: ["tb"])
        for row in ["tb.blk.t", "tb.dut.x", "tb.do_write.addr"] {
            #expect(try await resolve(row, design: clean) == .notInDesign, "\(row)")
        }
        // The same rows when the load had errors: the instance the design lacks.
        #expect(try await resolve("tb.dut.x", design: clean, loadMessages: ["tb.sv:3: UnknownModule"]) == .notElaborated(instance: "tb.dut"))
    }

    @Test func theLoadDetailIsTheUnknownModuleError() {
        #expect(SVModelResolve.loadDetail(["a.sv:4: PortDoesNotExist", "tb.sv:19: UnknownModule"]) == "tb.sv:19: UnknownModule")
        #expect(SVModelResolve.loadDetail(["a.sv:4: PortDoesNotExist"]) == "a.sv:4: PortDoesNotExist")
        #expect(SVModelResolve.loadDetail([]) == nil)
    }

    @Test func theMissingInstanceIsNamedFromTheDumpsOwnPath() async throws {
        // The testbench-only design: a dump that also holds tb_bigsoc.u_soc's clk could let
        // inference map the testbench onto u_soc; the missing instance still comes from the row
        // as the dump names it.
        let dump: FakeDump = [
            "": [HierarchyNode(name: "tb_bigsoc", isScope: true)],
            "tb_bigsoc": [HierarchyNode(name: "u_soc", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1), HierarchyNode(name: "rst_n", isScope: false, width: 1)],
            "tb_bigsoc.u_soc": [HierarchyNode(name: "clk", isScope: false, width: 1), HierarchyNode(name: "rst_n", isScope: false, width: 1), HierarchyNode(name: "u_mbox", isScope: true)],
            "tb_bigsoc.u_soc.u_mbox": [HierarchyNode(name: "rdata", isScope: false, width: 32)],
        ]
        #expect(try await resolve("tb_bigsoc.u_soc.u_mbox.rdata", design: Self.tbOnly, dump: dump, loadMessages: Self.unknownModule)
            == .notElaborated(instance: "tb_bigsoc.u_soc"))
    }

    @Test func aNameTheInstanceLacksIsNotInTheDesign() async throws {
        #expect(try await resolve("tb_bigsoc.u_soc.nope", design: Self.whole) == .notInDesign)
        #expect(try await resolve("tb_bigsoc.u_soc.u_mbox.box[64]", design: Self.whole) == .notInDesign)
        #expect(try await resolve("elsewhere.x", design: Self.whole) == .notInDesign)
        #expect(try await resolve("tb_bigsoc.u_soc", design: Self.whole) == .notInDesign)
    }

    @Test func signalsAndWordsResolveAsTheyAre() async throws {
        #expect(try await resolve("tb_bigsoc.u_soc.mmio_rdata", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.mmio_rdata", designPrefix: "", dumpPrefix: ""))
        #expect(try await resolve("tb_bigsoc.u_soc.u_mbox.box[8]", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.u_mbox.box[8]", designPrefix: "", dumpPrefix: ""))
    }

    @Test func aRowKeepingARangeAsWideAsItsSignalIsTheSignal() async throws {
        // FSDB keeps `[0:0]` on a 1-bit vector declared `[N-1:0]` (review H1), and a row may keep its range.
        #expect(try await resolve("tb_bigsoc.u_soc.dfp_read[0:0]", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.dfp_read", designPrefix: "", dumpPrefix: ""))
        #expect(try await resolve("tb_bigsoc.u_soc.mmio_rdata[31:0]", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.mmio_rdata", designPrefix: "", dumpPrefix: ""))
        #expect(try await resolve("tb_bigsoc.u_soc.u_mbox.box[8][31:0]", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.u_mbox.box[8]", designPrefix: "", dumpPrefix: ""))
        // An ascending range spans its bits too.
        #expect(try await resolve("tb_bigsoc.u_soc.mmio_rdata[0:31]", design: Self.whole)
            == .signal(designPath: "tb_bigsoc.u_soc.mmio_rdata", designPrefix: "", dumpPrefix: ""))
        // A narrower range is a part-select, another signal.
        #expect(try await resolve("tb_bigsoc.u_soc.mmio_rdata[7:0]", design: Self.whole) == .notInDesign)
    }

    @Test func aMappedRowKeepsItsPrefixesWithoutTheRange() async throws {
        var mapping = HierarchyPathMapping()
        mapping.addInferredRule(designPrefix: "tb_bigsoc.u_soc", dumpPrefix: "top.dut")
        #expect(try await resolve("top.dut.dfp_read[0:0]", design: Self.whole, mapping: mapping)
            == .signal(designPath: "tb_bigsoc.u_soc.dfp_read", designPrefix: "tb_bigsoc.u_soc", dumpPrefix: "top.dut"))
    }

    @Test func anInferredRuleMapsARowWithItsRange() async throws {
        // The dump names the design's top `dut` under a wrapper, and keeps `[0:0]`.
        let design = FakeDesign(models: [
            "soc": Self.signals(["clk": Self.bit, "dfp_read": Self.bit, "mmio_rdata": Self.word32]),
            "soc.u_mbox": Self.signals(["rdata": Self.word32]),
        ], tops: ["soc"])
        let dump: FakeDump = [
            "": [HierarchyNode(name: "tb", isScope: true)],
            "tb": [HierarchyNode(name: "dut", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)],
            "tb.dut": [
                HierarchyNode(name: "u_mbox", isScope: true),
                HierarchyNode(name: "clk", isScope: false, width: 1),
                HierarchyNode(name: "dfp_read[0:0]", isScope: false, width: 1),
                HierarchyNode(name: "mmio_rdata", isScope: false, width: 32),
            ],
        ]
        #expect(try await resolve("tb.dut.dfp_read[0:0]", design: design, dump: dump)
            == .signal(designPath: "soc.dfp_read", designPrefix: "soc", dumpPrefix: "tb.dut"))
        #expect(try await resolve("tb.dut.mmio_rdata", design: design, dump: dump)
            == .signal(designPath: "soc.mmio_rdata", designPrefix: "soc", dumpPrefix: "tb.dut"))
    }

    // Inference beyond the design's tops (x-root review M3).

    static let gen = FakeDesign(models: [
        "soc": signals(["clk": bit, "g_blk.x": word32, "g_blk.y": bit]),
        "soc.g[0].u_sub": signals(["d": word32]),
        "soc.g[1].u_sub": signals(["d": word32]),
    ], tops: ["soc"])

    @Test func aGenerateBlocksSignalUnderARenamedTopIsInferred() async throws {
        let dump: FakeDump = [
            "": [HierarchyNode(name: "tb", isScope: true)],
            "tb": [HierarchyNode(name: "dut", isScope: true)],
            "tb.dut": [HierarchyNode(name: "clk", isScope: false, width: 1), HierarchyNode(name: "g_blk", isScope: true),
                       HierarchyNode(name: "g[0]", isScope: true), HierarchyNode(name: "g[1]", isScope: true)],
            "tb.dut.g_blk": [HierarchyNode(name: "x", isScope: false, width: 32), HierarchyNode(name: "y", isScope: false, width: 1)],
            "tb.dut.g[0]": [HierarchyNode(name: "u_sub", isScope: true)],
        ]
        #expect(try await resolve("tb.dut.g_blk.x", design: Self.gen, dump: dump)
            == .signal(designPath: "soc.g_blk.x", designPrefix: "soc", dumpPrefix: "tb.dut"))
        #expect(try await resolve("tb.dut.g[0].u_sub.d", design: Self.gen, dump: dump)
            == .signal(designPath: "soc.g[0].u_sub.d", designPrefix: "soc", dumpPrefix: "tb.dut"))
    }

    @Test func aDumpScopeNamedForADeeperInstanceIsInferred() async throws {
        // The dump's testbench names the design instance `dut`; the design's is `u_dut`.
        let design = FakeDesign(models: [
            "tb": Self.signals(["clk": Self.bit]),
            "tb.u_dut": Self.signals(["clk": Self.bit]),
            "tb.u_dut.u_alu": Self.signals(["x": Self.word32]),
            "tb.u_dut.u_reg": Self.signals(["q": Self.word32]),
        ], tops: ["tb"])
        let dump: FakeDump = [
            "": [HierarchyNode(name: "tb", isScope: true)],
            "tb": [HierarchyNode(name: "dut", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)],
            "tb.dut": [HierarchyNode(name: "u_alu", isScope: true), HierarchyNode(name: "u_reg", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)],
            "tb.dut.u_alu": [HierarchyNode(name: "x", isScope: false, width: 32)],
        ]
        #expect(try await resolve("tb.dut.u_alu.x", design: design, dump: dump)
            == .signal(designPath: "tb.u_dut.u_alu.x", designPrefix: "tb.u_dut", dumpPrefix: "tb.dut"))
    }

    /// Two identical cores (`u_core0`, `u_core1`, each with `u_a`/`u_b`/`u_c`) below `root`, dumped below `tb.dut`.
    static func twoCores(below root: String, models: [String: [String: Any]], tops: [String], dumpTb: [HierarchyNode]) -> (FakeDesign, FakeDump) {
        var models = models
        var dump: FakeDump = [
            "": [HierarchyNode(name: "tb", isScope: true)],
            "tb": dumpTb,
            "tb.dut": [HierarchyNode(name: "u_core0", isScope: true), HierarchyNode(name: "u_core1", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)],
        ]
        for core in ["u_core0", "u_core1"] {
            models["\(root).\(core)"] = signals(["clk": bit])
            dump["tb.dut.\(core)"] = ["u_a", "u_b", "u_c"].map { HierarchyNode(name: $0, isScope: true) }
            for sub in ["u_a", "u_b", "u_c"] {
                models["\(root).\(core).\(sub)"] = signals(["x": bit])
                dump["tb.dut.\(core).\(sub)"] = [HierarchyNode(name: "x", isScope: false, width: 1)]
            }
        }
        return (FakeDesign(models: models, tops: tops), dump)
    }

    @Test func aRowInTheSecondOfTwoIdenticalCoresMapsToItUnderARenamedTop() async throws {
        let (design, dump) = Self.twoCores(below: "soc", models: ["soc": Self.signals(["clk": Self.bit])], tops: ["soc"],
                                           dumpTb: [HierarchyNode(name: "dut", isScope: true)])
        #expect(try await resolve("tb.dut.u_core1.u_a.x", design: design, dump: dump)
            == .signal(designPath: "soc.u_core1.u_a.x", designPrefix: "soc", dumpPrefix: "tb.dut"))
    }

    @Test func aRowInTheSecondOfTwoIdenticalCoresMapsToItUnderADeeperInstance() async throws {
        let (design, dump) = Self.twoCores(
            below: "tb.u_dut", models: ["tb": Self.signals(["clk": Self.bit]), "tb.u_dut": Self.signals(["clk": Self.bit])], tops: ["tb"],
            dumpTb: [HierarchyNode(name: "dut", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)])
        #expect(try await resolve("tb.dut.u_core1.u_a.x", design: design, dump: dump)
            == .signal(designPath: "tb.u_dut.u_core1.u_a.x", designPrefix: "tb.u_dut", dumpPrefix: "tb.dut"))
    }

    static func scopes(_ names: [String]) -> [HierarchyNode] { names.map { HierarchyNode(name: $0, isScope: true) } }
    static func bits(_ names: [String]) -> [HierarchyNode] { names.map { HierarchyNode(name: $0, isScope: false, width: 1) } }

    /// Rules that map the row to one design path agree: a top and its own child instance tying is no tie.
    @Test func aTopAndItsChildInstanceScoringAlikeMapTheRow() async throws {
        let design = FakeDesign(models: [
            "soc": Self.signals(["clk": Self.bit, "rst": Self.bit]), "soc.u_mem": Self.signals(["d": Self.bit]),
            "soc.u_core": Self.signals(["clk": Self.bit]), "soc.u_core.u_a": Self.signals(["x": Self.bit]),
            "soc.u_core.u_b": Self.signals(["x": Self.bit]), "soc.u_core.u_c": Self.signals(["x": Self.bit]),
        ], tops: ["soc"])
        let dump: FakeDump = [
            "": Self.scopes(["tb"]), "tb": Self.scopes(["dut"]),
            "tb.dut": Self.scopes(["u_core", "u_mem"]) + Self.bits(["clk", "rst"]),
            "tb.dut.u_core": Self.scopes(["u_a", "u_b", "u_c"]), "tb.dut.u_core.u_a": Self.bits(["x"]),
        ]
        #expect(try await resolve("tb.dut.u_core.u_a.x", design: design, dump: dump)
            == .signal(designPath: "soc.u_core.u_a.x", designPrefix: "soc", dumpPrefix: "tb.dut"))
    }

    @Test func aTestbenchTopAndItsDutScoringAlikeMapTheRow() async throws {
        let design = FakeDesign(models: [
            "tb_soc": Self.signals(["clk": Self.bit, "rst": Self.bit]), "tb_soc.dut": Self.signals(["clk": Self.bit]),
            "tb_soc.dut.u_a": Self.signals(["x": Self.bit]), "tb_soc.dut.u_b": Self.signals(["x": Self.bit]),
            "glbl": Self.signals(["GSR": Self.bit]),
        ], tops: ["glbl", "tb_soc"])
        let dump: FakeDump = [
            "": Self.scopes(["tb"]), "tb": Self.scopes(["dut"]) + Self.bits(["clk", "rst"]),
            "tb.dut": Self.scopes(["u_a", "u_b"]) + Self.bits(["clk"]), "tb.dut.u_a": Self.bits(["x"]),
        ]
        #expect(try await resolve("tb.dut.u_a.x", design: design, dump: dump)
            == .signal(designPath: "tb_soc.dut.u_a.x", designPrefix: "tb_soc", dumpPrefix: "tb"))
    }

    /// `soc` (dumped as `tb.dut`) with `cores` identical cores (`u_a`..`u_d`) and a `u_dma` whose children share
    /// `shared` of a core's names (`u_a`, ...; the rest are its own).
    static func coresAndDma(cores: Int, shared: Int) -> (FakeDesign, FakeDump) {
        let coreKids = ["u_a", "u_b", "u_c", "u_d"]
        let dmaKids = Array(coreKids.prefix(shared)) + ["u_z", "u_y", "u_w", "u_v"].prefix(4 - shared)
        var models: [String: [String: Any]] = ["soc": signals(["clk": bit]), "soc.u_dma": signals(["clk": bit])]
        var dump: FakeDump = ["": scopes(["tb"]), "tb": scopes(["dut"])]
        let coreNames = (0..<cores).map { "u_core\($0)" }
        dump["tb.dut"] = scopes(coreNames + ["u_dma"]) + bits(["clk"])
        for core in coreNames {
            models["soc.\(core)"] = signals(["clk": bit])
            dump["tb.dut.\(core)"] = scopes(coreKids)
            for kid in coreKids { models["soc.\(core).\(kid)"] = signals(["x": bit]); dump["tb.dut.\(core).\(kid)"] = bits(["x"]) }
        }
        dump["tb.dut.u_dma"] = scopes(dmaKids)
        for kid in dmaKids { models["soc.u_dma.\(kid)"] = signals(["x": bit]); dump["tb.dut.u_dma.\(kid)"] = bits(["x"]) }
        return (FakeDesign(models: models, tops: ["soc"]), dump)
    }

    /// Probe D: the cores tie at their own scope, and the lone u_dma scoring lower there is another module.
    @Test func aNarrowerRuleBelowATieIsNotTaken() async throws {
        var (design, dump) = Self.coresAndDma(cores: 2, shared: 3)
        dump["tb.dut"] = Self.scopes(["u_core0", "u_core1"]) + Self.bits(["clk"])
        #expect(try await resolve("tb.dut.u_core1.u_a.x", design: design, dump: dump)
            == .signal(designPath: "soc.u_core1.u_a.x", designPrefix: "soc", dumpPrefix: "tb.dut"))
    }

    /// Whatever the overlap between instances' children, a row maps to its own instance by the top's rule,
    /// never to another instance's signal of the same name.
    @Test func aRowNeverMapsToAnotherInstance() async throws {
        for cores in 1...3 {
            for shared in 0...4 {
                for dumpDma in [true, false] {
                    var (design, dump) = Self.coresAndDma(cores: cores, shared: shared)
                    if !dumpDma { dump["tb.dut"] = dump["tb.dut"]!.filter { $0.name != "u_dma" } }
                    let rows = dump.keys.filter { $0.hasPrefix("tb.dut.") && dump[$0]!.allSatisfy { !$0.isScope } }.sorted()
                        .filter { dumpDma || !$0.hasPrefix("tb.dut.u_dma") }
                    for row in rows {
                        let got = try await resolve("\(row).x", design: design, dump: dump)
                        let own = "soc" + "\(row).x".dropFirst("tb.dut".count)
                        // The top's rule (soc = tb.dut) is there in every case, so the row is found.
                        #expect(got == .signal(designPath: own, designPrefix: "soc", dumpPrefix: "tb.dut"),
                                "cores \(cores), shared \(shared), dma dumped \(dumpDma): \(row).x -> \(got)")
                    }
                }
            }
        }
    }

    /// An extra top (a module nothing instantiates, which slang makes a top) sharing clk and rst with a renamed DUT:
    /// the DUT's own signals and scopes map to the DUT, not to the extra top.
    @Test func aRenamedInstancesSignalsAreNotAnExtraTops() async throws {
        let design = FakeDesign(models: [
            "tb": Self.signals(["clk": Self.bit]),
            "tb.u_dut": Self.signals(["clk": Self.bit, "rst": Self.bit, "x": Self.bit]),
            "tb.u_dut.u_a": Self.signals(["x": Self.bit]), "tb.u_dut.u_b": Self.signals(["x": Self.bit]),
            "other": Self.signals(["clk": Self.bit, "rst": Self.bit]),
            "other.u_c": Self.signals(["x": Self.bit]), "other.u_d": Self.signals(["x": Self.bit]),
        ], tops: ["other", "tb"])
        let dump: FakeDump = [
            "": Self.scopes(["tb"]), "tb": Self.scopes(["dut"]) + Self.bits(["clk"]),
            "tb.dut": Self.scopes(["u_a", "u_b"]) + Self.bits(["clk", "rst", "x"]),
            "tb.dut.u_a": Self.bits(["x"]), "tb.dut.u_b": Self.bits(["x"]),
        ]
        for name in ["rst", "clk", "x"] {
            #expect(try await resolve("tb.dut.\(name)", design: design, dump: dump)
                == .signal(designPath: "tb.u_dut.\(name)", designPrefix: "tb.u_dut", dumpPrefix: "tb.dut"))
        }
        #expect(try await resolve("tb.dut.u_a.x", design: design, dump: dump)
            == .signal(designPath: "tb.u_dut.u_a.x", designPrefix: "tb.u_dut", dumpPrefix: "tb.dut"))
    }

    @Test func designRootsListScopesOnceAndInstancesBelowTheTops() async {
        let roots = await SVModelResolve.designRoots(tops: Self.gen.tops, instances: Self.gen.instances, model: { Self.gen.models[$0] })
        #expect(roots["soc"] == [
            HierarchyNode(name: "g[0]", isScope: true), HierarchyNode(name: "g[1]", isScope: true), HierarchyNode(name: "g_blk", isScope: true),
            HierarchyNode(name: "clk", isScope: false),
        ])
        // An instance below the tops is a root by its scopes, and only with two at least.
        #expect(roots["soc.g[0].u_sub"] == nil)
        let deep = await SVModelResolve.designRoots(tops: ["tb"], instances: ["tb", "tb.u_dut", "tb.u_dut.u_alu", "tb.u_dut.u_reg", "tb.u_dut.u_alu.u_add"], model: { _ in nil })
        #expect(deep["tb.u_dut"] == [HierarchyNode(name: "u_alu", isScope: true), HierarchyNode(name: "u_reg", isScope: true)])
        #expect(deep["tb.u_dut.u_alu"] == nil)
    }

    @Test func wordIndexesAreTheEnginesDigits() {
        let model = Self.signals(["box": ["width": 0, "kind": "var", "array": ["lo": 0, "hi": 63, "elemWidth": 32]]])
        #expect(!SVModelLoad.isSignal("box[+3]", inModel: model))
        #expect(!SVModelLoad.isSignal("box[ 3]", inModel: model))
        #expect(SVModelLoad.isSignal("box[03]", inModel: model))
        #expect(SVModelLoad.width(of: "box[3]", inModel: model) == 32)
        #expect(SVModelLoad.width(of: "box", inModel: model) == 0)
    }
}
#endif
