import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Remote preview downloads (⌘-click and `cmux open`) share one cache; it is
/// kept under a size budget, least recently written first.
@Suite(.serialized)
struct RemotePreviewCacheBudgetTests {
    private static func makeCache(_ files: [(String, Int, TimeInterval)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-preview-cache-\(UUID().uuidString)", isDirectory: true)
        for (relativePath, size, age) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path
            )
        }
        return root
    }

    private static func exists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    @Test
    func testOldestFilesGoFirstUntilTheCacheFitsTheBudget() throws {
        let root = try Self.makeCache([
            ("ns/a/old.sv", 400, 7_200), ("ns/b/middle.sv", 400, 3_600),
            ("ns/c/new.sv", 400, 1_800), ("other/d/kept.sv", 400, 9_000),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("other/d/kept.sv")
        let removed = RemotePreviewCacheBudget.evict(in: root, budgetBytes: 900, keeping: [kept.path], recentUseGrace: 60)
        #expect(removed.count == 2)
        #expect(!Self.exists(root, "ns/a/old.sv"))
        #expect(!Self.exists(root, "ns/b/middle.sv"))
        #expect(Self.exists(root, "ns/c/new.sv"))
        #expect(Self.exists(root, "other/d/kept.sv"))
        // Emptied per-path directories go too.
        #expect(!Self.exists(root, "ns/a"))
    }

    @Test
    func testRecentlyWrittenFilesAreNotEvicted() throws {
        // A preview opened a moment ago may still be on screen.
        let root = try Self.makeCache([("ns/a/open.sv", 1_000, 5), ("ns/b/stale.sv", 1_000, 7_200)])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = RemotePreviewCacheBudget.evict(in: root, budgetBytes: 10, keeping: [], recentUseGrace: 600)
        #expect(Self.exists(root, "ns/a/open.sv"))
        #expect(!Self.exists(root, "ns/b/stale.sv"))
    }

    @Test
    func testUnderBudgetNothingIsRemoved() throws {
        let root = try Self.makeCache([("ns/a/x.sv", 100, 7_200), ("ns/b/y.sv", 100, 7_200)])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RemotePreviewCacheBudget.evict(in: root, budgetBytes: 1_000, keeping: [], recentUseGrace: 60).isEmpty)
        #expect(RemotePreviewCacheBudget.evict(in: root.appendingPathComponent("missing"), budgetBytes: 0, keeping: [], recentUseGrace: 0).isEmpty)
    }

    @Test
    func testDiscardingADownloadRemovesItsDirectoryButNothingAbove() throws {
        let root = try Self.makeCache([("ns/a/refused.webarchive", 10, 0), ("ns/b/other.sv", 10, 0)])
        defer { try? FileManager.default.removeItem(at: root) }
        RemotePreviewCacheBudget.discard(root.appendingPathComponent("ns/a/refused.webarchive"), cacheRoot: root)
        #expect(!Self.exists(root, "ns/a"))
        #expect(Self.exists(root, "ns/b/other.sv"))
        #expect(Self.exists(root, ""))
        // Never outside the cache.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-outside-\(UUID().uuidString)")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        RemotePreviewCacheBudget.discard(outside, cacheRoot: root)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}
