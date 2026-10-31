import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// What the SystemVerilog editor shows while the waveform debugger steps
/// (FEATURES.md F.1): the signals that changed this cycle, the lines that drive
/// them (the module's other lines dimmed), the same signals' rows in the
/// waveform, and the declaration and drivers of the row selected there.
///
/// Drawn with the layout manager's temporary attributes, so the text, its
/// undo and its syntax colors are untouched.
@MainActor
enum WaveformDebuggerEditorHighlights {
    /// A module's instance in the design and in the dump.
    struct Instance: Equatable {
        var design: String
        var dump: String
    }

    /// One inline-value refresh of an editor: its visible lines and the values they showed.
    struct Shown {
        let editor: FilePreviewLanguageFeatures
        let textView: NSTextView
        let lines: [SystemVerilogInlineScan.Line]
        let waveform: FilePreviewPanel
        let time: Int64
        /// Per module: name → value at `time`.
        let values: [String: [String: String]]
        let instances: [String: Instance]
    }

    private final class Drawn {
        var attributes: [(range: NSRange, key: NSAttributedString.Key, value: Any)] = []
    }

    private final class Work {
        var task: Task<Void, Never>?
    }

    private final class Paths {
        var paths: [[String]] = []
    }

    /// Most driver cones asked of slang-server per refresh (each is cached).
    private static let maxConeRequests = 16
    private static let maxCachedCones = 4000
    /// Most waveform rows lit per editor.
    private static let maxRows = 200

    private static let cycleDrawn = NSMapTable<NSTextView, Drawn>.weakToStrongObjects()
    private static let work = NSMapTable<NSTextView, Work>.weakToStrongObjects()
    /// Per editor: the dump paths of its changed signals, lit in its waveform.
    private static let rowPaths = NSMapTable<FilePreviewLanguageFeatures, Paths>.weakToStrongObjects()
    /// Per viewer: the rows last sent, so an unchanged set is not sent again.
    private static let sentRows = NSMapTable<FilePreviewPanel, Paths>.weakToStrongObjects()
    private struct ConeKey: Hashable {
        let server: ObjectIdentifier
        let path: String
    }

    /// slang's driver cone per server and signal path.
    private static var cones: [ConeKey: [SlangConeEntry]] = [:]
    /// The selected row's declaration and driver lines, per text view (drawn over the cycle highlights).
    private static let selectionLines = NSMapTable<NSTextView, Drawn>.weakToStrongObjects()

    // MARK: Cycle highlights

    /// An editor drew its values: while its waveform is stepped, compare them with the
    /// cycle before and highlight what changed and what drove it.
    static func valuesShown(_ shown: Shown) {
        WaveformDebugger.updateLocals(from: shown.editor)
        let textView = shown.textView
        let job = work.object(forKey: textView) ?? Work()
        work.setObject(job, forKey: textView)
        job.task?.cancel()
        guard WaveformDebugger.isStepping(shown.waveform) else {
            clear(in: textView)
            setRows([], from: shown.editor, in: shown.waveform)
            return
        }
        // The text the lines were scanned from: an edit before the task runs makes them stale too.
        let text = textView.string
        job.task = Task { @MainActor in
            guard let result = await cycleHighlights(shown, text: text), !Task.isCancelled else { return }
            apply(result.highlights, lines: shown.lines, in: textView)
            setRows(result.rows, from: shown.editor, in: shown.waveform)
        }
    }

