import Foundation

extension FileExplorerStore {
    /// Shared by the right sidebar and tool panes; owns Cloud observation and retry.
    func syncWorkspaceRoot(from workspace: Workspace) {
        if workspaceRootObservation?.workspace !== workspace {
            workspaceRootObservation?.stop()
            workspaceRootObservation = FileExplorerWorkspaceObservation(
                workspace: workspace, resolver: FileExplorerWorkspaceRootResolver(),
                apply: { [weak self, weak workspace] root in
                    guard let self else { return }
                    if case .none = root {
                        self.setPinnedWorkspaceRootPath(nil)
                    } else {
                        self.setPinnedWorkspaceRootPath(workspace?.fileExplorerPinnedRootPath)
                    }
                    self.applyWorkspaceRoot(root)
                }
            )
        }
        workspaceRootObservation?.refresh()
    }

    /// Pins (or with `nil`, unpins) the observed workspace's Files root.
    func setWorkspaceRootPin(_ path: String?) {
        workspaceRootObservation?.workspace?.setFileExplorerPinnedRootPath(path)
    }

    var canPinWorkspaceRoot: Bool {
        workspaceRootObservation?.workspace != nil
    }

    func retryRemoteRoot() {
        if let observation = workspaceRootObservation {
            observation.refresh(force: true)
        }
        if !rootPath.isEmpty { reload() }
        if let target = (provider as? CloudVMFileExplorerProvider)?.target, !target.isCurrent() {
            setRootStatusMessage(String(localized: "fileExplorer.status.cloudDisconnected",
                defaultValue: "Cloud machine is not connected"))
        }
    }
}
