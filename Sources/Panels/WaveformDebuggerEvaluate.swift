import AppKit
import CmuxSyntaxHighlighting

/// The waveform debugger's Evaluate from a SystemVerilog editor, and its watches in the session.
/// "Evaluate at Cycle N" in the editor's context menu evaluates the selection (or the identifier
/// clicked) in the viewer's page (cmux-expr.js), in the dump instance of the clicked line's module;
/// the result shows in the viewer's cycle strip. The page reports its watch list
/// (`{ event: 'watches', items }`), kept per workspace and sent back to a new page.
@MainActor
enum WaveformDebuggerEvaluate {
    /// The page's limit on an expression's length (cmux-expr.js MAX_TEXT).
    static let maxExpressionLength = 1000

    /// What a right-click at `index` evaluates: the selection when it has text and contains the
    /// click (or no click is given), else the identifier at the click (or just before it).
    static func expression(in text: NSString, selection: NSRange, at index: Int?) -> String? {
        let clickInSelection = index.map { NSLocationInRange($0, selection) || $0 == NSMaxRange(selection) } ?? true
        if selection.length > 0, clickInSelection, NSMaxRange(selection) <= text.length {
            let picked = text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !picked.isEmpty, picked.count <= maxExpressionLength else { return nil }
            return picked
        }
        guard let index else { return nil }
        guard let range = FilePreviewLanguageIdentifier.range(containing: index, in: text)
            ?? FilePreviewLanguageIdentifier.range(containing: index - 1, in: text) else { return nil }
        return text.substring(with: range)
    }

    /// "Evaluate at Cycle N", while the editor's viewer is being stepped; nil otherwise.
    static func menuItem(for editor: FilePreviewLanguageFeatures, at index: Int?) -> NSMenuItem? {
        guard let textView = editor.debuggerTextView,
              let waveform = WaveformSourceLink.waveformPanel(near: editor.linkPanel),
              WaveformDebugger.isStepping(waveform),
              let expr = expression(in: textView.string as NSString, selection: textView.selectedRange(), at: index)
        else { return nil }
        let instance = editor.debuggerInstance(at: index ?? textView.selectedRange().location)
        let scope = instance.map { HierarchyPathMapping.segments($0.dump) } ?? []
        let state = WaveformDebugger.state(of: waveform)
        let title = state.cycle.map {
            String(
                format: String(localized: "waveformDebugger.evaluateAtCycle", defaultValue: "Evaluate at Cycle %@"),
                NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)
            )
        } ?? String(localized: "waveformDebugger.evaluateAtMarker", defaultValue: "Evaluate at the Marker")
        return ActionMenuItem(title: title) { [weak waveform] in
            guard let waveform else { return }
            evaluate(expr, scope: scope, in: waveform)
        }
    }

    /// Evaluates `expr` at the marker in `scope` (dump path segments; empty: the shown instance)
    /// and shows it in the viewer's cycle strip, which keeps it in its history.
    static func evaluate(_ expr: String, scope: [String], in waveform: FilePreviewPanel) {
        var argument: [String: Any] = ["expr": expr, "show": true]
        if !scope.isEmpty { argument["scope"] = scope }
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("evaluate", argument: argument)
        }
    }

    // MARK: Watches in the session

    private(set) static var watches: [UUID: [String]] = [:]

    /// `{ event: 'watches', items: [expr, ...] }` from the page.
    static func watchesReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let items = (body["items"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxExpressionLength }
        watches[waveform.workspaceId] = items.isEmpty ? nil : items
    }

    /// A new page has no watches: it gets the workspace's.
    static func pageLoaded(_ waveform: FilePreviewPanel) {
        guard let items = watches[waveform.workspaceId], !items.isEmpty else { return }
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("restoreWatches", argument: ["items": items])
        }
    }

    /// The workspace's watches for its session snapshot; nil when it has none.
    static func snapshot(of workspace: UUID) -> [String]? {
        guard let items = watches[workspace], !items.isEmpty else { return nil }
        return items
    }

    /// Watches from a restored session; they go to the workspace's viewers when their pages load.
    static func restore(_ items: [String]?, in workspace: UUID) {
        guard let items, !items.isEmpty else { return }
        watches[workspace] = items
    }

    @MainActor private final class ActionMenuItem: NSMenuItem {
        private let run: @MainActor () -> Void
        init(title: String, run: @escaping @MainActor () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(runItem), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func runItem() { run() }
    }
}
