import Foundation
import WebKit

/// Serves the bundled waveform viewer page (`Resources/vaporview`) and the one
/// waveform file its panel opened, over `cmux-waveform://viewer/`.
///
/// The viewer's wellen worker reads the file through synchronous range
/// requests, so the file is served with HEAD and `Range` support straight from
/// a file handle and is never loaded whole. A remote FSDB file is not served
/// as bytes: the page POSTs its requests to `fsdb/<token>` and the relay
/// answers them through the FSDB helper on the SSH host. Nothing outside the
/// bundle folder is reachable, and the file or relay only under a random
/// per-open token.
@MainActor
final class WaveformViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cmux-waveform"
    nonisolated static let host = "viewer"
    nonisolated static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!

    /// A GET without a `Range` header is answered whole only up to this size.
    nonisolated static let maxUnrangedResponseBytes: UInt64 = 16 * 1024 * 1024
    /// Upper bound for one range response; the worker asks for at most 60 KB.
    nonisolated static let maxRangeResponseBytes: UInt64 = 16 * 1024 * 1024

    private let assetRoot: URL?
    private let ioQueue = DispatchQueue(label: "com.cmuxterm.waveform-viewer.io", qos: .userInitiated)
    private var activeTasks: Set<ObjectIdentifier> = []
    private var source: WaveformFileSource?
    private var fsdbRelay: WaveformFSDBRelay?

    init(assetRoot: URL? = WaveformViewerSchemeHandler.bundledAssetRoot()) {
        self.assetRoot = assetRoot?.standardizedFileURL.resolvingSymlinksInPath()
        super.init()
    }

    nonisolated static func bundledAssetRoot(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("vaporview", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else {
            return nil
        }
        return url
    }

    var hasAssets: Bool { assetRoot != nil }

    /// Makes `fileURL` the only file this handler serves, under a fresh token,
    /// and returns the URL the viewer reads it from.
    func serve(fileURL: URL) -> URL {
        stopServing()
        let token = UUID().uuidString.lowercased()
        source = WaveformFileSource(fileURL: fileURL, token: token)
        return URL(string: "\(Self.scheme)://\(Self.host)/file/\(token)")!
    }

    /// Makes `relay` answer the page's FSDB requests, under a fresh token,
    /// and returns the URL the page POSTs them to.
    func serve(fsdbRelay relay: @escaping WaveformFSDBRelay.Handler) -> URL {
        stopServing()
        let token = UUID().uuidString.lowercased()
        fsdbRelay = WaveformFSDBRelay(token: token, handle: relay)
        return URL(string: "\(Self.scheme)://\(Self.host)/fsdb/\(token)")!
    }

    func stopServing() {
        fsdbRelay = nil
        guard let source else { return }
        self.source = nil
        ioQueue.async { source.close() }
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        let route = request.url.flatMap {
            Self.route(for: $0, assetRoot: assetRoot, source: source, fsdbRelay: fsdbRelay)
        }
        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.insert(taskId)
        let task = WaveformSchemeTaskBox(urlSchemeTask)
        if case .fsdb(let relay) = route {
            let body = request.httpMethod?.uppercased() == "POST" ? Self.body(of: request) : nil
            Task { @MainActor [weak self] in
                let response: WaveformSchemeResponse
                if let body {
                    response = await relay.handle(body)
                } else {
                    response = .status(405)
                }
                guard let self, self.activeTasks.remove(taskId) != nil else { return }
                task.deliver(response)
            }
            return
        }
        let isHead = request.httpMethod?.uppercased() == "HEAD"
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        ioQueue.async { [weak self] in
            let response: WaveformSchemeResponse
            switch route {
            case .asset(let fileURL):
                response = Self.assetResponse(fileURL: fileURL, isHead: isHead)
            case .file(let source):
                response = Self.fileResponse(source: source, isHead: isHead, rangeHeader: rangeHeader)
            case .fsdb:
                response = .status(405)
            case nil:
                response = .status(404)
            }
            DispatchQueue.main.async {
                guard let self, self.activeTasks.remove(taskId) != nil else { return }
                task.deliver(response)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    // MARK: Routing

    enum Route {
        case asset(URL)
        case file(WaveformFileSource)
        case fsdb(WaveformFSDBRelay)
    }

    /// A request body: WebKit hands a `fetch` body over as data or as a stream.
    nonisolated static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&chunk, maxLength: chunk.count)
            if count <= 0 { break }
            data.append(chunk, count: count)
            if data.count > 1024 * 1024 { return nil }
        }
        return data
    }

    /// Resolves a request to a bundled asset or to the served file. Rejects
    /// other schemes and hosts, dot segments, and anything that resolves
    /// outside the asset folder.
    nonisolated static func route(
        for url: URL,
        assetRoot: URL?,
        source: WaveformFileSource?,
        fsdbRelay: WaveformFSDBRelay? = nil
    ) -> Route? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }

        if components.first == "file" {
            guard components.count == 2, let source, components[1] == source.token else { return nil }
            return .file(source)
        }
        if components.first == "fsdb" {
            guard components.count == 2, let fsdbRelay, components[1] == fsdbRelay.token else { return nil }
            return .fsdb(fsdbRelay)
        }

        guard let assetRoot else { return nil }
        var candidate = assetRoot
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(assetRoot.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return .asset(resolved)
    }

    // MARK: Responses

    nonisolated static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "wasm": "application/wasm",
        "ttf": "font/ttf",
        "svg": "image/svg+xml",
    ]

    nonisolated static func assetResponse(fileURL: URL, isHead: Bool) -> WaveformSchemeResponse {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return .status(404) }
        let headers = [
            "Content-Type": mimeTypes[fileURL.pathExtension.lowercased()] ?? "application/octet-stream",
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        return WaveformSchemeResponse(status: 200, headers: headers, body: isHead ? Data() : data)
    }

    nonisolated static func fileResponse(
        source: WaveformFileSource,
        isHead: Bool,
        rangeHeader: String?
    ) -> WaveformSchemeResponse {
        guard let size = source.currentSize() else { return .status(404) }
        var headers = [
            "Content-Type": "application/octet-stream",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if isHead {
            headers["Content-Length"] = String(size)
            return WaveformSchemeResponse(status: 200, headers: headers, body: Data())
        }

        let range: ClosedRange<UInt64>
        let status: Int
        if let rangeHeader {
            guard let parsed = WaveformByteRange.parse(rangeHeader, size: size),
                  parsed.upperBound - parsed.lowerBound < maxRangeResponseBytes else {
                headers["Content-Range"] = "bytes */\(size)"
                return WaveformSchemeResponse(status: 416, headers: headers, body: Data())
            }
            range = parsed
            status = 206
        } else {
            guard size <= maxUnrangedResponseBytes else { return .status(413) }
            guard size > 0 else {
                headers["Content-Length"] = "0"
                return WaveformSchemeResponse(status: 200, headers: headers, body: Data())
            }
            range = 0...(size - 1)
            status = 200
        }

        guard let body = source.read(range: range) else { return .status(500) }
        headers["Content-Length"] = String(body.count)
        if status == 206 {
            let end = range.lowerBound + UInt64(max(body.count, 1)) - 1
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(end)/\(size)"
        }
        return WaveformSchemeResponse(status: status, headers: headers, body: body)
    }
}

