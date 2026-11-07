import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Driver tracing's KDB design model (Resources/vaporview/verdi-trace/npi-model.sh + npi-model.py on
/// the host): the launch command, what its output says, and the model's lookups and port aliases.
@Suite struct KDBDesignModelTests {
    /// tb (top) > u_dut (dut) > u_core (core), and a generate block's net in u_dut.
    static let model = """
    {"tops":["tb"],"source":"kdb","instances":{
    "tb":{"path":"tb","module":"tb","parent":null,"ports":[],"signals":{"clk":{"width":1},"bus":{"width":8,"msb":7,"lsb":0}},
      "children":[{"path":"tb.u_dut","name":"u_dut","module":"dut"}],"files":["tb.sv"],"writes":{"clk":[{"kind":"proc","loc":[0,5,0]}]}},
    "tb.u_dut":{"path":"tb.u_dut","module":"dut","parent":"tb","ports":[
        {"name":"clk","dir":"In","width":1,"conn":{"leaves":["clk"],"src":"clk","width":1}},
        {"name":"data","dir":"Out","width":8,"conn":{"leaves":["bus"],"src":"bus","width":8}},
        {"name":"narrow","dir":"In","width":4,"conn":{"leaves":["bus"],"src":"bus","width":8}},
        {"name":"open","dir":"In","width":1}],
      "signals":{"clk":{"width":1},"data":{"width":8},"narrow":{"width":4},"open":{"width":1},"g.x":{"width":1},
        "mem":{"width":0,"array":{"lo":0,"hi":3,"elemWidth":8}}},
      "children":[{"path":"tb.u_dut.u_core","name":"u_core","module":"core"}],"files":["dut.sv"],
      "writes":{"data":[{"kind":"assign","loc":[0,12,0]}],"g.x":[{"kind":"nb","loc":[0,20,0]}]}},
    "tb.u_dut.u_core":{"path":"tb.u_dut.u_core","module":"core","parent":"tb.u_dut","ports":[
        {"name":"clk","dir":"In","width":1,"conn":{"leaves":["clk"],"src":"clk","width":1}}],
      "signals":{"clk":{"width":1}},"children":[],"files":[],"writes":{}}}}
    """

    @Test func theOutputGivesTheModelOrWhyNot() throws {
        let ok = Data(("{\"ok\": true, \"cached\": true}\n" + Self.model.replacingOccurrences(of: "\n", with: "") + "\n").utf8)
        guard case .model(let model, let cached) = KDBModelLaunch.parse(output: ok) else {
            Issue.record("no model")
            return
        }
        #expect(cached)
        #expect(model.tops == ["tb"])
        #expect(model.instancePaths == ["tb", "tb.u_dut", "tb.u_dut.u_core"])
        let denied = Data("Synopsys banner\n{\"ok\":false,\"error\":\"licence\",\"message\":\"load_design failed\"}\n".utf8)
        #expect(KDBModelLaunch.parse(output: denied) == .unavailable(code: "licence", message: "load_design failed"))
        #expect(KDBModelLaunch.parse(output: Data("{\"ok\": true, \"cached\": false}\n{not json\n".utf8)) == .unavailable(code: "model", message: ""))
        #expect(KDBModelLaunch.parse(output: Data()) == .unavailable(code: "start", message: ""))
    }

    @Test func theCommandSendsBothScriptsAndTheDump() {
        let command = KDBModelLaunch.command(launcher: Data("L".utf8), exporter: Data("E".utf8), fsdbPath: "/runs/a b/x.fsdb")
        #expect(!command.contains("'"))
        #expect(command.contains(Data("L".utf8).base64EncodedString()) && command.contains(Data("E".utf8).base64EncodedString()))
        #expect(command.contains(Data("/runs/a b/x.fsdb".utf8).base64EncodedString()))
        #expect(command.contains("npi-model.sh") && command.contains("--print") && command.contains("rm -rf"))
    }

