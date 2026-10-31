import Combine
import Foundation

/// State for the command palette's Go to File mode, for local and SSH workspaces.
///
/// One palette session takes one file-list snapshot (``GoToFileSnapshotLoader``)
/// and ranks it on this Mac for every query (``GoToFileRanker``). This follows
/// the session-snapshot and superseded-search design of manaflow-ai/cmux#18661
/// (Go to File quick open, which covers local workspaces only).
@MainActor
final class GoToFilePaletteModel: ObservableObject {
    nonisolated static let maxResults = 200

    /// Paths relative to the session root, best first.
    @Published private(set) var results: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTruncated = false
    @Published private(set) var selectedIndex = 0

    private(set) var source: GoToFileSnapshotSource?
    private(set) var workspaceId: UUID?
    /// The Files root the session was resolved from; SSH opens bind previews to it.
    private(set) var workspaceRoot: FileExplorerWorkspaceRoot?
    /// Serves SSH previews when the Files sidebar shows another workspace.
    private(set) lazy var remotePreviewStore = FileExplorerStore()
    private var snapshot: GoToFileSnapshot?
    /// Stub for the failing tests: nothing is queued yet.
    private(set) var opensWhenRanked = false
    var onDeferredOpen: ((String) -> Void)?

    func openSelectionOrQueue() -> String? { selectedRelativePath }
    private var query = ""
    private var resultsQuery: String?
    private var generation: UInt64 = 0
    private var snapshotTask: Task<Void, Never>?
    private var rankTask: Task<Void, Never>?
    private let loadSnapshot: @Sendable (GoToFileSnapshotSource) async throws -> GoToFileSnapshot

    init(
        loadSnapshot: @escaping @Sendable (GoToFileSnapshotSource) async throws -> GoToFileSnapshot = {
            try await GoToFileSnapshotLoader.load($0)
        }
    ) {
        self.loadSnapshot = loadSnapshot
    }

    var isActive: Bool { source != nil }

    /// Starts a session and lists the root once.
    func begin(source: GoToFileSnapshotSource, workspaceId: UUID, workspaceRoot: FileExplorerWorkspaceRoot? = nil) {
        end()
        self.source = source
        self.workspaceId = workspaceId
        self.workspaceRoot = workspaceRoot
        isLoading = true
        generation &+= 1
        let sessionGeneration = generation
        let loadSnapshot = loadSnapshot
        snapshotTask = Task { [weak self] in
            let outcome: Result<GoToFileSnapshot, Error>
            do {
                outcome = .success(try await loadSnapshot(source))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishSnapshot(outcome, generation: sessionGeneration)
        }
    }

    /// Re-ranks the session snapshot for a new query.
    func update(query: String) {
        self.query = query
        guard isActive else { return }
        rank()
    }

    /// Ends the session and cancels its listing and ranking.
    func end() {
        generation &+= 1
        snapshotTask?.cancel()
        rankTask?.cancel()
        snapshotTask = nil
        rankTask = nil
        source = nil
        workspaceId = nil
        workspaceRoot = nil
        snapshot = nil
        query = ""
        resultsQuery = nil
        results = []
        isLoading = false
        errorMessage = nil
        isTruncated = false
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) -> Bool {
        guard !results.isEmpty else { return false }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        return true
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// The selected path, only when the results belong to the current query.
    var selectedRelativePath: String? {
        guard resultsQuery == query, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    /// The absolute path of a result on the session's host.
    func absolutePath(forRelativePath relativePath: String) -> String? {
        guard let root = source?.rootPath, !root.isEmpty else { return nil }
        return root == "/" ? "/" + relativePath : root + "/" + relativePath
    }

    private func finishSnapshot(_ outcome: Result<GoToFileSnapshot, Error>, generation sessionGeneration: UInt64) {
        guard sessionGeneration == generation else { return }
        snapshotTask = nil
        switch outcome {
        case .success(let snapshot):
            self.snapshot = snapshot
            isTruncated = snapshot.isTruncated
            rank()
        case .failure(let error):
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func rank() {
        guard let snapshot else { return }
        generation &+= 1
        let rankGeneration = generation
        let query = query
        rankTask?.cancel()
        isLoading = true
        let paths = snapshot.paths
        let worker = Task.detached(priority: .userInitiated) {
            GoToFileRanker.rank(
                paths: paths,
                query: query,
                limit: GoToFilePaletteModel.maxResults,
                shouldCancel: { Task.isCancelled }
            )
        }
        rankTask = Task { [weak self] in
            let ranked = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, rankGeneration == self.generation else { return }
            self.results = ranked
            self.resultsQuery = query
            self.selectedIndex = 0
            self.isLoading = false
            self.rankTask = nil
        }
    }
}
