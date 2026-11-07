#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// When cmux asks a host for a dump's KDB model: in the background, once per KDB in flight, never
/// again for a KDB whose export failed (one log line), and not at all with the setting off.
@Suite struct KDBExportScheduleTests {
    static func model(_ top: String) -> KDBDesignModel {
        let data = try! JSONSerialization.data(withJSONObject: ["tops": [top], "instances": [top: ["path": top, "module": top, "signals": [:]]]])
        return KDBDesignModel(json: data)!
    }

    @Test func dumpsOfOneSimulationShareTheirKDB() {
        #expect(KDBExportSchedule.key(host: "h", dumpPath: "/sim/run/a.fsdb") == KDBExportSchedule.key(host: "h", dumpPath: "/sim/run/b.fsdb"))
        #expect(KDBExportSchedule.key(host: "h", dumpPath: "/sim/run/a.fsdb") != KDBExportSchedule.key(host: "h", dumpPath: "/sim/other/a.fsdb"))
        #expect(KDBExportSchedule.key(host: "h", dumpPath: "/sim/run/a.fsdb") != KDBExportSchedule.key(host: "g", dumpPath: "/sim/run/a.fsdb"))
    }

    @Test func oneExportInFlightPerKDBWhateverViewersOpen() {
        var schedule = KDBExportSchedule()
        #expect(schedule.opened("k", enabled: true) == .start)
        #expect(schedule.opened("k", enabled: true) == .join)
        #expect(schedule.opened("other", enabled: true) == .start)
        #expect(schedule.model("k") == nil)
        // The export of "other" was never joined: its model is installed.
        _ = schedule.finished("other", .model(Self.model("o"), cached: false))
        #expect(schedule.model("other")?.tops == ["o"] && !schedule.pending("other"))
        // Reopened later: the host's cache answers (a new KDB gives a new model).
        #expect(schedule.opened("other", enabled: true) == .start)
    }

    /// A viewer (re)opening while its KDB's export runs may come with another KDB (a rerun
    /// rewrote it after the export read it): that export's model is dropped and the export runs
    /// once more (the host's cache answers it when the KDB is the same), however many join (Refs #8).
    @Test func anOpenDuringAnExportRunsItOnceMore() {
        var schedule = KDBExportSchedule()
        #expect(schedule.opened("k", enabled: true) == .start)
        #expect(schedule.pending("k"))
        #expect(schedule.opened("k", enabled: true) == .join)
        #expect(schedule.opened("k", enabled: true) == .join)
        #expect(schedule.finished("k", .model(Self.model("old"), cached: false)) == nil)
        #expect(schedule.model("k") == nil, "the export that began before the reopen is not installed")
        #expect(schedule.pending("k"), "it runs once more for the reopened dump")
        _ = schedule.finished("k", .model(Self.model("new"), cached: true))
        #expect(schedule.model("k")?.tops == ["new"] && !schedule.pending("k"))
        // A failure of the superseded export says nothing; the next one's is said.
        _ = schedule.opened("j", enabled: true)
        _ = schedule.opened("j", enabled: true)
        #expect(schedule.finished("j", .unavailable(code: "licence", message: "no seat")) == nil)
        #expect(schedule.pending("j") && schedule.finished("j", .unavailable(code: "licence", message: "no seat")) != nil)
        #expect(!schedule.pending("j"))
    }

    @Test func nothingIsPendingWithTheSettingOff() {
        var schedule = KDBExportSchedule()
        _ = schedule.opened("k", enabled: false)
        #expect(!schedule.pending("k"))
    }

    /// A reopened dump (a reload after another simulation) may come with another KDB: the model in
    /// hand is the old one's, so a trace uses slang's design until the export answers (Refs #8).
    @Test func aReopenedDumpWaitsForItsKDBsAnswer() {
        var schedule = KDBExportSchedule()
        _ = schedule.opened("k", enabled: true)
        _ = schedule.finished("k", .model(Self.model("old"), cached: false))
        #expect(schedule.model("k")?.tops == ["old"])
        #expect(schedule.opened("k", enabled: true) == .start)
        #expect(schedule.model("k") == nil, "not the old KDB's model while the export of the reopened dump runs")
        _ = schedule.finished("k", .model(Self.model("new"), cached: false))
        #expect(schedule.model("k")?.tops == ["new"])
        // The same KDB (the host answers `tried` after a failure): no model comes back from before.
        _ = schedule.opened("k", enabled: true)
        _ = schedule.finished("k", .unavailable(code: "tried", message: ""))
        #expect(schedule.model("k") == nil)
    }

