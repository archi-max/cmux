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

        func roots() -> [String: [HierarchyNode]] {
            var roots: [String: [HierarchyNode]] = [:]
            for top in tops {
                var kids = models.keys.filter { $0.hasPrefix(top + ".") && !$0.dropFirst(top.count + 1).contains(".") }
                    .sorted().map { HierarchyNode(name: String($0.dropFirst(top.count + 1)), isScope: true) }
                kids += ((models[top]?["signals"] as? [String: Any]) ?? [:]).keys.sorted().map { HierarchyNode(name: $0, isScope: false) }
                roots[top] = kids
            }
            return roots
        }
    }

    /// The dump's hierarchy: each scope path's children.
    typealias FakeDump = [String: [HierarchyNode]]

    func resolve(_ row: String, design: FakeDesign, dump: FakeDump = [:], mapping: HierarchyPathMapping = .init()) async throws -> SVModelResolve.Outcome {
        try await SVModelResolve.resolve(
            dumpPath: HierarchyPathMapping.segments(row),
            mapping: mapping,
            lookup: { design.lookup($0) },
            model: { design.models[$0] },
            designRoots: { design.roots() },
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
            #expect(try await resolve(row, design: Self.tbOnly) == .notElaborated(instance: "tb_bigsoc.u_soc"), "\(row)")
        }
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
