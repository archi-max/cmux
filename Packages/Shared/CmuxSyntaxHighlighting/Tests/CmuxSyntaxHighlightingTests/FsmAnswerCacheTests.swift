@testable import CmuxSyntaxHighlighting
import Testing

/// The state machine pane's answers per waveform and dump path (WaveformFSMEngines): an answer
/// computed across a reload of its waveform is neither kept nor shown, a request after the reload
/// runs the engines again, and a transient failure isn't kept (verify F2).
@Suite struct FsmAnswerCacheTests {
    @Test func anAnswerIsKeptUntilItsWaveformIsOpenedAgain() throws {
        var cache = FsmAnswerCache<String>()
        let first = cache.start("w1", "tb.state")
        let ticket = try #require(first)
        let second = cache.start("w1", "tb.state")
        #expect(second == nil, "one run per path at a time")
        let shown = cache.finish(ticket, "model", keep: true)
        #expect(shown, "current: shown")
        #expect(cache.answer("w1", "tb.state") == "model")
        #expect(cache.answer("w2", "tb.state") == nil, "per waveform")
        cache.opened("w1")
        #expect(cache.answer("w1", "tb.state") == nil, "a reload drops the waveform's answers")
    }

    @Test func anAnswerComputedAcrossAReloadIsNeitherKeptNorShown() throws {
        var cache = FsmAnswerCache<String>()
        let oldStarted = cache.start("w1", "tb.state")
        let old = try #require(oldStarted)
        cache.opened("w1")
        let started = cache.start("w1", "tb.state")
        let new = try #require(started, "a request after the reload runs the engines again")
        let oldShown = cache.finish(old, "old model", keep: true)
        #expect(!oldShown, "the old run's answer isn't shown")
        #expect(cache.answer("w1", "tb.state") == nil, "nor kept")
        let again = cache.start("w1", "tb.state")
        #expect(again == nil, "the new run still counts as running")
        let newShown = cache.finish(new, "new model", keep: true)
        #expect(newShown)
        #expect(cache.answer("w1", "tb.state") == "new model")
        // Another waveform's reload doesn't touch this one's runs.
        let otherStarted = cache.start("w1", "tb.other")
        let other = try #require(otherStarted)
        cache.opened("w2")
        let otherShown = cache.finish(other, "other", keep: true)
        #expect(otherShown)
    }

    @Test func aTransientFailureIsShownButNotKept() throws {
        var cache = FsmAnswerCache<String>()
        let started = cache.start("w1", "tb.state")
        let ticket = try #require(started)
        let shown = cache.finish(ticket, "Verdi failed: ssh", keep: false)
        #expect(shown)
        #expect(cache.answer("w1", "tb.state") == nil)
        let again = cache.start("w1", "tb.state")
        #expect(again != nil, "asked again, the engines run again")
    }

    /// Verify G2: answers (a Verdi model over ssh above all) are kept with no design open, until the
    /// design opens or changes: a Show or a reload doesn't rerun Verdi each time.
    @Test func answersAreKeptUntilTheDesignChanges() throws {
        var cache = FsmAnswerCache<String>()
        let started = cache.start("w1", "tb.state")
        let ticket = try #require(started)
        let shown = cache.finish(ticket, "verdi model", keep: true)
        #expect(shown)
        #expect(cache.answer("w1", "tb.state") == "verdi model", "kept: the next Show uses it")
        cache.designChanged()
        #expect(cache.answer("w1", "tb.state") == nil, "a design opened or changed: asked again")
    }

    @Test func aRunStartedBeforeADesignChangeIsShownButNotKept() throws {
        var cache = FsmAnswerCache<String>()
        let started = cache.start("w1", "tb.state")
        let ticket = try #require(started)
        cache.designChanged()
        let again = cache.start("w1", "tb.state")
        #expect(again == nil, "still one run per path")
        let shown = cache.finish(ticket, "model of the old design", keep: true)
        #expect(shown, "the pane waits for it: shown")
        #expect(cache.answer("w1", "tb.state") == nil, "but not kept for the new design")
    }

    @Test func transientNotesAreTheOnesARetryMayChange() {
        let model = FsmModel.observed(signal: "state", width: 3, names: [:])
        func result(_ notes: [FsmPipeline.Note]) -> FsmPipeline.Result { FsmPipeline.Result(model: model, notes: notes) }
        #expect(result([.verdi(reason: "failed", detail: "ssh")]).hasTransientFailure)
        #expect(result([.verdi(reason: "licence", detail: "")]).hasTransientFailure)
        #expect(result([.yosys(.failed("ssh"))]).hasTransientFailure)
        #expect(!result([]).hasTransientFailure)
        #expect(!result([.verdi(reason: "no-kdb", detail: ""), .verdi(reason: "no-fsm", detail: "")]).hasTransientFailure)
        #expect(!result([.yosys(.notFound)]).hasTransientFailure)
        #expect(!result([.yosys(.failed(""))]).hasTransientFailure, "no Yosys installed: not a retry's business")
    }

    @Test func aDesignChangeOfSomeWaveformsLeavesTheOthersAnswers() throws {
        var cache = FsmAnswerCache<String>()
        for waveform in ["w1", "w2"] {
            let started = cache.start(waveform, "tb.state")
            let run = try #require(started)
            let shown = cache.finish(run, "model", keep: true)
            #expect(shown)
        }
        let w1Started = cache.start("w1", "tb.other")
        let w1Run = try #require(w1Started)
        let w2Started = cache.start("w2", "tb.other")
        let w2Run = try #require(w2Started)
        // Only w1's server switched profiles.
        cache.designChanged(waveforms: ["w1"])
        #expect(cache.answer("w1", "tb.state") == nil)
        #expect(cache.answer("w2", "tb.state") == "model")
        // w1's run started before the switch is shown but not kept; w2's is kept.
        let w1Shown = cache.finish(w1Run, "old", keep: true)
        #expect(w1Shown)
        #expect(cache.answer("w1", "tb.other") == nil)
        let w2Shown = cache.finish(w2Run, "new", keep: true)
        #expect(w2Shown)
        #expect(cache.answer("w2", "tb.other") == "new")
    }
}
