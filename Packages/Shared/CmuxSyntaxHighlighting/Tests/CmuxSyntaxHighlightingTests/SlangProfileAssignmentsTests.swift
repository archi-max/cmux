@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Per-file slang profiles: each file keeps the profile chosen while it was active, files with
/// none follow the last-set profile, and the server follows the active file.
@Suite struct SlangProfileAssignmentsTests {
    static let tbA = SlangProfileChoice.buildFile("/w/.slang/tb_a.f")
    static let tbB = SlangProfileChoice.buildFile("/w/.slang/tb_b.f")

    @Test func aFileKeepsItsOwnProfileAndOthersFollowTheLastSet() {
        var assignments = SlangProfileAssignments()
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == nil)
        assignments.choose(Self.tbA, file: "/w/a_tb.sv")
        assignments.choose(Self.tbB, file: "/w/b_tb.sv")
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == Self.tbA)
        #expect(assignments.choice(forFile: "/w/b_tb.sv") == Self.tbB)
        // A file with no choice of its own follows the profile set last.
        #expect(assignments.choice(forFile: "/w/rtl/alu.sv") == Self.tbB)
        #expect(assignments.ownChoice(forFile: "/w/rtl/alu.sv") == nil)
        assignments.choose(.explore, file: nil)
        #expect(assignments.choice(forFile: "/w/rtl/alu.sv") == .explore)
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == Self.tbA)
        assignments.forgetFile("/w/a_tb.sv")
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == .explore)
    }

    @Test func theWaveformsPickOnlyChangesTheLastSetProfile() {
        var assignments = SlangProfileAssignments()
        assignments.choose(Self.tbA, file: "/w/a_tb.sv")
        assignments.setLastSet(Self.tbB)
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == Self.tbA)
        #expect(assignments.choice(forFile: "/w/other.sv") == Self.tbB)
        assignments.setLastSet(nil)
        #expect(assignments.choice(forFile: "/w/other.sv") == nil)
    }

    @Test func aRemovedProfilesFilesFallBackToTheLastSet() {
        var assignments = SlangProfileAssignments()
        assignments.choose(Self.tbA, file: "/w/a_tb.sv")
        assignments.choose(Self.tbA, file: "/w/a2_tb.sv")
        assignments.choose(Self.tbB, file: "/w/b_tb.sv")
        assignments.profileWasRemoved("/w/.slang/tb_a.f")
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == Self.tbB)
        #expect(assignments.ownChoice(forFile: "/w/a2_tb.sv") == nil)
        // The last-set profile itself removed: nothing is set.
        assignments.profileWasRemoved("/w/.slang/tb_b.f")
        #expect(assignments.choice(forFile: "/w/b_tb.sv") == nil)
        #expect(assignments.lastSet == nil)
    }

    @Test func aRenameIsFollowedByProfilesAndFiles() {
        var assignments = SlangProfileAssignments()
        assignments.choose(Self.tbA, file: "/w/a_tb.sv")
        assignments.choose(.topLevel("/w/hvl/top_tb.sv"), file: "/w/hvl/top_tb.sv")
        assignments.pathWasMoved(from: "/w/.slang/tb_a.f", to: "/w/.slang/tb_alpha.f")
        #expect(assignments.choice(forFile: "/w/a_tb.sv") == .buildFile("/w/.slang/tb_alpha.f"))
        // A folder moved: the files and the profile paths below it.
        assignments.pathWasMoved(from: "/w/hvl", to: "/w/tb")
        #expect(assignments.ownChoice(forFile: "/w/hvl/top_tb.sv") == nil)
        #expect(assignments.choice(forFile: "/w/tb/top_tb.sv") == .topLevel("/w/tb/top_tb.sv"))
        #expect(assignments.lastSet == .topLevel("/w/tb/top_tb.sv"))
        // A sibling whose name only starts the same is not below the folder.
        assignments.choose(Self.tbB, file: "/w/tbx/x.sv")
        assignments.pathWasMoved(from: "/w/tb", to: "/w/bench")
        #expect(assignments.ownChoice(forFile: "/w/tbx/x.sv") == Self.tbB)
        #expect(assignments.ownChoice(forFile: "/w/bench/top_tb.sv") == .topLevel("/w/bench/top_tb.sv"))
    }

    @Test func filesChosenLongestAgoAreDroppedPastTheCap() {
        var assignments = SlangProfileAssignments()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0...SlangProfileAssignments.maxFiles {
            assignments.choose(Self.tbA, file: "/w/f\(index).sv", at: start.addingTimeInterval(Double(index)))
        }
        #expect(assignments.files.count == SlangProfileAssignments.maxFiles)
        #expect(assignments.ownChoice(forFile: "/w/f0.sv") == nil)
        #expect(assignments.ownChoice(forFile: "/w/f\(SlangProfileAssignments.maxFiles).sv") == Self.tbA)
    }

    @Test func choicesMatchTheServersCompilationState() {
        typealias State = LanguageServerSession.SlangCompilationState
        #expect(SlangProfileChoice(State(target: .buildFile("/w/a.f"), isExplore: false)) == .buildFile("/w/a.f"))
        #expect(SlangProfileChoice(State(target: .topLevel("/w/t.sv"), isExplore: false)) == .topLevel("/w/t.sv"))
        #expect(SlangProfileChoice(State(target: nil, isExplore: true)) == .explore)
        #expect(SlangProfileChoice(State(target: nil, isExplore: false)) == .configured)
        for choice in [Self.tbA, .topLevel("/w/t.sv"), .explore, .configured] {
            #expect(SlangProfileChoice(choice.state) == choice)
        }
    }

    @Test func theStoreKeepsRootsApartAcrossLaunches() throws {
        let suite = "cmux-slangprof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var local = SlangProfileAssignments()
        local.choose(Self.tbA, file: "/w/a_tb.sv")
        var remote = SlangProfileAssignments()
        remote.choose(.buildFile("/home/u/mp/.slang/tb_b.f"), file: "/home/u/mp/hvl/b_tb.sv")
        SlangProfileAssignmentStore(defaults: defaults).save(local, root: "local|/w")
        SlangProfileAssignmentStore(defaults: defaults).save(remote, root: "ssh:remote-host|||/home/u/mp")
        // A new store (a relaunch) reads both back.
        let store = SlangProfileAssignmentStore(defaults: defaults)
        #expect(store.load(root: "local|/w") == local)
        #expect(store.load(root: "ssh:remote-host|||/home/u/mp").choice(forFile: "/home/u/mp/hvl/b_tb.sv") == .buildFile("/home/u/mp/.slang/tb_b.f"))
        #expect(store.load(root: "local|/other").lastSet == nil)
        store.save(SlangProfileAssignments(), root: "local|/w")
        #expect(store.load().keys.sorted() == ["ssh:remote-host|||/home/u/mp"])
    }

    @Test func theStoreDropsTheRootsUnusedLongest() throws {
        let suite = "cmux-slangprof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SlangProfileAssignmentStore(defaults: defaults)
        for index in 0...SlangProfileAssignmentStore.maxRoots {
            var assignments = SlangProfileAssignments()
            assignments.choose(Self.tbA, file: nil, at: Date(timeIntervalSince1970: Double(1_000 + index)))
            store.save(assignments, root: "local|/r\(index)")
        }
        let roots = store.load()
        #expect(roots.count == SlangProfileAssignmentStore.maxRoots)
        #expect(roots["local|/r0"] == nil)
        #expect(roots["local|/r\(SlangProfileAssignmentStore.maxRoots)"] != nil)
    }
}

