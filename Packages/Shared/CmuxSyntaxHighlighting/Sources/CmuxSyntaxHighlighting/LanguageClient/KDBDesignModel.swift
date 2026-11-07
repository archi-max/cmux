import Foundation

/// Driver tracing's design model from a VCS KDB (`<simv>.daidir/kdb.elab++` next to the dump), as
/// Resources/vaporview/verdi-trace/npi-model.py exports it: what VCS elaborated, so its names are
/// the dump's. Each instance has cmux-sv-model's shape without statement trees (`"partial": true`):
/// module, parent, ports (with their connection in the parent when it is one whole net), signals
/// (widths, ranges, arrays) and `writes` (each signal's writing statements, file and line).
public struct KDBDesignModel: @unchecked Sendable {
    public struct Write: Equatable, Sendable {
        public let kind: String
        public let file: String
        public let line: Int
        public init(kind: String, file: String, line: Int) {
            self.kind = kind
            self.file = file
            self.line = line
        }
    }

    public let tops: [String]
    /// Every instance path, sorted.
    public let instancePaths: [String]
    private let instances: [String: [String: Any]]

    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let instances = object["instances"] as? [String: [String: Any]] else { return nil }
        self.tops = (object["tops"] as? [String] ?? []).sorted()
        self.instances = instances
        self.instancePaths = instances.keys.sorted()
    }

    public func instance(_ path: String) -> [String: Any]? { instances[path] }

    /// The deepest instance that is `path` or above it, and the rest of `path` below it (a signal's
    /// name there, dotted in a generate block). Nil when no instance is on the path.
    public func lookup(_ path: String) -> (instance: String, name: String)? {
        if instances[path] != nil { return (path, "") }
        var end = path.endIndex
        while let dot = Self.lastDot(in: path, before: end) {
            let prefix = String(path[..<dot])
            if instances[prefix] != nil { return (prefix, String(path[path.index(after: dot)...])) }
            end = dot
        }
        return nil
    }

    /// Whether `path` is a signal of the design: one of its instance's, or an element of its array.
    public func hasSignal(_ path: String) -> Bool { signal(path) != nil }

    /// Where the signal on `path` is written (none: not written in the design, or not a signal).
    public func writes(of path: String) -> [Write] {
        guard let (instance, name) = signalName(path), let model = instances[instance],
              let writes = (model["writes"] as? [String: Any])?[name] as? [[String: Any]] else { return [] }
        let files = model["files"] as? [String] ?? []
        return writes.compactMap { entry in
            guard let loc = entry["loc"] as? [Int], loc.count >= 2, loc[0] >= 0, loc[0] < files.count else { return nil }
            return Write(kind: entry["kind"] as? String ?? "", file: files[loc[0]], line: loc[1])
        }
    }

    /// The dump's port aliases: for each port bound to one whole net of its parent with the same
    /// width, [port, net] and [net, port] (full paths; the helper keeps what it can use), at most
    /// `limit` pairs.
    public func aliasPairs(limit: Int = .max) -> [[String]] {
        var pairs: [[String]] = []
        for path in instancePaths {
            guard let model = instances[path], let parent = model["parent"] as? String, !parent.isEmpty else { continue }
            for port in model["ports"] as? [[String: Any]] ?? [] {
                guard let name = port["name"] as? String, let conn = port["conn"] as? [String: Any],
                      let leaves = conn["leaves"] as? [String], leaves.count == 1, conn["src"] as? String == leaves[0],
                      let width = port["width"] as? Int, width > 0, conn["width"] as? Int == width else { continue }
                let inner = path + "." + name, outer = parent + "." + leaves[0]
                for pair in [[inner, outer], [outer, inner]] {
                    guard pairs.count < limit else { return pairs }
                    pairs.append(pair)
                }
            }
        }
        return pairs
    }

    private func signal(_ path: String) -> [String: Any]? {
        guard let (instance, name) = signalName(path) else { return nil }
        return (instances[instance]?["signals"] as? [String: Any])?[name] as? [String: Any]
    }

    /// The instance and signal name of `path`; an array element's (`mem[2]`) is its array's.
    private func signalName(_ path: String) -> (String, String)? {
        guard let (instance, name) = lookup(path), !name.isEmpty,
              let signals = instances[instance]?["signals"] as? [String: Any] else { return nil }
        if signals[name] != nil { return (instance, name) }
        if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
            let array = String(name[..<open])
            if (signals[array] as? [String: Any])?["array"] != nil { return (instance, array) }
        }
        return nil
    }

    /// The last `.` before `end` outside brackets (`g[0].u` splits there, `a[1.5]` doesn't).
    private static func lastDot(in path: String, before end: String.Index) -> String.Index? {
        var depth = 0
        var i = end
        while i > path.startIndex {
            i = path.index(before: i)
            switch path[i] {
            case "]": depth += 1
            case "[": depth -= 1
            case "." where depth == 0: return i
            default: break
            }
        }
        return nil
    }
}

