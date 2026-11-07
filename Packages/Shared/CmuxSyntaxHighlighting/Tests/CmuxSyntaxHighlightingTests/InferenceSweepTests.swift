#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Randomized wrong-module sweep over inferred rules. Modules reuse child names from a small pool; children
/// may sit in generate scopes (`g[0].u_x`) or be instance arrays (`u_lane[1]`). The dump is the design's tree
/// under a renamed prefix. Every leaf is resolved by SVModelResolve.resolve; it must map to its own design path
/// or to nothing. Also counted, against inference with the tops only as roots (first-wins): rows it found that
/// resolve no longer does ("lost"). `SWEEP_N` designs per mode (default 40).
@MainActor
@Suite struct InferenceSweepTests {
    typealias D = SVModelResolveTests.FakeDesign
    struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) } }
    static let pool = ["u_a", "u_b", "u_c", "u_d", "u_regs", "u_fifo", "u_ctrl", "u_core0", "u_core1", "u_dma", "u_mem", "u_bus"]
    static let sigPool = ["clk", "rst", "x", "q", "d", "valid"]
    static let bit: [String: Any] = ["width": 1, "kind": "var"]

    struct Out { var rows = 0, wrong = 0, none = 0, lost = 0, base = 0; var samples: [String] = [] }

    static func runOne(seed: UInt64, mode: Int) async throws -> Out {
        var r = RNG(s: seed | 1)
        let nMods = 3 + r.int(5)
        // A child: its path segments below the parent (1 or 2: a generate scope then the instance) and its module.
        // Module nMods is an extra one that nothing instantiates (mode 3's extra top), with children of modules 1...
        var kids: [[([String], Int)]] = Array(repeating: [], count: nMods + 1)
        var sigs: [[String]] = Array(repeating: [], count: nMods + 1)
        for m in 0...nMods {
            sigs[m] = Array(Set((0..<(1 + r.int(3))).map { _ in sigPool[r.int(sigPool.count)] })).sorted()
            guard m != nMods - 1 else { continue }
            var used = Set<String>()
            for _ in 0..<r.int(5) {
                let n = pool[r.int(pool.count)], c = m == nMods ? 1 + r.int(nMods - 1) : m + 1 + r.int(nMods - m - 1)
                switch r.int(4) {
                case 0: // generate loop g_<n>[0..k]
                    let g = "g_" + n.dropFirst(2)
                    if used.insert(g).inserted { for k in 0..<(1 + r.int(3)) { kids[m].append((["\(g)[\(k)]", n], c)) } }
                case 1: // instance array
                    if used.insert(n).inserted { for k in 0..<(2 + r.int(2)) { kids[m].append((["\(n)[\(k)]"], c)) } }
                default:
                    if used.insert(n).inserted { kids[m].append(([n], c)) }
                }
            }
        }
        var models: [String: [String: Any]] = [:]
        var dump: [String: [HierarchyNode]] = [:]
        var leaves: [(dump: String, design: String)] = []
        func addDump(_ path: String, _ node: HierarchyNode) { if !(dump[path] ?? []).contains(node) { dump[path, default: []].append(node) } }
        func build(_ m: Int, design: String, dumpPath: String, depth: Int, record: Bool = true) {
            // Not dumped (an extra top): the dump and leaves are kept as they were.
            if !record {
                let (keptDump, keptLeaves) = (dump, leaves)
                defer { (dump, leaves) = (keptDump, keptLeaves) }
                build(m, design: design, dumpPath: dumpPath, depth: depth, record: true)
                return
            }
            models[design] = ["signals": Dictionary(uniqueKeysWithValues: sigs[m].map { ($0, bit) })]
            if dump[dumpPath] == nil { dump[dumpPath] = [] }
            if depth < 6 {
                for (segs, c) in kids[m] {
                    var dp = dumpPath, dg = design
                    for s in segs { addDump(dp, HierarchyNode(name: s, isScope: true)); dp += "." + s; dg += "." + s }
                    build(c, design: dg, dumpPath: dp, depth: depth + 1, record: record)
                }
            }
            for sg in sigs[m] { addDump(dumpPath, HierarchyNode(name: sg, isScope: false, width: 1)); if record { leaves.append((dumpPath + "." + sg, design + "." + sg)) } }
        }
        var tops: [String]
        func tb(_ name: String, _ inst: String) { dump[""] = [HierarchyNode(name: name, isScope: true)]; dump[name] = [HierarchyNode(name: inst, isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)] }
        switch mode {
        case 0: build(0, design: "soc", dumpPath: "tb.dut", depth: 0); tb("tb", "dut"); tops = ["soc"]
        case 1: models["tb"] = ["signals": ["clk": bit]]; build(0, design: "tb.u_dut", dumpPath: "tb.dut", depth: 0); tb("tb", "dut"); tops = ["tb"]
        case 2:
            build(0, design: "soc", dumpPath: "top_tb.wrap.dut", depth: 0)
            dump[""] = [HierarchyNode(name: "top_tb", isScope: true)]
            dump["top_tb"] = [HierarchyNode(name: "wrap", isScope: true), HierarchyNode(name: "clk", isScope: false, width: 1)]
            dump["top_tb.wrap"] = [HierarchyNode(name: "dut", isScope: true), HierarchyNode(name: "rst", isScope: false, width: 1)]
            tops = ["soc"]
        case 3, 5: // as 1, plus an extra top `other`, not dumped: slang's top for a module nothing instantiates, its
            // names from the same pool (3); or a copy of module 1, which the DUT instantiates too (5: --top given twice)
            models["tb"] = ["signals": ["clk": bit]]; build(0, design: "tb.u_dut", dumpPath: "tb.dut", depth: 0); tb("tb", "dut")
            build(mode == 3 ? nMods : 1, design: "other", dumpPath: "other", depth: 0, record: false)
            tops = ["other", "tb"]
        default: // design has its own TB top; the dump's TB is named differently, DUT instance alike
            models["tb_soc"] = ["signals": ["clk": bit, "rst": bit]]
            build(0, design: "tb_soc.dut", dumpPath: "tb.dut", depth: 0); tb("tb", "dut"); dump["tb"]!.append(HierarchyNode(name: "rst", isScope: false, width: 1))
            tops = ["tb_soc"]
        }
        let design = D(models: models, tops: tops)
        // Tops-only roots: each top with its direct child instances and every signal name.
        var topRoots: [String: [HierarchyNode]] = [:]
        for top in tops {
            let inst = design.instances.filter { $0.hasPrefix(top + ".") && !$0.dropFirst(top.count + 1).contains(".") }
                .map { HierarchyNode(name: String($0.dropFirst(top.count + 1)), isScope: true) }
            let s = ((models[top]?["signals"] as? [String: Any]) ?? [:]).keys.sorted().map { HierarchyNode(name: $0, isScope: false) }
            topRoots[top] = inst + s
        }
        var o = Out()
        for leaf in leaves {
            o.rows += 1
            let got = try await SVModelResolve.resolve(
                dumpPath: HierarchyPathMapping.segments(leaf.dump), mapping: .init(), loadMessages: [],
                lookup: { design.lookup($0) }, model: { design.models[$0] },
                designRoots: { await SVModelResolve.designRoots(tops: design.tops, instances: design.instances, model: { design.models[$0] }) },
                dumpChildren: { dump[HierarchyPathMapping.join($0)] })
            var baseOK = false
            if let rule = await HierarchyPrefixInference.designRule(forDumpPath: leaf.dump, designRoots: topRoots, dumpChildren: { dump[HierarchyPathMapping.join($0)] }, ties: .first) {
                var mp = HierarchyPathMapping(); mp.addInferredRule(designPrefix: rule.designPrefix, dumpPrefix: rule.dumpPrefix)
                baseOK = mp.designPath(forDumpPath: leaf.dump) == leaf.design
            }
            if baseOK { o.base += 1 }
            switch got {
            case .signal(let p, _, _):
                if p != leaf.design { o.wrong += 1; if o.samples.count < 6 { o.samples.append("WRONG seed \(seed) mode \(mode): \(leaf.dump) -> \(p)") } }
            default:
                o.none += 1
                if baseOK { o.lost += 1; if o.samples.count < 3 { o.samples.append("LOST seed \(seed) mode \(mode): \(leaf.dump) (tops only: \(leaf.design))") } }
            }
        }
        return o
    }

    @Test func sweep() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["SWEEP_N"] ?? "") ?? 40
        let start = Int(env["SWEEP_START"] ?? "") ?? 0  // first seed index, to split a long sweep over processes
        let only = Set((env["SWEEP_MODES"] ?? "").split(separator: ",").compactMap { Int($0) })
        let modes = 6
        var per = [Out](repeating: Out(), count: modes)
        var lostDesigns = [Int](repeating: 0, count: modes), wrongDesigns = [Int](repeating: 0, count: modes)
        for i in start..<(start + n) { for mode in 0..<modes where only.isEmpty || only.contains(mode) {
            let o = try await Self.runOne(seed: UInt64(i) &* 0x9E3779B97F4A7C15 &+ 777, mode: mode)
            per[mode].rows += o.rows; per[mode].wrong += o.wrong; per[mode].none += o.none; per[mode].lost += o.lost; per[mode].base += o.base
            if o.lost > 0 { lostDesigns[mode] += 1 }; if o.wrong > 0 { wrongDesigns[mode] += 1 }
            // Wrong rows' samples before lost ones'.
            per[mode].samples = Array((per[mode].samples + o.samples).sorted { $0.hasPrefix("WRONG") && !$1.hasPrefix("WRONG") }.prefix(4))
        } }
        for m in 0..<modes {
            let p = per[m]
            print("SWEEP mode \(m): designs \(n) rows \(p.rows) wrong \(p.wrong) (\(wrongDesigns[m]) designs) none \(p.none) | tops only correct \(p.base), lost \(p.lost) (\(lostDesigns[m]) designs)")
            for s in p.samples { print("SWEEP   ", s) }
        }
        for m in 0..<modes { #expect(per[m].wrong == 0, "mode \(m): \(per[m].wrong) rows mapped to another design path: \(per[m].samples)") }
    }
}
#endif
