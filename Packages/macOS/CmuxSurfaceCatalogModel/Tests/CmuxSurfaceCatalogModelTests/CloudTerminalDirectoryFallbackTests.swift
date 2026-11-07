import CmuxSurfaceCatalogModel
import Foundation
import Testing

@Suite struct CloudTerminalDirectoryFallbackTests {
    private typealias Fallback = CloudTerminalDirectoryFallback

    private func terminal(_ id: String, title: String, cwd: String? = "/home/u", cols: Int? = 80) -> CloudVMTerminalState {
        CloudVMTerminalState(id: id, tabIDs: ["tab-\(id)"], title: title, cwd: cwd, lifecycle: "running", cols: cols)
    }

    /// Drives one terminal with events far enough apart that spacing never delays a query.
    private final class Driver {
        var fallback = Fallback()
        var now: TimeInterval = 0
        var shown: Set<String> = ["t1"]

        func show(_ terminals: [CloudVMTerminalState]) -> [Fallback.Probe] {
            now += 10
            return fallback.observe(terminals, projected: shown, now: now)
        }

        func title(_ title: String, cwd: String? = "/home/u") -> Fallback.Probe? {
            show([CloudVMTerminalState(id: "t1", tabIDs: ["tab-t1"], title: title, cwd: cwd, lifecycle: "running", cols: 80)]).first
        }

        func finish(_ probe: Fallback.Probe, _ answer: Fallback.Answer) -> (directoryChanged: Bool, next: Fallback.Probe?) {
            now += 0.1
            return fallback.finish(probe, answer: answer, now: now)
        }
    }

    @Test func probesWhenShownAndOnEachTitleChangeOnly() throws {
        let driver = Driver()
        let first = try #require(driver.title("bash"))
        #expect(first.terminalID == "t1" && first.delay == 0)
        _ = driver.finish(first, .directory("/home/u"))
        // A resize is not a reason to ask again; a new title is.
        #expect(driver.show([terminal("t1", title: "bash", cols: 120)]).isEmpty)
        let renamed = try #require(driver.title("vim notes"))
        _ = driver.finish(renamed, .directory("/home/u"))
        // The same new title seen again (any later graph event) asks nothing.
        #expect(driver.title("vim notes") == nil)
        #expect(driver.show([terminal("t1", title: "vim notes", cols: 100)]).isEmpty)
    }

    /// The daemon publishes no graph event when a terminal's title changes; the title
    /// reaches the Mac only through the terminal's own output, so that is what asks again.
    @Test func aTitleTheTerminalSetAsksAgainWithoutAGraphEvent() throws {
        let driver = Driver()
        let first = try #require(driver.title("u@h:~"))
        _ = driver.finish(first, .directory("/home/u"))
        driver.now += 10
        let probe = try #require(driver.fallback.terminalTitleChanged("u@h: /etc", terminalID: "t1", now: driver.now))
        #expect(probe.terminalID == "t1")
        #expect(driver.finish(probe, .directory("/etc")).directoryChanged)
        #expect(driver.fallback.directory(forTerminal: "t1") == "/etc")
        // The same title again, or the graph's stale copy, asks nothing.
        driver.now += 10
        #expect(driver.fallback.terminalTitleChanged("u@h: /etc", terminalID: "t1", now: driver.now) == nil)
        #expect(driver.title("u@h:~") == nil)
    }

    @Test func aTerminalTitleIsIgnoredWhenNotShownOrReporting() throws {
        let driver = Driver()
        #expect(driver.fallback.terminalTitleChanged("x", terminalID: "t1", now: 1) == nil)
        let first = try #require(driver.title("a"))
        // During a query, a new title queues the one rerun.
        #expect(driver.fallback.terminalTitleChanged("b", terminalID: "t1", now: driver.now) == nil)
        #expect(driver.finish(first, .directory("/home/u")).next != nil)
        // A terminal that reports its own directory is not asked.
        let reporting = Driver()
        let probe = try #require(reporting.title("a"))
        _ = reporting.finish(probe, .directory("/home/u"))
        #expect(reporting.title("a", cwd: "/srv") == nil)
        reporting.now += 10
        #expect(reporting.fallback.terminalTitleChanged("c", terminalID: "t1", now: reporting.now) == nil)
    }

