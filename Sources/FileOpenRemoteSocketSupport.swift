import CmuxRemoteWorkspace
import Foundation

extension TerminalController {
    /// `file.open_remote`: previews a file on an SSH workspace's host, the
    /// way ⌘-click on a path in that SSH terminal does. `cmux open` in an
    /// SSH session sends it through the relay.
    ///
    /// The path is a host path, resolved by the remote CLI. It is only ever
    /// fetched through the workspace's own SSH connection
    /// (`RemoteTerminalFilePreviewCoordinator`), never read on this Mac, and
    /// the terminal must be an SSH terminal of that workspace. The relay
    /// gates have already limited relay callers to their own workspace and
    /// terminal; the reply carries nothing beyond the request.
    func v2FileOpenRemote(params: [String: Any]) -> V2CallResult {
        guard let path = params["path"] as? String,
              RemoteRelayCommandPolicy.isAcceptableRemoteFileOpenPath(path) else {
            return .err(code: "invalid_params", message: String(
                localized: "socket.fileOpenRemote.invalidPath",
                defaultValue: "The path must be an absolute path on the SSH host"
            ), data: nil)
        }
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let surfaceID = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: String(
                localized: "socket.fileOpenRemote.missingTerminal",
                defaultValue: "Name the workspace and the terminal to open the file from"
            ), data: nil)
        }
        let tabManager = v2ResolveTabManager(params: params)
        return v2MainSync { () -> V2CallResult in
            guard let workspace = tabManager?.tabs.first(where: { $0.id == workspaceID }),
                  workspace.surfaceOwnershipTarget(for: surfaceID) != nil else {
                return .err(code: "not_found", message: String(
                    localized: "socket.fileOpenRemote.terminalNotFound",
                    defaultValue: "Terminal not found in this workspace"
                ), data: nil)
            }
            // Only SSH terminals: anything else would resolve the path on this Mac.
            guard workspace.remoteTerminalFilePreviewConfiguration(for: surfaceID) != nil,
                  workspace.deferRemoteTerminalFileLinkOpen(sourcePanelId: surfaceID, rawValue: path) else {
                return .err(code: "unsupported", message: String(
                    localized: "socket.fileOpenRemote.notSSH",
                    defaultValue: "This terminal is not connected over SSH"
                ), data: nil)
            }
            return .ok(["queued": true, "path": path])
        }
    }
}