/// How cmux exports the KDB model on an SSH host: npi-model.sh and npi-model.py go base64-encoded
/// into a private scratch folder (removed when it ends), and the launcher answers from the user's
/// cache on the host or exports (one Verdi licence seat for a few seconds).
public enum KDBModelLaunch {
    public enum Outcome: Equatable, Sendable {
        case model(KDBDesignModel, cached: Bool)
        /// The launcher's error code (noFile, noKDB, noVerdi, licence, memory, time, start, walk),
        /// `model` for an unreadable model, `start` for no answer.
        case unavailable(code: String, message: String)

        public static func == (a: Outcome, b: Outcome) -> Bool {
            switch (a, b) {
            case (.unavailable(let c1, let m1), .unavailable(let c2, let m2)): return c1 == c2 && m1 == m2
            case (.model(let x, let c1), .model(let y, let c2)): return c1 == c2 && x.instancePaths == y.instancePaths && x.tops == y.tops
            default: return false
            }
        }
    }

    /// The bundled scripts' folder (`<resources>/vaporview/verdi-trace`).
    public static func scripts(in folder: URL) -> (launcher: Data, exporter: Data)? {
        guard let launcher = try? Data(contentsOf: folder.appendingPathComponent("npi-model.sh")),
              let exporter = try? Data(contentsOf: folder.appendingPathComponent("npi-model.py")) else { return nil }
        return (launcher, exporter)
    }

    /// The host command (no single quotes: it runs in `sh -c '…'`).
    public static func command(launcher: Data, exporter: Data, fsdbPath: String) -> String {
        let path = Data(fsdbPath.utf8).base64EncodedString()
        return "W=$(mktemp -d /tmp/cmux-kdb-model.XXXXXX) || exit 1; chmod 700 \"$W\"; trap \"rm -rf \\\"$W\\\"\" EXIT; "
            + "printf %s \(launcher.base64EncodedString()) | base64 -d > \"$W/npi-model.sh\" && "
            + "printf %s \(exporter.base64EncodedString()) | base64 -d > \"$W/npi-model.py\" && "
            + "bash -l \"$W/npi-model.sh\" \"$W\" \"$(printf %s \(path) | base64 -d)\" --print"
    }

    /// The launcher's output: its summary line (short, after a login shell's noise), then the model's line.
    public static func parse(output: Data) -> Outcome {
        let lines = output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let index = lines.firstIndex(where: { $0.first == UInt8(ascii: "{") && $0.count < 65536 && isSummary(Data($0)) }),
              let summary = try? JSONSerialization.jsonObject(with: Data(lines[index])) as? [String: Any] else {
            return .unavailable(code: "start", message: "")
        }
        guard summary["ok"] as? Bool == true else {
            return .unavailable(code: summary["error"] as? String ?? "start", message: summary["message"] as? String ?? "")
        }
        guard index + 1 < lines.count, let model = KDBDesignModel(json: Data(lines[index + 1])) else {
            return .unavailable(code: "model", message: "")
        }
        return .model(model, cached: summary["cached"] as? Bool ?? false)
    }

    private static func isSummary(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return object["ok"] is Bool
    }
}
