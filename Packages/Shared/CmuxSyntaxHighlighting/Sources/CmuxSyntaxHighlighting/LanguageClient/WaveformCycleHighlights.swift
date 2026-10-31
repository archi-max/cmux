import Foundation

/// What the SystemVerilog editor highlights while the waveform debugger steps
/// a clock: the signals whose value changed this cycle, and the lines that
/// drive them (the rest of the module is dimmed around those).
public enum WaveformCycleHighlights {
    /// The names whose value now differs from the value a cycle before.
    /// A name with no earlier value (not dumped then) is not counted as changed.
    public static func changedNames(now: [String: String], before: [String: String]) -> Set<String> {
        Set(now.compactMap { name, value in
            guard let old = before[name], old != value else { return nil }
            return name
        })
    }

    public struct Result: Equatable, Sendable {
        /// Each occurrence of a changed signal on the lines, in the text's UTF-16 units.
        public var changedIdentifiers: [NSRange] = []
        /// The lines (without their line break) that assign a changed signal.
        public var driverLines: [NSRange] = []
        /// Per module, the changed names some line assigns.
        public var assigned: [String: Set<String>] = [:]

        public init() {}
    }

    /// The changed occurrences on `lines` (`changed`: per module, its changed names)
    /// and the lines where one is an assignment's target (`x <= ...`, `assign x = ...`).
    public static func highlights(
        lines: [SystemVerilogInlineScan.Line],
        text: NSString,
        changed: [String: Set<String>]
    ) -> Result {
        var result = Result()
        for line in lines {
            guard let module = line.module, let names = changed[module], !names.isEmpty,
                  NSMaxRange(line.contentRange) <= text.length else { continue }
            var lineText: String?
            var drives = false
            for identifier in line.identifiers where names.contains(identifier.name) {
                let length = (identifier.name as NSString).length
                result.changedIdentifiers.append(NSRange(location: identifier.offset, length: length))
                let content = lineText ?? text.substring(with: line.contentRange)
                lineText = content
                if SystemVerilogAssignmentScanner.isAssignmentTarget(
                    line: content,
                    column: identifier.offset - line.contentRange.location,
                    length: length
                ) {
                    drives = true
                    result.assigned[module, default: []].insert(identifier.name)
                }
            }
            if drives { result.driverLines.append(line.contentRange) }
        }
        return result
    }

    /// The child instances of `designInstance` whose ports drive the signal a
    /// driver cone was asked for: cone signals named `designInstance.<child>.<port>`.
    public static func drivingChildInstances(cone: [SlangConeEntry], designInstance: String) -> [String] {
        let parent = HierarchyPathMapping.segments(designInstance)
        var children: [String] = []
        for entry in cone {
            let segments = HierarchyPathMapping.segments(entry.path)
            guard segments.count == parent.count + 2, Array(segments.prefix(parent.count)) == parent else { continue }
            let child = segments[parent.count]
            if !children.contains(child) { children.append(child) }
        }
        return children
    }

    /// The lines of the instantiation that starts on `lines[start]` (up to the line
    /// holding its `;`, at most 200 lines) where `name` is connected. Empty when
    /// it is not among them.
    public static func connectionLines(
        of name: String,
        instantiationAt start: Int,
        lines: [SystemVerilogInlineScan.Line],
        text: NSString
    ) -> [NSRange] {
        guard lines.indices.contains(start) else { return [] }
        var out: [NSRange] = []
        for index in start..<min(lines.count, start + 200) {
            let line = lines[index]
            if line.identifiers.contains(where: { $0.name == name }) { out.append(line.contentRange) }
            if NSMaxRange(line.contentRange) <= text.length, text.substring(with: line.contentRange).contains(";") { break }
        }
        return out
    }
}
