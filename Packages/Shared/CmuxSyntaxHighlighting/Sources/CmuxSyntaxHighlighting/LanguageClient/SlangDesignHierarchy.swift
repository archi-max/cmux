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
        // A module no instance of the design elaborates gets paths with an empty instance part (`.x`).
        return (result.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.hasPrefix(".") && seen.insert($0).inserted }
    }

    /// Hierarchical paths of the symbol `identifier` at `position`, one per
    /// instance it is elaborated in. Unlike `slangInstancePaths`, this also
    /// places symbols of an `` `include ``d fragment (a file with no module of
    /// its own, which slang cannot place by position): through the
    /// declaration a symbol of the includer resolves to, else by walking the
    /// design for the scopes that include the file.
    ///
    /// A symbol inside a module is only placed by position: a module that is
    /// not under the top is not in the design, whatever its ports connect to.
    /// `isInModule` nil: read from the open document's text.
    /// `willSearch` runs before the (slower) walk of the design.
    ///
    /// Server errors other than an unresolvable path are thrown, so a timeout
    /// or a stopped server is not reported as "not in the design".
    public func slangDesignPaths(
        uri: URL,
        position: LSPPosition,
        identifier: String,
        isInModule: Bool? = nil,
        searchTimeLimit: TimeInterval = 10,
        willSearch: (@Sendable () async -> Void)? = nil
    ) async throws -> [String] {
        let direct = try await slangInstancePaths(uri: uri, position: position)
        guard direct.isEmpty else { return direct }
        guard !(isInModule ?? documentIsInModule(uri, at: position)) else { return [] }
        let file = uri.standardizedFileURL.path
        var includesFile: [String: Bool] = [:]
        var throughIncludeDirectory: [String]?
        // A symbol the includer declares: its declaration's paths, kept where the
        // declaring scope includes this file (not, say, every instance's port).
        let declarations = try await definitionSkippingUnresolved(uri: uri, position: position)
        for declaration in declarations.prefix(4) {
            if declaration.uri.standardizedFileURL.path == file, declaration.range.start.line == position.line,
               declaration.range.start.character <= position.character,
               position.character <= declaration.range.end.character {
                continue
            }
            let paths = try await instancePathsSkippingUnresolved(uri: declaration.uri, position: declaration.range.start)
            guard !paths.isEmpty else { continue }
            var kept: [String] = []
            for path in paths.prefix(Self.fragmentSearchResultLimit) {
                let parent = Self.parentPath(of: path)
                if includesFile[parent] == nil {
                    let children = try await scopeChildrenSkippingUnresolved(parent)
                    includesFile[parent] = !parent.isEmpty && children.contains { $0.location?.uri.standardizedFileURL.path == file }
                }
                if includesFile[parent] == true { kept.append(path) }
            }
            if !kept.isEmpty { return kept }
            // A fragment that declares nothing (only assigns or always blocks) has nothing in the
            // declaring scope to find it by: placed when the declaring file `include`s it, by
            // path or through a macro that expands to it.
            switch await includeMatch(of: uri, inDeclaringFile: declaration.uri) {
            case .exact?: return Array(paths.prefix(Self.fragmentSearchResultLimit))
            case .suffix?: if throughIncludeDirectory == nil { throughIncludeDirectory = Array(paths.prefix(Self.fragmentSearchResultLimit)) }
            case nil: break
            }
        }
        if let throughIncludeDirectory { return throughIncludeDirectory }
        guard !identifier.isEmpty else { return [] }
        await willSearch?()
        return try await slangFragmentPaths(of: identifier, inFile: uri, timeLimit: searchTimeLimit)
    }

    /// How an `` `include `` names a fragment: by its path (next to the includer, or absolute), or
    /// only by a path ending the fragment's (found through an include directory, or not checkable).
    enum IncludeMatch: Equatable {
        case exact
        case suffix
    }

    /// Macro includes of one declaring file read through a hover at most (one request each).
    private static let macroIncludeLimit = 16

    /// How the file at `declaringURI` `` `include ``s `fragment`, the best of its directives. A
    /// macro (`` `include `TB_FILE ``, often defined in the build file) counts through its
    /// expansion, which slang-server's hover shows. Read from the open document, else from disk
    /// for a local server; nil when the text is not at hand.
    private func includeMatch(of fragment: URL, inDeclaringFile declaringURI: URL) async -> IncludeMatch? {
        var text = documentText(declaringURI)
        if text == nil, case .local = launch {
            text = try? String(contentsOf: declaringURI, encoding: .utf8)
        }
        guard let text else { return nil }
        let file = serverPath(for: fragment)
        let declaringFile = serverPath(for: declaringURI)
        let fileExists: ((String) -> Bool)? = launch.isRemote ? nil : { FileManager.default.fileExists(atPath: $0) }
        var best: IncludeMatch?
        var macros = 0
        for directive in Self.includeDirectiveLocations(in: text) {
            var target = directive.target
            if target.hasPrefix("`") {
                guard macros < Self.macroIncludeLimit else { continue }
                macros += 1
                // A macro slang can't expand here is no evidence either way.
                guard let hover = try? await hover(uri: declaringURI, position: directive.position),
                      let expansion = Self.macroIncludeTarget(fromHover: hover) else { continue }
                target = expansion
            }
            switch Self.includeMatch(target: target, declaringFile: declaringFile, file: file, fileExists: fileExists) {
            case .exact?: return .exact
            case .suffix?: best = .suffix
            case nil: break
            }
        }
        return best
    }

    /// Whether the include target `target` of `declaringFile` is `file` (server paths). slang looks
    /// next to the includer first, then in the include directories, which cmux doesn't know: a
    /// relative target ending `file`'s path matches as `.suffix`, unless `fileExists` says the
    /// file next to the includer exists (that one is included). `fileExists` nil: can't check.
    static func includeMatch(target: String, declaringFile: String, file: String, fileExists: ((String) -> Bool)?) -> IncludeMatch? {
        func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        let file = standardized(file)
        guard !target.isEmpty else { return nil }
        if target.hasPrefix("/") { return standardized(target) == file ? .exact : nil }
        let besideIncluder = standardized(((declaringFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target))
        if besideIncluder == file { return .exact }
        if fileExists?(besideIncluder) == true { return nil }
        let components = target.split(separator: "/").filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return file.hasSuffix("/" + components.joined(separator: "/")) ? .suffix : nil
    }

    /// The file a macro expands to, from slang-server's hover on its use: the code block after
    /// "Expands to", without its quotes (`"file.sv"` or `<file.sv>`). Nil for anything else.
    static func macroIncludeTarget(fromHover hover: String) -> String? {
        guard let expands = hover.range(of: "Expands to") else { return nil }
        var lines = hover[expands.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        guard let fence = lines.first, fence.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return nil }
        lines = lines.dropFirst()
        let body = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard body.count >= 3,
              (body.hasPrefix("\"") && body.hasSuffix("\"")) || (body.hasPrefix("<") && body.hasSuffix(">")) else { return nil }
        let target = String(body.dropFirst().dropLast())
        return target.isEmpty ? nil : target
    }

    /// The targets of a text's `` `include `` directives: `"file.sv"`, `<file.sv>` or `` `MACRO ``,
    /// without their quotes. Directives in `//` and `/* */` comments and in strings are skipped.
    static func includeDirectives(in text: String) -> [String] {
        includeDirectiveLocations(in: text).map(\.target)
    }

    /// `includeDirectives` with where each target starts (for a macro: inside its name).
    static func includeDirectiveLocations(in text: String) -> [(target: String, position: LSPPosition)] {
        let units = Array(text.utf16)
        let slash = UInt16(UInt8(ascii: "/")), star = UInt16(UInt8(ascii: "*")), quote = UInt16(UInt8(ascii: "\""))
        let newline = UInt16(UInt8(ascii: "\n")), backslash = UInt16(UInt8(ascii: "\\")), tick = UInt16(UInt8(ascii: "`"))
        let less = UInt16(UInt8(ascii: "<")), greater = UInt16(UInt8(ascii: ">"))
        let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
        let keyword = Array("`include".utf16)
        func isIdentifier(_ unit: UInt16) -> Bool {
            guard unit < 128 else { return false }
            let c = Character(Unicode.Scalar(UInt8(unit)))
            return c.isLetter || c.isNumber || c == "_" || c == "$"
        }
        var targets: [(target: String, position: LSPPosition)] = []
        var index = 0
        var line = 0
        var lineStart = 0
        func advance() {
            if units[index] == newline { line += 1; lineStart = index + 1 }
            index += 1
        }
        while index < units.count {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if unit == slash, next == slash {
                while index < units.count, units[index] != newline { index += 1 }
            } else if unit == slash, next == star {
                index += 2
                while index < units.count, !(units[index] == star && index + 1 < units.count && units[index + 1] == slash) { advance() }
                index = min(index + 2, units.count)
            } else if unit == quote {
                index += 1
                while index < units.count, units[index] != quote, units[index] != newline {
                    // An escape (or a line continuation, which `advance` counts) is skipped whole.
                    if units[index] == backslash { index += 1 }
                    if index < units.count { advance() }
                }
                if index < units.count, units[index] == quote { index += 1 }
            } else if unit == tick, units[index...].starts(with: keyword),
                      index + keyword.count >= units.count || !isIdentifier(units[index + keyword.count]) {
                index += keyword.count
                while index < units.count, units[index] == space || units[index] == tab { index += 1 }
                guard index < units.count else { break }
                let open = units[index]
                let start: Int
                var end: Int
                switch open {
                case quote, less:
                    let close = open == quote ? quote : greater
                    start = index + 1
                    end = start
                    while end < units.count, units[end] != close, units[end] != newline { end += 1 }
                    index = end < units.count && units[end] == close ? end + 1 : end
                case tick:
                    start = index
                    end = index + 1
                    while end < units.count, isIdentifier(units[end]) { end += 1 }
                    index = end
                default:
                    continue
                }
                if end > start + (open == tick ? 1 : 0) {
                    let target = String(decoding: units[start..<end], as: UTF16.self)
                    let column = start - lineStart + (open == tick ? 1 : 0)
                    targets.append((target, LSPPosition(line: line, character: column)))
                }
            } else {
                advance()
            }
        }
        return targets
    }

    /// Whether `position` of the open document is inside a module, interface or program
    /// (false for an `` `include ``d fragment, and when the document is not open).
    private func documentIsInModule(_ uri: URL, at position: LSPPosition) -> Bool {
        guard let text = documentText(uri) else { return false }
        var offset = 0
        var line = 0
        let units = Array(text.utf16)
        while line < position.line, offset < units.count {
            if units[offset] == 0x0A { line += 1 }
            offset += 1
        }
        offset = min(offset + position.character, units.count)
        return SystemVerilogInlineScan.lines(in: text, range: NSRange(location: offset, length: 0)).first?.module != nil
    }

    /// `path` without its last component (`a.b[0]` → `a.b`, `a.b` → `a`, `a` → ``).
    static func parentPath(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "." || $0 == "[" }) else { return "" }
        return String(path[..<index])
    }

    /// The JSON-RPC internal error slang-server answers a path it cannot resolve with.
    private static let unresolvedPathCode = -32603

    /// Whether slang-server answered that it could not resolve the path (the walk skips those).
    static func isUnresolvedPath(_ error: any Error) -> Bool {
        if case LanguageServerError.responseError(let code, _) = error { return code == unresolvedPathCode }
        return false
    }

    private func definitionSkippingUnresolved(uri: URL, position: LSPPosition) async throws -> [LSPLocation] {
        do { return try await definition(uri: uri, position: position) } catch where Self.isUnresolvedPath(error) { return [] }
    }

    private func instancePathsSkippingUnresolved(uri: URL, position: LSPPosition) async throws -> [String] {
        do { return try await slangInstancePaths(uri: uri, position: position) } catch where Self.isUnresolvedPath(error) { return [] }
    }

    /// A walk's getScope: its timeout means the scope is too big to read, not a hung server.
    private func scopeChildrenSkippingUnresolved(_ path: String) async throws -> [SlangHierarchyItem] {
        do {
            return try await slangScopeChildren(path, timeout: Self.walkRequestTimeout, countsTowardWedged: false)
        } catch where Self.isUnresolvedPath(error) {
            return []
        }
    }

    /// Per getScope of the walk; shorter than an ordinary request, so a slow scope can't use the whole walk.
    private static let walkRequestTimeout: TimeInterval = 5

    /// Scopes `slangFragmentPaths` reads at most, how deep it goes, how many it reads at once.
    private static let fragmentSearchScopeLimit = 300
    private static let fragmentSearchDepthLimit = 12
    private static let fragmentSearchResultLimit = 64
    /// slang-server answers one request at a time; more in flight only queue (and time out together).
    private static let fragmentSearchConcurrency = 2

    /// Paths of `identifier` in the scopes `file` is included into: a child
    /// of that name declared in the file, else (for a name the includer
    /// declares) a child of that name of a scope with anything declared in
    /// the file. Breadth first from the design's tops, a level at a time
    /// (`fragmentSearchConcurrency` scopes at once); stops below the first
    /// level with a match, and after `timeLimit` with what it found.
    private func slangFragmentPaths(of identifier: String, inFile uri: URL, timeLimit: TimeInterval) async throws -> [String] {
        let file = uri.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(timeLimit)
        var declaredInFile: [String] = []
        var inIncludingScope: [String] = []
        var level = [""]
        var visited = 0
        for depth in 0...Self.fragmentSearchDepthLimit {
            var next: [String] = []
            var index = 0
            while index < level.count, visited < Self.fragmentSearchScopeLimit, Date() < deadline {
                try Task.checkCancellation()
                let batch = Array(level[index..<min(level.count, index + Self.fragmentSearchConcurrency, index + Self.fragmentSearchScopeLimit - visited)])
                index += batch.count
                visited += batch.count
                let results = try await withThrowingTaskGroup(of: (Int, [SlangHierarchyItem]).self) { group in
                    for (offset, path) in batch.enumerated() {
                        group.addTask {
                            // A scope slang cannot resolve by path is skipped; other errors end the walk.
                            (offset, try await self.scopeChildrenSkippingUnresolved(path))
                        }
                    }
                    var results = [[SlangHierarchyItem]](repeating: [], count: batch.count)
                    for try await (offset, children) in group { results[offset] = children }
                    return results
                }
                for (path, children) in zip(batch, results) {
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
                            next.append(childPath)
                        }
                    }
                }
                if declaredInFile.count + inIncludingScope.count >= Self.fragmentSearchResultLimit { break }
            }
            // Instances of the includer deeper down are found through the shallowest ones.
            if !declaredInFile.isEmpty || !inIncludingScope.isEmpty || next.isEmpty
                || visited >= Self.fragmentSearchScopeLimit || Date() >= deadline {
                break
            }
            level = next
        }
        let found = declaredInFile.isEmpty ? inIncludingScope : declaredInFile
        return Array(found.prefix(Self.fragmentSearchResultLimit))
    }

    /// Children of the scope at `hierPath`; the empty path lists the design's top instances.
    /// Empty when the path does not resolve or there is no full compilation.
    public func slangScopeChildren(_ hierPath: String) async throws -> [SlangHierarchyItem] {
        try await slangScopeChildren(hierPath, timeout: nil, countsTowardWedged: true)
    }

    func slangScopeChildren(_ hierPath: String, timeout: TimeInterval?, countsTowardWedged: Bool) async throws -> [SlangHierarchyItem] {
        let result = try await executeCommand("slang.getScope", argument: .string(hierPath), timeout: timeout, countsTowardWedged: countsTowardWedged)
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
