import Foundation

/// Stub for the failing tests; the implementation follows in the next commit.
enum RemotePreviewCacheBudget {
    @discardableResult
    static func evict(in directory: URL, budgetBytes: Int64, keeping: Set<String>, recentUseGrace: TimeInterval) -> [URL] { [] }

    static func discard(_ file: URL, cacheRoot: URL) {}
}
