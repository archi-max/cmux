import CmuxCloud
import CmuxCloudTui
import CmuxRemoteWorkspace
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// `cmux open` from a cmux-tui SSH terminal (``SSHTuiHostOpenCommand``).
    ///
    /// Request rows never reach the notification sync (`syncNotifications`
    /// partitions them out), so they are never shown. Every decision is
    /// ``SSHTuiHostOpenIngress``'s; this only resolves placements, runs the
    /// open, and sends each answer back as a `notification.ack` under its
    /// reserved client id. The open is `cmux open`'s existing path: the file
    /// is read only through that workspace's SSH connection and shown in the
    /// native preview, only while that terminal is focused.
    func syncHostOpenRequests(_ requests: [CloudVMNotificationRow]) {
        guard machine.isSSH else { return }
        var ingress = hostOpenIngress ?? SSHTuiHostOpenIngress(machineID: machine.rawValue)
        let actions = ingress.plan(
            requests: requests, now: Date(),
            placements: { [weak self] terminalID in self?.hostOpenPlacements(terminalID: terminalID) ?? [] },
            pathIsAcceptable: RemoteRelayCommandPolicy.isAcceptableRemoteFileOpenPath
        )
        hostOpenIngress = ingress
        for action in actions {
            switch action {
            case .open(let rowID, let path, let workspaceID, let panelID):
                sendHostOpenAnswer(openHostRequest(path: path, workspaceID: workspaceID, panelID: panelID), rowID: rowID)
            case .answer(let rowID, let answer):
                sendHostOpenAnswer(answer, rowID: rowID)
            case .recheck(let delay):
                scheduleHostOpenRecheck(after: delay)
            }
        }
    }

    /// Every pane showing `terminalID` of this machine, with the workspace the
    /// app finds for the projection's workspace id.
    private func hostOpenPlacements(terminalID: String) -> [SSHTuiHostOpenPlacement] {
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        return catalog.projections(of: resource).map { projection in
            let workspace = Self.hostOpenWorkspace(id: projection.workspaceID)
            return SSHTuiHostOpenPlacement(
                projectionWorkspaceID: projection.workspaceID,
                panelID: projection.panelID,
                workspaceID: workspace?.id,
                workspaceUsesSSHTui: workspace?.usesSSHTui ?? false,
                workspaceConnectionID: workspace?.remoteConfiguration.map { SSHTuiConnection(configuration: $0).id }
            )
        }
    }

    private static func hostOpenWorkspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    private func openHostRequest(path: String, workspaceID: UUID, panelID: UUID) -> SSHTuiHostOpenAnswer {
        guard let workspace = Self.hostOpenWorkspace(id: workspaceID) else { return .notOpenHere }
        let outcome = workspace.openRemoteFileFromCommandLine(sourcePanelId: panelID, path: path)
        #if DEBUG
        cmuxDebugLog("sshOpen.open machine=\(machineID) surface=\(panelID.uuidString) outcome=\(outcome)")
        #endif
        switch outcome {
        case .started:
            return .ok
        case .unsupportedType:
            workspace.terminalPanel(for: panelID)?.hostedView.showTerminalNotice(RemotePreviewNotice.typeOpensFromFilesPanel)
            return .unsupportedType
        case .unavailable:
            workspace.terminalPanel(for: panelID)?.hostedView.showTerminalNotice(RemotePreviewNotice.couldNotOpen)
            return .previewsOff
        }
    }

    private func sendHostOpenAnswer(_ answer: SSHTuiHostOpenAnswer, rowID: String) {
        let machineID = self.machineID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let connected = try await self.links.connected(machineID: machineID)
                guard let link = await self.links.link(machineID: machineID) else { return }
                _ = try await link.run(arguments: CloudTuiRequests.notificationAckArguments(
                    socketPath: connected.socketPath,
                    clientID: answer.clientID,
                    notificationIDs: [rowID],
                    idempotencyKey: "mac-cmux-open-\(rowID)-\(answer.rawValue.replacingOccurrences(of: ":", with: "-"))"
                ))
            } catch {
                #if DEBUG
                cmuxDebugLog("sshOpen.answer.failed machine=\(machineID) row=\(rowID) answer=\(answer.rawValue)")
                #endif
            }
        }
    }

    private func scheduleHostOpenRecheck(after delay: TimeInterval) {
        hostOpenRecheck?.cancel()
        hostOpenRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.1) * 1_000_000_000))
            guard !Task.isCancelled, let self, let state = self.cloudState else { return }
            self.syncNotifications(from: state)
        }
    }
}
