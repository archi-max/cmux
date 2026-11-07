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

    static func kdb(_ instances: [String: [String: Any]], compiled: Int64? = KDBAgreementTests.compiled) -> KDBDesignModel {
        var object: [String: Any] = ["tops": ["tb"], "instances": instances]
        if let compiled { object["compiled"] = compiled }
        return KDBDesignModel(json: try! JSONSerialization.data(withJSONObject: object))!
    }

    /// tb > u_fifo (fifo), as slang has it; the KDB's chain is the same unless a test says otherwise.
    func resolve(slang: [String: [String: Any]], kdb: KDBDesignModel,
                 sourceTimes: [String: Int64]? = [KDBAgreementTests.file: KDBAgreementTests.compiled - 10]) async throws -> SVModelResolve.Outcome {
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
            sourceTimes: sourceTimes.map { times in { times } }
        )
    }

    static let slangDesign: [String: [String: Any]] = [
        "tb": slang("tb", "tb", writes: [:], ports: []),
        "tb.u_fifo": slang("tb.u_fifo", "fifo", params: ["DEPTH": 8, "W": 8]),
    ]

    static func compiledDesign(fifoParams: [String: Any]? = ["DEPTH": 8, "W": 8], tbParams: [String: Any]? = [:], width: Int = 8,
                               writes: [String: Int] = ["q": 20], ports: [[String: Any]] = [["name": "q", "dir": "Out", "width": 8]],
                               compiled: Int64? = KDBAgreementTests.compiled) -> KDBDesignModel {
        kdb([
            "tb": compiledModel("tb", "tb", parent: nil, params: tbParams, writes: [:], ports: [], children: [("tb.u_fifo", "fifo")]),
            "tb.u_fifo": compiledModel("tb.u_fifo", "fifo", parent: "tb", params: fifoParams, width: width, writes: writes, ports: ports),
        ], compiled: compiled)
    }

    static let mapped = (designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "")

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
                sourceTimes: { (try? await session.sourceTimes(generation: g)) ?? nil }
            )
        }
        var coverage = KDBCoverage()
        let a = try await outcome("a"), b = try await outcome("b"), c = try await outcome("c"), d = try await outcome("d")
        [a, b, c, d].forEach { coverage.add($0) }
        print("[kdb agreement] a: \(a)\n  b: \(b)\n  c: \(c)\n  d: \(d)\n  \(coverage.summary)")
        #expect(a == .signal(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: ""))
        #expect(b == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "", differences: [.writes(signal: "q")]))
        #expect(c == .approximate(designPath: "tb.u_fifo.q", designPrefix: "", dumpPrefix: "",
                                  differences: [.parameter(instance: "tb.u_fifo", name: "AW", compiled: "5", slang: "4")]))
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
