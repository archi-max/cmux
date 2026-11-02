import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// On an SSH host the profile listing, the remote server and the local
/// completion mirror are separate round trips; they must overlap.
@MainActor
struct SlangStartupScheduleTests {
    private struct ServerFailed: Error {}

    @MainActor
    private final class Log {
        var events: [String] = []
        var serverStarted = false
        var mirrorSawServer = false
    }

    /// Waits up to two seconds for the server to start, polling.
    private static func waitForServer(_ log: Log) async -> Bool {
        for _ in 0..<200 {
            if log.serverStarted { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test
    func testServerStartsWhileTheMirrorIsStillStarting() async throws {
        let log = Log()
        let result = await SlangStartupSchedule.run(
            listing: { log.events.append("listing") },
            mirror: {
                log.events.append("mirror-begin")
                log.mirrorSawServer = await Self.waitForServer(log)
                log.events.append("mirror-end")
            },
            server: {
                log.serverStarted = true
                log.events.append("server")
                return 7
            }
        )
        #expect(try result.get() == 7)
        #expect(log.mirrorSawServer, "the server must not wait for the mirror")
        #expect(log.events.first == "listing")
        #expect(log.events.last == "mirror-end", "run returns only after the mirror finished")
    }

    @Test
    func testAServerFailureStillWaitsForTheMirror() async {
        let log = Log()
        let result: Result<Int, Error> = await SlangStartupSchedule.run(
            listing: {},
            mirror: {
                try? await Task.sleep(nanoseconds: 50_000_000)
                log.events.append("mirror-end")
            },
            server: { throw ServerFailed() }
        )
        guard case .failure(let error) = result else {
            Issue.record("expected the server's failure")
            return
        }
        #expect(error is ServerFailed)
        #expect(log.events == ["mirror-end"])
    }
}
