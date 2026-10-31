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
    @Test func theListCommandForcesLiteralNames() {
        let command = ProcessSSHFileExplorerTransport.listCommand(path: "/work/my sim", showHidden: true)
        #expect(command.hasPrefix("QUOTING_STYLE=literal ls -1paFA "))
        #expect(command.contains(#"'/work/my sim'"#))
        #expect(ProcessSSHFileExplorerTransport.listCommand(path: "/w", showHidden: false).contains(" -1paF "))
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
