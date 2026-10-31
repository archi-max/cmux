import AppKit
import CmuxCloud
import CmuxCloudTui
import Bonsplit
import CmuxCore
import CmuxExtensionKit
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("SSH cmux-tui migration", .serialized)
struct SSHTuiMigrationTests {
    @Test("SSH terminal failures do not use Cloud wording")
    func sshTerminalFailureUsesSSHCopy() {
        let failure = CloudPaneCreationFailure(machine: .ssh("austins-macbook-pro"), error: CloudMachineLink.LinkError.timedOut)

        #expect(failure.displayTitle == "Couldn’t open SSH terminal")
        #expect(failure.errorText == "The SSH connection could not be established.")
        #expect(failure.recoveryText.contains("SSH connection"))
        #expect(!failure.copyableText.contains("Cloud"))
    }

    @Test("SSH terminal failures do not expose provider responses")
    func sshTerminalFailureSanitizesProviderDetails() {
        struct LeakyError: LocalizedError {
            var errorDescription: String? { "provider-name: response payload and secret" }
        }
        let failure = CloudPaneCreationFailure(machine: .ssh("host"), error: LeakyError())

        #expect(!failure.errorText.contains("provider-name"))
        #expect(!failure.copyableText.contains("response payload"))
        #expect(!failure.copyableText.contains("secret"))
    }

