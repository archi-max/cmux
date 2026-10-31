import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct SlangTopLevelTests {
    /// The module at the caret marked `|` (the marker is removed first).
    static func module(_ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SystemVerilogModuleLocator.declaration(at: caret, in: text)?.name
    }

    @Test func caretInsideOrOnAModuleFindsIt() {
        #expect(Self.module("module cpu(input clk);\n  logic |a;\nendmodule\n") == "cpu")
        #expect(Self.module("mod|ule cpu;\nendmodule\n") == "cpu")
        #expect(Self.module("module c|pu;\nendmodule\n") == "cpu")
        #expect(Self.module("  |  module cpu;\nendmodule\n") == "cpu")
        #expect(Self.module("module cpu;\nendmodul|e\n") == "cpu")
    }

    @Test func caretOutsideModulesFindsNone() {
        #expect(Self.module("module a;\nendmodule\n|\nmodule b;\nendmodule\n") == nil)
        #expect(Self.module("|// header\nmodule a;\nendmodule\n") == nil)
        #expect(Self.module("package p;\n  typedef logic |t;\nendpackage\n") == nil)
    }

    @Test func secondModuleOfAFile() {
        #expect(Self.module("module leaf;\nendmodule\nmodule top;\n  leaf |u();\nendmodule\n") == "top")
    }

    @Test func interfacesAndProgramsAreNotModules() {
        #expect(Self.module("interface bus;\n  logic |a;\nendinterface\n") == nil)
        #expect(Self.module("program p;\n  initial |begin end\nendprogram\n") == nil)
    }

    @Test func commentsStringsAndDefinesDoNotOpenModules() {
        #expect(Self.module("// module fake;\n/* module also_fake; */\nlogic |x;\n") == nil)
        #expect(Self.module("string s = \"module fake;\";\nlogic |x;\n") == nil)
        #expect(Self.module("`define M module fake; \\\n  endmodule\nlogic |x;\n") == nil)
        #expect(Self.module("module real_one; // endmodule\n  logic |x;\nendmodule\n") == "real_one")
    }

    @Test func nestedModulesGiveTheInnermost() {
        let text = "module outer;\n  module inner;\n    logic |a;\n  endmodule\n  logic b;\nendmodule\n"
        #expect(Self.module(text) == "inner")
        #expect(Self.module(text.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "logic b", with: "logic |b")) == "outer")
    }

    @Test func ifdefSecondHeaderIsTheSameModule() {
        let text = "`ifdef X\nmodule m(input a);\n`else\nmodule m(input a, input b);\n`endif\n  logic q;\nendmodule\n|\n"
        #expect(Self.module(text) == nil)
        #expect(Self.module(text.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "logic q", with: "logic |q")) == "m")
    }

    @Test func externPrototypesLifetimesAndEscapedNames() {
        #expect(Self.module("extern module ext(input a);\nlogic |x;\n") == nil)
        #expect(Self.module("module automatic auto_m;\n  logic |x;\nendmodule\n") == "auto_m")
        #expect(Self.module("module \\esc.name (input a);\n  logic |x;\nendmodule\n") == "esc.name")
        #expect(Self.module("macromodule mm;\n  logic |x;\nendmodule : mm\n") == "mm")
    }

    @Test func attributesNumbersAndLineEndings() {
        #expect(Self.module("module (* keep *) attr_m;\n  logic |x;\nendmodule\n") == "attr_m")
        #expect(Self.module("module m;\n  always @(*) y = 8'hff;\n  logic |x;\nendmodule\n") == "m")
        #expect(Self.module("`define M module fake; \\\r\n  endmodule\r\nlogic |x;\r\n") == nil)
        #expect(Self.module("module crlf;\r\n  logic |x;\r\nendmodule\r\n") == "crlf")
        #expect(Self.module("module m; logic [7:0] endmodule_count; |endmodule\n") == "m")
    }

    @Test func unterminatedModuleRunsToTheEnd() {
        #expect(Self.module("module open_ended;\n  logic a;\n  |") == "open_ended")
    }

    // MARK: server.json

    static func object(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    @Test func settingBuildCreatesTheFile() throws {
        let data = try SlangServerConfigFile.settingBuild("/w/top.f", in: nil)
        #expect(Self.object(data)["build"] as? String == "/w/top.f")
        #expect(Self.object(data).count == 1)
        #expect(try SlangServerConfigFile.settingBuild("/w/top.f", in: Data("  \n".utf8)) == data)
        #expect(String(decoding: data, as: UTF8.self).contains("\"/w/top.f\""))
    }

    @Test func settingBuildKeepsOtherKeys() throws {
        let existing = Data("""
        {"flags": "-Wno-unused", "incdirs": ["inc", "rtl/inc"], "build": "/old.f",
         "inlayHints": {"portTypes": true, "funcArgNames": 3}, "indexingThreads": 4}
        """.utf8)
        let object = Self.object(try SlangServerConfigFile.settingBuild("/new.f", in: existing))
        #expect(object["build"] as? String == "/new.f")
        #expect(object["flags"] as? String == "-Wno-unused")
        #expect(object["incdirs"] as? [String] == ["inc", "rtl/inc"])
        #expect(object["indexingThreads"] as? Int == 4)
        let hints = object["inlayHints"] as? [String: Any]
        #expect(hints?["portTypes"] as? Bool == true)
        #expect(hints?["funcArgNames"] as? Int == 3)
        #expect(object.count == 5)
    }

    @Test func clearingBuildRemovesOnlyIt() throws {
        let existing = Data(#"{"flags": "-DX", "build": "/old.f"}"#.utf8)
        let cleared = try SlangServerConfigFile.settingBuild(nil, in: existing)
        let object = Self.object(cleared)
        #expect(object["build"] == nil)
        #expect(object["flags"] as? String == "-DX")
        #expect(SlangServerConfigFile.build(in: existing) == "/old.f")
        #expect(SlangServerConfigFile.build(in: cleared) == nil)
    }

    @Test func invalidConfigIsNotOverwritten() {
        #expect(throws: SlangServerConfigFile.EditError.notAJSONObject) {
            try SlangServerConfigFile.settingBuild("/a.f", in: Data("{ not json".utf8))
        }
        #expect(throws: SlangServerConfigFile.EditError.notAJSONObject) {
            try SlangServerConfigFile.settingBuild("/a.f", in: Data("[1, 2]".utf8))
        }
    }

    @Test func configPathIsTheLocalOverride() {
        #expect(SlangServerConfigFile.path(inWorkspace: "/home/u/proj") == "/home/u/proj/.slang/local/server.json")
    }
}