    private static func cycleHighlights(_ shown: Shown, text: String) async -> (highlights: WaveformCycleHighlights.Result, rows: [[String]])? {
        let page = shown.waveform.nativeViewSessions.waveform
        // The page's cycle must be the one these values were read at.
        guard let state = await page.callDebugger("state") as? [String: Any],
              (state["time"] as? NSNumber)?.int64Value == shown.time,
              let previous = (state["previousTime"] as? NSNumber)?.int64Value,
              !Task.isCancelled else {
            clear(in: shown.textView)
            return nil
        }
        var changed: [String: Set<String>] = [:]
        for (module, now) in shown.values {
            guard let instance = shown.instances[module], !now.isEmpty else { continue }
            let names = now.keys.sorted()
            let values = await WaveformSourceLink.inlineValues(
                names: names, dumpInstance: instance.dump, waveform: shown.waveform, time: previous
            )
            guard !Task.isCancelled else { return nil }
            var before: [String: String] = [:]
            for (name, value) in zip(names, values) {
                if let value { before[name] = value }
            }
            changed[module] = WaveformCycleHighlights.changedNames(now: now, before: before)
        }
        let nsText = text as NSString
        var result = WaveformCycleHighlights.highlights(lines: shown.lines, text: nsText, changed: changed)
        await addPortDrivers(to: &result, changed: changed, shown: shown, text: nsText)
        // An edit since: the ranges are stale, and the edit's refresh follows.
        guard !Task.isCancelled, shown.textView.string == text else { return nil }
        var rows: [[String]] = []
        for (module, names) in changed {
            guard let instance = shown.instances[module] else { continue }
            let scope = HierarchyPathMapping.segments(instance.dump)
            rows += names.sorted().map { scope + [$0] }
        }
        return (result, Array(rows.prefix(maxRows)))
    }

    /// Changed signals no line here assigns may be driven by a child instance's
    /// output port (slang's driver cone says which): its connection line drives them.
    private static func addPortDrivers(
        to result: inout WaveformCycleHighlights.Result,
        changed: [String: Set<String>],
        shown: Shown,
        text: NSString
    ) async {
        guard let session = shown.editor.linkSession?.session else { return }
        let server = ObjectIdentifier(session)
        var requests = 0
        var lines = Set(result.driverLines.map(\.location))
        for module in changed.keys.sorted() {
            guard let instance = shown.instances[module], !instance.design.isEmpty else { continue }
            for name in changed[module, default: []].sorted() where result.assigned[module]?.contains(name) != true {
                let path = instance.design + "." + name
                let key = ConeKey(server: server, path: path)
                var cone = cones[key]
                if cone == nil {
                    guard requests < maxConeRequests else { continue }
                    requests += 1
                    let found = (try? await session.slangDriverCone(path)) ?? []
                    guard !Task.isCancelled else { return }
                    if cones.count >= maxCachedCones { cones.removeAll() }
                    cones[key] = found
                    cone = found
                }
                for child in WaveformCycleHighlights.drivingChildInstances(cone: cone ?? [], designInstance: instance.design) {
                    guard let start = shown.lines.firstIndex(where: { line in
                        line.module == module && line.identifiers.contains { $0.name == child }
                    }) else { continue }
                    for range in WaveformCycleHighlights.connectionLines(of: name, instantiationAt: start, lines: shown.lines, text: text)
                    where lines.insert(range.location).inserted {
                        result.driverLines.append(range)
                    }
                }
            }
        }
    }

    private static func apply(_ result: WaveformCycleHighlights.Result, lines: [SystemVerilogInlineScan.Line], in textView: NSTextView) {
        clear(in: textView)
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        let drawn = Drawn()
        func add(_ key: NSAttributedString.Key, _ value: Any, _ range: NSRange) {
            guard range.length > 0, NSMaxRange(range) <= length else { return }
            layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
            drawn.attributes.append((range, key, value))
        }
        let driverStarts = Set(result.driverLines.map(\.location))
        let drivingModules = Set(lines.filter { driverStarts.contains($0.contentRange.location) }.compactMap(\.module))
        let dimmed = (textView.textColor ?? .textColor).withAlphaComponent(0.4)
        for line in lines where line.module.map(drivingModules.contains) == true && !driverStarts.contains(line.contentRange.location) {
            add(.foregroundColor, dimmed, line.contentRange)
        }
        for range in result.driverLines {
            add(.backgroundColor, NSColor.systemYellow.withAlphaComponent(0.16), range)
        }
        for range in result.changedIdentifiers {
            add(.backgroundColor, NSColor.systemOrange.withAlphaComponent(0.4), range)
        }
        cycleDrawn.setObject(drawn, forKey: textView)
        drawSelection(in: textView)
    }

