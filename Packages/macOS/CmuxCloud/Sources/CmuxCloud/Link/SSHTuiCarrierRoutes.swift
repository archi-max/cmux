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

    /// The options for a one-off `ssh`, `scp` or `sftp` to `configuration`'s machine.
    public func fileOperationSSHOptions(for configuration: WorkspaceRemoteConfiguration) -> [String] {
        SSHTuiConnection(configuration: configuration).fileOperationSSHOptions
    }
}