    /// View > Retry KDB Export: the host runs a KDB marked `tried` again (CMUX_KDB_RETRY=1); a plain ask does not.
    @Test func aRetryAsksTheHostToRunATriedKDBAgain() {
        let plain = KDBModelLaunch.command(launcher: Data("L".utf8), exporter: Data("E".utf8), fsdbPath: "/runs/x.fsdb")
        let retry = KDBModelLaunch.command(launcher: Data("L".utf8), exporter: Data("E".utf8), fsdbPath: "/runs/x.fsdb", retry: true)
        #expect(!plain.contains("CMUX_KDB_RETRY"))
        #expect(retry.contains("CMUX_KDB_RETRY=1 bash -l") && !retry.contains("'"))
    }

    @Test func aDumpPathIsLookedUpAsItIs() throws {
        let model = try #require(KDBDesignModel(json: Data(Self.model.utf8)))
        #expect(model.lookup("tb.u_dut.data")?.instance == "tb.u_dut")
        #expect(model.lookup("tb.u_dut.data")?.name == "data")
        #expect(model.lookup("tb.u_dut.g.x")?.name == "g.x")
        #expect(model.lookup("tb.u_dut.u_core.clk")?.instance == "tb.u_dut.u_core")
        #expect(model.lookup("other.clk") == nil)
        #expect(model.hasSignal("tb.u_dut.data"))
        #expect(model.hasSignal("tb.u_dut.g.x"))
        #expect(model.hasSignal("tb.u_dut.mem[2]"))
        #expect(!model.hasSignal("tb.u_dut.nothing"))
        #expect(!model.hasSignal("tb.u_dut"))
        #expect(model.instance("tb.u_dut")?["module"] as? String == "dut")
        #expect(model.writes(of: "tb.u_dut.g.x") == [KDBDesignModel.Write(kind: "nb", file: "dut.sv", line: 20)])
        #expect(model.writes(of: "tb.u_dut.clk") == [])
    }

    @Test func singleNetPortsOfTheSameWidthAreAliasPairs() throws {
        let model = try #require(KDBDesignModel(json: Data(Self.model.utf8)))
        let pairs = Set(model.aliasPairs().map { $0.joined(separator: " ") })
        // Both orientations; a narrower port (a part of the net) and an open one are no aliases.
        #expect(pairs == [
            "tb.u_dut.clk tb.clk", "tb.clk tb.u_dut.clk",
            "tb.u_dut.data tb.bus", "tb.bus tb.u_dut.data",
            "tb.u_dut.u_core.clk tb.u_dut.clk", "tb.u_dut.clk tb.u_dut.u_core.clk",
        ])
        #expect(model.aliasPairs(limit: 2).count == 2)
    }
}

/// The same port aliases from slang's instance models (cmux-sv-model's shape), whose paths are the
/// design's: mapped to the dump's with the rule a trace resolved (design prefix -> dump prefix).
@Suite struct DesignAliasPairsTests {
    @Test func slangsPortsGiveTheDumpsAliasesUnderTheResolvedPrefix() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(KDBDesignModelTests.model.utf8)) as? [String: Any])
        let models = try #require(object["instances"] as? [String: [String: Any]])
        // The design's tb.u_dut is the dump's top.dut (another testbench dumped it).
        let pairs = Set(DesignAliasPairs.pairs(models: models, designPrefix: "tb.u_dut", dumpPrefix: "top.dut").map { $0.joined(separator: " ") })
        // Only below the prefix: tb.u_dut's own ports bind to tb's nets, which the dump doesn't name so.
        #expect(pairs == ["top.dut.u_core.clk top.dut.clk", "top.dut.clk top.dut.u_core.clk"])
        let same = DesignAliasPairs.pairs(models: models, designPrefix: "", dumpPrefix: "")
        #expect(same.count == 6)
        #expect(DesignAliasPairs.pairs(models: models, designPrefix: "", dumpPrefix: "", limit: 3).count == 3)
    }
}