    /// Removes the cycle highlights (not the selected row's) from `textView`.
    static func clear(in textView: NSTextView?) {
        guard let textView else { return }
        work.object(forKey: textView)?.task?.cancel()
        remove(cycleDrawn.object(forKey: textView), from: textView)
        cycleDrawn.removeObject(forKey: textView)
        drawSelection(in: textView)
    }

    private static func remove(_ drawn: Drawn?, from textView: NSTextView) {
        guard let drawn, let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        for (range, key, _) in drawn.attributes {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            if clamped.length > 0 { layoutManager.removeTemporaryAttribute(key, forCharacterRange: clamped) }
        }
    }

    // MARK: Waveform rows

    private static func setRows(_ paths: [[String]], from editor: FilePreviewLanguageFeatures, in waveform: FilePreviewPanel) {
        let mine = rowPaths.object(forKey: editor) ?? Paths()
        mine.paths = paths
        rowPaths.setObject(mine, forKey: editor)
        var all: [[String]] = []
        for other in FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId) {
            guard WaveformSourceLink.waveformPanel(near: other.linkPanel) === waveform else { continue }
            for path in rowPaths.object(forKey: other)?.paths ?? [] where !all.contains(path) { all.append(path) }
        }
        let sent = sentRows.object(forKey: waveform) ?? Paths()
        guard sent.paths != all else { return }
        sent.paths = all
        sentRows.setObject(sent, forKey: waveform)
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("highlightRows", argument: ["paths": all])
        }
    }

    /// The viewer stopped stepping (the page dropped its highlights itself).
    static func forget(_ waveform: FilePreviewPanel) {
        sentRows.removeObject(forKey: waveform)
        showSelection(nil, drivers: [], near: nil)
    }

    // MARK: Selected row → editor

    /// Lights the lines of `declaration` and `drivers` in the editor showing their file
    /// (nil: removes the last selection's lines).
    static func showSelection(_ declaration: LSPLocation?, drivers: [LSPLocation], near editor: FilePreviewLanguageFeatures?) {
        for textView in selectionLines.keyEnumerator().allObjects.compactMap({ $0 as? NSTextView }) {
            let drawn = selectionLines.object(forKey: textView)
            selectionLines.removeObject(forKey: textView)
            remove(drawn, from: textView)
            // The cycle highlights under the selection's lines come back.
            if let cycle = cycleDrawn.object(forKey: textView) { redraw(cycle, in: textView) }
        }
        guard let declaration, let editor,
              let target = FilePreviewLanguageFeatures.linkable(showingDocumentPath: declaration.uri.standardizedFileURL.path, like: editor),
              let textView = target.debuggerTextView else { return }
        let text = textView.string as NSString
        let lineIndex = FilePreviewLSPLineIndex(textView.string)
        let drawn = Drawn()
        let color = NSColor.systemBlue.withAlphaComponent(0.24)
        for location in [declaration] + drivers {
            let start = lineIndex.offset(for: location.range.start)
            guard start <= text.length else { continue }
            var line = text.lineRange(for: NSRange(location: start, length: 0))
            while line.length > 0, let last = Unicode.Scalar(text.character(at: NSMaxRange(line) - 1)),
                  CharacterSet.newlines.contains(last) {
                line.length -= 1
            }
            if line.length > 0 { drawn.attributes.append((line, .backgroundColor, color)) }
        }
        selectionLines.setObject(drawn, forKey: textView)
        drawSelection(in: textView)
    }

    private static func drawSelection(in textView: NSTextView) {
        if let drawn = selectionLines.object(forKey: textView) { redraw(drawn, in: textView) }
    }

    private static func redraw(_ drawn: Drawn, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        for (range, key, value) in drawn.attributes where range.length > 0 && NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttribute(key, value: value, forCharacterRange: range)
        }
    }
}
