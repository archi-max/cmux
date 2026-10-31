import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Inline values follow the waveform's marker without starving while the
/// debugger plays: a move never restarts a pending refresh's wait, and a move
/// during a refresh queues exactly one more.
@Suite struct WaveformRefreshThrottleTests {
    @Test func aMoveWhileIdleSchedules() {
        var throttle = WaveformRefreshThrottle()
        #expect(throttle.markerMoved())
    }

    @Test func movesWhileWaitingKeepTheWait() {
        var throttle = WaveformRefreshThrottle()
        _ = throttle.scheduled()
        #expect(!throttle.markerMoved())
        #expect(!throttle.markerMoved())
        #expect(throttle.phase == .waiting)
    }

    @Test func aMoveWhileRunningQueuesOneMore() {
        var throttle = WaveformRefreshThrottle()
        let serial = throttle.scheduled()
        throttle.started(serial)
        #expect(!throttle.markerMoved())
        #expect(!throttle.markerMoved())
        #expect(throttle.finished(serial))
        #expect(throttle.phase == .idle)
        let next = throttle.scheduled()
        throttle.started(next)
        #expect(!throttle.finished(next))
    }

    @Test func aReplacedRefreshFinishingChangesNothing() {
        var throttle = WaveformRefreshThrottle()
        let old = throttle.scheduled()
        throttle.started(old)
        let new = throttle.scheduled()
        #expect(!throttle.finished(old))
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
        #expect(!throttle.finished(serial))
        #expect(throttle.markerMoved())
    }

    @Test func aRefreshThatNeverEndsStopsHoldingMovesBack() {
        var throttle = WaveformRefreshThrottle()
        let start = Date(timeIntervalSince1970: 1000)
        let serial = throttle.scheduled()
        throttle.started(serial, at: start)
        #expect(!throttle.markerMoved(at: start.addingTimeInterval(1)))
        // A page or language server call that never returns must not freeze the values.
        #expect(throttle.markerMoved(at: start.addingTimeInterval(11)))
        let next = throttle.scheduled()
        #expect(!throttle.finished(serial))
        throttle.started(next, at: start.addingTimeInterval(11))
        #expect(throttle.phase == .running)
    }
}
