import Foundation

/// What the state machine engines need to know about a state register, from slang-server.
public struct SlangFsmContext: Sendable, Equatable {
    /// The module the instance is of.
    public var module: String
    /// The register's width.
    public var width: Int
    /// Its enum type, if it has one.
    public var enumType: SlangEnumType?
    /// The instance's parameters and localparams as elaborated (`slang.getScope` `Param` items).
    public var parameters: [FsmNaming.Param]
    /// The files Yosys needs to elaborate the module (server paths): every package's, the
    /// module's, and the modules' of the instances below it. Not the testbench's, which
    /// synthesis can't read.
    public var files: [String]
}

extension LanguageServerSession {
    /// The context of register `signal` in design instance `instance` (`tb.dut.u_ctl`), or nil
    /// when the instance has no such variable or slang can't say its module.
    public func slangFsmContext(instance: String, signal: String) async throws -> SlangFsmContext? {
        let items = try await executeCommand("slang.getScope", argument: .string(instance)).arrayValue ?? []
        var width: Int?
        var parameters: [FsmNaming.Param] = []
        for item in items {
            guard let name = item["instName"]?.stringValue, let kind = item["kind"]?.stringValue else { continue }
            let type = item["type"]?.stringValue ?? ""
            if kind == "Param", let value = item["value"]?.stringValue {
                parameters.append(.init(name: name, type: type, value: value))
            } else if name == signal, kind == "Logic" || kind == "Port" {
                width = Self.fsmWidth(ofType: type)
            }
        }
        guard let width else { return nil }
        let enumType = try await slangEnumSignals(inScope: instance, cache: SlangEnumTypeCache())[signal].flatMap { $0.isArray ? nil : $0.type }

        // Every instance's module (getScopesByModule names one instance per module; modules
        // with more are asked for theirs).
        let modules = try await executeCommand("slang.getScopesByModule", argument: nil).arrayValue ?? []
        var moduleOf: [String: String] = [:]
        var fileOf: [String: String] = [:]
        for entry in modules {
            guard let declName = entry["declName"]?.stringValue else { continue }
            if let uri = entry["declLoc"]?["uri"]?.stringValue, let url = URL(string: uri) { fileOf[declName] = url.path }
            let count = entry["instCount"]?.intValue ?? 1
            if count <= 1, let path = entry["inst"]?["instPath"]?.stringValue {
                moduleOf[path] = declName
            } else {
                for inst in try await executeCommand("slang.getInstancesOfModule", argument: .string(declName)).arrayValue ?? [] {
                    if let path = inst["instPath"]?.stringValue { moduleOf[path] = declName }
                }
            }
        }
        guard let module = moduleOf[instance] else { return nil }
        var files: [String] = []
        let add = { (path: String) in if !files.contains(path) { files.append(path) } }
        for package in try await slangScopeChildren("").filter({ $0.kind == "Package" }).map(\.name) {
            for path in try await slangFilesContainingModule(package) { add(path) }
        }
        if let file = fileOf[module] { add(file) }
        let prefix = instance + "."
        for (path, name) in moduleOf.sorted(by: { $0.key < $1.key }) where path.hasPrefix(prefix) {
            if let file = fileOf[name] { add(file) }
        }
        return SlangFsmContext(module: module, width: width, enumType: enumType, parameters: parameters, files: files)
    }

    /// `Enum state_t (logic[2:0])` -> 3, `logic[1:0]` -> 2, `input logic` -> 1.
    static func fsmWidth(ofType type: String) -> Int? {
        if case .named(_, let width)? = SlangEnumValues.scopeType(type) { return width }
        if case .anonymous(let enumType)? = SlangEnumValues.scopeType(type) { return enumType.width }
        let base = type.replacingOccurrences(of: "input ", with: "").replacingOccurrences(of: "output ", with: "")
            .replacingOccurrences(of: "inout ", with: "")
        return SlangEnumValues.baseWidth(base.trimmingCharacters(in: .whitespaces))
    }
}
