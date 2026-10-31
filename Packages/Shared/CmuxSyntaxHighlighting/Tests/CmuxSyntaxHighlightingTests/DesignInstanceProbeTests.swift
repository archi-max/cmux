import Foundation
import Testing
import CmuxSyntaxHighlighting

@Suite struct DesignInstanceProbeTests {
    struct Failed: Error {}

    @Test func aFailingProbeGoesOnToTheNext() async {
        var asked: [String] = []
        let found = await DesignInstanceProbe.firstFound(["a", "b", "c"]) { probe -> [String] in
            asked.append(probe)
            if probe == "a" { throw Failed() }
            return probe == "b" ? ["top.dut"] : []
        }
        #expect(found == ["top.dut"])
        #expect(asked == ["a", "b"])
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
}
