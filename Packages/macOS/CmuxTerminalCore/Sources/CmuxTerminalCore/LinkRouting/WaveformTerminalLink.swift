import Foundation

/// A VaporView terminal link (a time or an instance path) in a terminal line,
/// adapted from VaporView (https://github.com/Lramseyer/vaporview, GPL-3.0),
/// `src/extension_core/terminal_links.ts`@59107c6. The app's
/// `WaveformTerminalLinks` hands it to the workspace's waveform viewer.
///
/// Unlike VaporView, these never take a file name: an instance path must start
/// at a top scope and contain no `/`, a two-part name that ends in a source or
/// dump extension (`tb.sv:42`, `top.v`) is a file, and a time must not start
/// inside a word
/// (`sim_100ns`). Only a window around the click is scanned and every pattern
/// is anchored, so a long line costs the same as a short one.
public enum WaveformTerminalLink: Equatable, Sendable {
    /// A UVM timestamp (`@ 50000`, `units` nil: the dump's own units) or a time with units (`1,250 ns`).
    case time(Double, units: String?)
    /// A dotted path under one of the dump's top scopes (`top.core.alu.acc[15:0]`).
    case instancePath(String)

    /// Only this many UTF-16 units on each side of the click are scanned, so a
    /// long line costs the same as a short one.
    public static let scanRadius = 256

    /// Extensions that make a two-part dotted word (`tb.sv`) a file name, not an
    /// instance path. Longer paths keep them: `tb.dut.c` is a signal `c`.
    private static let fileExtensions: Set<String> = [
        "sv", "svh", "v", "vh", "vhd", "vhdl", "vcd", "fst", "fsdb", "ghw", "json", "f", "log", "txt",
        "py", "c", "h", "cc", "cpp", "hpp", "tcl", "do", "sh", "yml", "yaml", "md", "gz", "xml", "html",
    ]

    /// The link under `column` (a UTF-16 offset) of `line`, if any.
    /// - Parameters:
    ///   - topScopes: The dump's top scope names; instance paths must start at one.
    ///   - instancePaths: Whether instance paths are links (`enableInstancePathTerminalLinks`).
    public static func detect(in line: String, column: Int, topScopes: [String], instancePaths: Bool) -> WaveformTerminalLink? {
        let full = line as NSString
        guard column >= 0, column < full.length else { return nil }
        let start = max(0, column - scanRadius)
        let window = full.substring(with: NSRange(location: start, length: min(full.length, column + scanRadius) - start))
        let text = window as NSString
        let click = column - start
        func covering(_ pattern: String) -> NSTextCheckingResult? {
            guard let regex = regexCache.regex(pattern) else { return nil }
            let cut = start + text.length < full.length
            return regex.matches(in: window, range: NSRange(location: 0, length: text.length)).first { match in
                click >= match.range.location && click < match.range.location + match.range.length
                    // A match touching an edge the window cut may run on past it
                    // (its boundary checks can't see beyond), so it isn't a link.
                    && !(start > 0 && match.range.location == 0)
                    && !(cut && match.range.location + match.range.length == text.length)
            }
        }
        if instancePaths, !topScopes.isEmpty {
            let tops = topScopes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            // A top scope, then `.name`, `.name[3:0]` or `.mem[3][2]` parts; never
            // next to a word, `/` or `~`, and never a prefix of a longer dotted word
            // (`top.core.alu/x` is not `top.core`).
            let pattern = #"(?<![\w$./~-])(?:"# + tops + #")(?:\.[\w$]+(?:\[\d+(?::\d+)?\])*)+(?![\w$/\[]|\.[\w$])"#
            if let match = covering(pattern) {
                let path = text.substring(with: match.range)
                let parts = path.split(separator: ".")
                if parts.count > 2 || !fileExtensions.contains(parts.last.map { String($0).lowercased() } ?? "") {
                    return .instancePath(path)
                }
            }
        }
        if let match = covering(#"@\s+(\d+)(?!\d)"#), let time = Double(text.substring(with: match.range(at: 1))) {
            return time.isFinite ? WaveformTerminalLink.time(time, units: nil) : nil
        }
        // The number starts at a word boundary, so `sim_100ns` and `v1.5ns` are not times.
        if let match = covering(#"(?<![\w,./-])(\d[\d,]*(?:\.\d+)?)\s*([kmµμunpf]?s)\b"#) {
            let number = text.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let units = text.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "µ", with: "u")
                .replacingOccurrences(of: "μ", with: "u")
            if let time = Double(number), time.isFinite {
                return .time(time, units: units)
            }
        }
        return nil
    }

    /// The terminal reports a cell column; the line's characters map one to one
    /// to cells except for wide characters, which this ignores.
    public static func utf16Offset(ofCharacter column: Int, in line: String) -> Int {
        guard let index = line.index(line.startIndex, offsetBy: column, limitedBy: line.endIndex) else {
            return line.utf16.count
        }
        return line.utf16.distance(from: line.utf16.startIndex, to: index)
    }
}

/// Compiled patterns by source: the hover runs `detect` on every mouse move.
private final class WaveformTerminalLinkRegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var regexes: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let regex = regexes[pattern] { return regex }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        // Top-scope sets change only when a dump opens; keep the cache small.
        if regexes.count >= 16 { regexes.removeAll() }
        regexes[pattern] = regex
        return regex
    }
}

private let regexCache = WaveformTerminalLinkRegexCache()
