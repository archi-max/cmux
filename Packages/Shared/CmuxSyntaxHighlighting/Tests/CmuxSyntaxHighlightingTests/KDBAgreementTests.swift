#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// A row the KDB maps to slang's design is evaluated with slang's statements: exact only when the
/// compiled design and slang's agree where it matters (parameters along the row's instance chain;
/// the signal's shape, the instance's ports and the signal's write lines; no source slang read
/// newer than the compile), else approximate with what differs, or what could not be checked.
@MainActor
@Suite struct KDBAgreementTests {
    static let file = "/work/rtl/soc.sv"
    static let compiled: Int64 = 1_000_000

    /// slang's instance model: params, signals (width/msb/lsb), ports, and continuous assigns of `writes` {signal: line}.
    static func slang(_ path: String, _ module: String, params: [String: Any] = [:], width: Int = 8,
                      writes: [String: Int] = ["q": 20], ports: [[String: Any]] = [["name": "q", "dir": "Out", "width": 8]]) -> [String: Any] {
        [
            "path": path, "module": module, "params": params, "files": [file],
            "signals": ["q": ["width": width, "kind": "var", "msb": width - 1, "lsb": 0], "d": ["width": 8, "kind": "var", "msb": 7, "lsb": 0]],
            "ports": ports,
            "assigns": writes.map { name, line in
                ["lhs": ["name": name, "width": width], "rhs": ["text": "_L0_", "leaves": ["d"]], "loc": [0, line, 3, line, 20]] as [String: Any]
            },
            "procs": [],
        ]
    }

    /// The KDB's instance model, the same way (writes as the exporter writes them).
    static func compiledModel(_ path: String, _ module: String, parent: String?, params: [String: Any]? = [:], width: Int = 8,
                              writes: [String: Int] = ["q": 20], ports: [[String: Any]] = [["name": "q", "dir": "Out", "width": 8]],
                              children: [(String, String)] = []) -> [String: Any] {
        var m: [String: Any] = [
            "path": path, "module": module, "parent": parent as Any, "files": [file], "partial": true,
            "signals": ["q": ["width": width, "kind": "var", "msb": width - 1, "lsb": 0], "d": ["width": 8, "kind": "var", "msb": 7, "lsb": 0]],
            "ports": ports,
            "writes": writes.mapValues { [["kind": "assign", "loc": [0, $0, 0]]] },
            "children": children.map { ["path": $0.0, "name": String($0.0.dropFirst(path.count + 1)), "module": $0.1] },
        ]
        if let params { m["params"] = params }
        return m
    }

    /// `overrides`: the compile's parameter overrides as the exporter lists them (nil: it couldn't tell).
    static func kdb(_ instances: [String: [String: Any]], compiled: Int64? = KDBAgreementTests.compiled, overrides: [String]? = []) -> KDBDesignModel {
        var object: [String: Any] = ["tops": ["tb"], "instances": instances]
        if let compiled { object["compiled"] = compiled }
        if let overrides { object["overrides"] = overrides }
        return KDBDesignModel(json: try! JSONSerialization.data(withJSONObject: object))!
    }

    /// tb > u_fifo (fifo), as slang has it; the KDB's chain is the same unless a test says otherwise.
    func resolve(slang: [String: [String: Any]], kdb: KDBDesignModel,
                 sourceTimes: [String: Int64]? = [KDBAgreementTests.file: KDBAgreementTests.compiled - 10],
                 sameFiles: Bool = true, checked: ((Set<String>) -> Void)? = nil) async throws -> SVModelResolve.Outcome {
        func lookup(_ path: String) -> (instance: String, name: String)? {
            let instance = slang.keys.filter { path.hasPrefix($0 + ".") }.max { $0.count < $1.count }
            return instance.map { ($0, String(path.dropFirst($0.count + 1))) }
        }
        return try await SVModelResolve.resolve(
            dumpPath: ["tb", "u_fifo", "q"],
            mapping: HierarchyPathMapping(),
            lookup: { lookup($0) },
            model: { slang[$0] },
            designRoots: { [:] },
            dumpChildren: { _ in nil },
            kdb: kdb,
            instances: { slang.keys.sorted() },
            sourceTimes: sourceTimes.map { times in { times } },
            kdbSameFiles: sameFiles,
            kdbChecked: checked
        )
    }

    static let slangDesign: [String: [String: Any]] = [
        "tb": slang("tb", "tb", writes: [:], ports: []),
        "tb.u_fifo": slang("tb.u_fifo", "fifo", params: ["DEPTH": 8, "W": 8]),
    ]

