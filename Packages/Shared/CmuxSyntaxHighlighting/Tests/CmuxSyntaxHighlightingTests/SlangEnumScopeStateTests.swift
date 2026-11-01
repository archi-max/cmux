@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

private let slangServerPath = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/slang-server")

/// When the enum types read for a scope are used, kept or dropped (`SlangEnumScopeState`): the
/// decisions WaveformEnumLink makes for each language server session. Names may be missing,
/// never wrong (verify N1, N4).
@Suite struct SlangEnumScopeStateTests {
    static let old = ["state": SlangEnumSignal(type: SlangEnumTypesTests.state, isArray: false)]
    static let renumbered = ["state": SlangEnumSignal(type: SlangEnumType(name: "fsm.state_t", width: 3, members: [
        .init(name: "IDLE", bits: "000"), .init(name: "FETCH", bits: "001"), .init(name: "DECODE", bits: "101"),
        .init(name: "EXEC", bits: "110"), .init(name: "DONE", bits: "111"),
    ]), isArray: false)]
    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Reads `outcome` for `key`, started at `start` and answered at `end`.
    static func read(_ state: inout SlangEnumScopeState, _ key: String, _ outcome: SlangEnumScopeState.Outcome,
                     start: TimeInterval, end: TimeInterval) -> [String: SlangEnumSignal]? {
        let ticket = state.readStarted(key, at: t0 + start)
        return state.readFinished(ticket, outcome, at: t0 + end)
    }

    @Test func aScopeIsReadOnceThenUsedUntilTypesMayHaveChanged() {
        var state = SlangEnumScopeState()
        #expect(state.current("top.u_fsm", now: Self.t0) == nil, "never read: read it")
        #expect(Self.read(&state, "top.u_fsm", .signals(Self.old), start: 0, end: 0.1) == Self.old)
        #expect(state.current("top.u_fsm", now: Self.t0 + 60) == Self.old, "a read with enums stays current")
        state.markStale()
        #expect(state.current("top.u_fsm", now: Self.t0 + 61) == nil, "stale: read again")
        #expect(state.known("top.u_fsm") == Self.old, "and used meanwhile")
    }

    @Test func aScopeWithNoEnumIsAskedAgainAfterItsLifetime() {
        var state = SlangEnumScopeState()
        #expect(Self.read(&state, "top.u_fsm", .signals([:]), start: 0, end: 0.1) == [:])
        #expect(state.current("top.u_fsm", now: Self.t0 + 5) == [:])
        #expect(state.current("top.u_fsm", now: Self.t0 + 11) == nil)
        #expect(Self.read(&state, "top.qa", .failed, start: 0, end: 0.1) == [:])
        #expect(state.current("top.qa", now: Self.t0 + 5) == [:])
        #expect(state.current("top.qa", now: Self.t0 + 11) == nil)
    }

