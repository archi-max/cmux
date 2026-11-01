import Foundation

// The waveform viewer's state machine view: one model, filled by whichever engine can run.
// - Verdi (the user's own installation on the dump's host, run time only): FSM recognition in
//   its netlist model, then nState's batch analysis `fsmAnalyzeFSM`, whose text report is
//   parsed here (`VerdiFsmReport`). cmux ships nothing of Verdi.
// - Yosys (ISC; an external tool the user installs, e.g. from OSS CAD Suite): `fsm_detect` and
//   `fsm_extract` on the instance's module, whose `$fsm` cells are read from `write_json`
//   (`YosysFsm`).
// - Otherwise the states slang gives (an enum's members, or localparams of the state's width)
//   and only the transitions the dump shows (`FsmModel.observed`).
// cmux's own code is the glue: parsing, names for codes (`FsmNaming`), and the view.

/// A state: its code (bits, most significant first) and name when one is known.
public struct FsmState: Sendable, Equatable, Hashable, Codable {
    public var bits: String
    public var name: String?

    public init(bits: String, name: String?) {
        self.bits = bits
        self.name = name
    }
}

/// A transition of the static graph: `from` is a code, or `*` for any code that is no state
/// (Verdi's Others). `condition` is the engine's text (`go`, `!stall`); nil when unconditional.
public struct FsmTransition: Sendable, Equatable, Hashable, Codable {
    public var from: String
    public var to: String
    public var condition: String?

    public init(from: String, to: String, condition: String?) {
        self.from = from
        self.to = to
        self.condition = condition
    }
}

public struct FsmCount: Sendable, Equatable, Hashable, Codable {
    public var from: String
    public var to: String
    public var count: Int

    public init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

/// Counts an engine reported over the whole dump (Verdi's: cycles per state, and per transition with self loops).
public struct FsmCounts: Sendable, Equatable, Codable {
    public var states: [String: Int]
    public var transitions: [FsmCount]
}

public enum FsmEngine: String, Sendable, Codable {
    case verdi
    case yosys
    case observed
}

public struct FsmModel: Sendable, Equatable, Codable {
    /// The state register's name in its scope (no range).
    public var signal: String
    public var width: Int
    public var states: [FsmState]
    /// The reset state's code.
    public var reset: String?
    /// The reset input, when the engine says which.
    public var resetSignal: String?
    /// The inputs the transitions depend on (the reset and clock left out).
    public var controls: [String]
    public var transitions: [FsmTransition]
    public var engine: FsmEngine
    public var counts: FsmCounts?

    public init(signal: String, width: Int, states: [FsmState], reset: String?, resetSignal: String?, controls: [String],
                transitions: [FsmTransition], engine: FsmEngine, counts: FsmCounts?) {
        self.signal = signal
        self.width = width
        self.states = states
        self.reset = reset
        self.resetSignal = resetSignal
        self.controls = controls
        self.transitions = transitions
        self.engine = engine
        self.counts = counts
    }

    public func name(of bits: String) -> String? {
        states.first { $0.bits == bits }?.name
    }

    /// No engine ran: the enum's members as the states, the transitions to come from the dump.
    public static func observed(signal: String, enumType: SlangEnumType) -> FsmModel {
        FsmModel(signal: signal, width: enumType.width, states: enumType.members.map { FsmState(bits: $0.bits, name: $0.name) },
                 reset: nil, resetSignal: nil, controls: [], transitions: [], engine: .observed, counts: nil)
    }

    /// No engine ran and no enum: the named codes (localparams) as the states.
    public static func observed(signal: String, width: Int, names: [String: String]) -> FsmModel {
        FsmModel(signal: signal, width: width, states: names.sorted { $0.key < $1.key }.map { FsmState(bits: $0.key, name: $0.value) },
                 reset: nil, resetSignal: nil, controls: [], transitions: [], engine: .observed, counts: nil)
    }

