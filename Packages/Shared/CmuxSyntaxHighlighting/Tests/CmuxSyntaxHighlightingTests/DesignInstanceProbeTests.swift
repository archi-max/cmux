import Foundation
import Testing
import CmuxSyntaxHighlighting

@Suite struct DesignInstanceProbeTests {
    struct Failed: Error {}

    @Test func aFailingProbeStopsWithNoAnswer() async {
        // A failure is the server's (compiling, timed out), not the probe's: the others would
        // each wait out the same timeout. Nothing was learned.
        var asked: [String] = []
        let found = await DesignInstanceProbe.firstFound(["a", "b", "c"]) { probe -> [String] in
            asked.append(probe)
            if probe == "a" { throw Failed() }
            return ["top.dut"]
        }
        #expect(found == nil)
        #expect(asked == ["a"])
    }

    @Test func anUnresolvedPathAnswerGoesOnToTheNextProbe() async {
        // slang answers some positions (a macro, a type, a package name) with -32603: that probe
        // found nothing, the next may place the module.
        var asked: [String] = []
        let found = await DesignInstanceProbe.firstFound(["a", "b"]) { probe -> [String] in
            asked.append(probe)
            if probe == "a" { throw LanguageServerError.responseError(code: -32603, message: "cannot resolve") }
            return ["top.dut"]
        }
        #expect(found == ["top.dut"])
        #expect(asked == ["a", "b"])
    }

    @Test func probesThatFindNothingGoOnToTheNext() async {
        var asked: [String] = []
        let found = await DesignInstanceProbe.firstFound(["a", "b", "c"]) { probe -> [String] in
            asked.append(probe)
            return probe == "b" ? ["top.dut"] : []
        }
        #expect(found == ["top.dut"])
        #expect(asked == ["a", "b"])
    }

    @Test func noAnswerIsAskedAgainSoonerThanAMissButBacksOff() {
        #expect(DesignInstanceProbe.retryDelay(misses: 0, failures: 1) == 2)
        #expect(DesignInstanceProbe.retryDelay(misses: 0, failures: 2) == 4)
        #expect(DesignInstanceProbe.retryDelay(misses: 3, failures: 9) == 30)
        #expect(DesignInstanceProbe.retryDelay(misses: 1, failures: 0) == 10)
        #expect(DesignInstanceProbe.retryDelay(misses: 3, failures: 0) == 40)
        #expect(DesignInstanceProbe.retryDelay(misses: 20, failures: 0) == 300)
    }

    @Test func aFileThatMayBeAnIncludedFragmentIsAskedCheaplyAndNeverSaidUnplaced() {
        // Headers of parameters and typedefs look the same as a testbench body: until slang
        // shows an includer, a lookup is short and finding none says nothing.
        #expect(DesignInstanceProbe.fragmentProbeLimit == 2)
        #expect(DesignInstanceProbe.fragmentSearchTimeLimit == 2)
        #expect(DesignInstanceProbe.reportsNotPlaced(isFragment: true, designHasTops: true) == false)
        #expect(DesignInstanceProbe.reportsNotPlaced(isFragment: true, designHasTops: nil) == false)
        #expect(DesignInstanceProbe.reportsNotPlaced(isFragment: false, designHasTops: true) == true)
        // No top level at all: nothing can be placed, and the hint says how to set one up.
        #expect(DesignInstanceProbe.reportsNotPlaced(isFragment: true, designHasTops: false) == true)
    }

    @Test func noneFoundIsEmpty() async {
        let found = await DesignInstanceProbe.firstFound(["a", "b"]) { _ -> [String] in [] }
        #expect(found == [])
    }

    @Test func everyProbeFailingIsNilNotEmpty() async {
        // No probe got an answer (the server isn't ready): not a miss either.
        let found = await DesignInstanceProbe.firstFound(["a", "b"]) { _ -> [String] in throw Failed() }
        #expect(found == nil)
    }

    @Test func cancelledIsNilNotEmpty() async {
        // Cancelled (a scroll, an edit): nothing was learned, so it isn't a miss to cache.
        let task = Task { () -> [String]? in
            await DesignInstanceProbe.firstFound(["a", "b"]) { _ -> [String] in
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
        }
        let found = await task.value
        #expect(found == nil)
    }

    @Test func aCancelledOrFailedScopeKeepsWhatWasKnownOfTheTops() {
        #expect(DesignInstanceProbe.designHasTops(scopeKinds: ["Package"], cancelled: false, current: nil) == false)
        #expect(DesignInstanceProbe.designHasTops(scopeKinds: ["Package", "Instance"], cancelled: false, current: false) == true)
        // A scroll or an edit cancelled getScope(""): its error is no answer.
        #expect(DesignInstanceProbe.designHasTops(scopeKinds: nil, cancelled: true, current: false) == false)
        #expect(DesignInstanceProbe.designHasTops(scopeKinds: ["Package"], cancelled: true, current: true) == true)
        #expect(DesignInstanceProbe.designHasTops(scopeKinds: nil, cancelled: false, current: false) == false)
    }
}
