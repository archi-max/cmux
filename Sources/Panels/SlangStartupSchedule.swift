import Foundation

/// Orders the work that starts a SystemVerilog editor's language features
/// once its server root is known.
///
/// On an SSH host each piece is a separate round trip: the slang profile
/// listing is one `ssh` run, the remote server is its own `ssh` plus the
/// server's start-up, and the local completion mirror starts a local server.
/// None waits for another, so they overlap instead of running back to back.
enum SlangStartupSchedule {
    /// Starts `listing` (which only kicks off its own task), then runs
    /// `mirror` and `server` concurrently and returns once both finish.
    /// `server`'s error comes back as a failure after `mirror` has finished, so a caller
    /// can still read what the mirror set up.
    @MainActor
    static func run<Server: Sendable>(
        listing: @MainActor () -> Void,
        mirror: @escaping @MainActor () async -> Void,
        server: @MainActor () async throws -> Server
    ) async -> Result<Server, Error> {
        listing()
        async let mirrorStarted: Void = mirror()
        let result: Result<Server, Error>
        do {
            result = .success(try await server())
        } catch {
            result = .failure(error)
        }
        await mirrorStarted
        return result
    }
}
