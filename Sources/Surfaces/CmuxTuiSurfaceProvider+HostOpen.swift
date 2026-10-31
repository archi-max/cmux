import CmuxCloud
import CmuxRemoteWorkspace
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// `cmux open` from a cmux-tui SSH terminal (``SSHTuiHostOpenCommand``).
    ///
    /// Returns nil for an ordinary notification. A marked row is never shown;
    /// it is consumed (`.suppressed`, acknowledged) once handled or refused,
    /// and opens only when every check holds:
    /// - this provider is an SSH machine (Cloud rows are left alone);
    /// - the row is fresh, names a terminal, and its path passes the same
    ///   canonical absolute-path check `file.open_remote` applies;
    /// - the placement is the pane that shows exactly that terminal of this
    ///   machine, in a workspace whose SSH connection is this machine.
    /// The open itself is `cmux open`'s existing path: the file is read only
    /// through that workspace's SSH connection and shown in the native preview,
    /// only while that terminal is focused.
    func handleHostOpenRequest(
        _ row: CloudVMNotificationRow, target: CloudNotificationDeliveryTarget
    ) -> CloudNotificationDeliveryOutcome? {
        guard machine.isSSH else { return nil }
        let request = SSHTuiHostOpenRequest(
            row: row, now: Date(), pathIsAcceptable: RemoteRelayCommandPolicy.isAcceptableRemoteFileOpenPath
        )
        let path: String
        let terminalID: String
        switch request {
        case .notARequest:
            return nil
        case .refused(let reason):
            #if DEBUG
            cmuxDebugLog("sshOpen.refused machine=\(machineID) row=\(row.id) reason=\(reason)")
            #else
            _ = reason
            #endif
            return .suppressed
        case .open(let requestedPath, let requestedTerminal):
            path = requestedPath
            terminalID = requestedTerminal
        }
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        guard let panelID = target.panelID,
              catalog.projections(of: resource).contains(where: {
                  $0.panelID == panelID && $0.workspaceID == target.workspaceID
              }),
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: target.workspaceID)?
                .tabs.first(where: { $0.id == target.workspaceID }),
              workspace.usesSSHTui,
              let configuration = workspace.remoteConfiguration,
              SSHTuiConnection(configuration: configuration).id == machine.rawValue else {
            #if DEBUG
            cmuxDebugLog("sshOpen.unplaced machine=\(machineID) row=\(row.id)")
            #endif
            // Not shown in a pane here: leave it unacknowledged, so the host
            // CLI reports that no window took it. A later fold retries it and
            // consumes it once it is stale.
            return .declined
        }
        let outcome = workspace.openRemoteFileFromCommandLine(sourcePanelId: panelID, path: path)
        #if DEBUG
        cmuxDebugLog("sshOpen.open machine=\(machineID) row=\(row.id) surface=\(panelID.uuidString) outcome=\(outcome)")
        #endif
        switch outcome {
        case .started:
            break
        case .unsupportedType:
            workspace.terminalPanel(for: panelID)?.hostedView.showTerminalNotice(RemotePreviewNotice.typeOpensFromFilesPanel)
        case .unavailable:
            workspace.terminalPanel(for: panelID)?.hostedView.showTerminalNotice(RemotePreviewNotice.couldNotOpen)
        }
        return .suppressed
    }
}
