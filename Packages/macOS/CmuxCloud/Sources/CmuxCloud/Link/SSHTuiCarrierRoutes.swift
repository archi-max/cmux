import CmuxCore
import Foundation

/// The SSH options of each machine's live carrier, so the `ssh` runs of a
/// workspace on that machine (Files, previews, git status, search, the
/// language server) take the carrier's route: one-off runs on this app's
/// master beside the carrier's, long-lived ones on connections of their own.
///
/// A machine's identity ignores control options and the agent socket, so a
/// later `cmux ssh` open with other control options (for example the
/// `ControlPath` the user's own SSH config sets) reaches the carrier an earlier
/// open or restore started. That workspace's own configuration can then name a
/// different socket, or `ControlPath=none`, than the master the carrier holds.
public final class SSHTuiCarrierRoutes: @unchecked Sendable {
    /// The app's registry.
    public static let shared = SSHTuiCarrierRoutes()

    private let lock = NSLock()
    private var carriers: [String: SSHTuiConnection] = [:]

    public init() {}

    /// Records the connection a machine's carrier dials with. Entries stay for
    /// the app's life, as their managers do; unregistering one would need a `remove(id:)`.
    public func record(_ connection: SSHTuiConnection) {
        lock.lock()
        defer { lock.unlock() }
        carriers[connection.id] = connection
    }

    /// The options for a one-off `ssh`, `scp` or `sftp` to `configuration`'s
    /// machine: the carrier's, when one was recorded for it, else the
    /// configuration's own.
    ///
    /// They share the one-off master beside the carrier's, never the carrier's
    /// own (see ``SSHTuiConnection/fileOperationSSHOptions``), and a carrier
    /// that shares nothing (`ControlPath=none`) keeps them unshared too.
    public func fileOperationSSHOptions(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        connection(for: configuration).fileOperationSSHOptions
    }

    /// The options for a long-lived run to `configuration`'s machine
    /// (``SSHTuiConnection/longLivedSSHOptions``), on the same route.
    public func longLivedSSHOptions(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        connection(for: configuration).longLivedSSHOptions
    }

    /// The carrier's own options (``SSHTuiConnection/carrierSSHOptions``), for
    /// a run on a host where this app's one-off master can't log in.
    public func carrierSSHOptions(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        connection(for: configuration).carrierSSHOptions
    }

    private func connection(for configuration: WorkspaceRemoteConfiguration) -> SSHTuiConnection {
        let own = SSHTuiConnection(configuration: configuration)
        lock.lock()
        let carrier = carriers[own.id]
        lock.unlock()
        return carrier ?? own
    }
}
