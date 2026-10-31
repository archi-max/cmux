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

    /// The clock reports are timed by. (Not yet used.)
    static var now: () -> Date = { Date() }

    private final class Report {
        let time: Int64
        let drew: Bool
        let reasons: [String: Reason]

        init(time: Int64, drew: Bool, reasons: [String: Reason]) {
            self.time = time
            self.drew = drew
            self.reasons = reasons
        }
    }

    private final class Sent {
        var status: [String: AnyHashable]?
    }

    private static let reports = NSMapTable<FilePreviewLanguageFeatures, Report>.weakToStrongObjects()
    private static let sent = NSMapTable<FilePreviewPanel, Sent>.weakToStrongObjects()

    /// The editors that follow `waveform`: those of its workspace whose viewer it is.
    private static func editors(of waveform: FilePreviewPanel) -> [FilePreviewLanguageFeatures] {
        FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId).filter {
            WaveformSourceLink.waveformPanel(near: $0.linkPanel) === waveform
        }
    }

    /// `editor` finished with the cycle at `time`: it showed values (`drew`), or not, for `reasons`.
    static func editorDone(_ editor: FilePreviewLanguageFeatures, waveform: FilePreviewPanel, time: Int64, drew: Bool, reasons: [String: Reason]) {
        reports.setObject(Report(time: time, drew: drew, reasons: reasons), forKey: editor)
        report(waveform)
        ackIfAllShown(waveform)
    }

    /// Every editor that follows `waveform` is at the same cycle: the page may move on
    /// (it ignores an ack for a cycle it isn't waiting on).
    private static func ackIfAllShown(_ waveform: FilePreviewPanel) {
        guard WaveformDebugger.isStepping(waveform) else { return }
        let times = editors(of: waveform).map { reports.object(forKey: $0)?.time }
        guard let first = times.first, let time = first, times.allSatisfy({ $0 == time }) else { return }
        let page = waveform.nativeViewSessions.waveform
        Task { _ = await page.callDebugger("rtlShown", argument: ["time": NSNumber(value: time)]) }
    }

    /// Play started on `waveform`: what its editors drew before doesn't count for the cycles to come.
    static func playStarted(_ waveform: FilePreviewPanel) {
        for editor in editors(of: waveform) { reports.removeObject(forKey: editor) }
        report(waveform)
    }

    /// `editor` closed or stopped linking: the viewers it followed no longer wait for it.
    static func editorGone(_ editor: FilePreviewLanguageFeatures) {
        reports.removeObject(forKey: editor)
        for case let waveform as FilePreviewPanel in sent.keyEnumerator().allObjects {
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
        let editors = editors(of: waveform)
        let mine = sent.object(forKey: waveform) ?? Sent()
        sent.setObject(mine, forKey: waveform)
        let page = waveform.nativeViewSessions.waveform
        let status = self.status(of: editors)
        if mine.status != status {
            mine.status = status
            Task { _ = await page.callDebugger("setRtlStatus", argument: status) }
        }
    }

    private static func status(of editors: [FilePreviewLanguageFeatures]) -> [String: AnyHashable] {
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
                notes.append(note(file, text))
                if firstReason == nil, !report.drew { firstReason = rtl(text) }
            }
        }
        let text: String
        if drawn.count == 1 {
            text = rtl(drawn[0])
        } else if drawn.count > 1 {
            text = String(format: String(localized: "waveformDebugger.rtl.files", defaultValue: "RTL: %@ files"), String(drawn.count))
        } else if !anyReported {
            text = rtl(waiting)
        } else {
            text = firstReason ?? String(
                localized: "waveformDebugger.rtl.noValues",
                defaultValue: "RTL: no values for the lines on screen"
            )
        }
        let tooltip = (drawn + notes).joined(separator: "\n")
        return ["text": text, "tooltip": tooltip, "ok": !drawn.isEmpty, "wait": waitsForEditor]
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
