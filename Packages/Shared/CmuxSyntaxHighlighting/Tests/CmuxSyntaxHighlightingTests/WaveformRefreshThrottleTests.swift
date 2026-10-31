import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Inline values follow the waveform's marker without starving while the
/// debugger plays: a move never restarts a pending refresh's wait, and a move
/// during a refresh queues exactly one more.
@Suite struct WaveformRefreshThrottleTests {
    @Test func aMoveWhileIdleSchedules() {
        var throttle = WaveformRefreshThrottle()
        let result1 = throttle.markerMoved()
        #expect(result1)
    }

    @Test func movesWhileWaitingKeepTheWait() {
        var throttle = WaveformRefreshThrottle()
        _ = throttle.scheduled()
        let result2 = throttle.markerMoved()
        #expect(!result2)
        let result3 = throttle.markerMoved()
        #expect(!result3)
        #expect(throttle.phase == .waiting)
    }

    @Test func aMoveWhileRunningQueuesOneMore() {
        var throttle = WaveformRefreshThrottle()
        let serial = throttle.scheduled()
        throttle.started(serial)
        let result4 = throttle.markerMoved()
        #expect(!result4)
        let result5 = throttle.markerMoved()
        #expect(!result5)
        let result6 = throttle.finished(serial)
        #expect(result6)
        #expect(throttle.phase == .idle)
        let next = throttle.scheduled()
        throttle.started(next)
        let result7 = throttle.finished(next)
        #expect(!result7)
    }

    @Test func aReplacedRefreshFinishingChangesNothing() {
        var throttle = WaveformRefreshThrottle()
        let old = throttle.scheduled()
        throttle.started(old)
        let new = throttle.scheduled()
        let result8 = throttle.finished(old)
        #expect(!result8)
        #expect(throttle.phase == .waiting)
        throttle.started(old)
        #expect(throttle.phase == .waiting)
        throttle.started(new)
        #expect(throttle.phase == .running)
    }

    @Test func aClearForgetsTheQueuedRefresh() {
        var throttle = WaveformRefreshThrottle()
        let serial = throttle.scheduled()
        throttle.started(serial)
        _ = throttle.markerMoved()
        throttle.cleared()
        #expect(throttle.phase == .idle)
        let result9 = throttle.finished(serial)
        #expect(!result9)
        let result10 = throttle.markerMoved()
        #expect(result10)
    }

    @Test func aRefreshThatNeverEndsStopsHoldingMovesBack() {
        var throttle = WaveformRefreshThrottle()
        let start = Date(timeIntervalSince1970: 1000)
        let serial = throttle.scheduled()
        throttle.started(serial, at: start)
        let result11 = throttle.markerMoved(at: start.addingTimeInterval(1))
        #expect(!result11)
        // A page or language server call that never returns must not freeze the values.
        let result12 = throttle.markerMoved(at: start.addingTimeInterval(11))
        #expect(result12)
        let next = throttle.scheduled()
        let result13 = throttle.finished(serial)
        #expect(!result13)
        throttle.started(next, at: start.addingTimeInterval(11))
        #expect(throttle.phase == .running)
    }
}
