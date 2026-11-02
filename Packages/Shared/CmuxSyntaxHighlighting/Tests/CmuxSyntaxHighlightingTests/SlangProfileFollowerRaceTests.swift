@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Races and edge cases of per-file profiles, from the independent verify of the first round:
/// a focus during an in-flight switch (one switch at a time, the last focus wins), a newer focus
/// during a busy wait, prefix-aware moves with collisions, removed top-level choices, and the
/// store at its caps.
@MainActor
@Suite struct SlangProfileFollowerRaceTests {
    static let a = SlangProfileChoice.buildFile("/w/a.f")
    static let b = SlangProfileChoice.buildFile("/w/b.f")

    @MainActor final class Fake {
        var wanted: SlangProfileChoice?
        var current = LanguageServerSession.SlangCompilationState(target: nil, isExplore: false)
        var busy = false
        var applied: [SlangProfileChoice] = []
        var inFlight = 0
        var maxInFlight = 0
        var applyTime: Duration = .zero
        var maxBusyWait: Duration = .seconds(5)

        func follower() -> SlangProfileFollower {
            SlangProfileFollower(debounce: .milliseconds(30), busyRetry: .milliseconds(20), maxBusyWait: maxBusyWait, hooks: .init(
                wanted: { self.wanted },
                current: { self.current },
                isBusy: { self.busy },
                apply: { choice in
                    self.inFlight += 1
                    self.maxInFlight = max(self.maxInFlight, self.inFlight)
                    self.applied.append(choice)
                    try? await Task.sleep(for: self.applyTime)
                    self.current = choice.state
                    self.inFlight -= 1
                    return .applied
                },
                missing: { _ in }
            ))
        }

        /// Until the first switch has started (bounded).
        func waitForFirstApply() async {
            let deadline = ContinuousClock.now + .seconds(60)
            while applied.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        }
    }