/// The follower against fake hooks: debounce, no switch when unchanged, waiting while busy,
/// and a missing profile's fallback.
@MainActor
@Suite struct SlangProfileFollowerTests {
    @MainActor final class Fake {
        var wanted: SlangProfileChoice?
        var current = LanguageServerSession.SlangCompilationState(target: nil, isExplore: false)
        var busy = false
        var applied: [SlangProfileChoice] = []
        var missingPaths: Set<String> = []
        var failingPaths: Set<String> = []
        /// Apply answers `.busy` this many times first (another change claimed the server meanwhile).
        var busyAnswers = 0
        var fallback: SlangProfileChoice?

        func follower(debounce: Duration = .milliseconds(40)) -> SlangProfileFollower {
            SlangProfileFollower(debounce: debounce, busyRetry: .milliseconds(20), maxBusyWait: .seconds(5), hooks: .init(
                wanted: { self.wanted },
                current: { self.current },
                isBusy: { self.busy },
                apply: { choice in
                    if self.busyAnswers > 0 {
                        self.busyAnswers -= 1
                        return .busy
                    }
                    self.applied.append(choice)
                    if let path = choice.path, self.missingPaths.contains(path) { return .missing }
                    if let path = choice.path, self.failingPaths.contains(path) { return .failed }
                    self.current = choice.state
                    return .applied
                },
                missing: { _ in self.wanted = self.fallback }
            ))
        }
    }

