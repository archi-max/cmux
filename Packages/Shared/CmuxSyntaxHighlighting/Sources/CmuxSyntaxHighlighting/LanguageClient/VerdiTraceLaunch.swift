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

    /// Whether a ready session's times are the FSDB's ticks: Verdi's cursor is in its window
    /// unit, the viewer's times in the file's.
    public static func unitsMatch(_ info: SVModelSidecar.Reply) -> Bool {
        guard let file = info["fileUnit"] as? String, let window = info["windowUnit"] as? String else { return false }
        return !file.isEmpty && file == window
    }
}
