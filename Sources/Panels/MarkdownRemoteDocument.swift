import CmuxCloud
import Foundation

/// Maps a remote Markdown document's links and images to remote paths.
///
/// A remote viewer's shell loads with a file base URL under `shellRoot`, which
/// mirrors the remote path but does not exist on this Mac. WebKit resolves
/// relative links and images against that base; every resolved file URL then
/// maps back to a remote path, so nothing can name a file on the Mac.
enum MarkdownRemoteDocumentPaths {
    static let shellRoot = "/.cmux-remote-markdown"

    private static let imageMimeTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "svg": "image/svg+xml",
    ]

    /// Collapses `.`, `..`, and repeated slashes without consulting any filesystem.
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func shellBaseURL(forRemotePath remotePath: String) -> URL {
        URL(fileURLWithPath: shellRoot + normalized(remotePath), isDirectory: false)
    }

    /// The remote path a file URL from the shell names. Paths outside
    /// `shellRoot` (absolute links, or `..` past the remote root) are remote
    /// absolute paths too.
    static func remotePath(forShellURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "file" else { return nil }
        let path = normalized(url.path)
        if path == shellRoot { return "/" }
        if path.hasPrefix(shellRoot + "/") {
            return normalized(String(path.dropFirst(shellRoot.count)))
        }
        return path
    }

    /// Resolves a link target as written in the document (`other.md#usage`,
    /// `../docs/a.md`, `/abs/b.md`, `file:///x.md`) against the remote file.
    /// Returns `nil` for other URL schemes and for `~` paths.
    static func resolveLink(_ rawPath: String, relativeToRemoteFile remoteFile: String) -> String? {
        var stripped = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = stripped.firstIndex(of: "#") {
            stripped = String(stripped[..<hash])
        }
        if let question = stripped.firstIndex(of: "?") {
            stripped = String(stripped[..<question])
        }
        guard !stripped.isEmpty else { return nil }
        if let url = URL(string: stripped), let scheme = url.scheme {
            guard scheme.lowercased() == "file" else { return nil }
            return remotePath(forShellURL: url)
        }
        let decoded = stripped.removingPercentEncoding ?? stripped
        guard !decoded.isEmpty, !decoded.hasPrefix("~") else { return nil }
        if decoded.hasPrefix("/") { return normalized(decoded) }
        let directory = (normalized(remoteFile) as NSString).deletingLastPathComponent
        return normalized(directory + "/" + decoded)
    }

    /// The remote image path a `cmux-local-image://image?url=<file URL>`
    /// request names, when it has a supported image extension.
    static func remoteImagePath(fromImageRequest requestURL: URL, scheme: String) -> String? {
        guard requestURL.scheme?.lowercased() == scheme,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawFileURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let fileURL = URL(string: rawFileURL),
              let path = remotePath(forShellURL: fileURL),
              imageMimeType(forPath: path) != nil else {
            return nil
        }
        return path
    }

    static func imageMimeType(forPath path: String) -> String? {
        imageMimeTypes[(path as NSString).pathExtension.lowercased()]
    }
}

/// Downloads a remote document's images into its preview cache directory.
struct MarkdownRemoteImageLoader: Sendable {
    static let maximumImageBytes: Int64 = 10 * 1024 * 1024

    let provider: SSHFileExplorerProvider
    let cacheDirectory: URL

    /// Returns the image's bytes, or `nil` when it is missing, not a regular
    /// file, larger than ``maximumImageBytes``, or the download fails.
    func load(remotePath: String) async -> Data? {
        guard !ManagedFileTransferPolicy.isDisabled else { return nil }
        // The stamp check also rejects directories and missing files before downloading.
        guard let stamp = try? await provider.fileStamp(path: remotePath),
              stamp.size <= Self.maximumImageBytes else { return nil }
        let temporary = cacheDirectory
            .appendingPathComponent(".cmux-image-" + UUID().uuidString, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try await provider.downloadFile(path: remotePath, to: temporary)
        } catch {
            return nil
        }
        // The file can grow between the stat and the download.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber,
              size.int64Value <= Self.maximumImageBytes else { return nil }
        return try? Data(contentsOf: temporary)
    }
}

/// Ties a Markdown viewer to the SSH file its local copy was downloaded from.
/// The viewer renders the copy; links, images, editing, and refresh go back
/// through the remote host and never resolve against this Mac's filesystem.
@MainActor
final class MarkdownRemoteDocument {
    let lease: CloudFilePreviewLease
    let imageLoader: MarkdownRemoteImageLoader
    /// Opens a link target on the remote host through the Files preview path.
    var openRemoteFile: (@MainActor (String) -> Void)?
    /// Opens or focuses the editable source preview, which saves back over SSH.
    var editSource: (@MainActor () -> Void)?
    /// Downloads the remote file again and reloads the viewer.
    var refresh: (@MainActor () -> Void)?

    var remotePath: String { lease.remotePath }
    var remoteIdentity: String { lease.remoteIdentity }

    /// Only editable SSH previews qualify; Cloud VM previews stay in the file preview.
    init?(lease: CloudFilePreviewLease) {
        guard let provider = lease.sshProvider else { return nil }
        self.lease = lease
        self.imageLoader = MarkdownRemoteImageLoader(
            provider: provider,
            cacheDirectory: lease.url.deletingLastPathComponent()
        )
    }
}
