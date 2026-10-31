import Foundation

/// Keeps the remote preview cache (⌘-click and `cmux open` downloads, one
/// `<connection>/<path digest>/<name>` directory per host file) bounded.
enum RemotePreviewCacheBudget {
    /// Total size the cache may keep after a download.
    static let defaultBudgetBytes: Int64 = 512 * 1024 * 1024
    /// Files written this recently may still be on screen and are kept.
    static let defaultRecentUseGrace: TimeInterval = 10 * 60

    /// Deletes the least recently written files under `directory` until the
    /// rest fit in `budgetBytes`, skipping `keeping` (paths) and files written
    /// within `recentUseGrace`, then removes the directories that emptied.
    /// - Returns: The files removed.
    @discardableResult
    static func evict(
        in directory: URL,
        budgetBytes: Int64,
        keeping: Set<String>,
        recentUseGrace: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > budgetBytes else { return [] }
        // The walk reports /private/var where callers may say /var.
        let kept = Set(keeping.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var removed: [URL] = []
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > budgetBytes else { break }
            guard !kept.contains(file.url.resolvingSymlinksInPath().path),
                  now.timeIntervalSince(file.modified) >= recentUseGrace else { continue }
            guard (try? fileManager.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            removed.append(file.url)
            removeEmptyParents(of: file.url, below: directory, fileManager: fileManager)
        }
        return removed
    }

    /// Deletes a download nobody will show (refused or discarded) and its
    /// per-path directory once empty. Does nothing outside `cacheRoot`, or
    /// when `file` is in `keeping` (a panel shows it: the cache path is fixed
    /// per host file, so an earlier open of the same file uses it).
    static func discard(
        _ file: URL,
        cacheRoot: URL,
        keeping: Set<String> = [],
        fileManager: FileManager = .default
    ) {
        guard isInside(file, cacheRoot) else { return }
        let resolved = file.resolvingSymlinksInPath().path
        guard !keeping.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved }) else { return }
        try? fileManager.removeItem(at: file)
        removeEmptyParents(of: file, below: cacheRoot, fileManager: fileManager)
    }

    private static func removeEmptyParents(of file: URL, below root: URL, fileManager: FileManager) {
        var directory = file.deletingLastPathComponent()
        while isInside(directory, root),
              (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
            directory = directory.deletingLastPathComponent()
        }
    }

    /// Strictly below `root`, after resolving symlinks (/var vs /private/var).
    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
