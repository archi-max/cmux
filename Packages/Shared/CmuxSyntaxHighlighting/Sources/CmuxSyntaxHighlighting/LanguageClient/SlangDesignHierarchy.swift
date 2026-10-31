import Foundation

/// One child of a scope in slang-server's elaborated design (`slang.getScope`).
public struct SlangHierarchyItem: Sendable, Equatable {
    /// Instance, generate block or variable name within its parent scope.
    public var name: String
    /// slang's kind name (`Instance`, `Scope`, `Port`, `Logic`, `Param`, ...).
    public var kind: String
    /// Where the item is declared: the identifier for variables and ports, the instantiation for instances.
    public var location: LSPLocation?

    public init(name: String, kind: String, location: LSPLocation?) {
        self.name = name
        self.kind = kind
        self.location = location
    }

    /// Whether the item has children of its own (an instance, generate block or interface port).
    public var isScope: Bool {
        switch kind {
        case "Instance", "Scope", "ScopeArray", "InterfacePort", "InterfacePortArray", "InstanceArray", "Package":
            return true
        default:
            return false
        }
    }
}

/// slang-server's design commands (`workspace/executeCommand`), used by the
/// SystemVerilog editor ↔ waveform link. They answer from the full
/// compilation, which exists only once a top level or build file is set.
extension LanguageServerSession {
    /// Elaborating a large design for a new top level takes longer than an ordinary request.
    private static let setTopLevelTimeout: TimeInterval = 120

    /// Hierarchical paths of the signal or instance at `position`, one per
    /// instance of the enclosing module (`slang.getInstances`).
    public func slangInstancePaths(uri: URL, position: LSPPosition) async throws -> [String] {
        let result = try await executeCommand("slang.getInstances", argument: positionParams(uri: uri, position: position))
        var seen = Set<String>()
        return (result.arrayValue ?? []).compactMap(\.stringValue).filter { seen.insert($0).inserted }
    }

    /// Hierarchical paths of the symbol `identifier` at `position`, one per
    /// instance it is elaborated in. Unlike `slangInstancePaths`, this also
    /// places symbols of an `` `include ``d fragment (a file with no module of
    /// its own, which slang cannot place by position).
    public func slangDesignPaths(uri: URL, position: LSPPosition, identifier: String) async throws -> [String] {
        let direct = try await slangInstancePaths(uri: uri, position: position)
        guard direct.isEmpty else { return direct }
        // A symbol the includer (or another module) declares: place its declaration.
        let file = uri.standardizedFileURL.path
        for declaration in (try? await definition(uri: uri, position: position)) ?? [] {
            if declaration.uri.standardizedFileURL.path == file, declaration.range.start.line == position.line,
               declaration.range.start.character <= position.character,
               position.character <= declaration.range.end.character {
                continue
            }
            let paths = try await slangInstancePaths(uri: declaration.uri, position: declaration.range.start)
            if !paths.isEmpty { return paths }
        }
        guard !identifier.isEmpty else { return [] }
        return try await slangFragmentPaths(of: identifier, inFile: uri)
    }

    /// Scopes `slangFragmentPaths` reads at most, and how deep it goes.
    private static let fragmentSearchScopeLimit = 300
    private static let fragmentSearchDepthLimit = 12
    private static let fragmentSearchResultLimit = 64

    /// Paths of `identifier` in the scopes `file` is included into: a child
    /// of that name declared in the file, else (for a name the includer
    /// declares) a child of that name of a scope with anything declared in
    /// the file. Breadth first from the design's tops, bounded.
    private func slangFragmentPaths(of identifier: String, inFile uri: URL) async throws -> [String] {
        let file = uri.standardizedFileURL.path
        var declaredInFile: [String] = []
        var inIncludingScope: [String] = []
        var queue: [(path: String, depth: Int)] = [("", 0)]
        var visited = 0
        while !queue.isEmpty, visited < Self.fragmentSearchScopeLimit {
            try Task.checkCancellation()
            let (path, depth) = queue.removeFirst()
            visited += 1
            // A scope slang cannot resolve by path is skipped, not fatal.
            guard let children = try? await slangScopeChildren(path) else { continue }
            let includesFile = !path.isEmpty && children.contains { $0.location?.uri.standardizedFileURL.path == file }
            for child in children {
                // Array elements are named `[0]` and join without a dot.
                let childPath = path.isEmpty || child.name.hasPrefix("[") ? path + child.name : path + "." + child.name
                if child.name == identifier, !path.isEmpty {
                    if child.location?.uri.standardizedFileURL.path == file {
                        declaredInFile.append(childPath)
                    } else if includesFile {
                        inIncludingScope.append(childPath)
                    }
                }
                if child.isScope, child.kind != "Package", depth < Self.fragmentSearchDepthLimit {
                    queue.append((childPath, depth + 1))
                }
            }
            if declaredInFile.count + inIncludingScope.count >= Self.fragmentSearchResultLimit { break }
        }
        return declaredInFile.isEmpty ? inIncludingScope : declaredInFile
    }

    /// Children of the scope at `hierPath`; the empty path lists the design's top instances.
    /// Empty when the path does not resolve or there is no full compilation.
    public func slangScopeChildren(_ hierPath: String) async throws -> [SlangHierarchyItem] {
        let result = try await executeCommand("slang.getScope", argument: .string(hierPath))
        return (result.arrayValue ?? []).compactMap { item in
            guard let name = item["instName"]?.stringValue else { return nil }
            let kind = item["kind"]?.stringValue ?? item["kind"]?.intValue.map(Self.slangKindName(_:)) ?? ""
            var location: LSPLocation?
            if let uri = item["instLoc"]?["uri"]?.stringValue,
               let range = LSPResponseDecoding.range(item["instLoc"]?["range"]),
               let url = editorURL(forServerURI: uri) {
                location = LSPLocation(uri: url, range: range)
            }
            return SlangHierarchyItem(name: name, kind: kind, location: location)
        }
    }

    /// Server paths of the indexed files that define module `name`. Works without a full compilation.
    public func slangFilesContainingModule(_ name: String) async throws -> [String] {
        let result = try await executeCommand("slang.getFilesContainingModule", argument: .string(name))
        return (result.arrayValue ?? []).compactMap(\.stringValue)
    }

    /// Elaborates the design rooted at the top module in `serverPath`, replacing explore mode.
    public func slangSetTopLevel(_ serverPath: String) async throws {
        _ = try await executeCommand("slang.setTopLevel", argument: .string(serverPath), timeout: Self.setTopLevelTimeout)
    }

    /// slang's `SlangKind` order, for servers that send the enum as a number.
    private static func slangKindName(_ value: Int) -> String {
        let names = ["Instance", "Scope", "ScopeArray", "InterfacePort", "InterfacePortArray", "Port", "Param", "Logic",
                     "InstanceArray", "Package"]
        return names.indices.contains(value) ? names[value] : ""
    }
}
