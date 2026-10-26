import Foundation

/// Process-wide cache so editors share one server per (launch, root, language).
public actor LanguageServerPool {
    /// The pool used by the app.
    public static let shared = LanguageServerPool()

    private struct Key: Hashable {
        var launch: LanguageToolLaunch
        var rootURI: URL?
        var languageId: String
    }

    private var sessions: [Key: LanguageServerSession] = [:]

    /// Creates an empty pool. The app should use `shared`; this exists for tests.
    public init() {}

    /// Returns the shared session for this configuration, starting it if needed and restarting it if it died.
    ///
    /// A restarted session is the same object, so references held by other
    /// editors stay valid and their open documents are re-sent automatically.
    public func session(launch: LanguageToolLaunch, rootURI: URL?, languageId: String) async throws -> LanguageServerSession {
        let key = Key(launch: launch, rootURI: rootURI, languageId: languageId)
        let session: LanguageServerSession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = LanguageServerSession(launch: launch, rootURI: rootURI, languageId: languageId)
            sessions[key] = session
        }
        try await session.start()
        return session
    }

    /// Shuts down every session and empties the pool.
    public func shutdownAll() async {
        let all = Array(sessions.values)
        sessions.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for session in all {
                group.addTask { await session.shutdown() }
            }
        }
    }
}
