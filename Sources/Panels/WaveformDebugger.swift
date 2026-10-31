import AppKit
import CmuxSyntaxHighlighting
import Foundation

/// The waveform debugger (FEATURES.md section F, phase 1): a recorded run is
/// stepped one clock cycle at a time, and the SystemVerilog editor follows it.
///
/// The viewer page does the stepping (`Resources/vaporview/cmux-debugger.js`,
/// `window.cmuxWaveform.debugger`) and reports each cycle; this side runs the
/// commands from the keyboard, the View menu and the command palette, keeps
/// the Locals group on the instance at the editor's caret, and highlights in
/// the editor the declaration and drivers of the row selected in the waveform.
@MainActor
enum WaveformDebugger {
    enum Command: Equatable {
        case step(Int)
        case first
        case last
        case togglePlay
        /// Continue (1) or reverse continue (-1) to the nearest breakpoint hit.
        case continueToBreakpoint(Int)
        /// F5: continue when a breakpoint is enabled, else play or pause.
        case continueOrTogglePlay
        case faster
        case slower
        case useSelectedAsClock
        case defaultClock
        case stop
    }

    static let shortcutCommands: [(KeyboardShortcutSettings.Action, Command)] = [
        (.stepWaveformCycleForward, .step(1)),
        (.stepWaveformCycleBack, .step(-1)),
        (.toggleWaveformPlayback, .continueOrTogglePlay),
        (.reverseContinueWaveform, .continueToBreakpoint(-1)),
    ]

    /// What the page last reported for a viewer.
    struct PageState: Equatable {
        var stepping = false
        var playing = false
        var cycle: Int?
        var time: Int64?
        var previousTime: Int64?
    }

    private final class Box {
        var state = PageState()
        /// One Locals request at a time; the caret's newest scope is sent after it
        /// (the page itself skips a request for the scope it shows).
        var locals = LatestRequestCoalescer<[String]>()
        /// The row selection last highlighted in the editor.
        var selectedPath: [String]?
    }

    private static let boxes = NSMapTable<FilePreviewPanel, Box>.weakToStrongObjects()
    private static var caretObserver: NSObjectProtocol?
    private static var localsTask: Task<Void, Never>?
    private static var selectionTask: Task<Void, Never>?

    private static func box(_ waveform: FilePreviewPanel) -> Box {
        if let box = boxes.object(forKey: waveform) { return box }
        let box = Box()
        boxes.setObject(box, forKey: waveform)
        return box
    }

    static func state(of waveform: FilePreviewPanel) -> PageState {
        boxes.object(forKey: waveform)?.state ?? PageState()
    }

    /// Whether `waveform` is being stepped: the editor highlights only then.
    static func isStepping(_ waveform: FilePreviewPanel) -> Bool {
        state(of: waveform).stepping
    }

    // MARK: Targets and commands

    /// The viewer the commands act on for a focused panel: a waveform viewer
    /// itself, or the workspace's viewer next to a SystemVerilog editor.
    static func target(for panel: FilePreviewPanel?) -> FilePreviewPanel? {
        guard let panel, !panel.isClosed else { return nil }
        if panel.previewMode == .waveform { return panel }
        guard panel.previewMode == .text, FilePreviewLanguageFeatures.isSupported(filePath: panel.filePath) else { return nil }
        return WaveformSourceLink.waveformPanel(near: panel)
    }

    /// F10, Shift-F10, F5 and Shift-F5. False (the key goes on) unless a waveform viewer,
    /// or a SystemVerilog editor with a viewer in its workspace, has focus.
    static func performFromShortcut(_ command: Command, window: NSWindow?) -> Bool {
        if let waveform = WaveformSourceLink.focusedWaveformPanel(in: window) {
            // Typing in the viewer's search or value field.
            guard !waveform.nativeViewSessions.waveform.isEditableElementFocused else { return false }
            perform(command, on: waveform)
            return true
        }
        guard let features = AppDelegate.shared?.shortcutFocusedSavingTextView(in: window)?.languageFeatures,
              let waveform = WaveformSourceLink.waveformPanel(near: features.linkPanel) else { return false }
        perform(command, on: waveform)
        return true
    }

    /// Runs `command` on the viewer for `panel` (see `target(for:)`). False when there is none.
    @discardableResult
    static func perform(_ command: Command, for panel: FilePreviewPanel?) -> Bool {
        guard let waveform = target(for: panel) else { return false }
        perform(command, on: waveform)
        return true
    }