/// Answers the page's FSDB requests for one open remote file.
final class WaveformFSDBRelay: @unchecked Sendable {
    typealias Handler = @MainActor (Data) async -> WaveformSchemeResponse

    let token: String
    let handle: Handler

    init(token: String, handle: @escaping Handler) {
        self.token = token
        self.handle = handle
    }
}

/// A finished response, built off the main thread.
struct WaveformSchemeResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func status(_ status: Int) -> WaveformSchemeResponse {
        WaveformSchemeResponse(status: status, headers: ["Content-Length": "0"], body: Data())
    }
}

/// Parses a single-range `Range: bytes=...` header against a file size.
enum WaveformByteRange {
    static func parse(_ header: String, size: UInt64) -> ClosedRange<UInt64>? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = trimmed.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            // Suffix range: the last N bytes.
            guard let suffix = UInt64(endText), suffix > 0 else { return nil }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let start = UInt64(startText), start < size else { return nil }
        if endText.isEmpty {
            return start...(size - 1)
        }
        guard let end = UInt64(endText), end >= start else { return nil }
        return start...min(end, size - 1)
    }
}

/// The waveform file a viewer opened. Used only on the handler's I/O queue.
final class WaveformFileSource: @unchecked Sendable {
    let fileURL: URL
    let token: String
    private var handle: FileHandle?

    init(fileURL: URL, token: String) {
        self.fileURL = fileURL
        self.token = token
    }

    func currentSize() -> UInt64? {
        guard let handle = openHandle() else { return nil }
        return try? handle.seekToEnd()
    }

    func read(range: ClosedRange<UInt64>) -> Data? {
        guard let handle = openHandle() else { return nil }
        do {
            try handle.seek(toOffset: range.lowerBound)
            let count = Int(range.upperBound - range.lowerBound + 1)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        handle = try? FileHandle(forReadingFrom: fileURL)
        return handle
    }
}

/// Carries a scheme task from the main thread through the I/O queue and back.
private final class WaveformSchemeTaskBox: @unchecked Sendable {
    private let task: WKURLSchemeTask

    init(_ task: WKURLSchemeTask) {
        self.task = task
    }

    @MainActor
    func deliver(_ response: WaveformSchemeResponse) {
        guard let url = task.request.url,
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers
              ) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        task.didReceive(httpResponse)
        if !response.body.isEmpty {
            task.didReceive(response.body)
        }
        task.didFinish()
    }
}