    /// The model as the page's cmux-fsm.js takes it (JSON types only).
    public func pageObject() -> [String: Any] {
        var out: [String: Any] = [
            "signal": signal,
            "width": width,
            "engine": engine.rawValue,
            "controls": controls,
            "states": states.map { state -> [String: Any] in
                var item: [String: Any] = ["bits": state.bits]
                if let name = state.name { item["name"] = name }
                return item
            },
            "transitions": transitions.map { transition -> [String: Any] in
                var item: [String: Any] = ["from": transition.from, "to": transition.to]
                if let condition = transition.condition { item["condition"] = condition }
                return item
            },
        ]
        if let reset { out["reset"] = reset }
        if let resetSignal { out["resetSignal"] = resetSignal }
        if let counts {
            out["counts"] = [
                "states": counts.states,
                "transitions": counts.transitions.map { ["from": $0.from, "to": $0.to, "count": $0.count] as [String: Any] },
            ] as [String: Any]
        }
        return out
    }
}

// MARK: - Verdi

/// Verdi nState's FSM analysis report (`fsmAnalyzeFSM -output`), W-2024.09's layout: header
/// fields (`State Signal:state[2:0]`, `Initial State:IDLE`, `Reset Condition1:rst`), the state
/// table (`\tIDLE=3'b000`), per-state detail sections (`IDLE\tStateType:` then `\t ->FETCH\tgo`),
/// and the state and transition count reports (`\tIDLE: 11`, `\t(IDLE ->FETCH): 4`).
public enum VerdiFsmReport {
    public static func parse(_ text: String) -> FsmModel? {
        var signal: String?
        var width: Int?
        var initial: String?
        var resetSignal: String?
        var controls: [String] = []
        var table: [(name: String, bits: String)] = []
        var transitions: [(from: String, to: String, condition: String?)] = []
        var stateCounts: [String: Int] = [:]
        var transitionCounts: [(String, String, Int)] = []
        enum Section { case none, inputs, outputs, table, detail, stateCounts, transitionCounts, other }
        var section = Section.none
        var current: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("---") || trimmed.hasPrefix("===") || trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("= ") {
                if trimmed.contains("Detail State Report") { section = .detail }
                else { section = .other }
                continue
            }
            switch trimmed {
            case "Input Signals:": section = .inputs; continue
            case "Output Signals:": section = .outputs; continue
            case "State Table:": section = .table; continue
            case "State Report": section = .stateCounts; continue
            case "Transition Report": section = .transitionCounts; continue
            default: break
            }
            if let value = field(trimmed, "State Signal:") {
                let (name, range) = splitRange(value)
                signal = name.isEmpty ? nil : name
                width = range
                section = .none
                continue
            }
            if let value = field(trimmed, "Initial State:") { initial = value; continue }
            if trimmed.hasPrefix("Reset Condition"), let colon = trimmed.firstIndex(of: ":") {
                let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if resetSignal == nil, !value.isEmpty { resetSignal = value }
                continue
            }
            if field(trimmed, "Clock Signal:") != nil || field(trimmed, "Clock Polarity:") != nil { section = .none; continue }
            switch section {
            case .inputs:
                if let colon = trimmed.lastIndex(of: ":"), trimmed[trimmed.index(after: colon)...] == "Control" {
                    controls.append(splitRange(String(trimmed[..<colon])).name)
                }
            case .table:
                if let eq = trimmed.firstIndex(of: "=") {
                    let name = String(trimmed[..<eq]), literal = String(trimmed[trimmed.index(after: eq)...])
                    if let w = SlangEnumValues.literalWidth(literal), let bits = SlangEnumValues.literalBits(literal, width: w) {
                        table.append((name, bits))
                        if width == nil { width = w }
                    }
                }
            case .detail:
                if trimmed.hasSuffix("StateType:") || line.contains("\tStateType:") {
                    current = line.components(separatedBy: "\t").first?.trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("->"), let from = current {
                    let rest = trimmed.dropFirst(2)
                    let parts = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let to = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
                    let condition = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    if !to.isEmpty { transitions.append((from, to, condition.isEmpty ? nil : condition)) }
                }
            case .stateCounts:
                if let colon = trimmed.lastIndex(of: ":"), let n = Int(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                    stateCounts[String(trimmed[..<colon])] = n
                }
            case .transitionCounts:
                if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")"), let colon = trimmed.lastIndex(of: ":"),
                   let n = Int(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                    let pair = trimmed[trimmed.index(after: trimmed.startIndex)..<close].components(separatedBy: " ->")
                    if pair.count == 2 { transitionCounts.append((pair[0].trimmingCharacters(in: .whitespaces), pair[1].trimmingCharacters(in: .whitespaces), n)) }
                }
            default: break
            }
        }
        guard let signal, let width, !table.isEmpty else { return nil }
        let bitsOf = Dictionary(table.map { ($0.name, $0.bits) }, uniquingKeysWith: { a, _ in a })
        let code: (String) -> String? = { name in name == "Others" ? "*" : bitsOf[name] }
        let edges = transitions.compactMap { t -> FsmTransition? in
            guard let from = code(t.from), let to = code(t.to), to != "*" else { return nil }
            return FsmTransition(from: from, to: to, condition: t.condition)
        }
        var counts: FsmCounts?
        if !stateCounts.isEmpty || !transitionCounts.isEmpty {
            var states: [String: Int] = [:]
            for (name, n) in stateCounts { if let bits = bitsOf[name] { states[bits] = n } }
            let pairs = transitionCounts.compactMap { from, to, n -> FsmCount? in
                guard let f = bitsOf[from], let t = bitsOf[to] else { return nil }
                return FsmCount(from: f, to: t, count: n)
            }
            counts = FsmCounts(states: states, transitions: pairs)
        }
        let reset = resetSignal
        return FsmModel(
            signal: signal, width: width, states: table.map { FsmState(bits: $0.bits, name: $0.name) },
            reset: initial.flatMap { bitsOf[$0] }, resetSignal: reset,
            controls: controls.filter { $0 != reset }, transitions: edges, engine: .verdi, counts: counts
        )
    }

