import Foundation

/// Driver tracing's design model from a VCS KDB (not built yet).
public struct KDBDesignModel: @unchecked Sendable {
    public struct Write: Equatable, Sendable {
        public let kind: String
        public let file: String
        public let line: Int
        public init(kind: String, file: String, line: Int) {
            self.kind = kind
            self.file = file
            self.line = line
        }
    }
    public let tops: [String] = []
    public let instancePaths: [String] = []
    public init?(json: Data) { return nil }
    public func instance(_ path: String) -> [String: Any]? { nil }
    public func lookup(_ path: String) -> (instance: String, name: String)? { nil }
    public func hasSignal(_ path: String) -> Bool { false }
    public func writes(of path: String) -> [Write] { [] }
    public func aliasPairs(limit: Int = .max) -> [[String]] { [] }
}

/// How cmux exports the KDB model on an SSH host (not built yet).
public enum KDBModelLaunch {
    public enum Outcome: Equatable {
        case model(KDBDesignModel, cached: Bool)
        case unavailable(code: String, message: String)
        public static func == (a: Outcome, b: Outcome) -> Bool {
            switch (a, b) {
            case (.unavailable(let c1, let m1), .unavailable(let c2, let m2)): return c1 == c2 && m1 == m2
            case (.model(let x, let c1), .model(let y, let c2)): return c1 == c2 && x.instancePaths == y.instancePaths
            default: return false
            }
        }
    }
    public static func command(launcher: Data, exporter: Data, fsdbPath: String) -> String { "" }
    public static func parse(output: Data) -> Outcome { .unavailable(code: "", message: "") }
}
