import Foundation

extension SVModelResolve {
    /// Not built yet: today's resolve.
    public static func resolve(
        dumpPath: [String],
        mapping: HierarchyPathMapping,
        loadMessages: [String] = [],
        lookup: Lookup,
        model: Model,
        designRoots: () async throws -> [String: [HierarchyNode]],
        dumpChildren: HierarchyPrefixInference.Children,
        kdb: KDBDesignModel?,
        instances: () async throws -> [String],
        log: (String) -> Void = { _ in },
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Outcome {
        try await resolve(dumpPath: dumpPath, mapping: mapping, loadMessages: loadMessages, lookup: lookup, model: model,
                          designRoots: designRoots, dumpChildren: dumpChildren)
    }
}
