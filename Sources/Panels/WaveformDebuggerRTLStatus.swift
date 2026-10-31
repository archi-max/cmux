import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// The RTL item in the waveform debugger's strip: which editors follow the cycle,
/// or why none does (with the fix when there is one). It also tells the page when
/// every linked editor has drawn a cycle (`rtlShown`), so play can wait for them.
@MainActor
enum WaveformDebuggerRTLStatus {
    /// Why an editor's module shows no values.
    enum Reason: Equatable {
        case notPlaced
        case severalInstances(module: String)
        case onlyShownValues
        case noneDumped(instance: String)
    }

    /// Whether play waits for the editors to draw each cycle (at most 250 ms, in the page).
    static let waitForEditorKey = "waveformDebugger.waitForEditor"
    static var waitsForEditor: Bool { UserDefaults.standard.object(forKey: waitForEditorKey) as? Bool ?? true }

    private final class Report {
        let time: Int64
        let drew: Bool
        let reasons: [String: Reason]
        /// The viewer's play it was made in (`Sent.play`): reports from before don't count for the wait.
        let play: Int

        init(time: Int64, drew: Bool, reasons: [String: Reason], play: Int) {
            self.time = time
            self.drew = drew
            self.reasons = reasons
            self.play = play
        }
    }

    /// The clock moves and reports are timed by (the checks set it).
    static var now: () -> Date = { Date() }
    /// The page's wait for the editors on a played cycle (RTL_WAIT_MS in cmux-debugger.js).
    static let pageWait: TimeInterval = 0.25
    /// Plays started on any viewer: a report's play tells which one it was made in, across pages too.
    private static var plays = 0

    /// Per viewer: what its page was told, and the editors play waits for.
    private final class Sent {
        var status: [String: AnyHashable]?
        /// The play going on (or last), from `plays`: reports made before it don't count.
        var play = 0
        /// When the page moved to each recent played cycle.
        var movedAt: [Int64: Date] = [:]
        /// While playing, the cycle the page is on (it waits for the editors there).
        var pageTime: Int64?
        /// Editors the page moved on without (they missed a cycle): not waited for until they
        /// draw a played cycle within the page's wait of its move. Else one stalled editor caps
        /// every cycle at 250 ms.
        let behind = NSHashTable<FilePreviewLanguageFeatures>.weakObjects()
    }

    private static let reports = NSMapTable<FilePreviewLanguageFeatures, Report>.weakToStrongObjects()
    private static let sent = NSMapTable<FilePreviewPanel, Sent>.weakToStrongObjects()

    private static func state(_ waveform: FilePreviewPanel) -> Sent {
        if let mine = sent.object(forKey: waveform) { return mine }
        let mine = Sent()
        sent.setObject(mine, forKey: waveform)
        return mine
    }

