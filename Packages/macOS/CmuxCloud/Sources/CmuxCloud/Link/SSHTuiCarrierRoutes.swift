import CmuxCore
import Foundation

/// The SSH options of each machine's live carrier, so the one-off `ssh` runs
/// of a workspace on that machine (Files, previews, git status, search, the
/// language server) ride the carrier's master.
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

    /// Records the connection a machine's carrier dials with.
    public func record(_ connection: SSHTuiConnection) {
        lock.lock()
        defer { lock.unlock() }
        carriers[connection.id] = connection
    }

    /// The options for a one-off `ssh`, `scp` or `sftp` to `configuration`'s
    /// machine: the carrier's, when one was recorded for it, else the
    /// configuration's own.
    ///
    /// The carrier's master is the one this workspace's terminals already run
    /// on, so reusing it grants these runs nothing the workspace lacks. The
    /// options still never make a run a master (see
    /// ``SSHTuiConnection/fileOperationSSHOptions``), and a carrier that shares
    /// nothing (`ControlPath=none`) keeps them unshared too.
    public func fileOperationSSHOptions(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        let own = SSHTuiConnection(configuration: configuration)
        lock.lock()
        let carrier = carriers[own.id]
        lock.unlock()
        return (carrier ?? own).fileOperationSSHOptions
    }
}