    @Test func quickFocusChangesCompileOnlyTheFileFocusSettlesOn() async {
        let fake = Fake()
        let follower = fake.follower()
        for choice in [SlangProfileAssignmentsTests.tbA, SlangProfileAssignmentsTests.tbB, SlangProfileAssignmentsTests.tbA] {
            fake.wanted = choice
            follower.activeFileChanged()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await follower.waitUntilIdle()
        #expect(fake.applied == [SlangProfileAssignmentsTests.tbA])
    }

    @Test func theSameProfileIsNotCompiledAgain() async {
        let fake = Fake()
        fake.current = SlangProfileAssignmentsTests.tbA.state
        fake.wanted = SlangProfileAssignmentsTests.tbA
        let follower = fake.follower()
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        // Nothing chosen anywhere: the server is left as it is.
        fake.wanted = nil
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied.isEmpty)
        // Explore mode and the config's build are different compilations.
        fake.current = SlangProfileChoice.configured.state
        fake.wanted = .explore
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied == [.explore])
    }

    @Test func aSwitchWaitsForAChangeAlreadyRunning() async {
        let fake = Fake()
        fake.busy = true
        fake.wanted = SlangProfileAssignmentsTests.tbB
        let follower = fake.follower()
        follower.activeFileChanged()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fake.applied.isEmpty)
        fake.busy = false
        await follower.waitUntilIdle()
        #expect(fake.applied == [SlangProfileAssignmentsTests.tbB])
    }

    @Test func aMissingProfileFallsBackToTheLastSet() async {
        let fake = Fake()
        fake.missingPaths = ["/w/.slang/tb_a.f"]
        fake.wanted = SlangProfileAssignmentsTests.tbA
        fake.fallback = SlangProfileAssignmentsTests.tbB
        let follower = fake.follower()
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied == [SlangProfileAssignmentsTests.tbA, SlangProfileAssignmentsTests.tbB])
        #expect(SlangProfileChoice(fake.current) == SlangProfileAssignmentsTests.tbB)
    }

    @Test func aProfileThatElaboratesNothingIsTriedOnceUntilItsFilesChange() async {
        let fake = Fake()
        fake.failingPaths = ["/w/.slang/tb_a.f"]
        let follower = fake.follower(debounce: .milliseconds(10))
        func focus(_ choice: SlangProfileChoice) async {
            fake.wanted = choice
            follower.activeFileChanged()
            await follower.waitUntilIdle()
        }
        let tbA = SlangProfileAssignmentsTests.tbA
        let tbB = SlangProfileAssignmentsTests.tbB
        await focus(tbA)
        await focus(tbB)
        await focus(tbA)
        await focus(tbA)
        // tb_a failed once: later focuses don't build it again, tb_b still switches.
        #expect(fake.applied == [tbA, tbB])
        // A saved design file (its .f or a source) may fix it: tried again.
        follower.designFilesChanged()
        await focus(tbA)
        #expect(fake.applied == [tbA, tbB, tbA])
        await focus(tbA)
        #expect(fake.applied == [tbA, tbB, tbA])
        // The user choosing it again also tries it again.
        follower.userChose(tbA)
        await focus(tbA)
        #expect(fake.applied == [tbA, tbB, tbA, tbA])
    }

    @Test func aSwitchThatLostTheServerToAnotherChangeIsTriedAgain() async {
        let fake = Fake()
        fake.busyAnswers = 2
        fake.wanted = SlangProfileAssignmentsTests.tbB
        let follower = fake.follower(debounce: .milliseconds(10))
        follower.activeFileChanged()
        await follower.waitUntilIdle()
        #expect(fake.applied == [SlangProfileAssignmentsTests.tbB])
        #expect(SlangProfileChoice(fake.current) == SlangProfileAssignmentsTests.tbB)
    }

    @Test func eachSettledFocusIsFollowed() async {
        let fake = Fake()
        let follower = fake.follower(debounce: .milliseconds(10))
        for choice in [SlangProfileAssignmentsTests.tbA, SlangProfileAssignmentsTests.tbB, SlangProfileAssignmentsTests.tbA] {
            fake.wanted = choice
            follower.activeFileChanged()
            await follower.waitUntilIdle()
        }
        #expect(fake.applied == [SlangProfileAssignmentsTests.tbA, SlangProfileAssignmentsTests.tbB, SlangProfileAssignmentsTests.tbA])
    }
}

/// A window becoming key (Cmd-`, a click on its title bar) makes its focused editor the active one.
@MainActor
@Suite struct SlangKeyWindowFollowTests {
    static let didBecomeKey = Notification.Name("cmux.test.didBecomeKey")

    final class Window {}