    /// The editors that follow `waveform`: those of its workspace whose viewer it is.
    private static func editors(of waveform: FilePreviewPanel) -> [FilePreviewLanguageFeatures] {
        FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId).filter {
            WaveformSourceLink.waveformPanel(near: $0.linkPanel) === waveform
        }
    }

    /// The editors play waits for: those following `waveform` that keep up with its page.
    private static func waitedFor(_ waveform: FilePreviewPanel) -> [FilePreviewLanguageFeatures] {
        let mine = state(waveform)
        return editors(of: waveform).filter { !mine.behind.contains($0) }
    }

    /// `editor` finished with the cycle at `time`: it showed values (`drew`), or not, for `reasons`.
    static func editorDone(_ editor: FilePreviewLanguageFeatures, waveform: FilePreviewPanel, time: Int64, drew: Bool, reasons: [String: Reason]) {
        let mine = state(waveform)
        reports.setObject(Report(time: time, drew: drew, reasons: reasons, play: mine.play), forKey: editor)
        // Not playing, or it drew a played cycle in time: it keeps up again.
        if mine.pageTime == nil {
            mine.behind.remove(editor)
        } else if let movedAt = mine.movedAt[time], now().timeIntervalSince(movedAt) < pageWait {
            mine.behind.remove(editor)
        }
        report(waveform)
        ackIfAllShown(waveform)
    }

    /// Every editor play waits for drew the page's cycle (or, stepped by hand, the same cycle):
    /// the page may move on. It ignores an ack for a cycle it isn't waiting on.
    private static func ackIfAllShown(_ waveform: FilePreviewPanel) {
        guard WaveformDebugger.isStepping(waveform) else { return }
        let mine = state(waveform)
        let times = waitedFor(waveform).map { editor -> Int64? in
            guard let report = reports.object(forKey: editor), report.play == mine.play else { return nil }
            return report.time
        }
        guard let first = times.first, let time = mine.pageTime ?? first,
              times.allSatisfy({ $0 == time }) else { return }
        let page = waveform.nativeViewSessions.waveform
        Task { _ = await page.callDebugger("rtlShown", argument: ["time": NSNumber(value: time)]) }
    }

    /// Play started on `waveform`: what its editors drew before doesn't count for the wait
    /// (the strip still shows it), and every editor is waited for again.
    static func playStarted(_ waveform: FilePreviewPanel) {
        let mine = state(waveform)
        plays += 1
        mine.play = plays
        mine.pageTime = nil
        mine.movedAt = [:]
        mine.behind.removeAllObjects()
        report(waveform)
    }

    /// While playing, the page moved to the cycle at `time` from `left`; `missed`: it gave up
    /// waiting on `left`. The editors that hadn't drawn `left` by then are behind. (The page
    /// says so itself: the viewer's markerSet, which editors refresh on, lags when it is busy.)
    static func pageMoved(_ waveform: FilePreviewPanel, to time: Int64, left: Int64?, missed: Bool) {
        let mine = state(waveform)
        if missed, let left = left ?? mine.pageTime {
            for editor in editors(of: waveform) {
                guard let report = reports.object(forKey: editor), report.play == mine.play,
                      report.time == left || report.time == time else {
                    mine.behind.add(editor)
                    continue
                }
            }
        }
        mine.pageTime = time
        mine.movedAt[time] = now()
        if mine.movedAt.count > 64, let oldest = mine.movedAt.min(by: { $0.value < $1.value })?.key {
            mine.movedAt[oldest] = nil
        }
        report(waveform)
        // Every editor may have drawn this cycle already.
        ackIfAllShown(waveform)
    }

    /// Play paused or ended: no editor is behind any more, so the next play (and the strip) start
    /// out waiting for all of them.
    static func playStopped(_ waveform: FilePreviewPanel) {
        let mine = state(waveform)
        mine.pageTime = nil
        mine.movedAt = [:]
        mine.behind.removeAllObjects()
        report(waveform)
    }

    /// "Play Waits for the Editor" changed: every editor is waited for again.
    static func waitSettingChanged(_ waveform: FilePreviewPanel) {
        state(waveform).behind.removeAllObjects()
        report(waveform)
    }

    /// `editor` closed or stopped linking: the viewers it followed no longer wait for it.
    static func editorGone(_ editor: FilePreviewLanguageFeatures) {
        reports.removeObject(forKey: editor)
        for case let waveform as FilePreviewPanel in sent.keyEnumerator().allObjects {
            state(waveform).behind.remove(editor)
            report(waveform)
            ackIfAllShown(waveform)
        }
    }

    /// The page forgot what it was told (stepping stopped, or a new page).
    static func forget(_ waveform: FilePreviewPanel) {
        sent.removeObject(forKey: waveform)
    }

    /// Sends the strip's status when it changed.
    static func report(_ waveform: FilePreviewPanel) {
        guard WaveformDebugger.isStepping(waveform) else { return }
        let mine = state(waveform)
        let page = waveform.nativeViewSessions.waveform
        let status = self.status(of: editors(of: waveform), waitsForAny: !waitedFor(waveform).isEmpty)
        if mine.status != status {
            mine.status = status
            Task { _ = await page.callDebugger("setRtlStatus", argument: status) }
        }
    }

    /// `waitsForAny`: some editor keeps up, so play waits (when the setting is on).
    private static func status(of editors: [FilePreviewLanguageFeatures], waitsForAny: Bool) -> [String: AnyHashable] {
        guard !editors.isEmpty else {
            let text = String(
                localized: "waveformDebugger.rtl.noEditor",
                defaultValue: "RTL: open a SystemVerilog file of this design to follow it"
            )
            return ["text": text, "tooltip": text, "ok": false, "wait": false]
        }
        var drawn: [String] = []
        var notes: [String] = []
        var firstReason: String?
        var anyReported = false
        let waiting = String(localized: "waveformDebugger.rtl.waiting", defaultValue: "waiting for the editor")
        for editor in editors {
            let file = (editor.filePath as NSString).lastPathComponent
            guard let report = reports.object(forKey: editor) else {
                notes.append(note(file, waiting))
                continue
            }
            anyReported = true
            if report.drew { drawn.append(file) }
            for (_, reason) in report.reasons.sorted(by: { $0.key < $1.key }) {
                let text = self.text(of: reason, file: file)
                // (Not placed already names the file.)
                notes.append(reason == .notPlaced ? text : note(file, text))
                if firstReason == nil, !report.drew { firstReason = rtl(text) }
            }
        }
        let text: String
        if drawn.count == 1 {
            text = rtl(drawn[0])
        } else if drawn.count > 1 {
            text = String(localized: "waveformDebugger.rtl.files", defaultValue: "RTL: \(drawn.count) files")
        } else if !anyReported {
            text = rtl(waiting)
        } else {
            text = firstReason ?? String(
                localized: "waveformDebugger.rtl.noValues",
                defaultValue: "RTL: no values for the lines on screen"
            )
        }
        let tooltip = (drawn + notes).joined(separator: "\n")
        return ["text": text, "tooltip": tooltip, "ok": !drawn.isEmpty, "wait": waitsForEditor && waitsForAny]
    }

    /// The strip's item: "RTL: " and what follows.
    private static func rtl(_ text: String) -> String {
        String(format: String(localized: "waveformDebugger.rtl.item", defaultValue: "RTL: %@"), text)
    }

    /// A tooltip line about one file.
    private static func note(_ file: String, _ text: String) -> String {
        String(format: String(localized: "waveformDebugger.rtl.note", defaultValue: "%1$@: %2$@"), file, text)
    }

    private static func text(of reason: Reason, file: String) -> String {
        switch reason {
        case .notPlaced:
            return String(
                format: String(
                    localized: "waveformDebugger.rtl.notPlaced",
                    defaultValue: "%@ isn’t placed in the design. Set a top level or build file in .slang/server.json."
                ),
                file
            )
        case .severalInstances(let module):
            return String(
                format: String(
                    localized: "waveformDebugger.rtl.severalInstances",
                    defaultValue: "%@ has several instances. Right-click and choose Show Waveform Values For."
                ),
                module
            )
        case .onlyShownValues:
            return String(
                localized: "waveformDebugger.rtl.onlyShown",
                defaultValue: "no values. Turn on View > Show FSDB Values for Signals Not in the Waveform."
            )
        case .noneDumped(let instance):
            return String(
                format: String(localized: "waveformDebugger.rtl.noneDumped", defaultValue: "the waveform has no signals under %@."),
                instance
            )
        }
    }
}
