import Foundation

/// One signal of a driver cone (`slang.getDriversWithLocation`): a signal that
/// feeds the one asked about, with where that signal is declared.
public struct SlangConeEntry: Sendable, Equatable {
    /// The feeding signal's hierarchical path, for example `top.dut.ex_stg.ex_mem`
    /// when `top.dut.ex_mem` is connected to that instance's output port.
    public var path: String
    /// The feeding signal's declaration (not the statement that assigns it).
    public var location: LSPLocation?

    public init(path: String, location: LSPLocation?) {
        self.path = path
        self.location = location
    }
}

extension LanguageServerSession {
    /// The signals that drive the signal at `hierPath` in slang's elaborated design.
    /// Throws for a path the design does not have; needs a full compilation.
    public func slangDriverCone(_ hierPath: String) async throws -> [SlangConeEntry] {
        let result = try await executeCommand("slang.getDriversWithLocation", argument: .string(hierPath))
        return (result.arrayValue ?? []).compactMap { item in
            guard let path = item["path"]?.stringValue, !path.isEmpty else { return nil }
            var location: LSPLocation?
            // slang-server 0.3.1 sends the file relative to its working directory
            // (`file:///tmp/x/../../../home/...`): resolve the dots first.
            if let raw = item["location"]?["uri"]?.stringValue,
               let range = LSPResponseDecoding.range(item["location"]?["range"]),
               let standardized = URL(string: raw)?.standardized,
               let url = editorURL(forServerURI: standardized.absoluteString) {
                location = LSPLocation(uri: url, range: range)
            }
            return SlangConeEntry(path: path, location: location)
        }
    }
}
