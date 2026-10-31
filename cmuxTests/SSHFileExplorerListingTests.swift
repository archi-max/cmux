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

        // A non-ASCII folder name travels base64-encoded inside the script.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ls-\(UUID().uuidString)-résumé")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("my sim.json"))
        let dump = folder.appendingPathComponent("wave é.vcd")
        try Data(repeating: 0x41, count: 300).write(to: dump)
        for shell in Self.loginShells {
            let listing = try Self.run(ProcessSSHFileExplorerTransport.listCommand(path: folder.path, showHidden: false), shell: shell)
            #expect(listing.output.contains("my sim.json\n"), "\(shell)")
            #expect(listing.output.contains("wave é.vcd\n"), "\(shell)")

            let capped = try Self.run(ProcessSSHFileExplorerTransport.cappedDownloadCommand(path: dump.path, maxBytes: 99), shell: shell)
            #expect(capped.status == 0 && capped.data.count == 100, "\(shell): N+1 bytes, got \(capped.data.count)")
            let whole = try Self.run(ProcessSSHFileExplorerTransport.downloadCommand(path: dump.path), shell: shell)
            #expect(whole.status == 0 && whole.data.count == 300, "\(shell)")

            for refused in [folder.path, folder.appendingPathComponent("missing é.vcd").path] {
                let cappedMiss = try Self.run(ProcessSSHFileExplorerTransport.cappedDownloadCommand(path: refused, maxBytes: 99), shell: shell)
                let wholeMiss = try Self.run(ProcessSSHFileExplorerTransport.downloadCommand(path: refused), shell: shell)
                #expect(cappedMiss.status == 1 && cappedMiss.data.isEmpty, "\(shell) \(refused)")
                #expect(wholeMiss.status == 1 && wholeMiss.data.isEmpty, "\(shell) \(refused)")
            }
        }
    }

    @Test func theWholeFileDownloadIsAPOSIXScriptForAnyLoginShell() throws {
        let command = ProcessSSHFileExplorerTransport.downloadCommand(path: "/work/wave.vcd")
        #expect(SlangWorkspaceRoot.posixShellCommand(command) == command)
        let script = try #require(Self.script(in: command))
        #expect(script.hasPrefix("test -f "))
        #expect(script.contains("&& cat -- "))
    }

    /// Login shells ssh may run the command with, as installed on this Mac.
    private static let loginShells = ["/bin/sh", "/bin/csh", "/bin/tcsh"].filter {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    /// The POSIX script inside `sh -c 'eval "$(printf %s <base64> | ...)"'`.
    private static func script(in command: String) -> String? {
        let prefix = "sh -c 'eval \"$(printf %s "
        guard command.hasPrefix(prefix) else { return nil }
        let encoded = command.dropFirst(prefix.count).prefix { $0 != " " }
        return Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func run(_ command: String, shell: String) throws -> (output: String, data: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // ls prints names as the filesystem stores them (NFD on APFS).
        return (String(decoding: data, as: UTF8.self).precomposedStringWithCanonicalMapping, data, process.terminationStatus)
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
