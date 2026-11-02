import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// sshd allows 10 sessions on one connection by default, and refuses the rest
/// without a fallback. Runs that share a master must stay under that.
struct SSHSessionGateTests {
    /// A master that refuses a session past `maxSessions`, as sshd does.
    private final class MockMaster: @unchecked Sendable {
        let maxSessions: Int
        private let lock = NSLock()
        private var open = 0
        private(set) var peak = 0
        private(set) var refused = 0

        init(maxSessions: Int, held: Int) {
            self.maxSessions = maxSessions
            open = held
            peak = held
        }

        /// One short run: refused when the master is full, else held for `nanoseconds`.
        func run(nanoseconds: UInt64) async -> Bool {
            let admitted: Bool = lock.withLock {
                guard open < maxSessions else { refused += 1; return false }
                open += 1
                peak = max(peak, open)
                return true
            }
            guard admitted else { return false }
            try? await Task.sleep(nanoseconds: nanoseconds)
            lock.withLock { open -= 1 }
            return true
        }
    }

    private static func burst(gate: SSHSessionGate?, master: MockMaster, runs: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<runs {
                group.addTask {
                    if let gate {
                        _ = try? await gate.withSession(sharing: "/tmp/cmux-mock-ops") {
                            await master.run(nanoseconds: 20_000_000)
                        }
                    } else {
                        _ = await master.run(nanoseconds: 20_000_000)
                    }
                }
            }
        }
    }

    /// A Files refresh, previews and git status at once: 40 runs on a master
    /// that already holds 2 long-lived sessions (a carrier and a file channel).
    @Test
    func testABurstOfRunsStaysUnderTheSessionLimit() async {
        let ungated = MockMaster(maxSessions: 10, held: 2)
        await Self.burst(gate: nil, master: ungated, runs: 40)
        #expect(ungated.refused > 0)

        let master = MockMaster(maxSessions: 10, held: 2)
        let gate = SSHSessionGate(limit: 6)
        await Self.burst(gate: gate, master: master, runs: 40)
        #expect(master.refused == 0)
        #expect(master.peak <= 8)
        #expect(gate.activeCount("/tmp/cmux-mock-ops") == 0)
    }

    @Test
    func testTheSharedMasterIsTheFirstControlPath() {
        #expect(SSHSessionGate.sharedMasterKey(sshOptions: ["BatchMode=yes", "ControlPath=/tmp/a-ops", "ControlPath=/tmp/b"]) == "/tmp/a-ops")
        #expect(SSHSessionGate.sharedMasterKey(sshOptions: ["ControlPath none"]) == nil)
        #expect(SSHSessionGate.sharedMasterKey(sshOptions: ["controlpath=NONE"]) == nil)
        #expect(SSHSessionGate.sharedMasterKey(sshOptions: ["BatchMode=yes"]) == nil)
    }

    /// A run with its own connection never waits.
    @Test
    func testRunsWithoutAMasterDoNotWait() async throws {
        let gate = SSHSessionGate(limit: 1)
        let value = try await gate.withSession(sharing: "/tmp/cmux-mock-ops") {
            try await gate.withSession(sharing: nil) { 7 }
        }
        #expect(value == 7)
    }

    /// A cancelled waiter gives up its place, and the slot still passes on.
    @Test
    func testACancelledWaiterLeavesTheQueue() async throws {
        let gate = SSHSessionGate(limit: 1)
        let key = "/tmp/cmux-mock-ops"
        let holder = Task { try await gate.withSession(sharing: key) { try await Task.sleep(nanoseconds: 200_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await gate.withSession(sharing: key) { "ran" } }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        let cancelled: Bool
        do { _ = try await waiter.value; cancelled = false } catch { cancelled = error is CancellationError }
        #expect(cancelled)
        try await holder.value
        let after = try await gate.withSession(sharing: key) { "after" }
        #expect(after == "after")
        #expect(gate.activeCount(key) == 0)
    }
}
