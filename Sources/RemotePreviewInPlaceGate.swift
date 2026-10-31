import Foundation

/// The decisions behind `cmux open` of a dump read in place on the host
/// (`RemoteTerminalFilePreviewCoordinator.openInPlaceOnHost`), kept free of
/// app types so they can be tested on their own.
enum RemotePreviewInPlaceGate {
    enum Route: Equatable {
        /// Open beside the terminal.
        case open
        /// The terminal has no workspace pane (it is in a Dock): say so on it.
        case noticeNoPane
        /// No connected SSH Files root, or the terminal isn't remote.
        case unavailable
    }

    static func route(sshRootAvailable: Bool, terminalIsRemote: Bool, hasWorkspacePane: Bool) -> Route {
        guard sshRootAvailable, terminalIsRemote else { return .unavailable }
        return hasWorkspacePane ? .open : .noticeNoPane
    }

    /// Whether the open itself may still complete: its workspace is selected
    /// and the terminal is on the SSH configuration it was opened with.
    static func openIsCurrent<Configuration: Equatable>(
        isSelected: Bool,
        isRetired: Bool,
        terminalConfiguration: Configuration?,
        openedWith configuration: Configuration
    ) -> Bool {
        isSelected && !isRetired && terminalConfiguration == configuration
    }

    /// Whether the opened viewer may still refresh from the host. It outlives
    /// its terminal, so only the workspace's own configuration counts.
    static func panelIsCurrent<Configuration: Equatable>(
        isSelected: Bool,
        isRetired: Bool,
        workspaceConfiguration: Configuration?,
        openedWith configuration: Configuration
    ) -> Bool {
        isSelected && !isRetired && workspaceConfiguration == configuration
    }
}
