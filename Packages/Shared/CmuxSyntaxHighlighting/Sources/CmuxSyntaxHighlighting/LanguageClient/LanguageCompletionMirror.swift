import Foundation

/// Completion for a remote document from a local language server.
///
/// Some remote server builds hang on `textDocument/completion` (the Linux
/// slang-server 0.3.1 prebuilt spins and grows without bound), so remote
/// editors keep lint, hover, definition and references on the remote server
/// and ask this mirror for completion instead. It runs its own local server,
/// rooted in a private temporary directory that holds only a copy of the
/// document under the same file name, and keeps that copy in sync with the
/// editor buffer through `didOpen`/`didChange`.
///
/// The local server sees only this one file, so names declared in other
/// remote files (modules, packages, includes) are not offered. Completion
/// items carry no document URIs, so nothing has to be mapped back.
public actor LanguageCompletionMirror {
    /// The document as the remote server knows it.
    public nonisolated let remoteURI: URL
    /// The private directory the local server is rooted in.
    public nonisolated let directory: URL
    /// The local copy the local server edits.
    public nonisolated let mirrorURI: URL

    private let session: LanguageServerSession
    private var isOpen = false
    private var version = 0
    private var lastText: String?

    /// Creates a mirror served by the local `launch`. Nothing is written or launched until `open`.
    ///
    /// `identity` distinguishes hosts that share a path, such as an ssh provider identity.
    public init(remoteURI: URL, identity: String, languageId: String, launch: LanguageToolLaunch) {
        self.remoteURI = remoteURI
        directory = Self.directory(remoteURI: remoteURI, identity: identity)
        mirrorURI = directory.appendingPathComponent(remoteURI.lastPathComponent)
        session = LanguageServerSession(launch: launch, rootURI: directory, languageId: languageId)
    }

    /// `<tmp>/cmux-sv-completion/<hash of identity and path>-<unique>`; unique per mirror so two editors never share one.
    static func directory(remoteURI: URL, identity: String) -> URL {
        let key = identity + "\n" + remoteURI.path
        let name = "\(stableHash(key))-\(UUID().uuidString.prefix(8).lowercased())"
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-sv-completion", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// FNV-1a, stable across launches unlike `Hasher`.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Writes the copy, starts the local server and opens the document.
    public func open(text: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: mirrorURI, atomically: true, encoding: .utf8)
        version = 1
        lastText = text
        await session.open(uri: mirrorURI, text: text, version: version)
        isOpen = true
        try await session.start()
    }

    /// Sends the editor's full text to the local server when it changed.
    public func change(text: String) async {
        guard isOpen, text != lastText else { return }
        version += 1
        lastText = text
        await session.change(uri: mirrorURI, text: text, version: version)
    }

    /// Completion candidates at `position` in the remote document.
    ///
    /// Relaunches the local server first if it died; the session re-opens the copy.
    public func completion(position: LSPPosition) async throws -> [LSPCompletionItem] {
        guard isOpen else { throw LanguageServerError.notRunning }
        try await session.start()
        return try await session.completion(uri: mirrorURI, position: position)
    }

    /// Kills the local server without the shutdown handshake. Test hook.
    func simulateCrashForTesting() async {
        await session.simulateCrashForTesting()
    }

    /// Stops the local server and deletes the private directory.
    public func shutdown() async {
        isOpen = false
        await session.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
