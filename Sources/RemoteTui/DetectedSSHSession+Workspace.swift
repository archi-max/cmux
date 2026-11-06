import CmuxCloud
import CmuxCore
import Foundation

extension DetectedSSHSession {
    /// File copy uses the same SSH endpoint; it does not need a PTY-owning daemon.
    /// - Parameter sshOptions: The one-off options to use, such as a lease's
    ///   (``SSHMasterPool/lease(destination:port:identityFile:sshOptions:)``);
    ///   the configuration's ``WorkspaceRemoteConfiguration/fileOperationSSHOptions`` by default.
    init(configuration: WorkspaceRemoteConfiguration, sshOptions: [String]? = nil) {
        var options = sshOptions ?? configuration.fileOperationSSHOptions
        // OpenSSH keeps the first value it reads.
        if let agent = configuration.agentSocketPath { options.insert("IdentityAgent=" + agent, at: 0) }
        self.init(destination: configuration.destination, port: configuration.port,
                  identityFile: configuration.identityFile, configFile: nil, jumpHost: nil,
                  controlPath: nil, useIPv4: false, useIPv6: false, forwardAgent: false,
                  compressionEnabled: false, sshOptions: options)
    }
}

extension WorkspaceRemoteConfiguration {
    /// The SSH options for a one-off `ssh`, `scp` or `sftp` to this workspace:
    /// a file drop, the Files explorer, search, git status or a file preview.
    ///
    /// A `cmux ssh` workspace's runs name this app's one-off master beside the
    /// carrier's (``SSHTuiConnection/fileOperationSSHOptions``); run them
    /// through ``SSHMasterPool``, which lends a session on it, or the
    /// carrier's on a host where it can't log in. The machine's live carrier
    /// can predate this workspace's open and use other control options, so its
    /// recorded connection wins (``SSHTuiCarrierRoutes``).
    var fileOperationSSHOptions: [String] {
        routesThroughSSHTui ? SSHTuiCarrierRoutes.shared.fileOperationSSHOptions(for: self) : sshOptions
    }

    /// The SSH options for a long-lived run to this workspace, such as the
    /// language server, a waveform helper or an FSM run, and the lease it
    /// holds while it runs. On a host whose one-off masters work it gets the
    /// same route on a connection of its own, holding no session on a master
    /// that others share (``SSHTuiConnection/longLivedSSHOptions``), and no
    /// lease. On a host where those masters can't log in in batch mode its own
    /// connection couldn't either, so it gets the carrier's authenticated
    /// master and one of the carrier's sessions within the long-lived share
    /// (``SSHMasterPool/longLivedLease(destination:port:identityFile:sshOptions:)``);
    /// release the lease when the run ends.
    ///
    /// - Throws: ``SSHMasterPool/Unavailable`` when long-lived runs already
    ///   hold their share of the carrier's sessions.
    func longLivedSession(pool: SSHMasterPool = .shared) async throws -> LongLivedSSHSession {
        guard routesThroughSSHTui else { return LongLivedSSHSession(sshOptions: sshOptions, lease: nil) }
        let routes = SSHTuiCarrierRoutes.shared
        if let lease = try await pool.longLivedLease(
            destination: destination, port: port, identityFile: identityFile,
            sshOptions: routes.fileOperationSSHOptions(for: self)
        ) {
            return LongLivedSSHSession(sshOptions: routes.carrierSSHOptions(for: self), lease: lease)
        }
        return LongLivedSSHSession(sshOptions: ownConnectionSSHOptions, lease: nil)
    }

    /// A long-lived run's options on a connection of its own, before
    /// ``longLivedSession(pool:)`` has chosen (which may give it the carrier's).
    var ownConnectionSSHOptions: [String] {
        routesThroughSSHTui ? SSHTuiCarrierRoutes.shared.longLivedSSHOptions(for: self) : sshOptions
    }

    /// A one-off session to this workspace held across several runs, such as
    /// a file drop's (``SSHMasterPool/lease(destination:port:identityFile:sshOptions:)``).
    func fileOperationLease(pool: SSHMasterPool = .shared) async throws -> SSHMasterPool.Lease {
        try await pool.lease(destination: destination, port: port, identityFile: identityFile, sshOptions: fileOperationSSHOptions)
    }
}

/// A long-lived run's SSH options and the carrier session it holds, if any
/// (``WorkspaceRemoteConfiguration/longLivedSession(pool:)``).
struct LongLivedSSHSession: Sendable {
    let sshOptions: [String]
    let lease: SSHMasterPool.Lease?

    func release() { lease?.release() }
}
