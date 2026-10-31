import Foundation

/// Edits slang-server's per-workspace config (`.slang/local/server.json`),
/// used to choose a `.f` build file when the server has no `slang.setBuildFile`
/// command. Every other key of the file is kept.
public enum SlangServerConfigFile {
    /// Where cmux writes the build file: the workspace's local overrides,
    /// which slang-server reads after `.slang/server.json` and `~/.slang/server.json`.
    public static let relativePath = ".slang/local/server.json"

    public enum EditError: Error, Equatable {
        /// The file is not a JSON object; it is left alone rather than overwritten.
        case notAJSONObject
    }

    /// The path of the config file under `rootPath`.
    public static func path(inWorkspace rootPath: String, relativePath: String = relativePath) -> String {
        (rootPath as NSString).appendingPathComponent(relativePath)
    }

    /// `existing` (nil or empty: no file yet) with `"build"` set to `buildPath`,
    /// or removed when `buildPath` is nil.
    public static func settingBuild(_ buildPath: String?, in existing: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing, options: [.fragmentsAllowed]),
                  let dictionary = parsed as? [String: Any] else {
                throw EditError.notAJSONObject
            }
            object = dictionary
        }
        if let buildPath {
            object["build"] = buildPath
        } else {
            object.removeValue(forKey: "build")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// The `"build"` value of a config file, if it names one.
    public static func build(in data: Data?) -> String? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["build"] as? String
    }
}