    static func perform(_ command: Command, on waveform: FilePreviewPanel) {
        let page = waveform.nativeViewSessions.waveform
        Task { @MainActor in
            switch command {
            case .step(let by):
                _ = await page.callDebugger("step", argument: ["by": by])
            case .first:
                _ = await page.callDebugger("jump", argument: ["to": "first"])
            case .last:
                _ = await page.callDebugger("jump", argument: ["to": "last"])
            case .togglePlay:
                _ = await page.callDebugger("togglePlay")
            case .continueToBreakpoint(let direction):
                _ = await page.callDebugger("continue", argument: ["dir": direction])
            case .continueOrTogglePlay:
                _ = await page.callDebugger("continue", argument: ["dir": 1, "orTogglePlay": true])
            case .faster:
                _ = await page.callDebugger("changeRate", argument: ["by": 1])
            case .slower:
                _ = await page.callDebugger("changeRate", argument: ["by": -1])
            case .useSelectedAsClock:
                // The page says why when the selection is not a 1-bit signal.
                _ = await page.callDebugger("useSelectedAsClock")
            case .defaultClock:
                _ = await page.callDebugger("setClock", argument: ["path": NSNull()])
            case .stop:
                _ = await page.callDebugger("stop")
            }
        }
    }

    // MARK: Page reports

