import Foundation

/// Bounds the one-off `ssh` runs that share one ControlMaster.
///
/// Every session multiplexed over a master counts against the server's
/// `MaxSessions` for that one connection (10 by default), and past it OpenSSH
/// refuses the session ("Session open refused by peer", exit 255) without
/// falling back to a direct connection. Runs that share a master therefore
/// wait here for one of at most ``limit`` slots per master, which leaves room
/// for the few long-lived sessions (a file channel) that ride it too.
final class SSHSessionGate: @unchecked Sendable {
    /// The app's gate: 6 short runs per master.
    static let shared = SSHSessionGate(limit: 6)

    let limit: Int
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var waiting: [String: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    /// The master `options` multiplex over: their first `ControlPath`, unless it
    /// is `none`. Nil means the run opens its own connection and needs no slot.
    static func sharedMasterKey(sshOptions options: [String]) -> String? {
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == " " }) else { continue }
            guard trimmed[..<separator].lowercased() == "controlpath" else { continue }
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "= ").union(.whitespaces))
            // OpenSSH keeps the first value it reads.
            return value.isEmpty || value.lowercased() == "none" ? nil : value
        }
        return nil
    }

    /// Runs `body` once a slot on `key`'s master is free. A nil key runs at once.
    /// It runs on the caller's actor, so `body` need not be Sendable.
    func withSession<T>(
        sharing key: String?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        guard let key else { return try await body() }
        try await acquire(key)
        defer { release(key) }
        return try await body()
    }

    /// Slots in use on `key`'s master.
    func activeCount(_ key: String) -> Int {
        lock.withLock { active[key, default: 0] }
    }

    private func acquire(_ key: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Checked under the lock: a cancel either finds this waiter queued
                // (onCancel resumes it) or happened first and is seen here.
                enum Outcome { case run, cancelled, queued }
                let outcome: Outcome = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if true { // stub (red): no limit

                        active[key, default: 0] += 1
                        return .run
                    }
                    waiting[key, default: []].append((id, continuation))
                    return .queued
                }
                switch outcome {
                case .run: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .queued: break
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiting[key]?.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting[key]?.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    private func release(_ key: String) {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            if var queue = waiting[key], !queue.isEmpty {
                // The slot passes straight to the next waiter.
                let first = queue.removeFirst()
                waiting[key] = queue.isEmpty ? nil : queue
                return first.continuation
            }
            let remaining = active[key, default: 1] - 1
            active[key] = remaining > 0 ? remaining : nil
            return nil
        }
        next?.resume()
    }
}