    private static func field(_ line: String, _ prefix: String) -> String? {
        line.hasPrefix(prefix) ? line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : nil
    }

    /// `state[2:0]` -> ("state", 3); `go` -> ("go", nil).
    static func splitRange(_ text: String) -> (name: String, width: Int?) {
        guard text.hasSuffix("]"), let open = text.lastIndex(of: "[") else { return (text, nil) }
        let range = text[text.index(after: open)..<text.index(before: text.endIndex)].split(separator: ":")
        let name = String(text[..<open])
        guard range.count == 2, let a = Int(range[0]), let b = Int(range[1]) else { return (name, nil) }
        return (name, abs(a - b) + 1)
    }
}

/// Running `Resources/vaporview/fsm/cmux-fsm-verdi.sh` on the dump's host.
public enum VerdiFsmEngine {
    public enum Outcome: Sendable, Equatable {
        /// The report text and Verdi's name of the FSM instance.
        case report(text: String, instance: String?)
        /// `reason`: no-verdi, no-kdb, no-python, licence, no-fsm or failed.
        case unavailable(reason: String, detail: String)
    }

    static let prefix = "cmux-fsm: "

    /// What the script's output says.
    public static func outcome(ofOutput output: String) -> Outcome {
        var instance: String?
        var report: [String]?
        var finished = false
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let message = String(line.dropFirst(prefix.count))
                if message == "report-begin" { report = []; continue }
                if message == "report-end" { finished = true; break }
                if report == nil {
                    if message.hasPrefix("instance ") { instance = String(message.dropFirst("instance ".count)) }
                    if message.hasPrefix("unavailable ") {
                        let rest = message.dropFirst("unavailable ".count)
                        let parts = rest.split(separator: " ", maxSplits: 1)
                        return .unavailable(reason: parts.first.map(String.init) ?? "failed", detail: parts.count > 1 ? String(parts[1]) : "")
                    }
                    continue
                }
            }
            report?.append(line)
        }
        if let report {
            return finished ? .report(text: report.joined(separator: "\n"), instance: instance)
                : .unavailable(reason: "failed", detail: "the report was cut off")
        }
        let last = output.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return .unavailable(reason: "failed", detail: last)
    }

    /// The command ssh runs: the script comes on stdin, so nothing is installed on the host.
    public static func remoteCommand(fsdb: String, scope: String, signal: String) -> String {
        "bash -l -s -- \(shellQuoted(fsdb)) \(shellQuoted(scope)) \(shellQuoted(signal))"
    }

    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Yosys