    private func configuration(options: [String] = [], command: String? = nil, identityFile: String = "/tmp/key with spaces", profile: WorkspaceRemoteTerminalProfile = .shell) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            terminalProfile: profile, destination: "alice@example.invalid", port: 2222, identityFile: identityFile,
            sshOptions: options, localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: command,
            preserveAfterTerminalExit: true
        )
    }

    @Test("Provider defaults retain the SSH command and terminal profile")
    func providerDefaultUsesSSHLaunchConfiguration() {
        let command = "printf configured-command"
        let configured = SSHTuiConnection(configuration: configuration(command: command))
        #expect(RemoteTuiMachine.ssh(configured).defaultTerminalCommand ==
                ["/bin/sh", "-c", configured.hostOpenCommand.shellPrelude + "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"", "cmux-ssh", command])
        let tmux = SSHTuiConnection(configuration: configuration(command: command, profile: .defaultTmux))
        #expect(RemoteTuiMachine.ssh(tmux).defaultTerminalCommand ==
                WorkspaceRemoteTerminalProfile.defaultTmux.remoteCommandArguments)
        let shell = SSHTuiConnection(configuration: configuration())
        #expect(RemoteTuiMachine.ssh(shell).defaultTerminalCommand ==
                ["/bin/sh", "-c", shell.hostOpenCommand.shellPrelude + "exec \"${SHELL:-/bin/sh}\" -l"])
    }

    @MainActor
    @Test("SSH agent sidebar status reconciles the graph present at projector startup")
    func agentSidebarStatusReconcilesExistingCatalogGraph() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let machine = SurfaceMachineID.ssh("ssh-existing-status")
        let catalog = SurfaceCatalog()
        let provider = CloudPlacementTestProvider(machine: machine)
        catalog.register(provider)
        let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: "terminal-1")
        catalog.upsert(SurfaceResource(
            id: resourceID,
            title: "terminal",
            lifecycle: .running,
            agent: SurfaceAgentBadge(state: "working", source: "hook", agent: "codex")
        ))
        catalog.record(SurfaceProjection(resource: resourceID, workspaceID: workspace.id, panelID: panelID))

        _ = SSHTuiAgentStatusProjector(catalog: catalog, workspaceLookup: { id in
            id == workspace.id ? workspace : nil
        })

        #expect(workspace.statusEntries["cmux.remote.agent:codex"]?.value == "Running")
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["cmux.remote.agent:codex"] == .running)
    }

    @Test("OpenSSH resolves the cmux-tui carrier as a non-PTY exec channel")
    func carrierOverridesInteractiveHostDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key with spaces")
        try Data().write(to: key)
        let connection = SSHTuiConnection(configuration: configuration(options: [
            "RequestTTY=force", "RemoteCommand=interactive-only", "StrictHostKeyChecking=yes",
        ], identityFile: key.path))
        let arguments = connection.arguments(stateDirectory: "/tmp/client state", deviceName: "test")
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + sshArguments + [connection.configuration.destination]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let values = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(values.contains("requesttty false"))
        #expect(!values.contains(where: { $0.hasPrefix("remotecommand ") }))
        #expect(values.contains("port 2222"))
        #expect(values.contains("stricthostkeychecking true"))
        #expect(values.contains(Substring("identityfile " + key.path)))
    }

    @Test("The carrier authenticates in batch mode and keeps reconnecting after startup")
    func carrierKeepsUnlimitedBatchReconnects() {
        let arguments = SSHTuiConnection(configuration: configuration()).arguments(
            stateDirectory: "/tmp/cmux-tui-client",
            deviceName: "test"
        )
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        for option in ["BatchMode=yes", "RequestTTY=no", "RemoteCommand=none"] {
            #expect(zip(sshArguments, sshArguments.dropFirst()).contains { $0 == ("-o", option) })
        }
        // Reconnect limits apply to the whole carrier lifetime, so capping them
        // would end SSH persistence after the first network drop.
        for limit in ["--reconnect-attempts", "--reconnect-attempt-timeout-ms", "--connect-timeout-seconds"] {
            #expect(!arguments.contains(limit))
        }
    }

    @Test("Restore-only SSH carriers request sidecar recovery")
    func restoreCarrierRequestsSidecarUpgrade() {
        let connection = SSHTuiConnection(configuration: configuration())
        let fresh = connection.arguments(stateDirectory: "/tmp/state", deviceName: "test")
        let restored = connection.arguments(stateDirectory: "/tmp/state", deviceName: "test", upgrade: true)
        #expect(!fresh.contains("--upgrade"))
        #expect(restored.contains("--upgrade"))
    }

    @Test("Changing a ControlMaster path does not change persistent SSH terminal identity")
    func sessionIdentitySurvivesCarrierReplacement() {
        let first = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/first", "ProxyJump=bastion"]))
        let replacement = SSHTuiConnection(configuration: configuration(options: ["ControlPath=/tmp/second", "ProxyJump=bastion"]))
        let otherRoute = SSHTuiConnection(configuration: configuration(options: ["ProxyJump=another-host"]))
        #expect(first.id == replacement.id)
        #expect(first.id != otherRoute.id)
        #expect(SurfaceMachineID(rawValue: first.id).isSSH)
        #expect(SurfaceMachineID(rawValue: first.id).cloudMachineID == nil)
    }

    @Test("Saved SSH connections restore without executing the retired PTY wrapper")
    func restorePreservesEndpointWithoutLegacyDaemonLaunch() throws {
        let original = configuration(options: ["ProxyJump=bastion"], command: "exec fish -l")
        let snapshot = try #require(original.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted).workspaceConfiguration())
        #expect(restored.destination == original.destination)
        #expect(restored.port == original.port)
        #expect(restored.configuredRemoteCommand == original.configuredRemoteCommand)
        #expect(restored.preserveAfterTerminalExit)
        #expect(restored.terminalStartupCommand == nil)
        #expect(restored.relayPort == nil)
        #expect(restored.foregroundAuthToken == nil)
        #expect(SSHTuiConnection(configuration: original).id == SSHTuiConnection(configuration: restored).id)
    }

    @Test("A restored carrier logs in through the ControlMaster its open shared")
    func restoredCarrierSharesTheOpensControlMaster() throws {
        // `cmux ssh` opens with cmux's sharing defaults. The restored carrier
        // runs in batch mode, so on a password-only host the live master is
        // its only way in.
        // Like the CLI, the open sends this process's agent when it exists.
        let agent = SessionRemoteWorkspaceSnapshot(transport: .ssh, destination: "alice@example.invalid")
            .restorableAgentSocketPath()
        let base = configuration(options: ["ProxyJump=bastion"])
        let opened = WorkspaceRemoteConfiguration(
            terminalProfile: base.terminalProfile, destination: base.destination, port: base.port,
            identityFile: base.identityFile, sshOptions: base.sshOptions, localProxyPort: nil, relayPort: nil,
            relayID: nil, relayToken: nil, localSocketPath: nil, terminalStartupCommand: nil,
            configuredRemoteCommand: nil, agentSocketPath: agent, preserveAfterTerminalExit: true
        )
        let snapshot = try #require(opened.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted).workspaceConfiguration())
        let environment = ["PATH": "/usr/bin"]
        let openedCarrier = try resolvedControlSettings(SSHTuiConnection(configuration: opened, environment: environment))
        #expect(openedCarrier["controlmaster"] == "auto")
        let socketDirectory = try #require(SSHConnectionSharingOptions().controlSocketDirectoryPath)
        #expect(openedCarrier["controlpath"]?.hasPrefix(socketDirectory + "/") == true)
        #expect(try resolvedControlSettings(SSHTuiConnection(configuration: restored, environment: environment)) == openedCarrier)
    }

    @Test("A restored carrier finds the master an open with an SSH agent authenticated")
    func restoredCarrierSharesTheMasterOfAnOpenWithAnAgent() throws {
        // `cmux ssh` always sends the shell's SSH_AUTH_SOCK, and the master's
        // path is keyed by that agent. A restore that loses the agent dials a
        // different master, which batch mode cannot log in on a password-only host.
        let listener = try AgentSocketListener()
        defer { listener.remove() }
        let agent = listener.path
        let opened = WorkspaceRemoteConfiguration(
            terminalProfile: .shell, destination: "alice@example.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, configuredRemoteCommand: nil,
            agentSocketPath: agent, preserveAfterTerminalExit: true
        )
        let snapshot = try #require(opened.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted)
            .workspaceConfiguration(localSocketPath: "/tmp/cmux-test.sock"))
        #expect(restored.agentSocketPath == agent)
        let environment = ["PATH": "/usr/bin"]
        #expect(try resolvedControlSettings(SSHTuiConnection(configuration: restored, environment: environment))
                == resolvedControlSettings(SSHTuiConnection(configuration: opened, environment: environment)))
    }

    @Test("A restored carrier recomputes the app-owned route from durable options")
    func restoredCarrierRecomputesTheAppRoute() throws {
        // The CLI drops its own resolved ControlPath before the TUI payload.
        // The app then keys both the live carrier and its snapshot restore from
        // one captured agent route, so a password-only restore finds that same
        // authenticated master without needing the CLI's ssh -G digest.
        let listener = try AgentSocketListener()
        defer { listener.remove() }
        let agent = listener.path
        let base = configuration(options: ["ProxyCommand=/bin/sh -c true"])
        let opened = WorkspaceRemoteConfiguration(
            terminalProfile: base.terminalProfile, destination: base.destination, port: base.port,
            identityFile: base.identityFile, sshOptions: base.sshOptions, localProxyPort: nil, relayPort: nil,
            relayID: nil, relayToken: nil, localSocketPath: nil, terminalStartupCommand: nil,
            configuredRemoteCommand: nil, agentSocketPath: agent, preserveAfterTerminalExit: true
        )
        let snapshot = try #require(opened.sessionSnapshot())
        let persisted = try JSONEncoder().encode(snapshot)
        let restored = try #require(try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: persisted)
            .workspaceConfiguration(localSocketPath: "/tmp/cmux-test.sock"))
        let environment = ["PATH": "/usr/bin"]
        let openedSettings = try resolvedControlSettings(SSHTuiConnection(configuration: opened, environment: environment))
        #expect(try resolvedControlSettings(SSHTuiConnection(configuration: restored, environment: environment)) == openedSettings)
        #expect(SSHTuiConnection(configuration: restored, environment: environment).id
            == SSHTuiConnection(configuration: opened, environment: environment).id)
    }

    @Test("A restored Mosh workspace keeps the agent its snapshot saved")
    func restoredMoshWorkspaceKeepsSavedAgent() throws {
        let listener = try AgentSocketListener()
        defer { listener.remove() }
        let saved = listener.path
        let snapshot = SessionRemoteWorkspaceSnapshot(transport: .ssh, terminalTransport: .mosh,
            destination: "alice@example.invalid", agentSocketPath: saved)
        let restored = try #require(snapshot.workspaceConfiguration(localSocketPath: "/tmp/cmux-test.sock"))
        #expect(restored.terminalTransport == .mosh)
        #expect(restored.agentSocketPath == saved)
    }

    @Test("A restore uses the saved agent while it serves, then the app's agent")
    func restoredAgentFallsBackToTheAppsAgent() {
        let saved = "/tmp/cmux-test-saved-agent.sock"
        let current = "/tmp/cmux-test-current-agent.sock"
        var live: Set<String> = [current]
        var snapshot = SessionRemoteWorkspaceSnapshot(transport: .ssh, destination: "alice@example.invalid", agentSocketPath: saved)
        let environment = ["SSH_AUTH_SOCK": current]

        // A reboot moved the agent: the app's agent matches what a new `cmux ssh` sends.
        #expect(snapshot.restorableAgentSocketPath(environment: environment, isLiveAgent: live.contains) == current)
        live.insert(saved)
        #expect(snapshot.restorableAgentSocketPath(environment: environment, isLiveAgent: live.contains) == saved)
        // Snapshots written before the agent was saved still find the app's agent.
        snapshot.agentSocketPath = nil
        #expect(snapshot.restorableAgentSocketPath(environment: environment, isLiveAgent: live.contains) == current)
        #expect(snapshot.restorableAgentSocketPath(environment: [:], isLiveAgent: live.contains) == nil)
    }

    @Test("A restore carries the live fallback agent into SSH child environments")
    func restoredConfigurationUsesLiveFallbackAgent() throws {
        let listener = try AgentSocketListener()
        defer { listener.remove() }
        let saved = "/tmp/cmux-test-saved-agent.sock"
        let current = listener.path
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "alice@example.invalid",
            agentSocketPath: saved
        )
        let configuration = try #require(snapshot.workspaceConfiguration(
            environment: ["SSH_AUTH_SOCK": current],
            isLiveAgent: { [current].contains($0) }
        ))
        #expect(configuration.agentSocketPath == current)
        #expect(configuration.sshProcessEnvironment?["SSH_AUTH_SOCK"] == current)
    }

    @Test("A dead saved agent does not become an explicit disable during restore")
    func staleSavedAgentDoesNotPoisonFutureRestore() throws {
        let stale = "/tmp/cmux-stale-restore-agent.sock"
        let current = "/tmp/cmux-current-restore-agent.sock"
        var snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "alice@example.invalid",
            agentSocketPath: stale,
            agentSocketPathOverrideIsSet: true,
        )

        let restored = try #require(snapshot.workspaceConfiguration(
            environment: [:],
            isLiveAgent: { _ in false }
        ))
        #expect(restored.agentSocketPath == nil)
        #expect(!restored.agentSocketPathOverrideIsSet)

        let resaved = try #require(restored.sessionSnapshot())
        let resumed = try #require(resaved.workspaceConfiguration(
            environment: ["SSH_AUTH_SOCK": current],
            isLiveAgent: { $0 == current }
        ))
        #expect(resumed.agentSocketPath == current)
        #expect(resumed.agentSocketPathOverrideIsSet)

        var carrierSnapshot = snapshot
        carrierSnapshot.sshSessionOwner = "cmux-tui"
        carrierSnapshot.preserveAfterTerminalExit = true
        let restoredCarrier = try #require(carrierSnapshot.workspaceConfiguration(
            environment: [:],
            isLiveAgent: { _ in false }
        ))
        #expect(restoredCarrier.agentSocketPath == nil)
        #expect(!restoredCarrier.agentSocketPathOverrideIsSet)
    }

    @Test("A saved agent path that no longer serves never beats a live agent")
    func staleAgentPathLosesToALiveAgent() throws {
        let listener = try AgentSocketListener()
        defer { listener.remove() }
        // A leftover regular file where the saved agent used to listen.
        let stale = listener.directory + "/stale.sock"
        #expect(FileManager.default.createFile(atPath: stale, contents: nil))
        defer { unlink(stale) }
        let snapshot = SessionRemoteWorkspaceSnapshot(transport: .ssh, destination: "alice@example.invalid", agentSocketPath: stale)

        #expect(!SessionRemoteWorkspaceSnapshot.acceptsAgentConnections(atPath: stale))
        #expect(SessionRemoteWorkspaceSnapshot.acceptsAgentConnections(atPath: listener.path))
        #expect(snapshot.restorableAgentSocketPath(environment: ["SSH_AUTH_SOCK": listener.path]) == listener.path)
    }

    /// The control settings OpenSSH resolves for the carrier's own ssh arguments.
    private func resolvedControlSettings(_ connection: SSHTuiConnection) throws -> [String: String] {
        let arguments = connection.arguments(stateDirectory: "/tmp/cmux-tui-client", deviceName: "test")
        let sshArguments = arguments.indices.compactMap { index -> String? in
            guard index > 0, arguments[index - 1] == "--ssh-arg" else { return nil }
            return arguments[index]
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + sshArguments + [connection.configuration.destination]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        var settings: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, ["controlmaster", "controlpath", "controlpersist"].contains(parts[0]) else { continue }
            settings[String(parts[0])] = String(parts[1])
        }
        return settings
    }

    @Test("Legacy persistent SSH snapshots are not claimed by the TUI owner")
    func legacySnapshotDoesNotBecomeTuiSession() throws {
        let legacy = SessionRemoteWorkspaceSnapshot(transport: .ssh, destination: "fixture@host",
            preserveAfterTerminalExit: true, relayPort: 1234, persistentDaemonSlot: "legacy-owned")
        #expect(legacy.tuiSSHConfiguration(agentSocketPath: nil) == nil)
        let blocked = try #require(legacy.workspaceConfiguration())
        #expect(blocked.terminalStartupCommand == nil)
        #expect(blocked.sessionSnapshot() == legacy)
        #expect(blocked.scopedToOwnerWorkspace(UUID()).sessionSnapshot() == legacy)
        #expect(blocked.withSSHControlMasterLeaseGeneration(UUID()).sessionSnapshot() == legacy)

    }

    @Test("A stale legacy SSH snapshot starts a fresh cmux-tui workspace")
    func staleLegacySnapshotStartsFreshTuiWorkspace() throws {
        let legacy = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "fixture@host",
            preserveAfterTerminalExit: true,
            relayPort: 1234,
            persistentDaemonSlot: "legacy-owned"
        )
        var configuration = try #require(legacy.workspaceConfiguration())
        configuration.restoredSSHSession = legacy
        let prepared = SSHTuiWorkspaceCoordinator.configurationForAttach(configuration)
        #expect(prepared.restoredSSHSession == nil)
        #expect(prepared.destination == configuration.destination)
        #expect(prepared.preserveAfterTerminalExit)
    }

    @Test("SSH restores do not require Cloud creation receipts")
    func sshRestoreSkipsCloudOnlyReceiptResolution() {
        #expect(!SSHTuiWorkspaceCoordinator.usesDurableCreationReceipt(machineID: "ssh:fixture", restoring: true))
        #expect(SSHTuiWorkspaceCoordinator.usesDurableCreationReceipt(machineID: "vm_fixture", restoring: true))
        #expect(!SSHTuiWorkspaceCoordinator.usesDurableCreationReceipt(machineID: "ssh:fixture", restoring: false))
    }

    @Test("Fresh SSH opens skip the graph round trip before remote creation")
    func freshSSHOpenDoesNotNeedInitialGraphRefresh() {
        #expect(!SSHTuiWorkspaceCoordinator.needsInitialGraphRefresh(
            restoring: false, hasExistingProjections: false, hasRemoteBinding: false
        ))
        #expect(SSHTuiWorkspaceCoordinator.needsInitialGraphRefresh(
            restoring: true, hasExistingProjections: false, hasRemoteBinding: false
        ))
        #expect(SSHTuiWorkspaceCoordinator.needsInitialGraphRefresh(
            restoring: false, hasExistingProjections: true, hasRemoteBinding: false
        ))
        #expect(SSHTuiWorkspaceCoordinator.needsInitialGraphRefresh(
            restoring: false, hasExistingProjections: false, hasRemoteBinding: true
        ))
    }

    @Test("A legacy persistent SSH snapshot running a named tmux session reattaches it through cmux-tui")
    func legacyTmuxSnapshotReattachesItsTmuxSession() throws {
        // The remote block 0.64.25 wrote for `cmux ssh` workspaces with a tmux
        // profile: relay port and daemon slot, no session owner.
        let json = Data("""
        {"destination": "fixture-host", "persistentDaemonSlot": "ssh-410b76b4-e7ea-4db1-8394-9d06bfc19b5c",
         "preserveAfterTerminalExit": true, "relayPort": 52206, "skipDaemonBootstrap": false,
         "sshOptions": ["EscapeChar=none", "EnableEscapeCommandline=no", "StrictHostKeyChecking=accept-new"],
         "terminalProfile": {"kind": "tmux", "tmuxSessionName": "cc-fixture"},
         "terminalTransport": "ssh", "transport": "ssh"}
        """.utf8)
        let legacy = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: json)
        #expect(legacy.sshSessionOwner == nil)

        let restored = try #require(legacy.workspaceConfiguration())
        #expect(restored.routesThroughSSHTui)
        #expect(restored.restoredSSHSession == legacy)
        #expect(restored.destination == "fixture-host")
        #expect(restored.terminalProfile.tmuxSessionName == "cc-fixture")
        #expect(restored.terminalStartupCommand == nil)
        #expect(restored.relayPort == nil)
        #expect(restored.preserveAfterTerminalExit)
        // The command can return a created path even after a dead child; retain
        // the legacy descriptor until a future explicit liveness acknowledgment.
        let tmux = try #require(WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "cc-fixture"))
        #expect(SSHTuiConnection(configuration: restored).shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        // Keep the durable legacy descriptor across saves until a real process
        // liveness acknowledgment exists; this avoids claiming a dead attach.
        let resaved = try #require(restored.sessionSnapshot())
        #expect(resaved.sshSessionOwner == nil)
        #expect(resaved.relayPort == 52206)
        #expect(resaved.persistentDaemonSlot == "ssh-410b76b4-e7ea-4db1-8394-9d06bfc19b5c")
        #expect(resaved.terminalProfile == tmux)
    }

    @Test("Legacy tmux restore keeps its descriptor and attaches only to the existing session", arguments: [false, true])
    func legacyTmuxRestoreRequiresExistingSession(omitsTerminalTransport: Bool) throws {
        let json = Data("""
        {"destination": "fixture-host", "persistentDaemonSlot": "legacy-slot",
         "preserveAfterTerminalExit": true, "relayPort": 52206, "sshOptions": [],
         "terminalProfile": {"kind": "tmux", "tmuxSessionName": "cc-fixture"},
         "terminalTransport": "ssh", "transport": "ssh"}
        """.utf8)
        var fields = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        if omitsTerminalTransport { fields.removeValue(forKey: "terminalTransport") }
        let legacy = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        let restored = try #require(legacy.workspaceConfiguration())
        let tmux = try #require(WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "cc-fixture"))
        #expect(restored.restoredSSHSession == legacy)
        let connection = SSHTuiConnection(configuration: restored)
        #expect(connection.shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        // A failed attach must keep the legacy descriptor, rather than claiming
        // cmux-tui ownership before the remote session was proven.
        let failed = try #require(restored.sessionSnapshot())
        #expect(failed.sshSessionOwner == nil)
        #expect(failed.persistentDaemonSlot == "legacy-slot")
        #expect(failed.relayPort == 52206)
        let roundTripped = try #require(try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self, from: JSONEncoder().encode(failed)
        ).workspaceConfiguration())
        #expect(roundTripped.restoredSSHSession == failed)
        #expect(SSHTuiConnection(configuration: roundTripped).id == connection.id)
        #expect(SSHTuiConnection(configuration: roundTripped).shellCommand.suffix(3) == ["attach-session", "-t", "=cc-fixture"])

        let fresh = WorkspaceRemoteConfiguration(terminalProfile: tmux, destination: "fixture-host", port: nil,
            identityFile: nil, sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true)
        #expect(SSHTuiConnection(configuration: fresh).shellCommand == tmux.remoteCommandArguments)
    }

    // Covers the two attach helpers: the title attach enqueues as a rename before
    // binding, and the create request, whose fingerprint must not depend on it.
    @MainActor
    @Test("An SSH attach publishes the local workspace title to the remote workspace it creates")
    func attachPublishesLocalTitleToRemoteWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let untitled = SSHTuiWorkspaceCoordinator.remoteWorkspaceCreationRequest(for: workspace, socketPath: "/tmp/fixture.sock")
        #expect(untitled.operation == "workspace.create")
        #expect(untitled.params["initial_content"] as? String == "empty")
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == nil)

        // `cmux ssh --name`, `cmux mosh-tmux --name`, and a restored user title all
        // reach attach as the local custom title. The daemon graph owns the name
        // once the workspace is bound, so attach must publish the title or the
        // daemon default (`workspace-N`) replaces it.
        #expect(workspace.setCustomTitle("s655 @big-red", source: .user))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == "s655 @big-red")
        // The create itself stays unnamed and identical across title edits, so a
        // replay of the per-workspace idempotency key never conflicts.
        let titled = SSHTuiWorkspaceCoordinator.remoteWorkspaceCreationRequest(for: workspace, socketPath: "/tmp/fixture.sock")
        #expect(titled.params["name"] == nil)
        #expect(titled.parameters == untitled.parameters)
        #expect(titled.idempotencyKey == untitled.idempotencyKey)

        // Auto titles are derived locally, and a title over the daemon's
        // 1024-byte limit would fail the rename; neither is published.
        let automatic = Workspace()
        defer { automatic.teardownAllPanels() }
        #expect(automatic.setCustomTitle("derived-from-cwd", source: .auto))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: automatic) == nil)
        #expect(workspace.setCustomTitle(String(repeating: "x", count: 1025), source: .user))
        #expect(SSHTuiWorkspaceCoordinator.remoteWorkspaceTitleToPublish(for: workspace) == nil)
    }

    @Test("Managed SSH snapshot serialization records its session owner")
    func managedSnapshotRecordsOwner() throws {
        let snapshot = try #require(configuration().sessionSnapshot())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["sshSessionOwner"] as? String == "cmux-tui")
    }

    @MainActor
    @Test("A legacy relay configuration keeps its relay lifecycle and startup command")
    func legacyRelayConfigurationIsNotClaimedByCmuxTui() {
        let native = configuration()
        #expect(native.routesThroughSSHTui)
        // The shape the CLI's no-TTY `cmux ssh` path sends to workspace.remote.configure.
        let legacy = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007, relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64), localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh -T alice@example.invalid", preserveAfterTerminalExit: false
        )
        #expect(!legacy.routesThroughSSHTui)
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        #expect(workspace.configureRemoteConnection(legacy, autoConnect: false))
        #expect(!workspace.usesSSHTui)
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: workspace.remoteConfiguration) == "ssh -T alice@example.invalid")
        // Only cmux-tui-owned persistent sessions drop the startup command; a
        // persistent relay configuration still runs its own.
        let persistentLegacy = WorkspaceRemoteConfiguration(
            destination: "alice@example.invalid", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007, relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64), localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh-pty-attach", preserveAfterTerminalExit: true
        )
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: persistentLegacy) == "ssh-pty-attach")
        #expect(workspace.effectiveRemoteTerminalStartupCommand(from: native) == nil)
    }

    @Test("SSH projection identities survive session serialization without becoming Cloud machines")
    func projectionRoundTripRetainsSSHBackend() throws {
        let id = SSHTuiConnection(configuration: configuration()).id
        let record = SurfaceProjectionRecord(panelID: UUID(), resource: SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: id), kind: .terminal, key: "term_persistent"
        ), remoteWorkspaceID: "ws_persistent", remoteTabID: "tab_persistent")
        let decoded = try JSONDecoder().decode(SurfaceProjectionRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.resource == record.resource)
        #expect(decoded.remoteWorkspaceID == "ws_persistent")
        #expect(decoded.remoteTabID == "tab_persistent")
        #expect(decoded.resource.machine.isSSH)
    }

    @MainActor
    @Test("Pending native SSH projections remain remote until removed")
    func nativeSSHProjectionOwnsAgentAndPathClassification() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        #expect(!workspace.isRemoteTerminalContext(panelID))
        #expect(workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        workspace.remoteConfiguration = configuration()
        let resource = SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration()).id),
            kind: .terminal, key: "term_" + UUID().uuidString
        )
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        try #require(catalog.projectionIncludingPendingRestore(forPanel: panelID)?.resource == resource)
        #expect(workspace.activeRemoteTerminalSurfaceIds.isEmpty)
        #expect(workspace.isRemoteTerminalContext(panelID))
        #expect(!workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        #expect(!workspace.isRemoteTerminalContext(UUID()))
        catalog.endProjections(panelID: panelID, reason: .replaced)
        #expect(!workspace.isRemoteTerminalContext(panelID))
        #expect(workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
    }

    @MainActor
    @Test("Only terminals known to run on this Mac resolve paths locally")
    func unplacedAndCloudSurfacesNeverResolvePathsLocally() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        #expect(workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        #expect(!workspace.terminalLinkIsRemoteTerminal(panelID))
        let unplaced = UUID()
        #expect(!workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: unplaced))
        #expect(workspace.terminalLinkIsRemoteTerminal(unplaced))

        let resource = SurfaceResourceID(
            machine: .cloud("vm-path-fixture-" + UUID().uuidString),
            kind: .terminal, key: "term_" + UUID().uuidString
        )
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        try #require(catalog.projectionIncludingPendingRestore(forPanel: panelID)?.resource == resource)
        #expect(!workspace.canResolveTerminalPathsAgainstLocalFilesystem(surfaceID: panelID))
        #expect(workspace.terminalLinkIsRemoteTerminal(panelID))
    }

    @Test("Loopback links in SSH terminals retain remote routing")
    func sshLoopbackLinkUsesItsMachineCarrier() throws {
        let resource = SurfaceResource(
            id: .init(machine: .ssh("fixture"), kind: .terminal, key: "term_remote"),
            title: "shell", detail: "/home/alice", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        let url = try #require(URL(string: "http://localhost:3000/project?view=source"))
        let target = try #require(CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(
            url: url, resource: resource, privateAddress: "127.0.0.1"
        ))
        #expect(target.url.port == 3000)
        #expect(target.url.path == "/project")
        #expect(target.url.query == "view=source")
    }

    @Test("SSH port previews admit remote loopback without widening Cloud routes")
    func sshPortPreviewRetainsCarrierOwnership() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: .ssh("fixture"), port: 3000)
        #expect(CloudPortRoutePlan.plan(resource: resource, privateAddress: "127.0.0.1")
            == .privateDirect(remoteURL: "http://127.0.0.1:3000"))
        let cloud = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("fixture"), port: 3000)
        guard case .unsupported = CloudPortRoutePlan.plan(resource: cloud, privateAddress: "127.0.0.1") else {
            Issue.record("Cloud must not acquire an SSH loopback route")
            return
        }
    }

    @Test("An unconfirmed SSH graph cannot publish its saved remote working directory")
    @MainActor
    func unconfirmedSSHDirectoryRemainsUntrusted() {
        let resource = SurfaceResource(
            id: .init(machine: .ssh("fixture"), kind: .terminal, key: "term_remote"),
            title: "shell", detail: "/home/alice", lifecycle: .running,
            agent: nil, remoteWorkspace: nil, port: nil, url: nil
        )
        #expect(SurfaceCatalog().resourceForPresentation(resource).detail == nil)
    }
    @Test("Native SSH forks never fall back to local creation without a provider")
    @MainActor
    func disconnectedNativeSSHForkFailsClosed() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        let config = configuration()
        workspace.remoteConfiguration = config
        let resource = SurfaceResourceID(machine: .init(rawValue: SSHTuiConnection(configuration: config).id),
                                         kind: .terminal, key: "fork-test-" + UUID().uuidString)
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        let snapshot = SessionRestorableAgentSnapshot(kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951", workingDirectory: "/home/alice/project")
        let originalPanels = Set(workspace.panels.keys)
        #expect(workspace.remotePTYRespawnRouting(panelId: panelID) == .unsupportedRemote)
        #expect(workspace.respawnTerminalSurface(panelId: panelID, command: "printf remote-only") == nil)
        #expect(workspace.forkAgentConversation(fromPanelId: panelID, snapshot: snapshot, direction: .right) == nil)
        #expect(workspace.forkAgentConversationToNewTab(fromPanelId: panelID, snapshot: snapshot,
                                                       anchorTabId: tabID, paneId: paneID) == nil)
        #expect(Set(workspace.panels.keys) == originalPanels)
        let launch = try #require(workspace.forkAgentWorkspaceLaunch(fromPanelId: panelID, snapshot: snapshot))
        let forkConfiguration = try #require(launch.remoteConfiguration)
        #expect(SSHTuiConnection(configuration: forkConfiguration).id == resource.machine.rawValue)
        #expect(forkConfiguration.configuredRemoteCommand == snapshot.forkCommand)
        #expect(launch.initialTerminalCommand == nil)
        #expect(launch.initialTerminalInput.isEmpty)
        #expect(launch.startupRestoreAgent == nil)
        #expect(launch.autoConnectRemoteConfiguration)
    }

    /// A terminal saved in an SSH workspace without a host terminal (a local
    /// shell opened from a file preview, or a pane whose create never finished)
    /// restores as a process-free pane that no provider adopts. It must not
    /// claim another Mac disconnected, and its Retry must open a host terminal.
    @Test("A restored SSH tab with no host terminal retries onto the host", .timeLimit(.minutes(1)))
    @MainActor
    func unattachedRestoredSSHTerminalRetriesOntoHost() async throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = originalTabManager ?? TabManager()
        appDelegate.tabManager = manager
        let workspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) { manager.closeWorkspace(workspace, recordHistory: false) }
            appDelegate.tabManager = originalTabManager
        }
        let config = configuration()
        let connection = SSHTuiConnection(configuration: config)
        workspace.remoteConfiguration = config
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(machine: .init(rawValue: connection.id))
        catalog.register(provider)
        defer {
            provider.release.resolve(true)
            catalog.unregister(machine: provider.machine)
        }
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: connection.id, isBase: false, remoteWorkspaceID: provider.remote.id)
        let paneID = try #require(workspace.focusedPanelId.flatMap { workspace.paneId(forPanelId: $0) })
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(workspace.createPanel(
            from: saved, inPane: paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))
        #expect(catalog.projectionIncludingPendingRestore(forPanel: restoredID) == nil)

        let notice = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: restoredID))
        #expect(notice.showsReconnectButton)
        #expect(!notice.title.contains("Mac"), "An SSH host is not another Mac: \(notice.title)")
        #expect(!notice.detail.contains("Mac"), "An SSH host is not another Mac: \(notice.detail)")

        #expect(workspace.reconnectCloudTerminalSurface(surfaceId: restoredID))
        let replacement = try #require(
            workspace.cloudPendingCreations.values.first { $0.machine == provider.machine },
            "Retry left the pane with nothing to reconnect to"
        )
        #expect(workspace.paneId(forPanelId: replacement.panelID) == paneID)
        _ = await provider.creationStarted.result
        // Bonsplit finishes the tab close on a later main-queue turn.
        for _ in 0..<100 where workspace.panels[restoredID] != nil { await Task.yield() }
        #expect(workspace.panels[restoredID] == nil, "The process-free pane is replaced, not left beside the new one")
        #expect(provider.requestedWorkspaces == [provider.remote.id])
        #expect(provider.requestedCommands == [connection.shellCommand])
    }

    /// Retry keeps the tab where it was, focused, with its user-set name and
    /// pin, and a second click while the first is in flight creates nothing.
    @Test("Retry on a restored SSH tab keeps its place, name and pin, once", .timeLimit(.minutes(1)))
    @MainActor
    func unattachedRestoredSSHTerminalRetryKeepsTabIdentity() async throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let workspace = fixture.workspace
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: "build box", directory: nil,
            isPinned: true, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(workspace.createPanel(
            from: saved, inPane: fixture.paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))
        let tabIndex: (UUID) -> Int? = { panelID in
            workspace.bonsplitController.tabs(inPane: fixture.paneID).firstIndex { workspace.panelIdFromSurfaceId($0.id) == panelID }
        }
        let originalIndex = try #require(tabIndex(restoredID))

        #expect(workspace.reconnectCloudTerminalSurface(surfaceId: restoredID))
        #expect(workspace.reconnectCloudTerminalSurface(surfaceId: restoredID))

        #expect(fixture.hostReservations == 1, "A double-click on Retry created two terminals")
        let replacement = try #require(workspace.cloudPendingCreations.values.first { $0.machine == fixture.provider.machine })
        #expect(workspace.focusedPanelId == replacement.panelID)
        #expect(workspace.panelCustomTitles[replacement.panelID] == "build box")
        #expect(workspace.pinnedPanelIds.contains(replacement.panelID))
        for _ in 0..<100 where workspace.panels[restoredID] != nil { await Task.yield() }
        #expect(tabIndex(replacement.panelID) == originalIndex)
    }

    @Test("Retry on a restored SSH tab names the host terminal after the tab", .timeLimit(.minutes(1)))
    @MainActor
    func unattachedRestoredSSHTerminalRetrySendsCustomTitleToHost() async throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: "build box", directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(fixture.workspace.createPanel(
            from: saved, inPane: fixture.paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))

        #expect(fixture.workspace.reconnectCloudTerminalSurface(surfaceId: restoredID))
        _ = await fixture.provider.creationStarted.result

        #expect(fixture.provider.requestedNames == ["build box"], "The daemon's default name would overwrite the tab's")
    }

    @Test("Forking an agent from a restored SSH tab with no host terminal is refused")
    @MainActor
    func forkFromUnattachedRestoredSSHTerminalIsRefused() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let workspace = fixture.workspace
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(workspace.createPanel(
            from: saved, inPane: fixture.paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))
        let agent = SessionRestorableAgentSnapshot(kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951", workingDirectory: "/Users/alice/project",
            launchCommand: nil)
        let panelsBefore = Set(workspace.panels.keys)

        #expect(workspace.forkNativeSSHAgentConversation(
            fromPanelId: restoredID, snapshot: agent,
            destination: .tab(workspaceID: workspace.id, paneID: fixture.paneID.id.uuidString, index: nil)
        ) == nil)
        #expect(workspace.forkAgentConversation(fromPanelId: restoredID, snapshot: agent, direction: .right) == nil)

        #expect(Set(workspace.panels.keys) == panelsBefore, "A local agent's fork reached a shell")
        #expect(fixture.hostReservations == 0, "A local agent's resume command was sent to the host")
    }

    /// Another Mac's pane restored into an SSH workspace is still that Mac's.
    @Test("A device pane restored in an SSH workspace keeps the Mac wording")
    @MainActor
    func deviceProjectionInSSHWorkspaceKeepsMacWording() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "studio-mac", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: nil,
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(fixture.workspace.createPanel(
            from: saved, inPane: fixture.paneID, snapshotWorkspaceId: nil,
            shouldRestoreSingleDefaultCloudTerminal: false, restoresDeviceProjection: true
        ))

        let notice = try #require(fixture.workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: restoredID))
        #expect(notice.title == "Mac disconnected")
    }

    /// A saved host terminal whose pane could not be reserved waits for the SSH
    /// provider; it is not another Mac, and Retry asks again.
    @Test("A pending SSH pane says it is not running on the host and Retry asks again")
    @MainActor
    func pendingSSHTerminalNoticeAndRetry() {
        var retries = 0
        let status = DeviceTerminalAttachmentStatus(origin: .pendingSSHTerminal)
        status.onRetry = { retries += 1 }
        status.update(connected: false, connecting: false)
        let notice = status.presentation
        #expect(notice?.title == "Not running on the SSH host")
        #expect(notice?.detail.contains("Mac") == false)
        #expect(notice?.showsReconnectButton == true)
        status.retry()
        #expect(retries == 1)
        #expect(status.presentation?.showsProgress == true)
    }

    @Test("Retry on a restored SSH tab without a provider stops and stays put")
    @MainActor
    func unattachedRestoredSSHTerminalRetryWithoutProviderStops() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let workspace = fixture.workspace
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(workspace.createPanel(
            from: saved, inPane: fixture.paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))
        SurfaceCatalog.shared.unregister(machine: fixture.provider.machine)
        let localBefore = fixture.localTerminalCount

        _ = workspace.reconnectCloudTerminalSurface(surfaceId: restoredID)

        #expect(fixture.localTerminalCount == localBefore)
        #expect(workspace.panels[restoredID] != nil, "The pane stays so the user can retry later")
        let notice = try #require(workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: restoredID))
        #expect(!notice.showsProgress, "Retry left the spinner running with nothing in flight")
        #expect(workspace.cloudPaneCreationFailureStore.failure != nil)
    }

    /// Cmd+T from that pane is a new terminal where the pane belongs, not a
    /// local shell that would come back dead on the next relaunch.
    @Test("A new tab beside a restored SSH tab with no host terminal runs on the host")
    @MainActor
    func newTabFromUnattachedRestoredSSHTerminalIsRemote() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = originalTabManager ?? TabManager()
        appDelegate.tabManager = manager
        let workspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) { manager.closeWorkspace(workspace, recordHistory: false) }
            appDelegate.tabManager = originalTabManager
        }
        let config = configuration()
        let connection = SSHTuiConnection(configuration: config)
        workspace.remoteConfiguration = config
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(machine: .init(rawValue: connection.id))
        catalog.register(provider)
        defer {
            provider.release.resolve(true)
            catalog.unregister(machine: provider.machine)
        }
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: connection.id, isBase: false, remoteWorkspaceID: provider.remote.id)
        let paneID = try #require(workspace.focusedPanelId.flatMap { workspace.paneId(forPanelId: $0) })
        let saved = SessionPanelSnapshot(
            id: UUID(), type: .terminal, title: "alice@host:~/project", customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, listeningPorts: [], ttyName: "ttys011",
            terminal: nil, browser: nil, markdown: nil, filePreview: nil, rightSidebarTool: nil
        )
        let restoredID = try #require(workspace.createPanel(
            from: saved, inPane: paneID, snapshotWorkspaceId: nil, shouldRestoreSingleDefaultCloudTerminal: false
        ))
        let restoredTab = try #require(workspace.surfaceIdFromPanelId(restoredID))
        workspace.bonsplitController.selectTab(restoredTab)
        let localBefore = workspace.panels.values.compactMap { $0 as? TerminalPanel }.filter { $0.surface.ioMode != .manualMirror }.count

        let outcome = workspace.newTerminalSurfaceOutcome(inPane: paneID, focus: false)

        #expect(outcome.isAccepted)
        let localAfter = workspace.panels.values.compactMap { $0 as? TerminalPanel }.filter { $0.surface.ioMode != .manualMirror }.count
        #expect(localAfter == localBefore, "Cmd+T started a local shell in an SSH workspace")
        #expect(workspace.cloudPendingCreations.values.contains { $0.machine == provider.machine })
    }

    /// An SSH workspace whose selected tab is a file preview: the anchor that
    /// used to send Cmd+T, Cmd+D and the tab bar's + to a local shell.
    @MainActor
    private struct PreviewSelectedSSHWorkspace {
        let manager: TabManager
        let workspace: Workspace
        let provider: CloudTerminalPlacementTestProvider
        let paneID: PaneID
        let previewID: UUID
        /// The main window the fixture owns, when it asked for one.
        let window: NSWindow?
        let cleanup: () -> Void

        var localTerminalCount: Int {
            workspace.panels.values.compactMap { $0 as? TerminalPanel }.filter { $0.surface.ioMode != .manualMirror }.count
        }

        var hostReservations: Int {
            workspace.cloudPendingCreations.values.filter { $0.machine == provider.machine }.count
        }
    }

    @MainActor
    private func previewSelectedSSHWorkspace(
        remote: Bool = true, bound: Bool = true, ownWindow: Bool = false
    ) throws -> PreviewSelectedSSHWorkspace {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        // A shortcut test gets its own key window so routing never depends on
        // whatever the host app's first responder happens to be.
        let windowID = ownWindow ? appDelegate.createMainWindow() : nil
        let window = windowID.flatMap { appDelegate.windowForMainWindowId($0) }
        let manager = try windowID.map { try #require(appDelegate.tabManagerFor(windowId: $0)) }
            ?? originalTabManager ?? TabManager()
        if windowID == nil { appDelegate.tabManager = manager }
        let originalSelection = manager.selectedTabId
        let workspace = manager.addWorkspace(select: true)
        let config = configuration()
        let connection = SSHTuiConnection(configuration: config)
        if remote { workspace.remoteConfiguration = config }
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(machine: .init(rawValue: connection.id))
        catalog.register(provider)
        if remote, bound {
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: connection.id, isBase: false, remoteWorkspaceID: provider.remote.id)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-preview-\(UUID().uuidString).sv")
        try "module top; endmodule\n".write(to: file, atomically: true, encoding: .utf8)
        let cleanup = {
            provider.release.resolve(true)
            catalog.unregister(machine: provider.machine)
            try? FileManager.default.removeItem(at: file)
            if manager.tabs.contains(where: { $0.id == workspace.id }) { manager.closeWorkspace(workspace, recordHistory: false) }
            if let originalSelection { manager.selectedTabId = originalSelection }
            window?.close()
            appDelegate.tabManager = originalTabManager
        }
        do {
            let paneID = try #require(workspace.bonsplitController.focusedPaneId)
            let preview = try #require(workspace.newFilePreviewSurface(inPane: paneID, filePath: file.path, focus: true))
            try #require(workspace.focusedPanelId == preview.id)
            // Key but off-screen: the test never puts a window in front of the user.
            window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window?.makeKeyAndOrderFront(nil)
            return PreviewSelectedSSHWorkspace(
                manager: manager, workspace: workspace, provider: provider,
                paneID: paneID, previewID: preview.id, window: window, cleanup: cleanup
            )
        } catch {
            cleanup()
            throw error
        }
    }

    @Test("Cmd+T beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func newTabFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        fixture.manager.newSurface()

        #expect(fixture.localTerminalCount == localBefore, "Cmd+T started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("The tab bar's + beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func tabBarNewTerminalFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        fixture.workspace.splitTabBar(fixture.workspace.bonsplitController, didRequestNewTab: "terminal", inPane: fixture.paneID)

        #expect(fixture.localTerminalCount == localBefore, "The tab bar's + started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("Cmd+D from a file preview in an SSH workspace splits onto the host")
    @MainActor
    func splitFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        let outcome = fixture.manager.createSplitOutcome(
            tabId: fixture.workspace.id, surfaceId: fixture.previewID, direction: .right
        )

        #expect(outcome.isAccepted)
        #expect(fixture.localTerminalCount == localBefore, "Cmd+D started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("The pane split button beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func paneSplitButtonFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        let newPane = fixture.workspace.bonsplitController.splitPane(fixture.paneID, orientation: .horizontal)

        #expect(newPane != nil)
        #expect(fixture.localTerminalCount == localBefore, "The split button started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("The empty pane's Terminal button in an SSH workspace runs on the host")
    @MainActor
    func emptyPaneTerminalButtonRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        _ = fixture.workspace.newEmptyPaneTerminal(inPane: fixture.paneID)

        #expect(fixture.localTerminalCount == localBefore, "The empty pane's button started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("Alt-n beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func autoLayoutPaneFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        let outcome = fixture.manager.createAutoLayoutPaneOutcome(tabId: fixture.workspace.id, surfaceId: fixture.previewID)

        #expect(outcome.isAccepted)
        #expect(fixture.localTerminalCount == localBefore, "Alt-n started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("Canvas Cmd+D beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func canvasSplitShortcutFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace(ownWindow: true)
        defer { fixture.cleanup() }
        fixture.workspace.setLayoutMode(.canvas)
        try #require(fixture.workspace.layoutMode == .canvas)
        let appDelegate = try #require(AppDelegate.shared)
        let window = try #require(fixture.window)
        let localBefore = fixture.localTerminalCount

        _ = appDelegate.performSplitShortcut(direction: .right, preferredWindow: window)

        #expect(fixture.localTerminalCount == localBefore, "Canvas Cmd+D started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("Canvas Alt-n beside a file preview in an SSH workspace runs on the host")
    @MainActor
    func canvasAutoLayoutShortcutFromFilePreviewRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace(ownWindow: true)
        defer { fixture.cleanup() }
        fixture.workspace.setLayoutMode(.canvas)
        try #require(fixture.workspace.layoutMode == .canvas)
        let appDelegate = try #require(AppDelegate.shared)
        let window = try #require(fixture.window)
        let localBefore = fixture.localTerminalCount

        _ = appDelegate.performAutoLayoutPaneShortcut(preferredWindow: window)

        #expect(fixture.localTerminalCount == localBefore, "Canvas Alt-n started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    /// A sidebar extension's terminal beside a host terminal is created on the
    /// host asynchronously; that is an accepted request, not a rejection.
    @Test("A sidebar extension's new terminal routed to the host is accepted")
    @MainActor
    func sidebarExtensionTerminalRoutedToHostIsAccepted() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let workspace = fixture.workspace
        let catalog = SurfaceCatalog.shared
        // The workspace's first terminal stands in for a pane already on the host.
        let anchorID = try #require(workspace.panels.values.first { $0 is TerminalPanel }?.id)
        let anchorTab = try #require(workspace.surfaceIdFromPanelId(anchorID))
        let anchor = fixture.provider.resource(key: "anchor")
        catalog.upsert(anchor, from: fixture.provider)
        catalog.record(SurfaceProjection(resource: anchor.id, workspaceID: workspace.id, panelID: anchorID,
            remoteWorkspaceID: fixture.provider.remote.id, remoteTabID: "tab-anchor"))
        defer { catalog.endProjections(panelID: anchorID, reason: .replaced) }
        workspace.bonsplitController.selectTab(anchorTab)

        let result = fixture.manager.createSidebarExtensionTerminalSurface(workspaceId: workspace.id)

        #expect(result.accepted, "A request routed to the host was reported as rejected")
    }

    @Test("A sidebar extension's new terminal in an SSH workspace runs on the host")
    @MainActor
    func sidebarExtensionTerminalRunsOnHost() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        let result = fixture.manager.createSidebarExtensionTerminalSurface(workspaceId: fixture.workspace.id)

        #expect(result.accepted)
        #expect(fixture.localTerminalCount == localBefore, "A sidebar extension started a local shell in an SSH workspace")
        #expect(fixture.hostReservations == 1)
    }

    @Test("Cmd+T beside a file preview in a local workspace stays local")
    @MainActor
    func newTabFromFilePreviewInLocalWorkspaceStaysLocal() throws {
        let fixture = try previewSelectedSSHWorkspace(remote: false)
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        fixture.manager.newSurface()

        #expect(fixture.localTerminalCount == localBefore + 1)
        #expect(fixture.hostReservations == 0)
    }

    @Test("Cmd+T in an SSH workspace not yet bound to its host fails closed")
    @MainActor
    func newTabInUnboundSSHWorkspaceFailsClosed() throws {
        let fixture = try previewSelectedSSHWorkspace(bound: false)
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        fixture.manager.newSurface()

        #expect(fixture.localTerminalCount == localBefore, "An unbound SSH workspace started a local shell")
        #expect(fixture.workspace.cloudPaneCreationFailureStore.failure != nil, "The refusal is explained in the pane")
    }

    /// Socket and CLI creates that carry their own command keep their
    /// existing local behavior; only the UI entry points route to the host.
    @Test("A scripted create with a command beside a file preview stays unchanged")
    @MainActor
    func scriptedCreateFromFilePreviewIsUnchanged() throws {
        let fixture = try previewSelectedSSHWorkspace()
        defer { fixture.cleanup() }
        let localBefore = fixture.localTerminalCount

        let outcome = fixture.workspace.newTerminalSurfaceOutcome(
            inPane: fixture.paneID, focus: false, initialCommand: "true"
        )

        #expect(outcome.panel != nil)
        #expect(fixture.localTerminalCount == localBefore + 1)
        #expect(fixture.hostReservations == 0)
    }

    @Test("Native SSH respawn preserves its surface and executes only through the provider")
    @MainActor
    func nativeSSHRespawnUsesProviderReplacement() async throws {
        // Projection validates its destination through Workspace.liveWorkspace, so
        // the workspace must belong to the app's TabManager. A detached Workspace()
        // fails with destinationNotFound and the provider never materializes.
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = originalTabManager ?? TabManager()
        appDelegate.tabManager = manager
        let workspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) { manager.closeWorkspace(workspace, recordHistory: false) }
            appDelegate.tabManager = originalTabManager
        }
        let panelID = try #require(workspace.focusedPanelId)
        let tabID = try #require(workspace.surfaceIdFromPanelId(panelID))
        let config = configuration()
        let connection = SSHTuiConnection(configuration: config)
        workspace.remoteConfiguration = config
        let catalog = SurfaceCatalog.shared
        let provider = CloudTerminalPlacementTestProvider(machine: .init(rawValue: connection.id))
        catalog.register(provider)
        defer {
            provider.release.resolve(true)
            catalog.unregister(machine: provider.machine)
        }
        let original = provider.resource(key: "original")
        catalog.upsert(original, from: provider)
        catalog.record(SurfaceProjection(resource: original.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-original"))
        let replacement = try #require(workspace.respawnTerminalSurface(
            panelId: panelID, command: "printf remote-only", workingDirectory: "/remote/project", focus: false))
        #expect(replacement.id == panelID)
        #expect(replacement.surface.ioMode == .manualMirror)
        #expect(workspace.surfaceIdFromPanelId(panelID) == tabID)
        _ = await provider.creationStarted.result
        #expect(provider.closedTerminals == [original.id])
        #expect(provider.requestedCommands == [connection.commandArguments("printf remote-only")])
        #expect(provider.requestedDirectories == ["/remote/project"])
        #expect(provider.requestedWorkspaces == [provider.remote.id])
        provider.release.resolve(true)
        _ = await provider.materializationFinished.result
        #expect(provider.materialized.last?.panelID == panelID)
        #expect(provider.materialized.last?.resource.machine == provider.machine)
    }

    @Test("An all-session query with no native SSH workspaces retains legacy dispatch")
    @MainActor
    func allSessionsWithoutNativeWorkspacesFallsBack() async {
        let result = await TerminalController.shared.tuiSSHSessions(params: ["all_workspaces": true])
        #expect(result == nil)
    }

    @Test("Reconnect for an unrelated pane cannot restart a native SSH workspace")
    @MainActor
    func unrelatedSurfaceReconnectDoesNotRestartSSHWorkspace() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.remoteConfiguration = configuration()
        let localPanelID = try #require(workspace.focusedPanelId)
        #expect(workspace.usesSSHTui)
        #expect(workspace.reconnectRemoteConnection(surfaceId: localPanelID) == false)
        #expect(workspace.reconnectRemoteConnection(surfaceId: UUID()) == false)
        #expect(workspace.sshTuiConnectionAttemptID == nil)
    }

    @Test("All sessions includes both owners and preserves partial listing errors")
    func mixedSessionListsPreserveRowsAndErrors() throws {
        let result = TerminalController.shared.mergeRemotePTYSessionLists(
            tui: .ok(["workspace_count": 2,
                      "sessions": [["session_id": "term_native", "workspace_id": "native"]],
                      "errors": [["workspace_id": "native-offline", "error": "offline"]]]),
            legacy: .ok(["workspace_count": 2,
                         "sessions": [["session_id": "legacy-session", "workspace_id": "legacy"]],
                         "errors": [["workspace_id": "legacy-offline", "error": "offline"]]])
        )
        guard case .ok(let raw) = result else { Issue.record("Expected a combined session list"); return }
        let payload = try #require(raw as? [String: Any])
        #expect(payload["all_workspaces"] as? Bool == true)
        #expect(payload["workspace_count"] as? Int == 4)
        let sessions = try #require(payload["sessions"] as? [[String: Any]])
        #expect(sessions.compactMap { $0["workspace_id"] as? String } == ["native", "legacy"])
        let errors = try #require(payload["errors"] as? [[String: Any]])
        #expect(errors.compactMap { $0["workspace_id"] as? String } == ["native-offline", "legacy-offline"])
    }


    @Test("The carrier asks the host to install the requested agent hooks")
    func carrierRequestsAgentHooks() throws {
        var carrier = SSHTuiConnection(configuration: configuration())
        #expect(!carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test").contains("--agent-hooks"))
        carrier.agentHookProviders = ["claude", "codex"]
        let arguments = carrier.arguments(stateDirectory: "/tmp/state", deviceName: "test")
        let index = try #require(arguments.firstIndex(of: "--agent-hooks"))
        #expect(arguments[index + 1] == "claude,codex")
        #expect(carrier.id == SSHTuiConnection(configuration: configuration()).id)
    }

    @Test("Integrations hook toggles choose the SSH agent hook providers")
    func agentHookProvidersFollowIntegrationToggles() throws {
        let suite = "SSHTuiMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["claude", "codex"])
        defaults.set(false, forKey: "claudeCodeHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults) == ["codex"])
        defaults.set(false, forKey: "codexHooksEnabled")
        #expect(SSHTuiConnection.agentHookProviders(defaults: defaults).isEmpty)
    }
}

/// A listening Unix socket standing in for an SSH agent. Its path stays under
/// the 104-byte `sun_path` limit, which a per-user temporary directory can exceed.
private struct AgentSocketListener {
    let directory: String
    let path: String
    private let fd: Int32

    init() throws {
        var template = Array("/tmp/cmux-agent-XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress).map { String(cString: $0) }
        }
        directory = try #require(created)
        path = directory + "/a.sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketPath = path
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 4) == 0)
    }

    func remove() {
        close(fd)
        unlink(path)
        rmdir(directory)
    }
}
