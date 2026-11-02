import CmuxCloud
import CmuxCore
import CmuxFoundation
import Foundation
import Testing

@Suite("One-off SSH runs ride the machine's live carrier")
struct SSHTuiCarrierRoutesTests {
    private static let environment = ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/cmux-routes-agent.sock"]

    private func configuration(options: [String]) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: options,
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: "/tmp/cmux-routes-agent.sock"
        )
    }

    private func controlPaths(_ options: [String]) -> [String] {
        options.filter { $0.hasPrefix("ControlPath=") }
    }

    /// A restored workspace started the carrier with no control options, so it
    /// holds cmux's route master. A later `cmux ssh` open of the same machine
    /// carries the user's own ssh_config ControlPath; with an agent that
    /// caller-owned path becomes `ControlPath=none`, and that open's Files,
    /// preview and language-server runs then logged in afresh every time.
    @Test("A later open with its own control options still uses the carrier's master")
    func laterOpenUsesCarrierMaster() throws {
        let carrier = SSHTuiConnection(configuration: configuration(options: []), environment: Self.environment)
        let laterOpen = configuration(options: [
            "ControlMaster=auto", "ControlPersist=600", "ControlPath=/tmp/cmux-routes-user/%r@%h:%p",
        ])
        #expect(SSHTuiConnection(configuration: laterOpen, environment: Self.environment).id == carrier.id)
        let carrierPath = try #require(controlPaths(carrier.preflightArguments).first)
        #expect(carrierPath != "ControlPath=none")

        let routes = SSHTuiCarrierRoutes()
        routes.record(carrier)
        let options = routes.fileOperationSSHOptions(for: laterOpen)

        #expect(controlPaths(options) == [carrierPath])
        #expect(!options.contains { $0.hasPrefix("ControlMaster=") || $0.hasPrefix("ControlPersist=") })
    }

    /// A carrier the user opened with `--ssh-option ControlPath=none` shares
    /// nothing, and the one-off runs beside it must not either.
    @Test("A carrier that shares nothing keeps one-off runs unshared")
    func unsharedCarrierStaysUnshared() {
        let carrier = SSHTuiConnection(configuration: configuration(options: ["ControlPath=none"]), environment: Self.environment)
        let routes = SSHTuiCarrierRoutes()
        routes.record(carrier)

        #expect(controlPaths(routes.fileOperationSSHOptions(for: configuration(options: []))) == ["ControlPath=none"])
    }

    @Test("Without a carrier the workspace's own options apply")
    func noCarrierFallsBackToWorkspaceOptions() {
        let workspace = configuration(options: [])
        #expect(SSHTuiCarrierRoutes().fileOperationSSHOptions(for: workspace)
            == SSHTuiConnection(configuration: workspace).fileOperationSSHOptions)
    }
}