    @Test func aFocusDuringAnInFlightSwitchIsFollowedAfterItOneAtATime() async {
        let fake = Fake()
        fake.applyTime = .milliseconds(400)
        let follower = fake.follower()
        fake.wanted = Self.a
        follower.activeFileChanged()
        await fake.waitForFirstApply()
        fake.wanted = Self.b
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied == [Self.a, Self.b])
        #expect(fake.maxInFlight == 1)
        #expect(SlangProfileChoice(fake.current) == Self.b)
    }

    @Test func aFocusBackDuringAnInFlightSwitchEndsOnTheLastFocus() async {
        let fake = Fake()
        fake.current = Self.a.state
        fake.applyTime = .milliseconds(400)
        let follower = fake.follower()
        fake.wanted = Self.b
        follower.activeFileChanged()
        await fake.waitForFirstApply()
        fake.wanted = Self.a
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(SlangProfileChoice(fake.current) == Self.a)
        #expect(fake.applied == [Self.b, Self.a])
        #expect(fake.maxInFlight == 1)
    }

    @Test func aNewerFocusDuringTheBusyWaitWins() async {
        let fake = Fake()
        fake.busy = true
        let follower = fake.follower()
        fake.wanted = Self.a
        follower.activeFileChanged()
        try? await Task.sleep(for: .milliseconds(150))
        fake.wanted = Self.b
        follower.activeFileChanged()
        try? await Task.sleep(for: .milliseconds(100))
        fake.busy = false
        await follower.waitUntilIdle()
        #expect(fake.applied == [Self.b])
    }

    @Test func aBusyServerPastTheWaitIsFollowedOnceFree() async {
        let fake = Fake()
        fake.busy = true
        fake.maxBusyWait = .milliseconds(100)
        let follower = fake.follower()
        fake.wanted = Self.a
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied.isEmpty)
        fake.busy = false
        follower.serverBecameFree()
        await follower.waitUntilIdle()
        #expect(fake.applied == [Self.a])
    }

    @Test func movesArePrefixAwareAndKeepTheNewerChoice() {
        var assignments = SlangProfileAssignments()
        let earlier = Date(timeIntervalSince1970: 1)
        let later = Date(timeIntervalSince1970: 2)
        assignments.choose(.buildFile("/w/ab/x.f"), file: "/w/ab/f.sv", at: earlier)
        assignments.choose(.buildFile("/w/a/x.f"), file: "/w/a/f.sv", at: earlier)
        assignments.choose(.topLevel("/w/new/f.sv"), file: "/w/new/f.sv", at: later)
        assignments.pathWasMoved(from: "/w/a", to: "/w/new")
        #expect(assignments.ownChoice(forFile: "/w/ab/f.sv") == .buildFile("/w/ab/x.f"))
        // Collision: the file already at the new path chose later, so it keeps its own.
        #expect(assignments.ownChoice(forFile: "/w/new/f.sv") == .topLevel("/w/new/f.sv"))
        #expect(assignments.ownChoice(forFile: "/w/a/f.sv") == nil)
        // Trailing slashes.
        assignments.pathWasMoved(from: "/w/ab/", to: "/w/cd/")
        #expect(assignments.ownChoice(forFile: "/w/cd/f.sv") == .buildFile("/w/cd/x.f"))
        // Remote paths with spaces and colons are plain strings.
        assignments.choose(.buildFile("/home/u/p q/a:b.f"), file: "/home/u/p q/t.sv", at: later)
        assignments.pathWasMoved(from: "/home/u/p q", to: "/home/u/r")
        #expect(assignments.ownChoice(forFile: "/home/u/r/t.sv") == .buildFile("/home/u/r/a:b.f"))
    }

    @Test func aCollisionKeepsTheNewerChoiceWhicheverSideItIsOn() {
        var assignments = SlangProfileAssignments()
        // The moved file chose later than the one already at the destination.
        assignments.choose(.topLevel("/w/new/f.sv"), file: "/w/new/f.sv", at: Date(timeIntervalSince1970: 1))
        assignments.choose(Self.b, file: "/w/a/f.sv", at: Date(timeIntervalSince1970: 2))
        assignments.pathWasMoved(from: "/w/a", to: "/w/new")
        #expect(assignments.ownChoice(forFile: "/w/new/f.sv") == Self.b)
    }

    @Test func removingAProfileAlsoDropsTopLevelChoicesOfThatPathAndTheLastSet() {
        var assignments = SlangProfileAssignments()
        assignments.choose(.topLevel("/w/tb.sv"), file: "/w/tb.sv")
        assignments.choose(Self.a, file: "/w/x.sv")
        assignments.setLastSet(.topLevel("/w/tb.sv"))
        assignments.profileWasRemoved("/w/tb.sv")
        #expect(assignments.ownChoice(forFile: "/w/tb.sv") == nil)
        #expect(assignments.ownChoice(forFile: "/w/x.sv") == Self.a)
        #expect(assignments.lastSet == nil)
    }

    @Test func theStoreAtItsCaps() throws {
        let suite = "cmux-slangprof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SlangProfileAssignmentStore(defaults: defaults, key: "k")
        for root in 0..<40 {
            var assignments = SlangProfileAssignments()
            for file in 0..<300 {
                assignments.choose(
                    .buildFile("/home/u/projects/design-\(root)/.slang/testbench_\(file % 7).f"),
                    file: "/home/u/projects/design-\(root)/rtl/sub/module_\(file).sv",
                    at: Date(timeIntervalSince1970: Double(root * 1000 + file))
                )
            }
            store.save(assignments, root: "ssh:remote-host|22||opt|/home/u/projects/design-\(root)")
        }
        let roots = store.load()
        #expect(roots.count == SlangProfileAssignmentStore.maxRoots)
        #expect(roots.values.allSatisfy { $0.files.count <= SlangProfileAssignments.maxFiles })
        // The newest roots are kept.
        #expect(roots["ssh:remote-host|22||opt|/home/u/projects/design-39"] != nil)
        #expect(roots["ssh:remote-host|22||opt|/home/u/projects/design-0"] == nil)
    }
}
