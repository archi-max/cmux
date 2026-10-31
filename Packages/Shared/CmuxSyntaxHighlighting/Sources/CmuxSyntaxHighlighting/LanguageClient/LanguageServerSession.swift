import Foundation

/// One running language server. Full-document sync. Safe to share across editors of the same workspace.
///
/// Speaks JSON-RPC 2.0 with `Content-Length` framing over the child's
/// stdin/stdout. Every request has a timeout, and server-to-client requests
/// are answered with `null` (or an array of `null`s for
/// `workspace/configuration`) so the server never stalls waiting on us.
///
/// Documents passed to `open` are remembered until `close`. If the process
/// dies, pending requests fail with `LanguageServerError.processExited` and
/// `isRunning` becomes false; calling `start()` again (which
/// `LanguageServerPool` does on the next `session(...)` call) relaunches the
/// server and re-sends `didOpen` for every remembered document, so editors
/// can keep their reference to this object across restarts.
///
/// ## slang-server
/// slang-server indexes every `.sv`, `.svh`, `.v`, and `.vh` file under the
/// workspace root, which is what makes cross-file features work: go to
/// definition of an instantiated module, hover on ports driven from another
/// file, and "unknown module" diagnostics all depend on it. Pass the project
/// directory as `rootURI`; with `rootURI == nil` each file is compiled alone,
/// definitions in other files return `[]`, and instantiations of modules
/// defined elsewhere are reported as unknown. No `.slang/server.json` is
/// needed for plain projects. That file (or `.slang/local/server.json`) under
/// the root is only for extra flags, include directories (`incdirs`), index
/// globs, or a `.f` build file; see
/// https://hudson-trading.github.io/slang-server/start/config/.
///
/// slang-server reports URIs using symlink-resolved paths (for example
/// `/private/tmp` rather than `/tmp`). For local launches the session sends
/// resolved paths to the server and maps results back to the URLs the
/// editor used, so callers can compare URLs directly. Remote (ssh) URIs are
/// passed through unchanged.
///
/// Each request times out after `requestTimeout` (default 10 s). After two
/// timeouts in a row the server is considered wedged and its process is
/// killed, so it reports `isRunning == false` and the pool restarts it.
///
/// Positions are zero-based, with `character` in UTF-16 code units.
public actor LanguageServerSession {
    /// How the server is launched.
    public nonisolated let launch: LanguageToolLaunch
    /// Workspace root sent as `rootUri` and the single workspace folder.
    public nonisolated let rootURI: URL?
    /// Language id this session serves (for example `"verilog"`).
    public nonisolated let languageId: String
    /// Timeout applied to each request other than `initialize`.
    public nonisolated let requestTimeout: TimeInterval
    /// Timeout for the `initialize` request (covers ssh connection and indexing).
    public nonisolated let initializeTimeout: TimeInterval

    private enum State {
        case stopped
        case starting
        case running
    }

    private struct PendingRequest {
        var method: String
        var continuation: CheckedContinuation<JSONValue, any Error>
        var timeoutTask: Task<Void, Never>
    }

    private struct OpenDocument {
        var text: String
        var version: Int
    }

    private var state: State = .stopped
    private var tool: LanguageToolProcess?
    private var generation = 0
    private var startTask: Task<Void, any Error>?
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var framer = LSPMessageFramer()
    private var documents: [URL: OpenDocument] = [:]
    /// Server-side URI string -> URL the editor used.
    private var editorURLByServerURI: [String: URL] = [:]
    private var latestDiagnostics: [URL: [LSPDiagnostic]] = [:]
    private var diagnosticsSubscribers: [UUID: AsyncStream<(uri: URL, diagnostics: [LSPDiagnostic])>.Continuation] = [:]
    private var lastExit: LanguageServerError?
    private var consecutiveTimeouts = 0
    /// After this many back-to-back request timeouts the server is assumed wedged and is killed.
    private static let wedgedTimeoutLimit = 2

    /// Creates a session. Nothing is launched until `start()`.
    public init(
        launch: LanguageToolLaunch,
        rootURI: URL?,
        languageId: String,
        requestTimeout: TimeInterval = 10,
        initializeTimeout: TimeInterval = 30
    ) {
        self.launch = launch
        self.rootURI = rootURI
        self.languageId = languageId
        self.requestTimeout = requestTimeout
        self.initializeTimeout = initializeTimeout
    }

    /// Whether the server has completed the handshake and its process is alive.
    public var isRunning: Bool {
        state == .running
    }

    /// The last lines the server wrote to stderr.
    public var stderrTail: String {
        tool?.stderrTail.text ?? ""
    }

    // MARK: Lifecycle

    /// Spawns the server and performs the initialize/initialized handshake. Idempotent.
    ///
    /// Concurrent callers share one launch. After the process dies, calling
    /// this again relaunches it and re-opens remembered documents.
    public func start() async throws {
        if state == .running { return }
        if let startTask {
            return try await startTask.value
        }
        let task = Task { try await self.launchAndInitialize() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func launchAndInitialize() async throws {
        generation += 1
        let generation = generation
        framer = LSPMessageFramer()
        lastExit = nil
        consecutiveTimeouts = 0
        let tool = try LanguageToolProcess.spawn(launch, currentDirectory: rootURI.flatMap { $0.isFileURL ? $0 : nil })
        self.tool = tool
        state = .starting

        Task { [weak self] in
            for await chunk in tool.stdout {
                await self?.receive(chunk, generation: generation)
            }
        }
        Task { [weak self] in
            var status: Int32 = -1
            for await value in tool.exit {
                status = value
            }
            await self?.processDidExit(status: status, generation: generation)
        }

        do {
            _ = try await request("initialize", params: initializeParams(), timeout: initializeTimeout, allowWhileStarting: true)
        } catch {
            if self.generation == generation {
                teardown(error: error)
            }
            throw error
        }
        guard self.generation == generation, state == .starting else {
            throw lastExit ?? LanguageServerError.notRunning
        }
        notify("initialized", params: .object([:]))
        state = .running
        for (url, document) in documents {
            sendDidOpen(url: url, text: document.text, version: document.version)
        }
    }

    /// Sends shutdown and exit, then terminates the process if it lingers.
    ///
    /// Remembered documents are forgotten; diagnostics streams stay open.
    public func shutdown() async {
        documents.removeAll()
        editorURLByServerURI.removeAll()
        guard let tool, state != .stopped else { return }
        let generation = generation
        if state == .running {
            _ = try? await request("shutdown", params: .null, timeout: 2)
            notify("exit", params: .null)
        }
        tool.closeStdin()
        for _ in 0..<20 where tool.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        tool.terminate()
        for _ in 0..<20 where tool.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        tool.kill()
        if self.generation == generation {
            teardown(error: LanguageServerError.notRunning)
            lastExit = nil
        }
    }

    /// Kills the process without the shutdown handshake and waits until the session notices. Test hook.
    func simulateCrashForTesting() async {
        guard let tool else { return }
        tool.kill()
        for _ in 0..<200 where state != .stopped {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Document sync

    /// Sends `textDocument/didOpen` and remembers the document for restarts.
    public func open(uri: URL, text: String, version: Int) async {
        documents[uri] = OpenDocument(text: text, version: version)
        if state == .running {
            sendDidOpen(url: uri, text: text, version: version)
        }
    }

    /// Sends a full-text `textDocument/didChange`.
    public func change(uri: URL, text: String, version: Int) async {
        documents[uri] = OpenDocument(text: text, version: version)
        guard state == .running else { return }
        notify("textDocument/didChange", params: .object([
            "textDocument": .object(["uri": .string(serverURI(for: uri)), "version": .int(version)]),
            "contentChanges": .array([.object(["text": .string(text)])]),
        ]))
    }

    /// Sends `textDocument/didSave`, including the text when given.
    public func save(uri: URL, text: String?) async {
        if let text, var document = documents[uri] {
            document.text = text
            documents[uri] = document
        }
        guard state == .running else { return }
        var params: [String: JSONValue] = ["textDocument": .object(["uri": .string(serverURI(for: uri))])]
        if let text {
            params["text"] = .string(text)
        }
        notify("textDocument/didSave", params: .object(params))
    }

    /// The text of an open document, as last sent.
    func documentText(_ uri: URL) -> String? {
        documents[uri]?.text
    }

    /// Sends `textDocument/didClose` and forgets the document.
    public func close(uri: URL) async {
        documents[uri] = nil
        latestDiagnostics[uri] = nil
        guard state == .running else { return }
        notify("textDocument/didClose", params: .object([
            "textDocument": .object(["uri": .string(serverURI(for: uri))]),
        ]))
    }

    // MARK: Requests

    /// Hover text (markdown or plain text) at `position`, or `nil` if none.
    public func hover(uri: URL, position: LSPPosition) async throws -> String? {
        let result = try await request("textDocument/hover", params: positionParams(uri: uri, position: position))
        return LSPResponseDecoding.hoverText(result)
    }

    /// Definition locations for the symbol at `position`.
    public func definition(uri: URL, position: LSPPosition) async throws -> [LSPLocation] {
        let result = try await request("textDocument/definition", params: positionParams(uri: uri, position: position))
        return LSPResponseDecoding.locations(result, uriMapper: editorURL(forServerURI:))
    }

    /// Reference locations for the symbol at `position`.
    public func references(uri: URL, position: LSPPosition, includeDeclaration: Bool) async throws -> [LSPLocation] {
        guard case .object(var params) = positionParams(uri: uri, position: position) else { return [] }
        params["context"] = .object(["includeDeclaration": .bool(includeDeclaration)])
        let result = try await request("textDocument/references", params: .object(params))
        return LSPResponseDecoding.locations(result, uriMapper: editorURL(forServerURI:))
    }

    /// Completion candidates at `position`.
    public func completion(uri: URL, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let result = try await request("textDocument/completion", params: positionParams(uri: uri, position: position))
        return LSPResponseDecoding.completionItems(result)
    }

    /// Runs `workspace/executeCommand` with zero or one argument and returns its raw result.
    /// `countsTowardWedged`: false for exploratory requests (the design walk) whose timeout
    /// says the request was too big, not that the server hangs.
    func executeCommand(_ command: String, argument: JSONValue?, timeout: TimeInterval? = nil, countsTowardWedged: Bool = true) async throws -> JSONValue {
        var params: [String: JSONValue] = ["command": .string(command)]
        params["arguments"] = .array(argument.map { [$0] } ?? [])
        return try await request("workspace/executeCommand", params: .object(params), timeout: timeout, countsTowardWedged: countsTowardWedged)
    }

    // MARK: Diagnostics

    /// Every textDocument/publishDiagnostics notification. Multiple consumers may each call this to get their own stream.
    ///
    /// A new stream first replays the latest diagnostics of each open
    /// document, so subscribing after `open` does not miss the first report.
    /// Streams survive server restarts and end when the consumer stops
    /// iterating.
    public func diagnosticsUpdates() -> AsyncStream<(uri: URL, diagnostics: [LSPDiagnostic])> {
        let (stream, continuation) = AsyncStream<(uri: URL, diagnostics: [LSPDiagnostic])>.makeStream()
        let id = UUID()
        diagnosticsSubscribers[id] = continuation
        for (uri, diagnostics) in latestDiagnostics {
            continuation.yield((uri: uri, diagnostics: diagnostics))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDiagnosticsSubscriber(id) }
        }
        return stream
    }

    /// The most recent diagnostics published for `uri`, if any.
    public func diagnostics(for uri: URL) -> [LSPDiagnostic]? {
        latestDiagnostics[uri]
    }

    private func removeDiagnosticsSubscriber(_ id: UUID) {
        diagnosticsSubscribers[id] = nil
    }

    // MARK: JSON-RPC plumbing

    private func request(
        _ method: String,
        params: JSONValue,
        timeout: TimeInterval? = nil,
        allowWhileStarting: Bool = false,
        countsTowardWedged: Bool = true
    ) async throws -> JSONValue {
        guard let tool, state == .running || (allowWhileStarting && state == .starting) else {
            throw lastExit ?? LanguageServerError.notRunning
        }
        try Task.checkCancellation()
        let id = nextRequestID
        nextRequestID += 1
        let timeout = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.requestDidTimeOut(id: id, method: method, countsTowardWedged: countsTowardWedged)
                }
                pending[id] = PendingRequest(method: method, continuation: continuation, timeoutTask: timeoutTask)
                write(tool: tool, .object([
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "method": .string(method),
                    "params": params,
                ]))
            }
        } onCancel: {
            Task { await self.fail(requestID: id, with: CancellationError(), cancelOnServer: true) }
        }
    }

    private func requestDidTimeOut(id: Int, method: String, countsTowardWedged: Bool) {
        guard pending[id] != nil else { return }
        fail(requestID: id, with: LanguageServerError.timeout(method: method), cancelOnServer: true)
        guard countsTowardWedged else { return }
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= Self.wedgedTimeoutLimit, state == .running {
            // A server that stops answering stays "running" forever otherwise;
            // killing it lets the pool restart it on the next session(...) call.
            tool?.kill()
        }
    }

    private func fail(requestID id: Int, with error: any Error, cancelOnServer: Bool) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
        if cancelOnServer {
            notify("$/cancelRequest", params: .object(["id": .int(id)]))
        }
    }

    private func notify(_ method: String, params: JSONValue) {
        guard let tool else { return }
        write(tool: tool, .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func write(tool: LanguageToolProcess, _ message: JSONValue) {
        guard let body = try? message.encoded() else { return }
        tool.write(LSPMessageFramer.frame(body))
    }

    private func receive(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        for body in framer.append(data) {
            guard let message = try? JSONValue.decode(body) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSONValue) {
        let method = message["method"]?.stringValue
        let id = message["id"]
        if let method, let id {
            answerServerRequest(id: id, method: method, params: message["params"])
        } else if let method {
            handleNotification(method: method, params: message["params"])
        } else if let id = id?.intValue, let request = pending.removeValue(forKey: id) {
            request.timeoutTask.cancel()
            consecutiveTimeouts = 0
            if let error = message["error"] {
                request.continuation.resume(throwing: LanguageServerError.responseError(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "Unknown error"
                ))
            } else {
                request.continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    private func answerServerRequest(id: JSONValue, method: String, params: JSONValue?) {
        let result: JSONValue
        if method == "workspace/configuration" {
            let count = params?["items"]?.arrayValue?.count ?? 0
            result = .array(Array(repeating: .null, count: count))
        } else {
            result = .null
        }
        guard let tool else { return }
        write(tool: tool, .object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func handleNotification(method: String, params: JSONValue?) {
        guard method == "textDocument/publishDiagnostics",
              let uriString = params?["uri"]?.stringValue,
              let uri = editorURL(forServerURI: uriString)
        else { return }
        let diagnostics = LSPResponseDecoding.diagnostics(params?["diagnostics"])
        latestDiagnostics[uri] = diagnostics
        for continuation in diagnosticsSubscribers.values {
            continuation.yield((uri: uri, diagnostics: diagnostics))
        }
    }

    private func processDidExit(status: Int32, generation: Int) {
        guard generation == self.generation, state != .stopped else { return }
        let stderr = tool?.stderrTail.text ?? ""
        teardown(error: LanguageServerError.processExited(status: status, stderr: stderr))
    }

    private func teardown(error: any Error) {
        state = .stopped
        if let error = error as? LanguageServerError, error != .notRunning {
            lastExit = error
        }
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
        tool?.closeStdin()
        tool?.terminate()
        tool = nil
    }

    // MARK: Parameters and URIs

    private func initializeParams() -> JSONValue {
        var params: [String: JSONValue] = [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": .object(["name": .string("cmux")]),
            "capabilities": .object([
                "textDocument": .object([
                    "synchronization": .object([
                        "dynamicRegistration": .bool(false),
                        "didSave": .bool(true),
                        "willSave": .bool(false),
                        "willSaveWaitUntil": .bool(false),
                    ]),
                    "publishDiagnostics": .object(["relatedInformation": .bool(false)]),
                    "hover": .object(["contentFormat": .array([.string("markdown"), .string("plaintext")])]),
                    "definition": .object(["linkSupport": .bool(false)]),
                    "references": .object([:]),
                    "completion": .object([
                        "completionItem": .object(["snippetSupport": .bool(false)]),
                    ]),
                ]),
                "workspace": .object([
                    "configuration": .bool(true),
                    "workspaceFolders": .bool(true),
                ]),
                "window": .object(["workDoneProgress": .bool(true)]),
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
            ]),
        ]
        if launch.isRemote {
            params["processId"] = .null
        }
        if let rootURI {
            let uri = serverURI(for: rootURI)
            params["rootUri"] = .string(uri)
            params["rootPath"] = .string(serverPath(for: rootURI))
            params["workspaceFolders"] = .array([.object([
                "uri": .string(uri),
                "name": .string(rootURI.lastPathComponent),
            ])])
        } else {
            params["rootUri"] = .null
        }
        return .object(params)
    }

    func positionParams(uri: URL, position: LSPPosition) -> JSONValue {
        .object([
            "textDocument": .object(["uri": .string(serverURI(for: uri))]),
            "position": .object(["line": .int(position.line), "character": .int(position.character)]),
        ])
    }

    private func sendDidOpen(url: URL, text: String, version: Int) {
        notify("textDocument/didOpen", params: .object([
            "textDocument": .object([
                "uri": .string(serverURI(for: url)),
                "languageId": .string(protocolLanguageId(for: url)),
                "version": .int(version),
                "text": .string(text),
            ]),
        ]))
    }

    /// LSP language id for `url`; the catalog's "verilog" covers both dialects.
    private func protocolLanguageId(for url: URL) -> String {
        guard languageId == "verilog" else { return languageId }
        switch url.pathExtension.lowercased() {
        case "sv", "svh": return "systemverilog"
        default: return "verilog"
        }
    }

    private func serverPath(for url: URL) -> String {
        guard url.isFileURL else { return url.path }
        return launch.isRemote ? url.standardizedFileURL.path : Self.realPath(url.path)
    }

    private func serverURI(for url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        let uri = URL(fileURLWithPath: serverPath(for: url)).absoluteString
        editorURLByServerURI[uri] = url
        return uri
    }

    /// Maps a server URI back to the URL the editor used for it, or for its
    /// workspace root when the file was never opened.
    func editorURL(forServerURI string: String) -> URL? {
        guard let url = URL(string: string) else { return nil }
        guard url.isFileURL else { return url }
        let path = url.path
        if let editorURL = editorURLByServerURI[URL(fileURLWithPath: path).absoluteString] {
            return editorURL
        }
        if let rootURI, rootURI.isFileURL {
            let serverRoot = serverPath(for: rootURI)
            if path.hasPrefix(serverRoot + "/") {
                return rootURI.appendingPathComponent(String(path.dropFirst(serverRoot.count + 1)))
            }
        }
        return URL(fileURLWithPath: path)
    }

    /// `realpath(3)`, resolving the parent when the file itself does not exist yet.
    ///
    /// Unlike `URL.resolvingSymlinksInPath()`, this keeps the `/private` prefix,
    /// which is what slang-server reports.
    static func realPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path, let resolved = realpath(parent, nil) else { return path }
        defer { free(resolved) }
        return (String(cString: resolved) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
