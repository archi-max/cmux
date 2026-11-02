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
    /// language server or a waveform helper: the same route on a connection of
    /// its own, so it holds no session on a master that others share
    /// (``SSHTuiConnection/longLivedSSHOptions``). On a host where this app's
    /// one-off master can't log in in batch mode, its own connection couldn't
    /// either, so it uses the carrier's authenticated master, as before.
    var longLivedSSHOptions: [String] {
        guard routesThroughSSHTui else { return sshOptions }
        let routes = SSHTuiCarrierRoutes.shared
        if let route = SSHMasterPool.Route(
            destination: destination, port: port, identityFile: identityFile,
            sshOptions: routes.fileOperationSSHOptions(for: self)
        ), SSHMasterPool.shared.carrierPathIfMastersFail(route) != nil {
            return routes.carrierSSHOptions(for: self)
        }
        return routes.longLivedSSHOptions(for: self)
    }

    /// A lease on a one-off session to this workspace for a run that can't
    /// wait, such as a file drop (``SSHMasterPool/lease(destination:port:identityFile:sshOptions:)``).
    func fileOperationLease(pool: SSHMasterPool = .shared) -> SSHMasterPool.Lease {
        pool.lease(destination: destination, port: port, identityFile: identityFile, sshOptions: fileOperationSSHOptions)
    }
}
