import CmuxCloud
import CmuxCore
import Foundation

extension DetectedSSHSession {
    /// File copy uses the same SSH endpoint; it does not need a PTY-owning daemon.
    init(configuration: WorkspaceRemoteConfiguration) {
        var options = configuration.fileOperationSSHOptions
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
    /// a file drop, the Files explorer or a file preview.
    ///
    /// A `cmux ssh` workspace's carrier holds the authenticated master, so these
    /// reuse its route and ControlPath; a password-only host accepts their
    /// batch-mode runs only through it.
    ///
    /// These use the workspace's own options, not the machine's live carrier
    /// (``SSHTuiCarrierRoutes``): every app's carrier for a host shares one
    /// master, and sshd caps one connection's sessions (10 by default), so
    /// one-off runs and long-lived helpers riding it can refuse the carriers'
    /// own sessions.
    var fileOperationSSHOptions: [String] {
        routesThroughSSHTui ? SSHTuiConnection(configuration: self).fileOperationSSHOptions : sshOptions
    }
}