    /// tmux with `set-titles on` and a clock retitles every second and is always skipped.
    @Test func answersThatChangeNothingBackOff() throws {
        var fallback = Fallback()
        var starts: [TimeInterval] = []
        var running: Fallback.Probe?
        var startedAt: TimeInterval = 0
        func begin(_ probe: Fallback.Probe?, at now: TimeInterval) {
            guard let probe else { return }
            running = probe
            startedAt = now + probe.delay
            starts.append(startedAt)
        }
        for probe in fallback.observe([terminal("t1", title: "tmux 0")], projected: ["t1"], now: 0) { begin(probe, at: 0) }
        for step in 1...600 {
            let now = Double(step) / 10
            if let probe = running, now >= startedAt + 0.1 {
                running = nil
                begin(fallback.finish(probe, answer: .skipped, now: now).next, at: now)
            }
            if step % 10 == 0 {
                begin(fallback.terminalTitleChanged("tmux \(step)", terminalID: "t1", now: now), at: now)
            }
        }
        // 1 Hz without back-off would be about 60 starts in this minute.
        #expect(starts.count <= 12, "\(starts)")
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 <= Fallback.maximumProbeSpacing + 0.5 }, "\(gaps)")
        // A directory that changes resets the spacing.
        if let probe = running { _ = fallback.finish(probe, answer: .skipped, now: 100) }
        let a = try #require(fallback.terminalTitleChanged("a", terminalID: "t1", now: 200))
        _ = fallback.finish(a, answer: .directory("/x"), now: 200.1)
        let b = try #require(fallback.terminalTitleChanged("b", terminalID: "t1", now: 200.2))
        #expect(b.delay <= Fallback.minimumProbeSpacing, "\(b.delay)")
    }

    @Test func titleChangesDuringAQueryQueueOneRerun() throws {
        let driver = Driver()
        let probe = try #require(driver.title("a"))
        #expect(driver.title("b") == nil)
        #expect(driver.title("c") == nil)
        let rerun = try #require(driver.finish(probe, .directory("/home/u/a")).next)
        #expect(rerun.terminalID == "t1")
        #expect(driver.finish(rerun, .directory("/home/u/c")).next == nil)
        #expect(driver.fallback.directory(forTerminal: "t1") == "/home/u/c")
    }

    @Test func queryStartsAreSpacedWithATrailingRun() throws {
        // Titles every 50 ms for 5 s; each query takes 100 ms once started.
        var fallback = Fallback()
        let roundTrip: TimeInterval = 0.1
        let burstEnd: TimeInterval = 5
        var starts: [TimeInterval] = []
        var running: (probe: Fallback.Probe, finishesAt: TimeInterval)?
        func begin(_ probe: Fallback.Probe, at now: TimeInterval) {
            starts.append(now + probe.delay)
            running = (probe, now + probe.delay + roundTrip)
        }
        var lastTitle: TimeInterval = 0
        for step in 0...800 {
            let now = Double(step) / 100
            if let current = running, now >= current.finishesAt {
                running = nil
                let next = fallback.finish(current.probe, answer: .directory("/d\(step)"), now: now).next
                if let next { begin(next, at: now) }
            }
            if step % 5 == 0, now <= burstEnd {
                lastTitle = now
                for probe in fallback.observe([terminal("t1", title: "spin \(step)")], projected: ["t1"], now: now) {
                    begin(probe, at: now)
                }
            }
        }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 >= Fallback.minimumProbeSpacing - 1e-9 }, "\(starts)")
        #expect(starts.count <= Int(burstEnd / Fallback.minimumProbeSpacing) + 2, "\(starts)")
        // The last title still gets asked about.
        #expect((starts.last ?? 0) >= lastTitle, "\(starts)")
    }

    @Test func answerSetsTheDirectoryAndReportsChangesOnly() throws {
        let driver = Driver()
        let probe = try #require(driver.title("a"))
        #expect(driver.finish(probe, .directory("/srv/proj")).directoryChanged)
        #expect(driver.fallback.directory(forTerminal: "t1") == "/srv/proj")
        let again = try #require(driver.title("b"))
        #expect(!driver.finish(again, .directory("/srv/proj")).directoryChanged)
        // A failed or skipped query keeps the last answer.
        let failed = try #require(driver.title("c"))
        #expect(!driver.finish(failed, .failed).directoryChanged)
        let skipped = try #require(driver.title("d"))
        #expect(!driver.finish(skipped, .skipped).directoryChanged)
        #expect(driver.fallback.directory(forTerminal: "t1") == "/srv/proj")
    }

    @Test func aTerminalThatReportsItsDirectoryIsNeverAskedAgain() throws {
        let driver = Driver()
        let probe = try #require(driver.title("a", cwd: "/home/u"))
        // The shell reported a cd: the graph cwd moved off the spawn directory.
        #expect(driver.title("b", cwd: "/home/u/src") == nil)
        let late = driver.finish(probe, .directory("/somewhere/else"))
        #expect(!late.directoryChanged && late.next == nil)
        #expect(driver.fallback.directory(forTerminal: "t1") == nil)
        #expect(driver.title("c", cwd: "/home/u") == nil)
    }

    @Test func onlyShownTerminalsAreAskedAndGoneOnesAreForgotten() throws {
        let driver = Driver()
        driver.shown = ["t2"]
        #expect(driver.show([terminal("t1", title: "a"), terminal("t2", title: "a")]).map(\.terminalID) == ["t2"])
        #expect(driver.show([terminal("t1", title: "b"), terminal("t2", title: "a")]).isEmpty)
        driver.shown = ["t1", "t2"]
        let shown = driver.show([terminal("t1", title: "b"), terminal("t2", title: "a")])
        #expect(shown.map(\.terminalID) == ["t1"])
        let shownProbe = try #require(shown.first)
        // t1 closes while its query runs: the answer is dropped, and a new t1 starts fresh.
        #expect(driver.show([terminal("t2", title: "a")]).isEmpty)
        #expect(!driver.finish(shownProbe, .directory("/x")).directoryChanged)
        #expect(driver.fallback.directory(forTerminal: "t1") == nil)
        let reopened = driver.show([terminal("t1", title: "b"), terminal("t2", title: "a")])
        #expect(reopened.map(\.terminalID) == ["t1"])
        let reopenedProbe = try #require(reopened.first)
        #expect(!driver.finish(shownProbe, .directory("/stale")).directoryChanged)
        #expect(driver.finish(reopenedProbe, .directory("/fresh")).directoryChanged)
        #expect(driver.fallback.directory(forTerminal: "t1") == "/fresh")
    }

    @Test func repeatedFailuresStopTheQueries() throws {
        let driver = Driver()
        var probe = driver.title("0")
        for round in 1...Fallback.maximumFailedProbes {
            let current = try #require(probe, "round \(round)")
            _ = driver.finish(current, .failed)
            probe = driver.title("\(round)")
        }
        #expect(probe == nil)
    }

    @Test func aSuccessResetsTheFailureCount() throws {
        let driver = Driver()
        var title = 0
        func fail(_ driver: Driver) throws {
            title += 1
            _ = driver.finish(try #require(driver.title("\(title)")), .failed)
        }
        for _ in 1..<Fallback.maximumFailedProbes { try fail(driver) }
        title += 1
        _ = driver.finish(try #require(driver.title("\(title)")), .directory("/ok"))
        // Without the reset, these would be failures 3 and 4.
        for _ in 1..<Fallback.maximumFailedProbes { try fail(driver) }
        title += 1
        #expect(driver.title("\(title)") != nil)
    }

    @Test func skippedQueriesDoNotCountAsFailures() throws {
        let driver = Driver()
        for round in 0...(2 * Fallback.maximumFailedProbes) {
            let probe = try #require(driver.title("\(round)"), "round \(round)")
            _ = driver.finish(probe, .skipped)
        }
    }

    @Test func aTerminalShownAgainStartsOverAfterFailures() throws {
        let driver = Driver()
        var probe = driver.title("0")
        for round in 1...Fallback.maximumFailedProbes {
            _ = driver.finish(try #require(probe), .failed)
            probe = driver.title("\(round)")
        }
        #expect(probe == nil)
        driver.shown = []
        #expect(driver.show([terminal("t1", title: "x")]).isEmpty)
        driver.shown = ["t1"]
        #expect(driver.show([terminal("t1", title: "x")]).map(\.terminalID) == ["t1"])
    }

    @Test func tmuxAsTheForegroundProcessIsNotItsShellsDirectory() {
        for executable in ["tmux", "/usr/bin/tmux", "tmux: client", "/opt/homebrew/bin/tmux"] {
            #expect(Fallback.Answer(foregroundDirectory: "/home/u", foregroundExecutable: executable) == .skipped, "\(executable)")
        }
        for executable in [nil, "bash", "/usr/bin/fish", "-zsh", "vim", "tmuxinator-helper"] {
            #expect(Fallback.Answer(foregroundDirectory: "/home/u", foregroundExecutable: executable) == .directory("/home/u"),
                    "\(executable ?? "nil")")
        }
        #expect(Fallback.Answer(foregroundDirectory: nil, foregroundExecutable: "bash") == .failed)
    }
}
