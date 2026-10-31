import CmuxTerminalCore
import Foundation

/// VaporView's terminal links for cmux terminals (VaporView,
/// https://github.com/Lramseyer/vaporview, GPL-3.0,
/// `src/extension_core/terminal_links.ts`@59107c6).
///
/// ⌘-click in a terminal of a workspace that has a waveform viewer open:
/// - a UVM timestamp (`@ 50000`) sets the marker at that time in the dump's units;
/// - a time with units (`1,250 ns`, `3.5us`) sets the marker at that time;
/// - an instance path under one of the dump's top scopes (`top.core.alu.acc`)
///   adds that signal to the viewer, unless `enableInstancePathTerminalLinks` is off.
///
/// `WaveformTerminalLink` (CmuxTerminalCore) finds the link. The terminal tries
/// an existing file first, and a link no viewer can use (no such signal, a time
/// past the end) leaves the click to cmux's own links.
enum WaveformTerminalLinks {
    typealias Link = WaveformTerminalLink

    /// The workspace's waveform viewers, the one to use first: the focused
    /// viewer, then the one used last, then by path.
    @MainActor
    static func viewers(in workspace: Workspace) -> [FilePreviewPanel] {
        let viewers = workspace.panels.values
            .compactMap { $0 as? FilePreviewPanel }
            .filter { !$0.isClosed && $0.previewMode == .waveform && $0.nativeViewSessions.waveform.isFileOpen }
            .sorted { $0.filePath < $1.filePath }
        let focused = workspace.focusedPanelId
        let last = FilePreviewWaveformSession.lastActivePanel
        return viewers.sorted { a, b in
            func rank(_ panel: FilePreviewPanel) -> Int {
                panel.id == focused ? 0 : (panel === last ? 1 : 2)
            }
            return rank(a) < rank(b)
        }
    }

    /// The link under `column` of `line` that a viewer of `workspace` can take, if any.
    @MainActor
    static func link(line: String, column: Int, workspace: Workspace) -> (Link, [FilePreviewPanel])? {
        let viewers = viewers(in: workspace)
        guard !viewers.isEmpty else { return nil }
        let utf16Column = Link.utf16Offset(ofCharacter: column, in: line)
        let instancePaths = FilePreviewWaveformSession.storedSettings()["enableInstancePathTerminalLinks"] as? Bool ?? true
        let tops = Array(Set(viewers.flatMap { $0.nativeViewSessions.waveform.topScopes }))
        guard let link = Link.detect(in: line, column: utf16Column, topScopes: tops, instancePaths: instancePaths) else { return nil }
        if case .instancePath(let path) = link {
            let top = String(path.prefix { $0 != "." })
            return (link, viewers.filter { $0.nativeViewSessions.waveform.topScopes.contains(top) })
        }
        return (link, viewers)
    }

    /// Sets the marker or adds the signal in the first of `viewers` that can.
    /// Returns false when none could (no such signal, a time past the end).
    @MainActor
    static func open(_ link: Link, in viewers: [FilePreviewPanel]) async -> Bool {
        for viewer in viewers {
            let session = viewer.nativeViewSessions.waveform
            let result: Any?
            switch link {
            case .instancePath(let path):
                result = await session.runCommandResult("waveformViewer.addVariable", args: ["instancePath": path, "quiet": true])
            case .time(let time, let units):
                var args: [String: Any] = ["time": time, "markerType": 0]
                args["units"] = units
                result = await session.runCommandResult("waveformViewer.setMarker", args: args)
            }
            if result as? Bool == true {
                return true
            }
        }
        return false
    }
}
