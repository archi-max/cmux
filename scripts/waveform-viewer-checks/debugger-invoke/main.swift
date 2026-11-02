// Waveform debugger invocation (run.sh debugger-invoke): the real
// Sources/Panels/WaveformDebuggerInvocation.swift. A command from the View menu or the
// command palette runs on the focused viewer even while one of its text fields (the
// Sequences or netlist search) has focus; a shortcut key goes to that field only when
// it types text (F5 and F10 don't); an explicit command with no viewer says why, in a
// notice over the window, instead of a bare beep.
import AppKit

nonisolated(unsafe) var failures = 0
func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

final class Viewer {}
typealias I = WaveformDebuggerInvocation

func describe(_ decision: I.Decision<Viewer>, _ viewers: [String: Viewer]) -> String {
    switch decision {
    case .perform(let viewer): return "perform " + (viewers.first { $0.value === viewer }?.key ?? "?")
    case .passKey: return "passKey"
    case .unavailable: return "unavailable"
    }
}

@MainActor func run() {
    let focused = Viewer(), nearEditor = Viewer()
    var names = ["focused": focused, "nearEditor": nearEditor]
    let inWorkspace = Viewer()
    names["inWorkspace"] = inWorkspace
    func decide(_ source: I.Source, focused viewer: Viewer?, field: Bool, editor: Viewer? = nil, workspace: Viewer? = nil) -> String {
        describe(I.decide(source: source, focusedViewer: viewer, viewerFieldFocused: field, editorViewer: editor, workspaceViewer: workspace), names)
    }
    // The user's report: the Sequences search had focus, View > Waveform Debugger > Continue beeped.
    expect(decide(.menu, focused: focused, field: true) == "perform focused", "the menu runs on the viewer while its search field has focus")
    expect(decide(.palette, focused: focused, field: true) == "perform focused", "the palette too")
    expect(decide(.menu, focused: focused, field: false) == "perform focused", "and without a field focused")
    // F5 in that field: a function key types nothing, so it runs.
    expect(decide(.key(typesText: false), focused: focused, field: true) == "perform focused", "F5 with the viewer's search field focused runs")
    // A shortcut rebound to a key that types text goes to the field.
    expect(decide(.key(typesText: true), focused: focused, field: true) == "passKey", "a text-typing shortcut key goes to the focused field")
    expect(decide(.key(typesText: true), focused: focused, field: false) == "perform focused", "and runs when no field has focus")
    // A SystemVerilog editor next to a viewer.
    expect(decide(.key(typesText: false), focused: nil, field: false, editor: nearEditor) == "perform nearEditor", "a key in the editor runs on the viewer next to it")
    expect(decide(.menu, focused: nil, field: false, editor: nearEditor) == "perform nearEditor", "the menu too")
    // Nothing to act on: a key goes on (a terminal gets its F5); the menu and palette say why.
    expect(decide(.key(typesText: false), focused: nil, field: false) == "passKey", "a key with no viewer goes on to the focused view")
    expect(decide(.menu, focused: nil, field: false) == "unavailable", "the menu with no viewer is unavailable")
    expect(decide(.palette, focused: nil, field: false) == "unavailable", "the palette too")
    // verify Q2: the menu and palette act on the workspace's focused viewer (focusedPanelId) even when
    // its web view doesn't hold the window's first responder; a key still needs the responder there.
    expect(decide(.menu, focused: nil, field: false, workspace: inWorkspace) == "perform inWorkspace",
           "the menu acts on the workspace's focused viewer without the responder")
    expect(decide(.palette, focused: nil, field: true, workspace: inWorkspace) == "perform inWorkspace",
           "the palette too, with a field focused")
    expect(decide(.key(typesText: false), focused: nil, field: false, workspace: inWorkspace) == "passKey",
           "a key without the responder in a viewer goes on (a terminal keeps its F5)")
    expect(decide(.menu, focused: focused, field: false, workspace: inWorkspace) == "perform focused",
           "the viewer holding the responder comes first")
    expect(decide(.menu, focused: nil, field: false, editor: nearEditor, workspace: inWorkspace) == "perform nearEditor",
           "then the viewer next to a focused editor")

    // Which key characters type text.
    let f5 = String(UnicodeScalar(UInt16(NSF5FunctionKey))!), f10 = String(UnicodeScalar(UInt16(NSF10FunctionKey))!)
    expect(!I.typesText(f5) && !I.typesText(f10), "F5 and F10 type no text")
    expect(!I.typesText("\u{1B}") && !I.typesText("\r") && !I.typesText("\t") && !I.typesText(nil) && !I.typesText(""), "Esc, Return, Tab and no characters type none")
    expect(I.typesText("n") && I.typesText(" ") && I.typesText("é"), "letters and space type text")

    // The notice: shown over the window's content, one at a time, gone after a moment.
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    WaveformDebuggerNotice.duration = 0.2
    let label = WaveformDebuggerNotice.show(I.unavailableMessage, in: content)
    _ = WaveformDebuggerNotice.show(I.unavailableMessage, in: content)
    let notices = content.subviews.filter { $0.identifier == WaveformDebuggerNotice.identifier }
    expect(label?.stringValue == "Focus a waveform viewer, or a SystemVerilog editor next to one." && notices.count == 1,
           "an explicit command with no viewer shows why, once: \(label?.stringValue ?? "nil") x\(notices.count)")
    expect(WaveformDebuggerNotice.show("x", in: nil) == nil, "no window: nothing shown (the caller beeps)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        expect(content.subviews.allSatisfy { $0.identifier != WaveformDebuggerNotice.identifier }, "the notice goes away")
        print(failures == 0 ? "DEBUGGER INVOKE CHECKS PASSED" : "DEBUGGER INVOKE CHECKS FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timeout"); exit(1) }
app.run()