    /// `{ type: 'debugger', event: 'cycle' | 'state', ...state }` from the viewer page.
    static func pageReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        // A played move, posted by the page as it moves (before the viewer's markerSet).
        if body["event"] as? String == "moved" {
            if isStepping(waveform), let time = (body["movedTo"] as? NSNumber)?.int64Value {
                WaveformDebuggerRTLStatus.pageMoved(
                    waveform, to: time, left: (body["left"] as? NSNumber)?.int64Value, missed: body["missed"] as? Bool ?? false
                )
            }
            return
        }
        let box = box(waveform)
        let wasStepping = box.state.stepping
        let wasPlaying = box.state.playing
        box.state = PageState(
            stepping: body["stepping"] as? Bool ?? false,
            playing: body["playing"] as? Bool ?? false,
            cycle: (body["cycle"] as? NSNumber)?.intValue,
            time: (body["time"] as? NSNumber)?.int64Value,
            previousTime: (body["previousTime"] as? NSNumber)?.int64Value
        )
        let editors = FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId)
        if box.state.stepping, !wasStepping {
            startFollowingCaret()
            WaveformDebuggerRTLStatus.report(waveform)
            if let editor = FilePreviewLanguageFeatures.mostRecentLinkable(inWorkspace: waveform.workspaceId) {
                updateLocals(from: editor)
            }
        } else if !box.state.stepping, wasStepping {
            stoppedStepping(waveform, editors: editors)
        }
        if box.state.stepping, box.state.playing, !wasPlaying {
            WaveformDebuggerRTLStatus.playStarted(waveform)
        } else if box.state.stepping, !box.state.playing, wasPlaying {
            WaveformDebuggerRTLStatus.playStopped(waveform)
        }
    }

    /// A new page (a reload or a web content crash) starts without stepping, and doesn't say so.
    static func pageLoaded(_ waveform: FilePreviewPanel) {
        guard isStepping(waveform) else { return }
        box(waveform).state = PageState()
        stoppedStepping(waveform, editors: FilePreviewLanguageFeatures.linkables(inWorkspace: waveform.workspaceId))
    }

    private static func stoppedStepping(_ waveform: FilePreviewPanel, editors: [FilePreviewLanguageFeatures]) {
        box(waveform).selectedPath = nil
        WaveformDebuggerRTLStatus.forget(waveform)
        WaveformDebuggerEditorHighlights.forget(waveform)
        for editor in editors {
            WaveformDebuggerEditorHighlights.clear(in: editor.debuggerTextView)
        }
        // No viewer left to follow the caret for.
        let anyStepping = boxes.objectEnumerator()?.allObjects.contains { ($0 as? Box)?.state.stepping == true } ?? false
        if !anyStepping, let caretObserver {
            NotificationCenter.default.removeObserver(caretObserver)
            self.caretObserver = nil
            localsTask?.cancel()
        }
    }

    /// The "Play Waits for the Editor" setting changed: the stepping viewers hear it.
    static func waitForEditorChanged() {
        for case let waveform as FilePreviewPanel in boxes.keyEnumerator().allObjects where isStepping(waveform) {
            WaveformDebuggerRTLStatus.waitSettingChanged(waveform)
        }
    }

    /// Strings the page shows (the cycle counter, its play button, the Locals group).
    static func pageStrings() -> [String: String] {
        [
            "debuggerLocals": String(localized: "waveformDebugger.locals", defaultValue: "Locals"),
            "debuggerCycle": String(localized: "waveformDebugger.cycle", defaultValue: "Cycle %1$@ of %2$@ · %3$@"),
            "debuggerRate": String(localized: "waveformDebugger.rate", defaultValue: "%@ cycles/s"),
            "debuggerRateTooltip": String(
                localized: "waveformDebugger.rateTooltip",
                defaultValue: "Playback speed. Click for faster, Shift-click for slower."
            ),
            "debuggerPlay": String(localized: "waveformDebugger.play", defaultValue: "Play"),
            "debuggerPause": String(localized: "waveformDebugger.pause", defaultValue: "Pause"),
            "debuggerNoCycle": String(localized: "waveformDebugger.noCycle", defaultValue: "Before the first cycle"),
            "debuggerClockTooltip": String(localized: "waveformDebugger.clockTooltip", defaultValue: "Clock: %@"),
            "debuggerNoClock": String(
                localized: "waveformDebugger.noClock",
                defaultValue: "No clock found. Select a 1-bit signal and choose View > Waveform Debugger > Use Selected Signal as Clock."
            ),
            "debuggerNoEdges": String(
                localized: "waveformDebugger.noEdges",
                defaultValue: "The clock never rises in this waveform."
            ),
            "debuggerTooManyEdges": String(
                localized: "waveformDebugger.tooManyEdges",
                defaultValue: "This clock has too many cycles to step (more than 10 million), or its changes could not be read."
            ),
            "debuggerClockNotBit": String(
                localized: "waveformDebugger.clockNotBit",
                defaultValue: "Select a 1-bit signal in the waveform to use as the clock."
            ),
        ].merging(breakpointPageStrings()) { first, _ in first }
    }

    /// Strings of the page's breakpoints: the list, the row menu, the hit messages.
    private static func breakpointPageStrings() -> [String: String] {
        [
            "debuggerBreakpoints": String(localized: "waveformDebugger.breakpoints", defaultValue: "Breakpoints"),
            "debuggerBreakWhenChanges": String(localized: "waveformDebugger.breakWhenChanges", defaultValue: "Break When Changes"),
            "debuggerBreakWhenEquals": String(localized: "waveformDebugger.breakWhenEquals", defaultValue: "Break When Equals…"),
            "debuggerBreakEqualsPrompt": String(localized: "waveformDebugger.breakEqualsPrompt", defaultValue: "Break when %@ equals"),
            "debuggerBreakEqualsPlaceholder": String(
                localized: "waveformDebugger.breakEqualsPlaceholder",
                defaultValue: "For example 'h3f, 8'b1010_??01, 12 or x"
            ),
            "debuggerBreakpointChanges": String(localized: "waveformDebugger.breakpointChanges", defaultValue: "%@ changes"),
            "debuggerBreakpointEquals": String(localized: "waveformDebugger.breakpointEquals", defaultValue: "%1$@ == %2$@"),
            "debuggerRemoveBreakpoint": String(localized: "waveformDebugger.removeBreakpoint", defaultValue: "Remove Breakpoint"),
            "debuggerBreakpointHit": String(
                localized: "waveformDebugger.breakpointHit",
                defaultValue: "Breakpoint: %1$@ at %2$@ (cycle %3$@)"
            ),
            "debuggerNoHitForward": String(localized: "waveformDebugger.noHitForward", defaultValue: "No breakpoint hit before the end."),
            "debuggerNoHitBack": String(localized: "waveformDebugger.noHitBack", defaultValue: "No breakpoint hit before the start."),
            "debuggerNoBreakpoints": String(localized: "waveformDebugger.noBreakpoints", defaultValue: "No breakpoints are enabled."),
            "debuggerBadValue": String(
                localized: "waveformDebugger.badValue",
                defaultValue: "“%1$@” is not a value for a %2$@-bit signal."
            ),
            "debuggerTooManyChanges": String(
                localized: "waveformDebugger.tooManyChanges",
                defaultValue: "%@ changes too often to search here."
            ),
            "debuggerBreakpointSignalGone": String(
                localized: "waveformDebugger.breakpointSignalGone",
                defaultValue: "%@ is not in this waveform."
            ),
        ]
    }

    // MARK: Locals

    /// Caret moves in any SystemVerilog editor move Locals of its workspace's stepped viewer.
    private static func startFollowingCaret() {
        guard caretObserver == nil else { return }
        caretObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let textView = notification.object as? SavingTextView,
                      let editor = textView.languageFeatures else { return }
                localsTask?.cancel()
                localsTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    updateLocals(from: editor)
                }
            }
        }
    }

    /// Locals of the viewer next to `editor` = the signals of the dump instance at its caret.
    /// Called on caret moves and after each inline-value refresh (which learns the instances).
    static func updateLocals(from editor: FilePreviewLanguageFeatures) {
        guard let waveform = WaveformSourceLink.waveformPanel(near: editor.linkPanel), isStepping(waveform),
              let instance = editor.instanceAtCaret else { return }
        let path = HierarchyPathMapping.segments(instance.dump)
        let box = box(waveform)
        guard !path.isEmpty, let send = box.locals.want(path) else { return }
        sendLocals(send, to: waveform, box: box)
    }

    private static func sendLocals(_ path: [String], to waveform: FilePreviewPanel, box: Box) {
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callDebugger("setLocals", argument: ["path": path])
            if let next = box.locals.finished() { sendLocals(next, to: waveform, box: box) }
        }
    }

    // MARK: Waveform row → editor

    /// The user selected a row while stepping: its declaration and drivers light up in the editor.
    static func rowSelected(in waveform: FilePreviewPanel) {
        guard isStepping(waveform) else { return }
        selectionTask?.cancel()
        selectionTask = Task { @MainActor in
            // Let the viewer settle (a click selects, a drag reorders).
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let box = box(waveform)
            let path = WaveformSourceLink.dumpPath(fromPage: await waveform.nativeViewSessions.waveform.callLink("selectedSignal"))
            guard !Task.isCancelled, path != box.selectedPath else { return }
            var found: (location: LSPLocation, editor: FilePreviewLanguageFeatures)?
            if let path { found = await WaveformSourceLink.debuggerDeclaration(ofDumpPath: path, waveform: waveform) }
            // Cancelled: a newer selection is on its way and draws.
            guard !Task.isCancelled else { return }
            guard let found, isStepping(waveform) else {
                box.selectedPath = nil
                WaveformDebuggerEditorHighlights.showSelection(nil, drivers: [], near: nil)
                return
            }
            let drivers = await driverReferences(of: found.location, editor: found.editor)
            guard !Task.isCancelled else { return }
            box.selectedPath = path
            WaveformDebuggerEditorHighlights.showSelection(found.location, drivers: drivers, near: found.editor)
        }
    }

    /// The references to the declared signal that assign it, in its own file.
    private static func driverReferences(of declaration: LSPLocation, editor: FilePreviewLanguageFeatures) async -> [LSPLocation] {
        guard let session = editor.linkSession?.session,
              let references = try? await session.references(
                  uri: declaration.uri, position: declaration.range.start, includeDeclaration: false
              ) else { return [] }
        let path = declaration.uri.standardizedFileURL.path
        guard let text = FilePreviewLanguageFeatures.linkable(showingDocumentPath: path, like: editor)?.linkText else { return [] }
        let lines = text.components(separatedBy: "\n")
        return references.filter { reference in
            guard reference.uri.standardizedFileURL.path == path, lines.indices.contains(reference.range.start.line),
                  reference.range.start.line == reference.range.end.line else { return false }
            return SystemVerilogAssignmentScanner.isAssignmentTarget(
                line: lines[reference.range.start.line],
                column: reference.range.start.character,
                length: reference.range.end.character - reference.range.start.character
            )
        }
    }
}

// MARK: - Included fragments

extension WaveformDebugger {
    /// The design instances an `include`d fragment's lines are in: slang-server places a
    /// fragment's symbol only through the file that includes it (slangDesignPaths walks there).
    /// Nil when nothing was learned: cancelled, or the server failed (see `DesignInstanceProbe.firstFound`).
    static func fragmentInstances(
        session: LanguageServerSession,
        documentURI: URL,
        probes: [(name: String, position: LSPPosition)]
    ) async -> [String]? {
        await DesignInstanceProbe.firstFound(Array(probes.prefix(DesignInstanceProbe.fragmentProbeLimit))) { probe in
            let paths = try await session.slangDesignPaths(
                uri: documentURI, position: probe.position, identifier: probe.name, isInModule: false,
                searchTimeLimit: DesignInstanceProbe.fragmentSearchTimeLimit
            )
            return WaveformSourceLink.instances(holding: probe.name, paths: paths)
        }
    }
}
