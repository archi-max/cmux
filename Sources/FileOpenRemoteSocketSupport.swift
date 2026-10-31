import CmuxRemoteWorkspace
import Foundation

extension TerminalController {
    /// `file.open_remote`: previews a file on an SSH workspace's host,
    /// like ⌘-click on a path in that SSH terminal but without its web routes. `cmux open` in an
    /// SSH session sends it through the relay.
    ///
    /// The path is a canonical host path, resolved by the remote CLI. It is
    /// only ever fetched through the workspace's own SSH connection
    /// (`RemoteTerminalFilePreviewCoordinator.openFromCommandLine`), never
    /// read on this Mac; the download is size-capped, and the result opens
    /// only in the native file preview, never in the browser or markdown
    /// viewer. The terminal must be an SSH terminal of that workspace. The relay
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
            // Only SSH terminals (anything else would resolve the path on this
            // Mac), and only while file previews are on.
            guard workspace.openRemoteFileFromCommandLine(sourcePanelId: surfaceID, path: path) else {
                return .err(code: "unsupported", message: String(
                    localized: "socket.fileOpenRemote.notSSH",
                    defaultValue: "This terminal is not connected over SSH, or file previews are off"
                ), data: nil)
            }
            return .ok(["queued": true, "path": path])
        }
    }
}
