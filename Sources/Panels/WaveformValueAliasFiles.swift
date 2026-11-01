import CryptoKit
import Foundation

/// The value alias files a waveform session names (`cmuxValueAliases` in
/// `Resources/vaporview/cmux-commands.js`). A session embeds small files and
/// names the rest by key and SHA-256. On restore the page asks cmux to read
/// those again (`readValueAliases`), by key only: cmux looks the key up in its
/// own `Registry`, filled from files cmux itself read (an alias file the user
/// picked, a session file it loaded), and re-reads the file found there. A
/// page can't name a path or a hash, so it can't make cmux read, or probe,
/// any other file. A file is handed back only if its content still has the
/// recorded hash: a changed file is reported rather than loaded.
///
/// By design, a session file cmux reads (Load Session, `<dump>.json`) may name
/// any path on this Mac or the open file's SSH host, and cmux reads it on
/// restore (a regular file, at most 8 MiB). Its text reaches the page only if
/// the session's hash matches, so the session's author must already know the
/// content; the read error (missing, no permission, too large, changed) does
/// reach the page.
enum WaveformValueAliasFiles {
    /// At most this many keys per request, as the page keeps at most 16.
    static let maxFiles = 16

    /// Where a recorded file is read from.
    enum Location: Equatable, Sendable {
        case local(String)
        case remote(String)
        /// A session file's entry for an SSH host other than the open file's.
        case otherHost(String)

        var path: String {
            switch self {
            case .local(let path), .remote(let path), .otherHost(let path): return path
            }
        }
    }

    /// A file cmux read: where it is and the hash of the text read.
    struct Record: Equatable, Sendable {
        let location: Location
        let sha256: String
    }

    /// The alias files one waveform viewer's native side knows, by key. Only
    /// native code adds to it; the page's messages only look keys up.
    @MainActor
    final class Registry {
        /// The most keys kept; the oldest go first.
        static let capacity = 64
        private var records: [String: Record] = [:]
        private var order: [String] = []

        init() {}

        func record(for key: String) -> Record? { records[key] }

        var count: Int { records.count }

        /// cmux read `text` for `key` from `location` (Load Value Alias File...).
        func noteLoaded(key: String, location: Location, text: String) {
            set(key, Record(location: location, sha256: WaveformValueAliasFiles.sha256(text)))
        }

        /// cmux read the session file `text`: records its `cmuxValueAliases`
        /// entries that carry a hash. The location comes from the key alone (a
        /// path on this Mac, or `remoteKey` for an SSH host); the entry's own
        /// `path` field isn't used.
        func noteSession(text: String, remoteIdentity: String?) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let list = object["cmuxValueAliases"] as? [Any] else { return }
            for item in list.suffix(WaveformValueAliasFiles.maxFiles) {
                guard let entry = item as? [String: Any],
                      let key = entry["key"] as? String,
                      let sha = entry["sha256"] as? String, WaveformValueAliasFiles.isSHA256(sha),
                      let location = WaveformValueAliasFiles.location(ofKey: key, remoteIdentity: remoteIdentity) else { continue }
                set(key, Record(location: location, sha256: sha))
            }
        }

        func removeAll() {
            records = [:]
            order = []
        }

        private func set(_ key: String, _ record: Record) {
            if records.updateValue(record, forKey: key) != nil {
                order.removeAll { $0 == key }
            }
            order.append(key)
            while order.count > Self.capacity {
                records[order.removeFirst()] = nil
            }
        }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The prefix of a remote file's key.
    static let remoteKeyPrefix = "ssh://"

    /// The host part of a remote key for the Files identity `identity`. For an
    /// SSH identity (`ssh:<dest>|<port>|<identity file>|<options>`) that is the
    /// destination and port only: the identity file and ssh options are never
    /// written into a session. Any other identity is named by a hash of it.
    static func remoteHost(identity: String) -> String {
        if identity.hasPrefix("ssh:") {
            let fields = identity.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false)
            let destination = fields.first.map(String.init) ?? ""
            let port = fields.count > 1 ? String(fields[1]) : ""
            if !destination.isEmpty, !destination.contains("/") {
                return port.isEmpty ? destination : destination + ":" + port
            }
        }
        return "id-" + sha256(identity).prefix(16)
    }

    /// The key of a file on the SSH host whose Files identity is `identity`:
    /// `ssh://<dest>[:port]<path>`.
    static func remoteKey(identity: String, path: String) -> String {
        remoteKeyPrefix + remoteHost(identity: identity) + path
    }

    /// Where a session file's key points: a path on this Mac, a path on the
    /// open file's SSH host (`remoteIdentity`), or another host's file. Nil
    /// when it is neither.
    static func location(ofKey key: String, remoteIdentity: String?) -> Location? {
        if key.hasPrefix("/") { return .local(key) }
        guard key.hasPrefix(remoteKeyPrefix) else { return nil }
        let rest = key.dropFirst(remoteKeyPrefix.count)
        // The host part has no "/": the path starts at the first one.
        guard let slash = rest.firstIndex(of: "/"), slash > rest.startIndex else { return nil }
        let host = String(rest[..<slash])
        let path = String(rest[slash...])
        if let remoteIdentity, host == remoteHost(identity: remoteIdentity) { return .remote(path) }
        return .otherHost(path)
    }

    /// The text of the regular file at `url` (a symlink is followed), refused
    /// when it is bigger than `maxBytes`: the size is checked on the file the
    /// link points to, and the read itself stops after `maxBytes + 1` bytes, so
    /// a file that grows (or a link swapped) after the check is still bounded.
    /// Not a FIFO or device: those are refused before anything is opened.
    nonisolated static func readText(at url: URL, maxBytes: Int) throws -> String {
        let target = url.resolvingSymlinksInPath()
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        guard (values.fileSize ?? 0) <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: target)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    /// The keys in the page's `readValueAliases` request (strings only, at most
    /// `maxFiles`, no repeats). Anything else in the request is ignored.
    static func keys(from value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var seen = Set<String>()
        let keys = list.compactMap { $0 as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return Array(keys.prefix(maxFiles))
    }

    /// The page's answer: for each key the registry knows, its key and path,
    /// plus `text` when the file was read and still has the recorded hash, or
    /// `error`. A key the registry doesn't know gets no answer at all.
    @MainActor
    static func answer(
        _ keys: [String],
        registry: Registry,
        read: (Location) async throws -> String
    ) async -> [[String: String]] {
        var answers: [[String: String]] = []
        for key in keys {
            guard let record = registry.record(for: key) else { continue }
            var answer = ["key": key, "path": record.location.path]
            if case .otherHost = record.location {
                answer["error"] = String(
                    localized: "filePreview.waveform.valueAlias.otherHost",
                    defaultValue: "The file is on another host."
                )
                answers.append(answer)
                continue
            }
            do {
                let text = try await read(record.location)
                if sha256(text) == record.sha256 {
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