/// Yosys's `$fsm` cells (after `fsm_extract`, before `fsm_map`) in `write_json` output.
/// Parameters are binary strings, most significant bit first:
/// - `STATE_TABLE`: STATE_NUM codes of STATE_BITS each, state 0 in the lowest bits;
/// - `TRANS_TABLE`: TRANS_NUM entries, entry 0 in the lowest bits, each (from the top)
///   state_in index (STATE_NUM_LOG2), ctrl_in cube (CTRL_IN_WIDTH, `-` = either), state_out index, ctrl_out;
/// - `STATE_RST`: the reset state's index.
/// `CTRL_IN` connects the cube's bits, least significant first, to nets named in `netnames`.
public enum YosysFsm {
    public enum Failure: Error, Sendable, Equatable {
        case notFound
        case failed(String)
    }

    /// The FSMs by their state register's name (`st`, or `u_lp.st` in a flattened design).
    public static func models(json: Data) -> [String: FsmModel] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let modules = root["modules"] as? [String: Any] else { return [:] }
        var out: [String: FsmModel] = [:]
        for case let module as [String: Any] in modules.values {
            let netnames = module["netnames"] as? [String: Any] ?? [:]
            var nameOfBit: [Int: String] = [:]
            // Visible names first; then Yosys's own ($...) for bits nothing else names.
            for hidden in [false, true] {
                for (name, value) in netnames.sorted(by: { $0.key < $1.key }) {
                    guard let net = value as? [String: Any], let bits = net["bits"] as? [Any] else { continue }
                    if (name.hasPrefix("$") || (net["hide_name"] as? Int) == 1) != hidden { continue }
                    for (index, bit) in bits.enumerated() {
                        guard let id = bit as? Int, nameOfBit[id] == nil else { continue }
                        nameOfBit[id] = bits.count == 1 ? name : "\(name)[\(index)]"
                    }
                }
            }
            for case let cell as [String: Any] in (module["cells"] as? [String: Any] ?? [:]).values {
                guard cell["type"] as? String == "$fsm", let parameters = cell["parameters"] as? [String: Any],
                      let model = model(parameters: parameters, connections: cell["connections"] as? [String: Any] ?? [:], nameOfBit: nameOfBit)
                else { continue }
                var name = parameters["NAME"] as? String ?? model.signal
                if name.hasPrefix("\\") { name.removeFirst() }
                out[name] = model
            }
        }
        return out
    }

    private static func number(_ value: Any?) -> Int? {
        guard let text = value as? String, !text.isEmpty, text.allSatisfy({ $0 == "0" || $0 == "1" }) else { return value as? Int }
        return Int(text, radix: 2)
    }

    private static func model(parameters: [String: Any], connections: [String: Any], nameOfBit: [Int: String]) -> FsmModel? {
        guard let stateBits = number(parameters["STATE_BITS"]), stateBits > 0,
              let stateNum = number(parameters["STATE_NUM"]), stateNum > 0,
              let log2 = number(parameters["STATE_NUM_LOG2"]),
              let inWidth = number(parameters["CTRL_IN_WIDTH"]), let outWidth = number(parameters["CTRL_OUT_WIDTH"]),
              let transNum = number(parameters["TRANS_NUM"]),
              let stateTable = parameters["STATE_TABLE"] as? String, stateTable.count == stateNum * stateBits,
              let transTable = parameters["TRANS_TABLE"] as? String
        else { return nil }
        let entry = 2 * log2 + inWidth + outWidth
        guard transTable.count == transNum * entry else { return nil }
        let codes = Array(stateTable)
        let code: (Int) -> String? = { index in
            guard index >= 0, index < stateNum else { return nil }
            let end = codes.count - index * stateBits
            return String(codes[(end - stateBits)..<end])
        }
        // The inputs, most significant first as the cubes are written.
        let inputBits = (connections["CTRL_IN"] as? [Any] ?? []).reversed().map { bit -> String in
            if let id = bit as? Int { return nameOfBit[id] ?? "$\(id)" }
            return "\(bit)"
        }
        guard inputBits.count == inWidth else { return nil }
        let trans = Array(transTable)
        var rows: [(from: Int, cube: [Character], to: Int)] = []
        for index in 0..<transNum {
            let end = trans.count - index * entry
            let chunk = Array(trans[(end - entry)..<end])
            guard let from = Int(String(chunk[0..<log2]), radix: 2),
                  let to = Int(String(chunk[(log2 + inWidth)..<(2 * log2 + inWidth)]), radix: 2) else { return nil }
            rows.append((from, Array(chunk[log2..<(log2 + inWidth)]), to))
        }
        let resetIndex = number(parameters["STATE_RST"])
        // The reset input: one value of it leads every state to the reset state.
        var reset: (index: Int, value: Character)?
        if let resetIndex {
            outer: for k in 0..<inWidth {
                for value: Character in ["1", "0"] {
                    let asserted = rows.filter { $0.cube[k] == value }
                    let states = Set(asserted.map(\.from))
                    if !asserted.isEmpty, states.count == stateNum, asserted.allSatisfy({ $0.to == resetIndex }),
                       rows.allSatisfy({ $0.cube[k] != "-" }) {
                        reset = (k, value)
                        break outer
                    }
                }
            }
        }
        var cubes: [[Int]: [[Character]]] = [:]
        var order: [[Int]] = []
        for row in rows {
            var cube = row.cube
            if let reset {
                if cube[reset.index] == reset.value { continue }
                cube[reset.index] = "-"
            }
            let key = [row.from, row.to]
            if cubes[key] == nil { order.append(key) }
            cubes[key, default: []].append(cube)
        }
        var transitions: [FsmTransition] = []
        for key in order {
            guard let from = code(key[0]), let to = code(key[1]) else { continue }
            let terms = (cubes[key] ?? []).map { cube in
                cube.indices.compactMap { k -> String? in
                    switch cube[k] {
                    case "1": return inputBits[k]
                    case "0": return "!" + inputBits[k]
                    default: return nil
                    }
                }
            }
            let condition: String?
            if terms.contains(where: \.isEmpty) {
                condition = nil
            } else if terms.count == 1 {
                condition = terms[0].joined(separator: " && ")
            } else {
                condition = terms.map { $0.count > 1 ? "(" + $0.joined(separator: " && ") + ")" : $0[0] }.joined(separator: " || ")
            }
            transitions.append(FsmTransition(from: from, to: to, condition: condition))
        }
        var name = parameters["NAME"] as? String ?? ""
        if name.hasPrefix("\\") { name.removeFirst() }
        let signal = String(name.split(separator: ".").last ?? Substring(name))
        let resetName = reset.map { inputBits[$0.index] }
        let controls = inputBits.filter { $0 != resetName && !$0.hasPrefix("$") }.sorted()
        return FsmModel(
            signal: signal, width: stateBits, states: (0..<stateNum).compactMap { code($0).map { FsmState(bits: $0, name: nil) } },
            reset: resetIndex.flatMap(code), resetSignal: resetName, controls: controls, transitions: transitions,
            engine: .yosys, counts: nil
        )
    }

    /// The Yosys script: the instance's module elaborated as the top with the instance's
    /// parameter values (an override of a localparam with its own value changes nothing),
    /// flattened, then FSM extraction. `force`: mark `signal` as an FSM (fsm_detect leaves
    /// out registers whose users it thinks would not gain from recoding).
    /// `slangFrontend`: sv-elab's `read_slang` (full SystemVerilog), else `read_verilog -sv`
    /// (also when a path has a space or a character Yosys's script reader takes as syntax).
    public static func script(files: [String], module: String, parameters: [(name: String, value: String)], signal: String,
                              force: Bool, slangFrontend: Bool, output: String) -> String {
        let literal = parameters.filter { isLiteral($0.value) && isIdentifier($0.name) }
        var lines: [String] = []
        let quoted = files.map(quote).joined(separator: " ")
        // read_slang hands its arguments to slang as they are (quotes would be part of the
        // path), so it only gets paths that need none.
        if slangFrontend, files.allSatisfy(isBarePath) {
            lines.append("read_slang \(files.joined(separator: " ")) --top \(module)" + literal.map { " -G \($0.name)=\($0.value)" }.joined())
        } else {
            lines.append("read_verilog -sv \(quoted)")
            lines.append("hierarchy -top \(module)" + literal.map { " -chparam \($0.name) \($0.value)" }.joined())
        }
        lines.append("proc")
        lines.append("flatten")
        lines.append("opt -nodffe -nosdff")
        if force { lines.append(#"setattr -set fsm_encoding "\"auto\"" w:"# + signal) }
        lines.append("fsm_detect")
        lines.append("fsm_extract")
        lines.append("write_json \(quote(output))")
        return lines.joined(separator: "\n") + "\n"
    }

    static func isBarePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains { $0.isWhitespace || $0 == "\"" || $0 == "#" || $0 == ";" }
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.allSatisfy { $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber }
    }

    /// A number Yosys and slang take as a value: `4`, `2'b0`, `32'sd3`, `8'hFF`.
    static func isLiteral(_ text: String) -> Bool {
        text.range(of: #"^(\d+)?('[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|\d+)$|^\d+$"#, options: .regularExpression) != nil
    }

    /// Whether `yosys` has sv-elab's `read_slang` (built in from 0.67; not in every build).
    public static func hasSlangFrontend(yosys: String) async -> Bool {
        // Not -q: that hides help's answer. A missing command is answered "No such command or cell type".
        guard let result = try? await run(yosys, ["-p", "help read_slang"], timeout: 60) else { return false }
        return result.status == 0 && result.output.contains("read_slang [options]")
    }

    /// Runs Yosys here and reads the FSMs it extracted. Throws `.failed` with Yosys's error
    /// line, `.notFound` when there is none for `signal`.
    public static func runLocally(yosys: String, files: [String], module: String, parameters: [(name: String, value: String)],
                                  signal: String, force: Bool, slangFrontend: Bool, timeout: TimeInterval = 300) async throws -> [String: FsmModel] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-fsm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("fsm.json").path
        let scriptURL = dir.appendingPathComponent("fsm.ys")
        try script(files: files, module: module, parameters: parameters, signal: signal, force: force,
                   slangFrontend: slangFrontend, output: output).write(to: scriptURL, atomically: true, encoding: .utf8)
        let result = try await run(yosys, ["-q", "-s", scriptURL.path], timeout: timeout)
        guard result.status == 0, let data = FileManager.default.contents(atPath: output) else {
            throw Failure.failed(errorLine(result.output))
        }
        let models = models(json: data)
        guard models.keys.contains(where: { $0 == signal || $0.hasSuffix("." + signal) }) else { throw Failure.notFound }
        return models
    }

    /// The first `ERROR:` line of Yosys's output, else its last line.
    public static func errorLine(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.first { $0.contains("ERROR") } ?? lines.last ?? ""
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, output: String) {
        do {
            return try await FsmProcess.run(executable, arguments, input: nil, timeout: timeout)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }

    // MARK: Where the sources are (another host)

    /// What the remote runner (`cmux-fsm-yosys.sh`) printed.
    public enum RemoteOutcome: Sendable, Equatable {
        /// Yosys's `write_json` output.
        case json(String)
        /// reason: no-yosys | failed.
        case unavailable(reason: String, detail: String)
    }

    /// The command that runs the runner, sent on its standard input, on the sources' host:
    /// both scripts (`read_slang` and `read_verilog`; the runner picks the one its Yosys can
    /// run, writing `fsm.json` in its own folder) base64 encoded, and the Yosys to use ("": look for one).
    public static func remoteCommand(slangScript: String, nativeScript: String, yosys: String) -> String {
        let encode = { (text: String) in Data(text.utf8).base64EncodedString() }
        return "bash -l -s -- " + [encode(slangScript), encode(nativeScript), yosys].map(VerdiFsmEngine.shellQuoted).joined(separator: " ")
    }

    public static func remoteOutcome(ofOutput output: String) -> RemoteOutcome {
        let lines = output.components(separatedBy: "\n")
        let marker = "cmux-fsm: "
        if let begin = lines.firstIndex(of: marker + "json-begin") {
            guard let end = lines[begin...].firstIndex(of: marker + "json-end") else {
                return .unavailable(reason: "failed", detail: "the output was cut off")
            }
            return .json(lines[(begin + 1)..<end].joined(separator: "\n"))
        }
        if let line = lines.last(where: { $0.hasPrefix(marker + "unavailable ") }) {
            let rest = line.dropFirst((marker + "unavailable ").count)
            let reason = rest.prefix { $0 != " " }
            return .unavailable(reason: String(reason), detail: String(rest.dropFirst(reason.count)).trimmingCharacters(in: .whitespaces))
        }
        let other = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix(marker) }
        return .unavailable(reason: "failed", detail: other.last ?? "")
    }
}

