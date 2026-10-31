import Foundation

/// VaporView's terminal links for cmux terminals, adapted from VaporView
/// (https://github.com/Lramseyer/vaporview, GPL-3.0),
/// `src/extension_core/terminal_links.ts`@59107c6.
///
/// ⌘-click in a terminal of a workspace that has a waveform viewer open:
/// - a UVM timestamp (`@ 50000`) sets the marker at that time in the dump's units;
/// - a time with units (`1,250 ns`, `3.5us`) sets the marker at that time;
/// - an instance path under one of the dump's top scopes (`top.core.alu.acc`)
///   adds that signal to the viewer, unless `enableInstancePathTerminalLinks` is off.
///
/// Unlike VaporView, an instance path must always start at a top scope (VaporView
/// matches any dotted word when a dump has more than 16), so ⌘-clicking a file
/// name still opens the file.
enum WaveformTerminalLinks {
    enum Link: Equatable {
        case time(Double, units: String?)
        case instancePath(String)
    }

    /// The link under `column` (a UTF-16 offset) of `line`, if any.
    static func link(in line: String, column: Int, topScopes: [String], instancePaths: Bool) -> Link? {
        let text = line as NSString
        func covering(_ regex: NSRegularExpression) -> NSTextCheckingResult? {
            regex.matches(in: line, range: NSRange(location: 0, length: text.length)).first { match in
                column >= match.range.location && column < match.range.location + match.range.length
            }
        }
        if instancePaths, !topScopes.isEmpty {
            let tops = topScopes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: #"(?<![\w$.])(?:"# + tops + #")(?:\.[\w$\[\]:]+)+"#),
               let match = covering(regex) {
                return .instancePath(text.substring(with: match.range))
            }
        }
        let uvmTimestamp = try? NSRegularExpression(pattern: #"@\s+(\d+)"#)
        let timeWithUnits = try? NSRegularExpression(pattern: #"([\d,.]+)\s*([kmµμunpf]?s)\b"#)
        if let uvmTimestamp, let match = covering(uvmTimestamp), let time = Double(text.substring(with: match.range(at: 1))) {
            return .time(time, units: nil)
        }
        if let timeWithUnits, let match = covering(timeWithUnits) {
            let number = text.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
            let units = text.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "µ", with: "u")
                .replacingOccurrences(of: "μ", with: "u")
            if let time = Double(number) {
                return .time(time, units: units)
            }
        }
        return nil
    }

    /// Opens the link under `column` of `line` in a waveform viewer of `workspace`.
    /// Returns false, leaving the click to cmux's own links, when there is no link
    /// or no viewer it applies to.
    @MainActor
    static func open(line: String, column: Int, workspace: Workspace) -> Bool {
        let viewers = workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.previewMode == .waveform }
            .sorted { $0.filePath < $1.filePath }
        guard !viewers.isEmpty else { return false }
        let utf16Column = utf16Offset(ofCharacter: column, in: line)
        let instancePaths = FilePreviewWaveformSession.storedSettings()["enableInstancePathTerminalLinks"] as? Bool ?? true
        for viewer in viewers {
            let session = viewer.nativeViewSessions.waveform
            guard case .instancePath(let path)? = link(
                in: line, column: utf16Column, topScopes: session.topScopes, instancePaths: instancePaths
            ) else { continue }
            session.runCommand("waveformViewer.addVariable", args: ["instancePath": path])
            return true
        }
        guard case .time(let time, let units)? = link(in: line, column: utf16Column, topScopes: [], instancePaths: false),
              let viewer = viewers.first(where: { !$0.nativeViewSessions.waveform.topScopes.isEmpty }) else { return false }
        var args: [String: Any] = ["time": time, "markerType": 0]
        args["units"] = units
        viewer.nativeViewSessions.waveform.runCommand("waveformViewer.setMarker", args: args)
        return true
    }

    /// The terminal reports a cell column; the line's characters map one to one
    /// to cells except for wide characters, which this ignores.
    private static func utf16Offset(ofCharacter column: Int, in line: String) -> Int {
        guard let index = line.index(line.startIndex, offsetBy: column, limitedBy: line.endIndex) else {
            return line.utf16.count
        }
        return line.utf16.distance(from: line.utf16.startIndex, to: index)
    }
}
