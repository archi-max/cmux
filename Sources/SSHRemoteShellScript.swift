import Foundation

/// Stub for the failing tests; the implementation follows in the next commit.
enum SSHRemoteShellScript {
    static let decodeFailedStatus: Int32 = 65

    static func command(lines: [String], watchdog: Bool = false) -> String {
        "sh -c '" + lines.joined(separator: "; ") + "'"
    }
}