    @Test func eachKeyWindowIsReported() async throws {
        let center = NotificationCenter()
        var activated: [ObjectIdentifier] = []
        var follow: SlangKeyWindowFollow? = SlangKeyWindowFollow(center: center, name: Self.didBecomeKey) { object in
            if let window = object as? Window { activated.append(ObjectIdentifier(window)) }
        }
        let first = Window()
        let second = Window()
        center.post(name: Self.didBecomeKey, object: first)
        center.post(name: Self.didBecomeKey, object: second)
        for _ in 0..<50 where activated.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(activated == [ObjectIdentifier(first), ObjectIdentifier(second)])
        // Released: no more reports.
        follow = nil
        center.post(name: Self.didBecomeKey, object: first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(activated.count == 2)
        _ = follow
    }
}

#if os(macOS)
/// The follower driving a real slang-server between two testbench profiles of one design.
@MainActor
@Suite struct SlangProfileFollowServerTests {
    @Test func theServerFollowsEachTestbenchsProfile() async throws {
        let slangServer = SlangCompilationSessionTests.slangServer
        guard FileManager.default.isExecutableFile(atPath: slangServer) else { return }
        let rootURL = URL(fileURLWithPath: "/tmp").appendingPathComponent("cmux-slangprof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(".slang"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let root = LanguageServerSession.realPath(rootURL.path)
        try "module dut #(parameter W = 8) (input logic [W-1:0] a, output logic [W-1:0] y);\n  assign y = ~a;\nendmodule\n"
            .write(toFile: root + "/dut.sv", atomically: true, encoding: .utf8)
        for (tb, width) in [("tb_a", 8), ("tb_b", 16)] {
            try "module \(tb);\n  logic [\(width - 1):0] a, y;\n  dut #(.W(\(width))) u (.a, .y);\nendmodule\n"
                .write(toFile: "\(root)/\(tb).sv", atomically: true, encoding: .utf8)
            try "--top \(tb)\n\(root)/dut.sv\n\(root)/\(tb).sv\n".write(toFile: "\(root)/.slang/\(tb).f", atomically: true, encoding: .utf8)
        }
        let session = LanguageServerSession(launch: .local(executablePath: slangServer, arguments: []), rootURI: rootURL, languageId: "verilog")
        try await session.start()
        defer { Task { await session.shutdown() } }
        await session.open(uri: URL(fileURLWithPath: root + "/tb_a.sv"), text: try String(contentsOfFile: root + "/tb_a.sv", encoding: .utf8), version: 1)

        var assignments = SlangProfileAssignments()
        var activeFile = root + "/tb_a.sv"
        var switches = 0
        var slowest: TimeInterval = 0
        let follower = SlangProfileFollower(debounce: .milliseconds(30), hooks: .init(
            wanted: { assignments.choice(forFile: activeFile) },
            current: { await session.slangCompilationState },
            isBusy: { false },
            apply: { choice in
                let start = Date()
                defer { slowest = max(slowest, Date().timeIntervalSince(start)) }
                switches += 1
                guard let path = choice.path else { return .failed }
                guard FileManager.default.fileExists(atPath: path) else { return .missing }
                try? await session.slangSetBuildFile(path)
                return .applied
            },
            missing: { choice in choice.path.map { assignments.profileWasRemoved($0) } }
        ))
        assignments.choose(.buildFile(root + "/.slang/tb_a.f"), file: root + "/tb_a.sv")
        assignments.choose(.buildFile(root + "/.slang/tb_b.f"), file: root + "/tb_b.sv")

        func focus(_ file: String) async throws -> [String] {
            activeFile = root + "/" + file
            follower.activeFileChanged()
            await follower.waitUntilIdle()
            return try await session.slangScopeChildren("").filter { $0.kind != "Package" }.map(\.name)
        }
        #expect(try await focus("tb_a.sv") == ["tb_a"])
        #expect(try await focus("tb_b.sv") == ["tb_b"])
        #expect(try await focus("tb_a.sv") == ["tb_a"])
        // dut.sv chose nothing: it follows the profile set last (tb_b).
        #expect(try await focus("dut.sv") == ["tb_b"])
        #expect(switches == 4)
        // Focus back on the same profile: no recompile.
        #expect(try await focus("tb_b.sv") == ["tb_b"])
        #expect(switches == 4)
        // tb_b's profile deleted. It was also the last-set profile, so tb_b.sv falls back to
        // nothing set, and the server keeps what it compiles.
        try FileManager.default.removeItem(atPath: root + "/.slang/tb_b.f")
        #expect(try await focus("tb_a.sv") == ["tb_a"])
        #expect(try await focus("tb_b.sv") == ["tb_a"])
        #expect(switches == 6)
        #expect(assignments.ownChoice(forFile: root + "/tb_b.sv") == nil)
        #expect(assignments.lastSet == nil)
        #expect(assignments.choice(forFile: root + "/tb_a.sv") == .buildFile(root + "/.slang/tb_a.f"))
        print("slang profile switch: \(switches) switches, slowest \(String(format: "%.3f", slowest)) s")
    }
}
#endif
