@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite("LSP message framing")
struct LSPMessageFramerTests {
    private func framed(_ json: String) -> Data {
        LSPMessageFramer.frame(Data(json.utf8))
    }

    @Test("Reassembles a message split across reads")
    func splitMessage() {
        var framer = LSPMessageFramer()
        let data = framed(#"{"jsonrpc":"2.0","id":1,"result":"héllo"}"#)
        var messages: [Data] = []
        for byte in data {
            messages += framer.append(Data([byte]))
        }
        #expect(messages.count == 1)
        #expect(String(decoding: messages[0], as: UTF8.self) == #"{"jsonrpc":"2.0","id":1,"result":"héllo"}"#)
    }

    @Test("Splits coalesced messages and keeps the trailing partial one")
    func coalescedMessages() {
        var framer = LSPMessageFramer()
        let third = framed(#"{"id":3}"#)
        var data = framed(#"{"id":1}"#)
        data.append(framed(#"{"id":2}"#))
        data.append(third.prefix(10))
        let first = framer.append(data)
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == [#"{"id":1}"#, #"{"id":2}"#])
        let rest = framer.append(third.dropFirst(10))
        #expect(rest.map { String(decoding: $0, as: UTF8.self) } == [#"{"id":3}"#])
    }

    @Test("Accepts extra headers and any header case")
    func extraHeaders() {
        var framer = LSPMessageFramer()
        let body = #"{"id":7}"#
        let data = Data("content-length: \(body.utf8.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n\(body)".utf8)
        #expect(framer.append(data).count == 1)
    }

    @Test("Frames with the UTF-8 byte length")
    func frameLength() {
        let framed = String(decoding: LSPMessageFramer.frame(Data("é".utf8)), as: UTF8.self)
        #expect(framed == "Content-Length: 2\r\n\r\né")
    }
}

@Suite("LSP response decoding")
struct LSPResponseDecodingTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.decode(Data(text.utf8))
    }

    private func mapper(_ uri: String) -> URL? {
        URL(string: uri)
    }

    @Test("Hover MarkupContent")
    func hoverMarkup() throws {
        let result = try json(#"{"contents":{"kind":"markdown","value":"**Variable** `mid`"}}"#)
        #expect(LSPResponseDecoding.hoverText(result) == "**Variable** `mid`")
    }

    @Test("Hover MarkedString and array of MarkedStrings")
    func hoverMarkedStrings() throws {
        #expect(LSPResponseDecoding.hoverText(try json(#"{"contents":"plain"}"#)) == "plain")
        let array = try json(#"{"contents":["intro",{"language":"systemverilog","value":"logic a;"}]}"#)
        #expect(LSPResponseDecoding.hoverText(array) == "intro\n\n```systemverilog\nlogic a;\n```")
    }

    @Test("Empty hover is nil")
    func hoverEmpty() throws {
        #expect(LSPResponseDecoding.hoverText(try json(#"{"contents":""}"#)) == nil)
        #expect(LSPResponseDecoding.hoverText(.null) == nil)
    }

    @Test("Definition as Location, Location[], LocationLink[], and null")
    func definitionShapes() throws {
        let range = LSPRange(start: LSPPosition(line: 0, character: 7), end: LSPPosition(line: 0, character: 10))
        let expected = [LSPLocation(uri: URL(string: "file:///w/sub.sv")!, range: range)]
        let rangeJSON = #"{"start":{"line":0,"character":7},"end":{"line":0,"character":10}}"#

        let single = try json(#"{"uri":"file:///w/sub.sv","range":\#(rangeJSON)}"#)
        #expect(LSPResponseDecoding.locations(single, uriMapper: mapper) == expected)

        let array = try json(#"[{"uri":"file:///w/sub.sv","range":\#(rangeJSON)}]"#)
        #expect(LSPResponseDecoding.locations(array, uriMapper: mapper) == expected)

        let links = try json(#"""
        [{"targetUri":"file:///w/sub.sv",
          "targetRange":{"start":{"line":0,"character":0},"end":{"line":5,"character":9}},
          "targetSelectionRange":\#(rangeJSON)}]
        """#)
        #expect(LSPResponseDecoding.locations(links, uriMapper: mapper) == expected)

        #expect(LSPResponseDecoding.locations(.null, uriMapper: mapper).isEmpty)
    }

    @Test("Completion as CompletionItem[] and CompletionList")
    func completionShapes() throws {
        let array = try json(#"""
        [{"label":"din","labelDetails":{"detail":" input logic[7:0]"},"kind":8,
          "textEdit":{"range":{"start":{"line":6,"character":16},"end":{"line":6,"character":19}},"newText":"din"}}]
        """#)
        #expect(LSPResponseDecoding.completionItems(array) == [
            LSPCompletionItem(label: "din", detail: "input logic[7:0]", insertText: "din", kind: 8),
        ])

        let list = try json(#"{"isIncomplete":false,"items":[{"label":"always_ff","detail":"keyword","insertText":"always_ff","kind":14},{"label":"x"}]}"#)
        #expect(LSPResponseDecoding.completionItems(list) == [
            LSPCompletionItem(label: "always_ff", detail: "keyword", insertText: "always_ff", kind: 14),
            LSPCompletionItem(label: "x"),
        ])
        #expect(LSPResponseDecoding.completionItems(.null).isEmpty)
    }

    @Test("Diagnostics with numeric code and missing severity")
    func diagnostics() throws {
        let value = try json(#"""
        [{"range":{"start":{"line":6,"character":22},"end":{"line":6,"character":36}},"severity":2,
          "message":"width mismatch","code":"WidthExpand","source":"slang"},
         {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"message":"bad","code":42}]
        """#)
        let diagnostics = LSPResponseDecoding.diagnostics(value)
        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].severity == .warning)
        #expect(diagnostics[0].code == "WidthExpand")
        #expect(diagnostics[0].source == "slang")
        #expect(diagnostics[1].severity == .error)
        #expect(diagnostics[1].code == "42")
    }

    @Test("JSON round-trips integers without becoming doubles")
    func jsonIntegers() throws {
        let value = try json(#"{"id":12,"ok":true,"x":1.5}"#)
        #expect(value["id"] == .int(12))
        #expect(value["ok"] == .bool(true))
        #expect(value["x"] == .double(1.5))
        #expect(String(decoding: try JSONValue.int(3).encoded(), as: UTF8.self) == "3")
    }
}

@Suite("Language tool registry")
struct LanguageToolRegistryTests {
    @Test("Remote destinations use ssh with an explicit PATH")
    func remoteLaunch() {
        #expect(LanguageToolRegistry.languageServer(forLanguage: "verilog", remoteDestination: "dev-host") == .ssh(
            destination: "dev-host",
            sshOptions: [],
            remoteCommand: #"sh -c 'PATH="$HOME/.local/bin:$PATH"; export PATH; exec slang-server'"#
        ))
        #expect(LanguageToolRegistry.formatter(forLanguage: "verilog", remoteDestination: "dev-host") == .ssh(
            destination: "dev-host",
            sshOptions: [],
            remoteCommand: #"sh -c 'PATH="$HOME/.local/bin:$PATH"; export PATH; exec verible-verilog-format --failsafe_success=false -'"#
        ))
    }

    #if os(macOS)
    @Test("The remote command finds ~/.local/bin tools from sh and csh login shells")
    func remoteCommandRunsUnderNonPOSIXLoginShells() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-lsp-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("verible-verilog-format")
        try "#!/bin/sh\necho \"formatted $*\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        guard case .ssh(_, _, let command)? = LanguageToolRegistry.formatter(forLanguage: "verilog", remoteDestination: "dev-host") else {
            Issue.record("expected an ssh launch")
            return
        }
        for shell in ["/bin/sh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            // -f keeps csh from reading the runner's ~/.cshrc.
            process.arguments = shell.hasSuffix("csh") ? ["-f", "-c", command] : ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(shell)")
            #expect(String(decoding: data, as: UTF8.self) == "formatted --failsafe_success=false -\n", "\(shell)")
        }
    }
    #endif

    @Test("Other languages have no tools")
    func otherLanguages() {
        #expect(LanguageToolRegistry.languageServer(forLanguage: "swift", remoteDestination: nil) == nil)
        #expect(LanguageToolRegistry.formatter(forLanguage: "python", remoteDestination: "dev-host") == nil)
    }

    @Test("ssh command line")
    func sshCommandLine() {
        let launch = LanguageToolLaunch.ssh(destination: "host", sshOptions: ["-p", "2222"], remoteCommand: "exec x")
        #expect(launch.commandLine.executable == "/usr/bin/ssh")
        #expect(launch.commandLine.arguments == ["-o", "BatchMode=yes", "-T", "-p", "2222", "host", "exec x"])
    }

    @Test("Search directories start with the GUI-invisible locations")
    func searchDirectories() {
        let directories = LanguageToolRegistry.searchDirectories
        #expect(Array(directories.prefix(3)) == [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
    }
}