    @Test func theSettingOffAsksNothing() {
        var schedule = KDBExportSchedule()
        #expect(schedule.opened("k", enabled: false) == .off)
        #expect(schedule.opened("k", enabled: true) == .start, "off asked nothing, so nothing is in flight")
    }

    @Test func aFailedExportSaysSoOnceAndKeepsSlang() {
        var schedule = KDBExportSchedule()
        _ = schedule.opened("k", enabled: true)
        let first = schedule.finished("k", .unavailable(code: "licence", message: "no seat"))
        #expect(first?.contains("licence") == true && first?.contains("no seat") == true, "\(String(describing: first))")
        #expect(schedule.model("k") == nil)
        // Reopened: the host answers `tried` (no seat asked); nothing more is logged.
        #expect(schedule.opened("k", enabled: true) == .start)
        #expect(schedule.finished("k", .unavailable(code: "tried", message: "licence: no seat")) == nil)
        #expect(schedule.finished("k", .unavailable(code: "licence", message: "no seat")) == nil)
        // A new KDB that exports, then fails later: said again.
        _ = schedule.finished("k", .model(Self.model("tb"), cached: false))
        #expect(schedule.finished("k", .unavailable(code: "time", message: "past 120 s")) != nil)
    }

    /// Retry KDB Export: a KDB whose failure was said (and that the host marks `tried`) is asked
    /// again, and a new failure is said again; one in flight is joined, as an open is.
    @Test func aRetryStartsATriedKDBAndSaysItsFailureAgain() {
        var schedule = KDBExportSchedule()
        _ = schedule.opened("k", enabled: true)
        #expect(schedule.finished("k", .unavailable(code: "time", message: "past 120 s")) != nil)
        #expect(schedule.retry("k", enabled: true) == .start)
        #expect(schedule.pending("k"))
        #expect(schedule.retry("k", enabled: true) == .join)
        _ = schedule.finished("k", .unavailable(code: "time", message: "past 120 s"))
        #expect(schedule.pending("k"), "a retry joined the running one: it runs once more")
        #expect(schedule.finished("k", .unavailable(code: "time", message: "past 120 s")) != nil, "the retry's failure is said")
        #expect(schedule.retry("k", enabled: false) == .off)
    }

    @Test func aKDBThatIsGoneTakesItsModel() {
        var schedule = KDBExportSchedule()
        _ = schedule.finished("k", .model(Self.model("tb"), cached: true))
        _ = schedule.finished("k", .unavailable(code: "noKDB", message: "/sim/run"))
        #expect(schedule.model("k") == nil)
    }

    @Test func theNewestKDBsModelsAreKept() {
        var schedule = KDBExportSchedule(maxModels: 2)
        for key in ["a", "b", "c"] {
            _ = schedule.opened(key, enabled: true)
            _ = schedule.finished(key, .model(Self.model(key), cached: true))
        }
        #expect(schedule.model("a") == nil && schedule.model("b") != nil && schedule.model("c") != nil)
        // b exported again is newer than c, so c goes when d comes.
        _ = schedule.opened("b", enabled: true)
        _ = schedule.finished("b", .model(Self.model("b"), cached: true))
        _ = schedule.opened("d", enabled: true)
        _ = schedule.finished("d", .model(Self.model("d"), cached: true))
        #expect(schedule.model("c") == nil && schedule.model("b") != nil && schedule.model("d") != nil)
    }

    @Test func aliasPairsGoToThePageInChunks() {
        let pairs = (0..<45_001).map { ["tb.u.p\($0)", "tb.n\($0)"] }
        let chunks = DesignAliasPairs.chunked(pairs)
        #expect(chunks.map(\.count) == [20_000, 20_000, 5_001])
        #expect(Array(chunks.joined()) == pairs)
        #expect(DesignAliasPairs.chunked([]).isEmpty)
    }

    @Test func slangAliasesAreOffByDefaultAndNeverBesideAKDBModel() {
        #expect(KDBExportSchedule.sendsSlangAliases(enabled: false, model: nil) == false)
        #expect(KDBExportSchedule.sendsSlangAliases(enabled: true, model: nil) == true)
        #expect(KDBExportSchedule.sendsSlangAliases(enabled: true, model: Self.model("tb")) == false)
    }
}
#endif
