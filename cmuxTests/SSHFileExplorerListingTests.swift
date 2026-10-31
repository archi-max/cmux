import CmuxSyntaxHighlighting
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The SSH folder listing must print names literally, whatever the remote
/// shell sets: Save on Host decides that `<dump>.json` is absent from it, so a
/// quoted `'my sim.json'` would let a real file be replaced unchecked.
@Suite("SSH file explorer listing")
struct SSHFileExplorerListingTests {
    @Test func theListCommandForcesLiteralNames() throws {
        let command = ProcessSSHFileExplorerTransport.listCommand(path: "/work/my sim", showHidden: true)
        let script = try #require(Self.script(in: command))
        #expect(script.hasPrefix("QUOTING_STYLE=literal ls -1paFA "))
        #expect(script.contains(#"'/work/my sim'"#))
        let plain = try #require(Self.script(in: ProcessSSHFileExplorerTransport.listCommand(path: "/w", showHidden: false)))
        #expect(plain.contains(" -1paF "))
    }

    /// `VAR=value cmd` and `2>` are sh syntax that csh/tcsh and fish reject, and
    /// ssh runs the command with the user's login shell: the listing travels
    /// as a POSIX script through the shared wrapper.
    @Test func theListCommandIsAPOSIXScriptForAnyLoginShell() throws {
        let command = ProcessSSHFileExplorerTransport.listCommand(path: "/work/my sim", showHidden: true)
        #expect(command.hasPrefix("sh -c '"))
        #expect(SlangWorkspaceRoot.posixShellCommand(command) == command, "already wrapped once")
        let capped = ProcessSSHFileExplorerTransport.cappedDownloadCommand(path: "/work/wave.vcd", maxBytes: 99)
        #expect(SlangWorkspaceRoot.posixShellCommand(capped) == capped)
        let script = try #require(Self.script(in: capped))
        #expect(script.contains("head -c 100 <"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("my sim.json"))
        for shell in ["/bin/sh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let output = try Self.run(ProcessSSHFileExplorerTransport.listCommand(path: folder.path, showHidden: false), shell: shell)
            #expect(output.contains("my sim.json\n"), "\(shell)")
        }
    }

    /// The POSIX script inside `sh -c 'eval "$(printf %s <base64> | ...)"'`.
    private static func script(in command: String) -> String? {
        let prefix = "sh -c 'eval \"$(printf %s "
        guard command.hasPrefix(prefix) else { return nil }
        let encoded = command.dropFirst(prefix.count).prefix { $0 != " " }
        return Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func run(_ command: String, shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func namesWithSpacesAndQuotesParseAsTheyAre() {
        let output = "./\n../\nmy sim.json\nrun dir/\nit's.vcd\ntool*\nlink@\n.hidden\n"
        let entries = ProcessSSHFileExplorerTransport.parseListOutput(output, path: "/work", showHidden: true)
        #expect(entries.map(\.name) == ["my sim.json", "run dir", "it's.vcd", "tool", "link", ".hidden"])
        #expect(entries.map(\.isDirectory) == [false, true, false, false, false, false])
        #expect(entries.first?.path == "/work/my sim.json")
        #expect(ProcessSSHFileExplorerTransport.parseListOutput(output, path: "/work/", showHidden: false).map(\.name)
            == ["my sim.json", "run dir", "it's.vcd", "tool", "link"])
    }
}
