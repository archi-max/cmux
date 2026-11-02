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
    /// Index into the rows: the typed-path row first when there is one, then ``results``.
    @Published private(set) var selectedIndex = 0
    /// The path the query names (``GoToFileTypedPath``), shown as a top
    /// "Open <path>" row; it opens without the listing.
    @Published private(set) var typedPath: String?

    private(set) var source: GoToFileSnapshotSource?
    private(set) var workspaceId: UUID?
    /// The Files root the session was resolved from; SSH opens bind previews to it.
    private(set) var workspaceRoot: FileExplorerWorkspaceRoot?
    /// Serves SSH previews when the Files sidebar shows another workspace.
    private(set) lazy var remotePreviewStore = FileExplorerStore()
    /// The root last applied to ``remotePreviewStore``; kept across sessions with the store.
    var remotePreviewRoot: FileExplorerWorkspaceRoot?
    private var snapshot: GoToFileSnapshot?
    /// The snapshot prepared for ranking, built once per session off the main actor.
    private var index: GoToFileRanker.Index?
    /// The last finished ranking and its query, to narrow a query that only grows.
    private var lastRanking: (query: String, ranking: GoToFileRanker.Ranking)?
    /// Enter was pressed before the current query's ranking landed.
    private(set) var opensWhenRanked = false
    /// Called with the top result when a queued Enter's ranking lands.
    var onDeferredOpen: ((String) -> Void)?
    private var query = ""
    private var resultsQuery: String?
    private var generation: UInt64 = 0
    private var snapshotTask: Task<Void, Never>?
    private var rankTask: Task<Void, Never>?
    private let loadSnapshot: @Sendable (GoToFileSnapshotSource) async throws -> GoToFileSnapshot

    init(
        loadSnapshot: @escaping @Sendable (GoToFileSnapshotSource) async throws -> GoToFileSnapshot = {
            try await GoToFileSnapshotLoader.cachedLoad($0)
        }
    ) {
        self.loadSnapshot = loadSnapshot
    }

    var isActive: Bool { source != nil }

    /// False for a typed-paths-only session (no Files root): nothing is listed.
    private(set) var listsFiles = true
    /// The source terminal's live directory, for `./` and `../` in a
    /// typed-paths-only session; nil when typed paths use the root.
    private(set) var liveRoot: (@MainActor () async -> String?)?

    /// Starts a session and lists the root once, unless `listsFiles` is
    /// false (typed paths only, `liveRoot` for relative ones).
    func begin(
        source: GoToFileSnapshotSource,
        workspaceId: UUID,
        workspaceRoot: FileExplorerWorkspaceRoot? = nil,
        listsFiles: Bool = true,
        liveRoot: (@MainActor () async -> String?)? = nil
    ) {
        end()
        self.source = source
        self.workspaceId = workspaceId
        self.workspaceRoot = workspaceRoot
        self.listsFiles = listsFiles
        self.liveRoot = liveRoot
        guard listsFiles else { return }
        isLoading = true
        generation &+= 1
        let sessionGeneration = generation
        let loadSnapshot = loadSnapshot
        snapshotTask = Task { [weak self] in
            let outcome: Result<(GoToFileSnapshot, GoToFileRanker.Index), Error>
            do {
                let snapshot = try await loadSnapshot(source)
                // Prepared once, off the main actor; every keystroke reuses it.
                let index = await Task.detached(priority: .userInitiated) {
                    GoToFileRanker.Index(paths: snapshot.paths)
                }.value
                outcome = .success((snapshot, index))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishSnapshot(outcome, generation: sessionGeneration)
        }
    }

    /// Re-ranks the session snapshot for a new query.
    func update(query: String) {
        // An Enter queued for the previous query must not open a match for this one.
        if query != self.query { opensWhenRanked = false }
        self.query = query
        guard isActive else { return }
        let typed = GoToFileTypedPath.parse(query)
        if typed != typedPath {
            typedPath = typed
            selectedIndex = 0
        }
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
        listsFiles = true
        liveRoot = nil
        snapshot = nil
        index = nil
        lastRanking = nil
        opensWhenRanked = false
        query = ""
        resultsQuery = nil
        typedPath = nil
        results = []
        isLoading = false
        errorMessage = nil
        isTruncated = false
        selectedIndex = 0
    }

    /// Rows above ``results``: the typed-path row.
    var resultRowOffset: Int { typedPath == nil ? 0 : 1 }

    func moveSelection(by delta: Int) -> Bool {
        let rows = results.count + resultRowOffset
        guard rows > 0 else { return false }
        selectedIndex = min(max(selectedIndex + delta, 0), rows - 1)
        return true
    }

    /// Selects row `index` (the typed-path row is 0 when shown).
    func select(index: Int) {
        guard index >= 0, index < results.count + resultRowOffset else { return }
        selectedIndex = index
    }

    /// The typed path, when its row is selected.
    var selectedTypedPath: String? {
        guard let typedPath, selectedIndex == 0 else { return nil }
        return typedPath
    }

    /// The selected path, only when the results belong to the current query.
    var selectedRelativePath: String? {
        let index = selectedIndex - resultRowOffset
        guard resultsQuery == query, results.indices.contains(index) else { return nil }
        return results[index]
    }

    /// The selected path when results are current; otherwise queues Enter so
    /// ``onDeferredOpen`` gets the top result once the ranking lands.
    func openSelectionOrQueue() -> String? {
        // The typed-path row opens through ``selectedTypedPath``, never queued.
        if selectedTypedPath != nil { return nil }
        if let selectedRelativePath { return selectedRelativePath }
        // Only while this query's ranking is still coming; an empty result stays empty.
        if isActive, listsFiles, errorMessage == nil, resultsQuery != query { opensWhenRanked = true }
        return nil
    }

    /// The absolute path of a result on the session's host.
    func absolutePath(forRelativePath relativePath: String) -> String? {
        guard let root = source?.rootPath, !root.isEmpty else { return nil }
        return root == "/" ? "/" + relativePath : root + "/" + relativePath
    }

    private func finishSnapshot(
        _ outcome: Result<(GoToFileSnapshot, GoToFileRanker.Index), Error>,
        generation sessionGeneration: UInt64
    ) {
        guard sessionGeneration == generation else { return }
        snapshotTask = nil
        switch outcome {
        case .success(let (snapshot, index)):
            self.snapshot = snapshot
            self.index = index
            isTruncated = snapshot.isTruncated
            rank()
        case .failure(let error):
            isLoading = false
            opensWhenRanked = false
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
        let preparedIndex = index
        // Typing more letters can only drop matches, so rank the last matches again.
        let within: [Int]? = lastRanking.flatMap { last in
            Self.normalized(query).hasPrefix(Self.normalized(last.query)) ? last.ranking.matches : nil
        }
        let paths = snapshot.paths
        let worker = Task.detached(priority: .userInitiated) { () -> (GoToFileRanker.Index, GoToFileRanker.Ranking) in
            let index = preparedIndex ?? GoToFileRanker.Index(paths: paths)
            let ranking = GoToFileRanker.rank(
                index: index,
                query: query,
                limit: GoToFilePaletteModel.maxResults,
                within: within,
                shouldCancel: { Task.isCancelled }
            )
            return (index, ranking)
        }
        rankTask = Task { [weak self] in
            let (index, ranking) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, rankGeneration == self.generation else { return }
            self.index = index
            self.lastRanking = (query, ranking)
            self.results = ranking.paths
            self.resultsQuery = query
            self.selectedIndex = 0
            self.isLoading = false
            self.rankTask = nil
            if self.opensWhenRanked {
                self.opensWhenRanked = false
                if let top = ranking.paths.first { self.onDeferredOpen?(top) }
            }
        }
    }

    /// The query as the ranker sees it (case and spaces ignored).
    private nonisolated static func normalized(_ query: String) -> String {
        String(query.filter { !$0.isWhitespace }).lowercased()
    }
}
