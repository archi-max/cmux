import CryptoKit
import Foundation

/// The value alias files a waveform session names (`cmuxValueAliases` in
/// `Resources/vaporview/cmux-commands.js`). A session embeds small files and
/// names the rest by key, path and SHA-256. On restore the page asks cmux to
/// read those again (`readValueAliases`). A file is handed back only if its
/// content still has the saved hash: a changed file is reported rather than
/// loaded, and a session file can't make cmux hand the page some other file's
/// text.
enum WaveformValueAliasFiles {
    /// At most this many files per request, as the page keeps at most 16.
    static let maxFiles = 16

    /// One file the page asks for.
    struct Request: Equatable, Sendable {
        /// `path` for a file on this Mac, `remoteKey(identity:path:)` for one on an SSH host.
        let key: String
        let path: String
        let sha256: String
    }

    /// Where a request's file is read from.
    enum Location: Equatable, Sendable {
        case local(String)
        case remote(String)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The key of a file on the SSH host whose Files identity is `identity`.
    static func remoteKey(identity: String, path: String) -> String {
        identity + ":" + path
    }

    /// The well-formed requests in the page's `files` list.
    static func requests(from value: Any?) -> [Request] {
        guard let list = value as? [Any] else { return [] }
        let requests: [Request] = list.compactMap { item in
            guard let entry = item as? [String: Any],
                  let key = entry["key"] as? String, let path = entry["path"] as? String,
                  let sha = entry["sha256"] as? String,
                  path.hasPrefix("/"), sha.count == 64, sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return Request(key: key, path: path, sha256: sha)
        }
        return Array(requests.prefix(maxFiles))
    }

    /// Where `request` is read from: this Mac when its key is its path, the
    /// open file's SSH host when its key names that host, otherwise nowhere.
    static func location(of request: Request, remoteIdentity: String?) -> Location? {
        if request.key == request.path { return .local(request.path) }
        if let remoteIdentity, request.key == remoteKey(identity: remoteIdentity, path: request.path) {
            return .remote(request.path)
        }
        return nil
    }

    /// The page's answer: per request its key and path, plus `text` when the
    /// file was read and still has its hash, or `error`.
    @MainActor
    static func answer(
        _ requests: [Request],
        remoteIdentity: String?,
        read: (Location) async throws -> String
    ) async -> [[String: String]] {
        var answers: [[String: String]] = []
        for request in requests {
            var answer = ["key": request.key, "path": request.path]
            guard let location = location(of: request, remoteIdentity: remoteIdentity) else {
                answer["error"] = String(
                    localized: "filePreview.waveform.valueAlias.otherHost",
                    defaultValue: "The file is on another host."
                )
                answers.append(answer)
                continue
            }
            do {
                let text = try await read(location)
                if sha256(text) == request.sha256 {
                    answer["text"] = text
                } else {
                    answer["error"] = String(
                        localized: "filePreview.waveform.valueAlias.changed",
                        defaultValue: "The file changed after the session was saved. Load it again with Load Value Alias File..."
                    )
                }
            } catch {
                answer["error"] = error.localizedDescription
            }
            answers.append(answer)
        }
        return answers
    }
}
