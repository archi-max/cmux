import Foundation

/// Placeholder API for the Go to File listing; the implementation follows in the next commit.
enum GoToFileSnapshotSource: Equatable, Sendable {
    case local(rootPath: String)
    case ssh(connection: SSHFileExplorerConnection, rootPath: String)

    var rootPath: String {
        switch self {
        case .local(let rootPath), .ssh(_, let rootPath): return rootPath
        }
    }
}

enum GoToFileSnapshotError: Error, Equatable {
    case timedOut
    case folderNotFound
    case failed(String)
}

enum GoToFileSnapshotLoader {
    static let timeoutSeconds = 20
    static let maxOutputBytes = 16 * 1024 * 1024

    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    static func invocation(
        for source: GoToFileSnapshotSource,
        sshArguments: (SSHFileExplorerConnection, String) -> [String] = ProcessSSHFileExplorerTransport.sshArguments
    ) -> Invocation {
        Invocation(executable: "/usr/bin/true", arguments: [])
    }

    static func load(_ source: GoToFileSnapshotSource) async throws -> GoToFileSnapshot {
        throw GoToFileSnapshotError.failed("")
    }

    static func load(
        _ invocation: Invocation,
        timeoutSeconds: Int = GoToFileSnapshotLoader.timeoutSeconds,
        maxOutputBytes: Int = GoToFileSnapshotLoader.maxOutputBytes
    ) async throws -> GoToFileSnapshot {
        throw GoToFileSnapshotError.failed("")
    }
}
