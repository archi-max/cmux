import Combine
import Foundation

/// Placeholder API for the Go to File palette session; the implementation
/// follows in the next commit.
@MainActor
final class GoToFilePaletteModel: ObservableObject {
    @Published private(set) var results: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTruncated = false
    @Published private(set) var selectedIndex = 0
    private(set) var source: GoToFileSnapshotSource?

    init(loadSnapshot: @escaping @Sendable (GoToFileSnapshotSource) async throws -> GoToFileSnapshot = {
        try await GoToFileSnapshotLoader.load($0)
    }) {}

    var isActive: Bool { source != nil }

    func begin(source: GoToFileSnapshotSource, workspaceId: UUID) {}

    func update(query: String) {}

    func end() {}

    func moveSelection(by delta: Int) -> Bool { false }

    var selectedRelativePath: String? { nil }

    func absolutePath(forRelativePath relativePath: String) -> String? { nil }
}
