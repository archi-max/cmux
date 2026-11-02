import Foundation

/// How cmux starts driver tracing's Verdi engine on an SSH host (Resources/vaporview/verdi-trace:
/// verdi-trace.sh runs the host's `verdi -nogui -play serve.tcl`; both scripts are cmux's own).
/// The session speaks JSON lines, so `SVModelSidecar` is its client.
public enum VerdiTraceLaunch {
    /// The bundled scripts' folder (`<resources>/vaporview/verdi-trace`).
    public static func scripts(in folder: URL) -> (launcher: Data, serve: Data)? {
        guard let launcher = try? Data(contentsOf: folder.appendingPathComponent("verdi-trace.sh")),
              let serve = try? Data(contentsOf: folder.appendingPathComponent("serve.tcl")) else { return nil }
        return (launcher, serve)
    }

    /// The host command (no single quotes: it runs in `sh -c '…'`). Both scripts and the FSDB
    /// path go base64-encoded into a private scratch folder, which the launcher removes when the
    /// session ends.
    public static func command(launcher: Data, serve: Data, fsdbPath: String) -> String {
        let path = Data(fsdbPath.utf8).base64EncodedString()
        return "W=$(mktemp -d /tmp/cmux-verdi-trace.XXXXXX) || exit 1; chmod 700 \"$W\"; "
            + "printf %s \(launcher.base64EncodedString()) | base64 -d > \"$W/verdi-trace.sh\" && "
            + "printf %s \(serve.base64EncodedString()) | base64 -d > \"$W/serve.tcl\" && "
            + "exec bash -l \"$W/verdi-trace.sh\" \"$W\" \"$(printf %s \(path) | base64 -d)\""
    }

    /// The sessions cmux keeps, least recently used first (each holds a licence seat).
    public struct SessionKeys: Sendable, Equatable {
        public private(set) var all: [String] = []
        public init() {}
        /// `key` was just used (or started): it goes last.
        public mutating func use(_ key: String) {
            all.removeAll { $0 == key }
            all.append(key)
        }
        public mutating func remove(_ key: String) { all.removeAll { $0 == key } }
        /// Drops the least recently used keys until `keeping` remain; returns them.
        public mutating func evict(keeping: Int) -> [String] {
            let n = max(0, all.count - max(0, keeping))
            let gone = Array(all.prefix(n))
            all.removeFirst(n)
            return gone
        }
    }

    /// How long a session waits after `failures` failed requests in a row before it asks Verdi
    /// again: 15 s, doubling, at most 5 minutes (0: no failure).
    public static func retryDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(300, 15 * pow(2, Double(min(failures, 16) - 1)))
    }

    /// The launcher's line on stderr while Verdi waits for a licence seat.
    public static let licenceQueueMarker = "cmux-verdi: waiting for a Verdi licence"

    /// What a start that did not finish (cmux gave up waiting) says: the licence queue when the
    /// launcher reported it, else the last lines of stderr without the login shell's noise.
    public static func startFailure(detail: String) -> (code: String, message: String) {
        if detail.contains(licenceQueueMarker) { return ("licenceQueue", "") }
        let lines = detail.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(".bashrc") && !$0.contains(".bash_profile") && !$0.contains(".profile:") }
        return ("start", lines.suffix(3).joined(separator: " "))
    }

    /// Whether a ready session's times are the FSDB's ticks: Verdi's cursor is in its window
    /// unit, the viewer's times in the file's.
    public static func unitsMatch(_ info: SVModelSidecar.Reply) -> Bool {
        guard let file = info["fileUnit"] as? String, let window = info["windowUnit"] as? String else { return false }
        return !file.isEmpty && file == window
    }
}
