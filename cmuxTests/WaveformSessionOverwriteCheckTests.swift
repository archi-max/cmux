import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Save on Host replaces `<dump>.json` only when it is absent or a VaporView
/// session, and refuses when it can't tell (an ssh failure must not count as
/// "no file").
@Suite("Waveform session overwrite check")
struct WaveformSessionOverwriteCheckTests {
    private struct Failure: Error {}
    private struct Stamp: Equatable, Sendable { let size: Int64 }

    private func decide(
        listing: Result<[String], Failure>,
        stamp: Result<Stamp, Failure> = .success(Stamp(size: 10)),
        text: Result<String, Failure> = .success(#"{"displayedSignals":[]}"#)
    ) async -> WaveformSessionOverwriteCheck.Outcome<Stamp> {
        await WaveformSessionOverwriteCheck.decide(
            name: "top.json",
            listParent: { try listing.get() },
            stamp: { try stamp.get() },
            size: { $0.size },
            read: { try text.get() },
            maxSize: 100,
            isSession: { $0.contains("displayedSignals") }
        )
    }

    @Test func anAbsentFileIsWrittenWithoutAStamp() async {
        guard case .write(expectedStamp: nil) = await decide(listing: .success(["top.vcd"])) else {
            Issue.record("absent file not written"); return
        }
    }

    @Test func anExistingSessionIsReplacedOnlyIfUnchanged() async {
        guard case .write(expectedStamp: Stamp(size: 10)?) = await decide(listing: .success(["top.json"])) else {
            Issue.record("session not replaced with its stamp"); return
        }
    }

    @Test func aFileThatIsNotASessionIsLeftAlone() async {
        let outcome = await decide(listing: .success(["top.json"]), text: .success(#"{"name":"tb config"}"#))
        guard case .notASession = outcome else { Issue.record("non-session replaced"); return }
    }

    @Test func aFileTooBigToBeASessionIsLeftUnread() async {
        let outcome = await decide(listing: .success(["top.json"]), stamp: .success(Stamp(size: 101)), text: .failure(Failure()))
        guard case .notASession = outcome else { Issue.record("oversized file not refused"); return }
    }

    @Test func anyFailureRefusesInsteadOfWriting() async {
        for outcome in [
            await decide(listing: .failure(Failure())),
            await decide(listing: .success(["top.json"]), stamp: .failure(Failure())),
            await decide(listing: .success(["top.json"]), text: .failure(Failure())),
        ] {
            guard case .failed = outcome else { Issue.record("a failure fell through to a write"); return }
        }
    }
}
