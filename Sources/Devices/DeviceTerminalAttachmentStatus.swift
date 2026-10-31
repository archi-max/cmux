import Foundation
import Observation

/// Pane-owned, in-memory connection notice. Dismissal lasts until this attachment recovers.
@MainActor
@Observable
final class DeviceTerminalAttachmentStatus {
    /// What the pane is waiting for. Device panes wait for another Mac. An SSH
    /// pane saved without a host terminal has nothing to reattach to; one whose
    /// saved host terminal could not be reserved waits for the SSH provider.
    enum Origin: Equatable {
        case device
        case unattachedSSHTerminal
        case pendingSSHTerminal
    }

    let origin: Origin
    /// Set once Retry has asked for this pane's replacement, so a second click
    /// while the pane is closing cannot ask again.
    private(set) var isReplaced = false
    private(set) var isConnected = false
    private(set) var isConnecting = true
    private(set) var isDismissed = false
    private var hasDisconnected = false
    @ObservationIgnored var onRetry: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    init(origin: Origin = .device) {
        self.origin = origin
    }

    func update(connected: Bool, connecting: Bool) {
        guard isConnected != connected || isConnecting != connecting else { return }
        isConnected = connected
        isConnecting = connecting
        if connected {
            isDismissed = false
            hasDisconnected = false
        } else if !connecting {
            hasDisconnected = true
        }
        onChange?()
    }

    func markReplaced() {
        isReplaced = true
        onChange?()
    }

    func dismiss() {
        isDismissed = true
        onChange?()
    }

    func retry() {
        isDismissed = false
        isConnecting = true
        onRetry?()
        onChange?()
    }

    var presentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        guard !isConnected, !isDismissed, !isReplaced, hasDisconnected else { return nil }
        switch origin {
        case .device:
            break
        case .unattachedSSHTerminal:
            return .init(
                title: String(localized: "ssh.terminal.unattached.title", defaultValue: "Not running on the SSH host"),
                detail: String(localized: "ssh.terminal.unattached.detail", defaultValue: "This tab has no session on the SSH host to reattach. Retry opens a new terminal on the host in its place."),
                showsProgress: isConnecting,
                showsReconnectButton: true
            )
        case .pendingSSHTerminal:
            return .init(
                title: String(localized: "ssh.terminal.unattached.title", defaultValue: "Not running on the SSH host"),
                detail: String(localized: "ssh.tui.sessionNotFound", defaultValue: "This SSH terminal is no longer available."),
                showsProgress: isConnecting,
                showsReconnectButton: true
            )
        }
        return .init(
            title: String(localized: "devices.terminal.disconnected.title", defaultValue: "Mac disconnected"),
            detail: String(localized: "devices.terminal.disconnected.detail", defaultValue: "Your layout and scrollback are preserved. Retry when the other Mac is available."),
            showsProgress: isConnecting,
            showsReconnectButton: true
        )
    }
}
