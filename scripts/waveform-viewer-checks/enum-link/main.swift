// The app's enum type wiring (run.sh enum-link): the real Sources/Panels/WaveformEnumLink.swift
// on a scripted language server session (stubs.swift), driven the way the editor and the viewer
// drive it: saves, slang's reports, waveform reloads, and reads slang refuses for unsaved edits.
// Names may be missing, never wrong (verify N1, N4, N6). Then the app's call sites: the save, the
// report and the reload hooks are where WaveformEnumLink needs them (a source check).
//
// Usage: enum-link <repo root>
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
@MainActor enum Checks { static var failures = 0 }
@MainActor func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { Checks.failures += 1 } }
func sleep(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

let state3 = { (decode: String, exec: String) in
    ["state": SlangEnumSignal(type: SlangEnumType(name: "fsm.state_t", width: 3, members: [
        .init(name: "IDLE", bits: "000"), .init(name: "FETCH", bits: "001"), .init(name: "DECODE", bits: decode),
        .init(name: "EXEC", bits: exec), .init(name: "DONE", bits: "111"),
    ]), isArray: false)]
}
let old = state3("100", "101")

@MainActor func runChecks() async {
    let session = LanguageServerSession()
    let scope = "top.u_fsm"
    func read() async -> [String: SlangEnumSignal] { await WaveformEnumLink.enumSignals(designInstance: scope, session: session) }

    session.answer = .success(old)
    expect(await read() == old && session.reads.count == 1, "a scope is read once (\(session.reads.count) reads)")
    _ = await read()
    expect(session.reads.count == 1, "and then used as read (\(session.reads.count) reads)")

    // A waveform reload (a new simulation): read again.
    var refreshes = FilePreviewLanguageFeatures.refreshes
    WaveformEnumLink.waveformReloading()
    await sleep(100)
    expect(FilePreviewLanguageFeatures.refreshes > refreshes, "a reload refreshes the editors' names")
    _ = await read()
    expect(session.reads.count == 2, "a reload reads the types again (\(session.reads.count) reads)")

    // slang's report on an unsaved edit (no save before it): nothing is read again.
    WaveformEnumLink.serverReported(session)
    await sleep(600)
    _ = await read()
    expect(session.reads.count == 2, "a report with no save before it keeps the types (\(session.reads.count) reads)")

    // A save, then slang's report on it: read again soon after the report.
    WaveformEnumLink.documentSaved(session)
    await sleep(100)
    _ = await read()
    expect(session.reads.count == 2, "a save waits for slang's compile (\(session.reads.count) reads)")
    WaveformEnumLink.serverReported(session)
    await sleep(600)
    _ = await read()
    expect(session.reads.count == 3, "slang's report on the save reads the types again (\(session.reads.count) reads)")

    // A save slang doesn't report on: read again after the fallback delay.
    WaveformEnumLink.documentSaved(session)
    await sleep(1800)
    _ = await read()
    expect(session.reads.count == 4, "a save with no report reads them again after its delay (\(session.reads.count) reads)")

    // A reload while a buffer has unsaved edits, with no save since the read: slang refuses,
    // and the types read stay (they match the saved sources).
    session.answer = .failure(SlangEnumScopeError.unsavedEdits)
    WaveformEnumLink.waveformReloading()
    await sleep(100)
    expect(await read() == old, "a refused read with no save since keeps the types read")
    expect(session.reads.count == 5, "(\(session.reads.count) reads)")
    _ = await read()
    expect(session.reads.count == 5, "a refused scope isn't asked again at once (\(session.reads.count) reads)")
    expect(WaveformEnumLink.enumSignalsNow(designInstance: scope, session: session) == old, "the editor's names stay too")

    // Verify N4: renumbered and saved, typed on before slang's compile, then re-simulated and
    // reloaded. Every read is refused; the types from before the save must not show.
    session.answer = .success(old)
    WaveformEnumLink.waveformReloading()
    await sleep(100)
    _ = await read()
    WaveformEnumLink.documentSaved(session)
    session.answer = .failure(SlangEnumScopeError.unsavedEdits)
    WaveformEnumLink.serverReported(session)
    await sleep(600)
    refreshes = FilePreviewLanguageFeatures.refreshes
    let afterSave = await read()
    expect(afterSave.isEmpty, "N4: a refused read after a save drops the types from before it: \(afterSave.keys.sorted())")
    expect(WaveformEnumLink.enumSignalsNow(designInstance: scope, session: session).isEmpty, "N4: the editor gets no names either")
    WaveformEnumLink.waveformReloading()
    await sleep(100)
    let afterReload = await read()
    expect(afterReload.isEmpty, "N4: and after a reload: \(afterReload.keys.sorted())")
    // Saved with the buffer clean: the new types.
    let renumbered = state3("101", "110")
    session.answer = .success(renumbered)
    WaveformEnumLink.documentSaved(session)
    WaveformEnumLink.serverReported(session)
    await sleep(600)
    expect(await read() == renumbered, "the next clean save reads the new types")

    // Verify X1: the file of a clean, open editor changes on disk (an agent, git, another editor)
    // and the editor reloads it. slang compiles it as saved: the new types are read on its report,
    // before any re-simulation, and the editors' names refresh.
    let external = state3("010", "011")
    session.answer = .success(external)
    let reads = session.reads.count
    refreshes = FilePreviewLanguageFeatures.refreshes
    await WaveformEnumLink.documentReloadedFromDisk(session, uri: URL(fileURLWithPath: "/rtl/fsm.sv"), text: "external", version: 9)
    expect(session.reloads == ["external"], "X1: the reload goes to the session as a reload from disk")
    WaveformEnumLink.serverReported(session)
    await sleep(600)
    let afterExternal = await read()
    expect(session.reads.count == reads + 1, "X1: slang's report on the reloaded file reads the types again (\(session.reads.count - reads) reads)")
    expect(afterExternal == external, "X1: the reloaded file's types, not the ones read before: \(afterExternal["state"]?.type.members.map(\.bits) ?? [])")
    expect(FilePreviewLanguageFeatures.refreshes > refreshes, "X1: and the editors' names refresh")
    // Then a re-simulation: slang refuses (another buffer's unsaved edit); never the types from before the reload.
    session.answer = .failure(SlangEnumScopeError.unsavedEdits)
    WaveformEnumLink.waveformReloading()
    await sleep(100)
    let refusedAfter = await read()
    expect(refusedAfter.isEmpty || refusedAfter == external, "X1: a refused read after it never shows the old types")

    // The app's call sites (source check): each hook is called where the event happens.
    func body(of file: String, after marker: String) -> String {
        guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8),
              let start = text.range(of: marker) else { return "" }
        var depth = 0
        var seenBrace = false
        var end = start.upperBound
        for index in text[start.lowerBound...].indices {
            let ch = text[index]
            if ch == "{" { depth += 1; seenBrace = true }
            if ch == "}" { depth -= 1 }
            if seenBrace && depth == 0 { end = index; break }
        }
        return String(text[start.lowerBound...end])
    }
    let saveHook = body(of: "Sources/Panels/FilePreviewLanguageFeatures.swift", after: "func documentDidSave(")
    expect(saveHook.contains("WaveformEnumLink.documentSaved(session)"), "the editor's save calls documentSaved")
    let reports = body(of: "Sources/Panels/FilePreviewLanguageFeatures.swift", after: "for await update in updates")
    expect(reports.contains("WaveformEnumLink.serverReported(session)"), "each slang report on the document calls serverReported")
    let change = body(of: "Sources/Panels/FilePreviewLanguageFeatures.swift", after: "func textDidChange(isUserEdit")
    expect(change.contains("isDirty"), "X1: a reload from disk checks the panel is clean")
    let send = body(of: "Sources/Panels/FilePreviewLanguageFeatures.swift", after: "func sendCurrentText(")
    expect(send.contains("WaveformEnumLink.documentReloadedFromDisk("), "X1: a clean reload is sent as a reload from disk")
    let reload = body(of: "Sources/Panels/WaveformSourceLink.swift", after: "static func waveformReloading(")
    expect(reload.contains("WaveformEnumLink.waveformReloading()"), "a waveform reload calls waveformReloading")
}

Task { @MainActor in
    await runChecks()
    print(Checks.failures == 0 ? "ENUM LINK CHECKS PASSED" : "ENUM LINK CHECKS FAILED: \(Checks.failures)")
    exit(Checks.failures == 0 ? 0 : 1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
dispatchMain()
