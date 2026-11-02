import CmuxCloud
import CmuxCore
import CmuxFoundation
import Foundation
import Testing

@Suite("One-off SSH runs ride the machine's live carrier")
struct SSHTuiCarrierRoutesTests {
    private static let environment = ["PATH": "/usr/bin", "SSH_AUTH_SOCK": "/tmp/cmux-routes-agent.sock"]

    private func configuration(
        _ destination: String = "alice@example.invalid",
        options: [String],
        agent: String = "/tmp/cmux-routes-agent.sock"
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination, port: nil, identityFile: nil, sshOptions: options,
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, agentSocketPath: agent
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
    @Test("A later open with its own control options still uses the machine's one-off master")
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

        #expect(controlPaths(options) == [carrierPath + "-ops"])
    }

    /// The machine's carrier master is shared by every app's carrier for the
    /// host, and sshd refuses a session past its per-connection limit with no
    /// fallback; a one-off run or long-lived helper there could refuse a
    /// carrier's reconnect. So no option set here ever names it.
    @Test("One-off and long-lived runs never use the carrier's ControlPath")
    func runsNeverUseTheCarrierControlPath() throws {
        let carrier = SSHTuiConnection(configuration: configuration(options: []), environment: Self.environment)
        let carrierPath = try #require(controlPaths(carrier.preflightArguments).first)
        let routes = SSHTuiCarrierRoutes()
        routes.record(carrier)
        let workspace = configuration(options: ["ControlPath=/tmp/cmux-routes-user/%r@%h:%p"])

        let oneOff = routes.fileOperationSSHOptions(for: workspace)
        let longLived = routes.longLivedSSHOptions(for: workspace)
        #expect(!oneOff.contains(carrierPath))
        #expect(!longLived.contains(carrierPath))
        #expect(controlPaths(oneOff) == [carrierPath + "-ops"])
        #expect(oneOff.contains("ControlMaster=auto") && oneOff.contains("ControlPersist=600"))
        #expect(controlPaths(longLived) == ["ControlPath=none"])
        #expect(longLived.contains("ControlMaster=no"))
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

    // The next three tests come from the independent review of this change.

    /// Each machine gets only its own carrier, and a machine with none gets its own options.
    @Test("Another machine's carrier is never used")
    func anotherMachinesCarrierIsNeverUsed() {
        let a = SSHTuiConnection(configuration: configuration("alice@a.invalid", options: []), environment: Self.environment)
        let b = SSHTuiConnection(configuration: configuration("bob@b.invalid", options: []), environment: Self.environment)
        let routes = SSHTuiCarrierRoutes()
        routes.record(a)
        routes.record(b)
        let pathA = controlPaths(a.fileOperationSSHOptions)
        let pathB = controlPaths(b.fileOperationSSHOptions)
        #expect(pathA != pathB)
        #expect(controlPaths(routes.fileOperationSSHOptions(for: configuration("bob@b.invalid", options: []))) == pathB)
        #expect(controlPaths(routes.fileOperationSSHOptions(for: configuration("alice@a.invalid", options: []))) == pathA)
        let c = configuration("carol@c.invalid", options: [])
        #expect(routes.fileOperationSSHOptions(for: c) == SSHTuiConnection(configuration: c).fileOperationSSHOptions)
    }

    @Test("A re-adopted carrier replaces the old route")
    func aReadoptedCarrierReplacesTheOldRoute() {
        let old = SSHTuiConnection(configuration: configuration("alice@a.invalid", options: []), environment: Self.environment)
        let new = SSHTuiConnection(
            configuration: configuration("alice@a.invalid", options: ["ControlPath=none"]),
            environment: Self.environment
        )
        #expect(old.id == new.id)
        let routes = SSHTuiCarrierRoutes()
        routes.record(old)
        routes.record(new)
        #expect(controlPaths(routes.fileOperationSSHOptions(for: configuration("alice@a.invalid", options: []))) == ["ControlPath=none"])
    }

    /// The carrier is shared per machine, agent included, as its terminals are;
    /// a one-off run still never rides the carrier's own master.
    @Test("A different agent on the same machine uses the carrier's one-off master")
    func aDifferentAgentOnTheSameMachine() {
        let carrier = SSHTuiConnection(configuration: configuration("alice@a.invalid", options: []), environment: Self.environment)
        let other = configuration("alice@a.invalid", options: [], agent: "/tmp/cmux-routes-agent-B.sock")
        let routes = SSHTuiCarrierRoutes()
        routes.record(carrier)
        let options = routes.fileOperationSSHOptions(for: other)
        #expect(controlPaths(options) == controlPaths(carrier.fileOperationSSHOptions))
        #expect(!options.contains { controlPaths(carrier.preflightArguments).contains($0) })
    }
}