    static func compiledDesign(fifoParams: [String: Any]? = ["DEPTH": 8, "W": 8], tbParams: [String: Any]? = [:], width: Int = 8,
                               writes: [String: Int] = ["q": 20], ports: [[String: Any]] = [["name": "q", "dir": "Out", "width": 8]],
                               compiled: Int64? = KDBAgreementTests.compiled, overrides: [String]? = [],
                               edit: (inout [String: Any]) -> Void = { _ in }) -> KDBDesignModel {
        var fifo = compiledModel("tb.u_fifo", "fifo", parent: "tb", params: fifoParams, width: width, writes: writes, ports: ports)
        edit(&fifo)
        return kdb([
            "tb": compiledModel("tb", "tb", parent: nil, params: tbParams, writes: [:], ports: [], children: [("tb.u_fifo", "fifo")]),
            "tb.u_fifo": fifo,
        ], compiled: compiled, overrides: overrides)
    }

    static func approximate(_ differences: [KDBDifference]) -> SVModelResolve.Outcome {
        .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: differences)
    }

    /// NPI reports a parameter's declared value when the compile overrode it (-pvalue: DEPTH=32
    /// reads 16), so a compile with any override (or one whose command the export couldn't read)
    /// leaves the parameters unchecked, whatever they compare as (Refs #9 F1).
    @Test func aCompileWithParameterOverridesLeavesTheParametersUnchecked() async throws {
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(overrides: ["-pvalue+tb.u_fifo.DEPTH=32"]))
                == Self.approximate([.notChecked(.overrides)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(overrides: nil))
                == Self.approximate([.notChecked(.overrides)]))
    }

    /// Every file slang's load read counts, not only those the chain's models point into: an
    /// include of defines or a package edited after the compile changes slang's text (Refs #9 F2).
    @Test func anIncludeNewerThanTheCompileIsApproximate() async throws {
        let times = [Self.file: Self.compiled - 10, "/work/rtl/defs.svh": Self.compiled + 5_000]
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(), sourceTimes: times)
                == Self.approximate([.sourceNewer(file: "/work/rtl/defs.svh")]))
    }

    /// What one side lacks is not taken as agreeing (Refs #9 L1).
    @Test func whatOneSideLacksIsNotChecked() async throws {
        let noShape = Self.compiledDesign { fifo in
            var signals = fifo["signals"] as! [String: Any]
            signals["q"] = ["kind": "var"]
            fifo["signals"] = signals
        }
        #expect(try await resolve(slang: Self.slangDesign, kdb: noShape) == Self.approximate([.notChecked(.shape)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign { $0["ports"] = nil }) == Self.approximate([.notChecked(.ports)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign { $0["writes"] = nil }) == Self.approximate([.notChecked(.writes)]))
        var noStatements = Self.slangDesign
        noStatements["tb.u_fifo"]!["assigns"] = nil
        noStatements["tb.u_fifo"]!["procs"] = nil
        #expect(try await resolve(slang: noStatements, kdb: Self.compiledDesign()) == Self.approximate([.notChecked(.writes)]))
        #expect(KDBAgreement.differences(chain: [], signal: "q", compiledAt: Self.compiled, sourceTimes: [:], overrides: []) == [.notChecked(.chain)])
    }

    /// The same file name in another folder is another file when slang and the KDB read one file
    /// system (slang picked the other copy). Across hosts the editor's copy is another file whose
    /// name only can be compared, so nothing is exact there (Refs #9 L2, re-check).
    @Test func theEditorsCopyOnAnotherHostIsNotChecked() async throws {
        let otherCopy = Self.compiledDesign { $0["files"] = ["/work/rtl_v2/soc.sv"] }
        #expect(try await resolve(slang: Self.slangDesign, kdb: otherCopy, sameFiles: true) == Self.approximate([.writes(signal: "q")]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: otherCopy, sameFiles: false) == Self.approximate([.notChecked(.copy)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(), sameFiles: false) == Self.approximate([.notChecked(.copy)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(), sameFiles: true) == Self.mapped)
    }

    /// What a row's agreement compared in full and found the same, so a later step elsewhere is
    /// not taken as checked: each chain level (slang's path) whose parameters and ports agree, and
    /// `level.signal` for each of its signals whose shape and write lines agree (Refs #9 F3).
    @Test func theChainsInstancesAndSignalsAreTheOnesChecked() async throws {
        var checked: Set<String>?
        _ = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign()) { checked = $0 }
        #expect(checked == ["tb", "tb.d", "tb.q", "tb.u_fifo", "tb.u_fifo.d", "tb.u_fifo.q"])
        // The row's own signal differs: approximate, and the signal is not checked.
        checked = nil
        _ = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(width: 16)) { checked = $0 }
        #expect(checked == ["tb", "tb.d", "tb.q", "tb.u_fifo", "tb.u_fifo.d"])
    }

    /// Another signal of the row's instance whose writes differ: the row stays exact, that signal
    /// is not checked (a step tracing it is approximate).
    @Test func anotherSignalsWritesLeaveItUnchecked() async throws {
        var checked: Set<String>?
        let outcome = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(writes: ["q": 20, "d": 30])) { checked = $0 }
        #expect(outcome == Self.mapped)
        #expect(checked == ["tb", "tb.d", "tb.q", "tb.u_fifo", "tb.u_fifo.q"])
    }

    /// The parent's ports (the side a step through the row's input port lands on) are compared too.
    @Test func theParentsPortsAreChecked() async throws {
        let parentPorts = Self.kdb([
            "tb": Self.compiledModel("tb", "tb", parent: nil, writes: [:], ports: [["name": "go", "dir": "In", "width": 1]], children: [("tb.u_fifo", "fifo")]),
            "tb.u_fifo": Self.compiledModel("tb.u_fifo", "fifo", parent: "tb", params: ["DEPTH": 8, "W": 8]),
        ])
        var checked: Set<String>?
        let outcome = try await resolve(slang: Self.slangDesign, kdb: parentPorts) { checked = $0 }
        #expect(outcome == Self.mapped)
        #expect(checked == ["tb.d", "tb.q", "tb.u_fifo", "tb.u_fifo.d", "tb.u_fifo.q"])
    }

    /// Parameters that can't be compared (an override) leave every level unchecked; the signals
    /// compared still count.
    @Test func uncomparedParametersLeaveTheLevelsUnchecked() async throws {
        var checked: Set<String>?
        _ = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(overrides: ["-pvalue+tb.u_fifo.DEPTH=32"])) { checked = $0 }
        #expect(checked == ["tb.d", "tb.q", "tb.u_fifo.d", "tb.u_fifo.q"])
    }

    /// An export whose KDB had no files to date it (compiled 0) has no compile time (Refs #9 L3).
    @Test func aCompileTimeOfZeroIsNone() async throws {
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(compiled: 0)) == Self.approximate([.notChecked(.sources)]))
    }

    static let mapped = SVModelResolve.Outcome.signal(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "")

    @Test func theSameCompileIsExact() async throws {
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign())
                == .signal(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: ""))
    }

    /// The same module and signal names, compiled with another DEPTH than slang's (no width depends on it).
    @Test func anotherParameterValueIsApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(fifoParams: ["DEPTH": 16, "W": 8]))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "",
                                    differences: [.parameter(instance: "tb.u_fifo", name: "DEPTH", compiled: "16", slang: "8")]))
    }

    @Test func aParameterOnlyOneSideHasIsApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(fifoParams: ["DEPTH": 8, "W": 8, "MODE": "\"fast\""]))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "",
                                    differences: [.parameter(instance: "tb.u_fifo", name: "MODE", compiled: "\"fast\"", slang: nil)]))
    }

    /// A parameter above the row (its parent's) differs: the row's instance may be specialized otherwise.
    @Test func aParameterAboveTheRowIsChecked() async throws {
        var design = Self.slangDesign
        design["tb"] = Self.slang("tb", "tb", params: ["N": 2], writes: [:], ports: [])
        let got = try await resolve(slang: design, kdb: Self.compiledDesign(tbParams: ["N": 4]))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "",
                                    differences: [.parameter(instance: "tb", name: "N", compiled: "4", slang: "2")]))
    }

    /// A define that picks another statement: the compiled design writes q at another line.
    @Test func aDefineThatPicksAnotherStatementIsApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(writes: ["q": 24]))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.writes(signal: "q")]))
    }

    @Test func anotherWidthIsApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(width: 16))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.shape(signal: "q")]))
    }

    @Test func otherPortsAreApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(ports: [["name": "q", "dir": "Out", "width": 8], ["name": "full", "dir": "Out", "width": 1]]))
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.ports(instance: "tb.u_fifo")]))
    }

    /// The RTL edited after the compile (another right-hand side, same lines and names): slang reads
    /// the new text, the dump is the old one's.
    @Test func aSourceNewerThanTheCompileIsApproximate() async throws {
        let got = try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(),
                                    sourceTimes: [Self.file: Self.compiled + 5_000])
        #expect(got == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.sourceNewer(file: Self.file)]))
    }

    /// What can't be checked is said, not taken as agreeing: an export without parameters (an
    /// older exporter), or without its compile time, or no source times from slang's side.
    @Test func whatCannotBeCheckedIsApproximate() async throws {
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(fifoParams: nil, tbParams: nil))
                == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.notChecked(.parameters)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(compiled: nil))
                == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.notChecked(.sources)]))
        #expect(try await resolve(slang: Self.slangDesign, kdb: Self.compiledDesign(), sourceTimes: nil)
                == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.notChecked(.sources)]))
    }

    /// Real compiles (env KDB_AGREEMENT_DIR: a/ b/ c/ d/, each with fifo.sv as VCS compiled it and
    /// npi-model.py's kdb.json, file times kept; CMUX_SV_MODEL_BIN: the sidecar): slang loads each
    /// fifo.sv as it is, without defines. a: the same compile, exact. b: compiled with +define+ALT,
    /// another statement writes q. c: compiled with -pvalue+tb.u_fifo.DEPTH=32 (NPI reports DEPTH
    /// as the instance's 16, its localparam AW as 5). d: fifo.sv edited after the compile.
    @Test func realCompilesAgreeOrSayWhatDiffers() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KDB_AGREEMENT_DIR"], let bin = env["CMUX_SV_MODEL_BIN"] else { return }
        func outcome(_ variant: String) async throws -> SVModelResolve.Outcome {
            let folder = dir + "/" + variant
            let kdb = try #require(KDBDesignModel(json: try Data(contentsOf: URL(fileURLWithPath: folder + "/kdb.json"))))
            let sidecar = SVModelSidecar(runner: { .init(executable: "/bin/sh", arguments: ["-c", $0]) }, launchCommand: "exec '\(bin)'", installCommand: nil)
            defer { sidecar.stop() }
            let session = SVDesignSession(sidecar: sidecar, args: ["--top", "tb", "fifo.sv"], cwd: folder)
            let g = try await session.load().generation
            return try await SVModelResolve.resolve(
                dumpPath: ["tb", "u_fifo", "q"],
                mapping: HierarchyPathMapping(),
                lookup: { (try? await session.lookup($0, generation: g)) ?? nil },
                model: { (try? await session.model($0, generation: g)) ?? nil },
                designRoots: { [:] },
                dumpChildren: { _ in nil },
                kdb: kdb,
                instances: { try await session.hierarchy(generation: g).instances },
                sourceTimes: { (try? await session.sourceTimes(generation: g)) ?? nil },
                kdbSameFiles: true
            )
        }
        var coverage = KDBCoverage()
        let a = try await outcome("a"), b = try await outcome("b"), c = try await outcome("c"), d = try await outcome("d")
        [a, b, c, d].forEach { coverage.add($0) }
        print("[kdb agreement] a: \(a)\n  b: \(b)\n  c: \(c)\n  d: \(d)\n  \(coverage.summary)")
        #expect(a == .signal(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: ""))
        #expect(b == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.writes(signal: "q")]))
        #expect(c == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "",
                                  differences: [.notChecked(.overrides)]))
        if case .approximate(_, _, _, let found) = d {
            #expect(found.count == 1 && found.first?.kind == "sourceNewer", "\(found)")
        } else {
            Issue.record("d: \(d)")
        }
    }

    /// Integer values compare as numbers (VCS's 8 and slang's 32'sd8 alike); strings and others as text.
    @Test func parameterValuesCompareByValue() {
        #expect(KDBAgreement.sameValue(8, "8"))
        #expect(KDBAgreement.sameValue("32'sd8", 8))
        #expect(KDBAgreement.sameValue("8'hff", 255))
        #expect(!KDBAgreement.sameValue(8, 16))
        #expect(KDBAgreement.sameValue("\"fast\"", "\"fast\""))
        #expect(!KDBAgreement.sameValue("\"fast\"", "\"slow\""))
    }

    /// Coverage is counted apart from pass/fail and timing: exact, approximate (by what differs) and
    /// compiled only (not evaluated).
    @Test func coverageCountsEachKind() {
        var coverage = KDBCoverage()
        coverage.add(.signal(designPath: "a", designPrefix: "", dumpPrefix: ""))
        coverage.add(.approximate(designPath: "b", designPrefix: "", dumpPrefix: "", differences: [.shape(signal: "b"), .notChecked(.sources)]))
        coverage.add(.approximate(designPath: "c", designPrefix: "", dumpPrefix: "", differences: [.notChecked(.sources)]))
        coverage.add(.compiledOnly(dumpPath: "d", reason: .notInSlang, writes: []))
        coverage.add(.notInDesign)
        #expect(coverage.exact == 1 && coverage.approximate == 2 && coverage.compiledOnly == 1 && coverage.unsupported == 1)
        #expect(coverage.differences == ["shape": 1, "notChecked.sources": 2])
        #expect(coverage.summary == "exact 1, approximate 2 (notChecked.sources 2, shape 1), compiled only 1, unsupported 1")
    }
}
#endif