    /// Verify N4: renumber, save, keep typing, re-simulate and reload. Every read after the save
    /// is refused (unsaved edits): the types read before the save are not shown.
    @Test func aRefusedReadAfterASaveDropsTheTypesReadBeforeIt() {
        var state = SlangEnumScopeState()
        _ = Self.read(&state, "top.u_fsm", .signals(Self.old), start: 0, end: 0.1)
        _ = state.saved(at: Self.t0 + 5)
        state.markStale()
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 5.4, end: 5.5) == [:])
        #expect(state.current("top.u_fsm", now: Self.t0 + 6) == [:], "refused: not asked again at once")
        #expect(state.known("top.u_fsm") == [:])
        // The waveform reloads (a new simulation of the saved sources): still refused, still no names.
        state.markStale()
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 20, end: 20.1) == [:])
        #expect(state.known("top.u_fsm") == [:])
        // Saved again with the buffer clean: the new types.
        _ = state.saved(at: Self.t0 + 30)
        state.markStale()
        #expect(Self.read(&state, "top.u_fsm", .signals(Self.renumbered), start: 30.4, end: 30.5) == Self.renumbered)
    }

    /// A reload with no save since the types were read: they match the saved sources, so a refused
    /// read keeps them.
    @Test func aRefusedReadWithNoSaveSinceKeepsTheTypes() {
        var state = SlangEnumScopeState()
        _ = Self.read(&state, "top.u_fsm", .signals(Self.old), start: 0, end: 0.1)
        state.markStale()
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 3, end: 3.1) == Self.old)
        #expect(state.current("top.u_fsm", now: Self.t0 + 9) == Self.old, "refused: kept for the retry lifetime")
        #expect(state.current("top.u_fsm", now: Self.t0 + 14) == nil, "then asked again")
        // A save after the read: dropped on the next refusal.
        _ = state.saved(at: Self.t0 + 15)
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 15.2, end: 15.3) == [:])
    }

    /// A read that started before a save answers for the text before it, even if it ends after.
    @Test func aReadStartedBeforeASaveCountsAsReadBeforeIt() {
        var state = SlangEnumScopeState()
        let ticket = state.readStarted("top.u_fsm", at: Self.t0)
        _ = state.saved(at: Self.t0 + 0.05)
        #expect(state.readFinished(ticket, .signals(Self.old), at: Self.t0 + 0.2) == Self.old)
        state.markStale()
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 1, end: 1.1) == [:])
    }

    /// A save or reload while a read runs: its answer may be the old types, so it isn't kept.
    @Test func aStaleMarkSupersedesReadsInFlight() {
        var state = SlangEnumScopeState()
        _ = Self.read(&state, "top.u_fsm", .signals(Self.old), start: 0, end: 0.1)
        let ticket = state.readStarted("top.u_fsm", at: Self.t0 + 1)
        state.markStale()
        #expect(state.readFinished(ticket, .signals(Self.renumbered), at: Self.t0 + 1.2) == nil)
        #expect(state.current("top.u_fsm", now: Self.t0 + 1.3) == nil, "still stale: read again")
        #expect(state.known("top.u_fsm") == Self.old)
        let refusedTicket = state.readStarted("top.u_fsm", at: Self.t0 + 2)
        state.markStale()
        #expect(state.readFinished(refusedTicket, .refused, at: Self.t0 + 2.1) == nil)
        #expect(state.current("top.u_fsm", now: Self.t0 + 2.2) == nil, "a superseded refusal doesn't hold off the read")
    }

    /// A save marks the types stale after slang's report on it, or after a fallback delay;
    /// a report with no save before it (an unsaved edit, opening) doesn't.
    @Test func aSaveIsReadAgainAfterSlangsReportOnIt() {
        var state = SlangEnumScopeState()
        #expect(state.serverReported() == nil)
        #expect(state.saved(at: Self.t0) == SlangEnumScopeState.staleDelay)
        #expect(state.serverReported() == SlangEnumScopeState.compiledDelay)
        #expect(state.serverReported() == nil)
    }

    @Test func aStaleMarkEndsARefusalsRetryWait() {
        var state = SlangEnumScopeState()
        #expect(Self.read(&state, "top.u_fsm", .refused, start: 0, end: 0.1) == [:])
        #expect(state.current("top.u_fsm", now: Self.t0 + 1) == [:])
        state.markStale()
        #expect(state.current("top.u_fsm", now: Self.t0 + 1.5) == nil)
    }

    // MARK: Against slang-server

    /// Verify N4 with slang: DECODE renumbered and saved, one more character typed before slang's
    /// compile, then reads as WaveformEnumLink makes them (after the report, and after a reload).
    /// No read may name a value with the type from before the save.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func typingRightAfterASaveNeverShowsTheTypesFromBeforeIt() async throws {
        try await SlangEnumTypesTests.withServer { session, _, root in
            let fsmFile = URL(fileURLWithPath: root + "/fsm.sv")
            let reports = SlangEnumTypesTests.ReportLog()
            let updates = await session.diagnosticsUpdates()
            let listener = Task { for await _ in updates { await reports.add() } }
            defer { listener.cancel() }
            var state = SlangEnumScopeState()
            func read() async -> [String: SlangEnumSignal] {
                let ticket = state.readStarted("top.u_fsm", at: Date())
                let outcome: SlangEnumScopeState.Outcome
                do {
                    outcome = .signals(try await session.slangEnumSignals(inScope: "top.u_fsm", cache: SlangEnumTypeCache()))
                } catch SlangEnumScopeError.unsavedEdits {
                    outcome = .refused
                } catch {
                    outcome = .failed
                }
                return state.readFinished(ticket, outcome, at: Date()) ?? [:]
            }
            await session.open(uri: fsmFile, text: SlangEnumTypesTests.fsm, version: 1)
            #expect(await reports.waitForMore(than: 0))
            #expect(await read()["state"]?.type.memberName(forBits: "100") == "DECODE")
            // Renumbered (DECODE 3'd4 -> 3'd5, EXEC follows to 110), saved, and typed on within ms.
            let renumbered = SlangEnumTypesTests.fsm.replacingOccurrences(of: "DECODE = 3'd4", with: "DECODE = 3'd5")
            try renumbered.write(to: fsmFile, atomically: true, encoding: .utf8)
            let seen = await reports.count
            await session.save(uri: fsmFile, text: renumbered)
            _ = state.saved(at: Date())
            await session.change(uri: fsmFile, text: renumbered + " ", version: 2)
            #expect(await reports.waitForMore(than: seen))
            #expect(state.serverReported() != nil, "slang's report after the save marks the types stale")
            try await Task.sleep(for: SlangEnumScopeState.compiledDelay)
            state.markStale()
            func neverOld(_ signals: [String: SlangEnumSignal], _ when: String) {
                // 101 is EXEC before the save, DECODE after it: only the new name (or none) may show.
                let name = signals["state"]?.type.memberName(forBits: "101")
                #expect(name == nil || name == "DECODE", "\(when): 101 shows as \(name ?? "nothing")")
            }
            neverOld(await read(), "the read after slang's report")
            neverOld(state.known("top.u_fsm"), "the entry after slang's report")
            // A new simulation of the saved sources, then the waveform reloads.
            state.markStale()
            neverOld(await read(), "the read on reload")
            neverOld(state.known("top.u_fsm"), "the entry on reload")
        }
    }

    /// Verify N5: an unsaved edit leaves the file without locations in slang until a save, even
    /// after the editor closes. Closing a document with unsaved edits saves it as it is on disk
    /// for slang, so its scopes can be read again.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: slangServerPath), "needs slang-server"))
    func closingAnEditedDocumentLetsSlangReadItsScopesAgain() async throws {
        try await SlangEnumTypesTests.withServer { session, _, root in
            let fsmFile = URL(fileURLWithPath: root + "/fsm.sv")
            let reports = SlangEnumTypesTests.ReportLog()
            let updates = await session.diagnosticsUpdates()
            let listener = Task { for await _ in updates { await reports.add() } }
            defer { listener.cancel() }
            await session.open(uri: fsmFile, text: SlangEnumTypesTests.fsm, version: 1)
            #expect(await reports.waitForMore(than: 0))
            var seen = await reports.count
            await session.change(uri: fsmFile, text: SlangEnumTypesTests.fsm + "// unsaved\n", version: 2)
            #expect(await reports.waitForMore(than: seen))
            await #expect(throws: SlangEnumScopeError.unsavedEdits) {
                try await session.slangEnumSignals(inScope: "top.u_fsm", cache: SlangEnumTypeCache())
            }
            seen = await reports.count
            await session.close(uri: fsmFile)
            _ = await reports.waitForMore(than: seen)
            var signals: [String: SlangEnumSignal]?
            for _ in 0..<20 where signals == nil {
                signals = try? await session.slangEnumSignals(inScope: "top.u_fsm", cache: SlangEnumTypeCache())
                if signals == nil { try await Task.sleep(for: .milliseconds(250)) }
            }
            #expect(signals?["state"]?.type == SlangEnumTypesTests.state, "after the close, the scope is read from the saved file")
        }
    }
}
