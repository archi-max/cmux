import CmuxSyntaxHighlighting
import Testing

/// The waveform debugger's Locals follows the caret: one request to the page at
/// a time, and the newest wish is never dropped while one is in flight.
@Suite struct LatestRequestCoalescerTests {
    @Test func theFirstWishIsSentAtOnce() {
        var c = LatestRequestCoalescer<String>()
        #expect(c.want("a") == "a")
    }

    @Test func aWishDuringARequestIsSentAfterIt() {
        var c = LatestRequestCoalescer<String>()
        _ = c.want("a")
        #expect(c.want("b") == nil)
        #expect(c.want("c") == nil)
        #expect(c.finished() == "c")
        #expect(c.finished() == nil)
        #expect(c.want("d") == "d")
    }

    @Test func theSameWishAgainIsNotResent() {
        var c = LatestRequestCoalescer<String>()
        _ = c.want("a")
        #expect(c.want("b") == nil)
        #expect(c.want("a") == nil)
        #expect(c.finished() == nil)
    }
}
