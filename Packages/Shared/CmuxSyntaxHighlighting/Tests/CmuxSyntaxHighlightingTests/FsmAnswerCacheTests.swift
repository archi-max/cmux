@testable import CmuxSyntaxHighlighting
import Testing

/// The state machine pane's answers per waveform and dump path (WaveformFSMEngines): an answer
/// computed across a reload of its waveform is neither kept nor shown, a request after the reload
/// runs the engines again, and a transient failure isn't kept (verify F2).
@Suite struct FsmAnswerCacheTests {
    @Test func anAnswerIsKeptUntilItsWaveformIsOpenedAgain() throws {
        var cache = FsmAnswerCache<String>()
        let ticket = try #require(cache.start("w1", "tb.state"))
        #expect(cache.start("w1", "tb.state") == nil, "one run per path at a time")
        #expect(cache.finish(ticket, "model", keep: true), "current: shown")
        #expect(cache.answer("w1", "tb.state") == "model")
        #expect(cache.answer("w2", "tb.state") == nil, "per waveform")
        cache.opened("w1")
        #expect(cache.answer("w1", "tb.state") == nil, "a reload drops the waveform's answers")
    }

    @Test func anAnswerComputedAcrossAReloadIsNeitherKeptNorShown() throws {
        var cache = FsmAnswerCache<String>()
        let old = try #require(cache.start("w1", "tb.state"))
        cache.opened("w1")
        let new = try #require(cache.start("w1", "tb.state"), "a request after the reload runs the engines again")
        #expect(!cache.finish(old, "old model", keep: true), "the old run's answer isn't shown")
        #expect(cache.answer("w1", "tb.state") == nil, "nor kept")
        #expect(cache.start("w1", "tb.state") == nil, "the new run still counts as running")
        #expect(cache.finish(new, "new model", keep: true))
        #expect(cache.answer("w1", "tb.state") == "new model")
        // Another waveform's reload doesn't touch this one's runs.
        let other = try #require(cache.start("w1", "tb.other"))
        cache.opened("w2")
        #expect(cache.finish(other, "other", keep: true))
    }

    @Test func aTransientFailureIsShownButNotKept() throws {
        var cache = FsmAnswerCache<String>()
        let ticket = try #require(cache.start("w1", "tb.state"))
        #expect(cache.finish(ticket, "Verdi failed: ssh", keep: false))
        #expect(cache.answer("w1", "tb.state") == nil)
        #expect(cache.start("w1", "tb.state") != nil, "asked again, the engines run again")
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
}
