import CmuxCloud
import CmuxCore
import Foundation
import Testing

/// A tagged DEV build and the release can both run `cmux-tui remote ssh` to one
/// host. Each uploads its own cmux-tui, so they must use separate remote
/// binaries and daemon sessions or each replaces the other's binary under a
/// running daemon.
@Suite("SSH carrier remote isolation for tagged builds")
struct SSHTuiRemoteIsolationTests {
    @Test("The release keeps the remote binary and session every release used")
    func releaseKeepsDefaults() {
        for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", nil] as [String?] {
            let connection = connection(bundleIdentifier: bundle)
            #expect(connection.remoteTag == nil)
            #expect(connection.session == "cmux")
            let arguments = connection.arguments(stateDirectory: "/tmp/cmux-test", deviceName: "test")
            #expect(!arguments.contains("--remote-binary"))
            #expect(value(after: "--session", in: arguments) == "cmux")
        }
    }

    @Test("A tagged DEV build uses its own remote binary and session in every launch")
    func taggedBuildIsIsolated() {
        let connection = connection(bundleIdentifier: "com.cmuxterm.app.debug.svedit")
        #expect(connection.remoteTag == "svedit")
        for arguments in [
            connection.arguments(stateDirectory: "/tmp/cmux-test", deviceName: "test"),
            connection.arguments(stateDirectory: "/tmp/cmux-test", deviceName: "test", upgrade: true),
            connection.browserArguments(stateDirectory: "/tmp/cmux-test"),
        ] {
            #expect(value(after: "--session", in: arguments) == "cmux-svedit")
            #expect(value(after: "--remote-binary", in: arguments) == "~/.local/bin/cmux-tui-svedit")
        }
    }

    @Test("Tags become shell-safe words")
    func tagsAreShellSafe() {
        #expect(SSHTuiConnection.remoteTag(bundleIdentifier: "com.cmuxterm.app.debug") == "dev")
        #expect(SSHTuiConnection.remoteTag(bundleIdentifier: "com.cmuxterm.app.debug.") == "dev")
        #expect(SSHTuiConnection.remoteTag(bundleIdentifier: "com.cmuxterm.app.debug.Fix_It.v2") == "fix-it-v2")
        #expect(SSHTuiConnection.remoteTag(bundleIdentifier: "com.cmuxterm.app.debugger") == nil)
        let long = SSHTuiConnection.remoteTag(bundleIdentifier: "com.cmuxterm.app.debug." + String(repeating: "a", count: 80))
        #expect(long?.count == 40)
    }

    private func connection(bundleIdentifier: String?) -> SSHTuiConnection {
        SSHTuiConnection(configuration: WorkspaceRemoteConfiguration(
            destination: "example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil
        ), environment: [:], bundleIdentifier: bundleIdentifier)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
