import CmuxSyntaxHighlighting
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
}