/// Runs a tool and gathers its output (standard error too), with a time limit.
public enum FsmProcess {
    public static func run(_ executable: String, _ arguments: [String], input: Data?, timeout: TimeInterval) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let inputPipe = input.map { _ in Pipe() }
            process.standardInput = inputPipe ?? FileHandle.nullDevice
            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (process.terminationStatus, collected.text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            if let inputPipe, let input {
                DispatchQueue.global().async {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Output gathered from a process's pipe (on its reading thread).
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private static let limit = 4 << 20

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < Self.limit { data.append(chunk.prefix(Self.limit - data.count)) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Names

/// Names for an FSM's codes when the engine gives none: the state's enum, or the localparams
/// (parameters) of its scope that have its width and a value no other of them has.
public enum FsmNaming {
    public struct Param: Sendable, Equatable {
        public var name: String
        /// slang's type text (`logic[1:0]`, `int`).
        public var type: String
        /// slang's value text (`2'b0`).
        public var value: String

        public init(name: String, type: String, value: String) {
            self.name = name
            self.type = type
            self.value = value
        }
    }

    public static func names(params: [Param], width: Int) -> [String: String] {
        var byBits: [String: [String]] = [:]
        for param in params {
            guard SlangEnumValues.baseWidth(param.type) == width,
                  let bits = SlangEnumValues.literalBits(param.value, width: width) else { continue }
            byBits[bits, default: []].append(param.name)
        }
        return byBits.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    public static func named(_ model: FsmModel, names: [String: String]) -> FsmModel {
        var out = model
        out.states = model.states.map { state in
            FsmState(bits: state.bits, name: state.name ?? names[state.bits])
        }
        return out
    }

    /// Every member named, and members the engine didn't find (unreachable) added as states.
    public static func named(_ model: FsmModel, enumType: SlangEnumType) -> FsmModel {
        guard enumType.width == model.width else { return model }
        var out = named(model, names: Dictionary(enumType.members.map { ($0.bits, $0.name) }, uniquingKeysWith: { a, _ in a }))
        let known = Set(out.states.map(\.bits))
        out.states += enumType.members.filter { !known.contains($0.bits) }.map { FsmState(bits: $0.bits, name: $0.name) }
        return out
    }
}
